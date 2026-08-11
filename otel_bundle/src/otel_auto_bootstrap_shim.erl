%% Entry-point AND phase-0/1 loader for the -eval hook.
%%
%%   ERL_AFLAGS="-pa <bundle>/otel_auto_bootstrap/ebin -eval code:load_file(otel_auto_bootstrap_shim),otel_auto_bootstrap_shim:start()"
%%
%% Why this is Erlang, not Elixir, and why it owns more than just "find and
%% call the real entry point": OtelAutoBootstrap (the Elixir module that
%% does the actual SDK-start and instrumentation-activation work) is
%% Elixir bytecode. Calling ANY of its functions — even something as
%% innocuous as a log line, since Elixir string interpolation desugars to
%% Kernel/String.Chars calls — requires Elixir's own runtime (the `elixir`
%% OTP application: Kernel, IO, String, ...) to already be loaded.
%%
%% On a mix release host that's a non-issue: the release IS an Elixir app,
%% so Kernel is already resident before -eval ever runs. But this bundle
%% is also meant to instrument hosts that have no Elixir at all (a plain
%% rebar3/Cowboy release) — proven necessary, not hypothetical, by
%% `run_spike_erlang.sh`, which crashes with `{undef, ['Elixir.Kernel',
%% inspect, ...]}` the moment anything Elixir-flavored runs before the
%% bundle's own `elixir` app has been loaded. On such a host there is no
%% Elixir runtime for the bundle's Elixir code to lean on until THIS
%% module — plain Erlang, needs nothing but kernel/stdlib, which every
%% BEAM node has — has loaded it.
%%
%% So the loading of every module of every bundle application (including
%% bundle-shipped `elixir` and `logger`, when the host doesn't already
%% have them) has to happen in pure Erlang, before a single Elixir
%% function is called. That is everything below. Once it is done, control
%% passes to 'Elixir.OtelAutoBootstrap':run/0 for the parts that
%% legitimately benefit from being Elixir (SDK start, instrumentation
%% detection) — Kernel is loaded by then, so calling into it is safe.
-module(otel_auto_bootstrap_shim).

-export([start/0]).

-define(GUARD_KEY, {?MODULE, started}).

%% Guards against double invocation (e.g. reboot_system_after_config:
%% true, which runs the whole boot sequence — ERL_AFLAGS included — twice)
%% at the very first opportunity, before any path/module-loading work is
%% even attempted a second time.
start() ->
    case persistent_term:get(?GUARD_KEY, false) of
        true ->
            %% ASCII only: io:format's ~s on a non-unicode-configured
            %% device raises badarg on codepoints above 255 (an em dash
            %% crashed this exact line during testing).
            log("start/0 called again (reboot_system_after_config?); skipping - already bootstrapped"),
            ok;
        false ->
            persistent_term:put(?GUARD_KEY, true),
            %% Run asynchronously so a hang here can never block init.
            spawn(fun run/0),
            ok
    end.

run() ->
    try
        log(io_lib:format("starting; code mode: ~p", [code:get_mode()])),
        BundleLib = bundle_lib_dir(),
        Apps = list_bundle_apps(BundleLib),
        add_paths(Apps),
        Closure = dependency_closure([App || {App, _Ebin} <- Apps]),
        suppress_on_load_noise(fun() -> load_modules_multipass(Closure) end),
        log(io_lib:format("prepared ~p applications (bundle + dependency closure)", [length(Closure)])),
        hand_off_to_elixir()
    catch
        Kind:Reason ->
            log(io_lib:format("bootstrap failed: ~p ~p", [Kind, Reason]))
    end.

hand_off_to_elixir() ->
    case code:load_file('Elixir.OtelAutoBootstrap') of
        {module, Mod} ->
            Mod:run();
        Error ->
            log(io_lib:format("cannot load OtelAutoBootstrap: ~p", [Error]))
    end.

%% -- bundle discovery + code path -------------------------------------------

bundle_lib_dir() ->
    case os:getenv("OTEL_AUTO_BUNDLE_LIB") of
        false ->
            %% Fall back to deriving it from where this very module was
            %% loaded: <bundle>/otel_auto_bootstrap/ebin/otel_auto_bootstrap_shim.beam
            Ebin = filename:dirname(code:which(?MODULE)),
            filename:dirname(Ebin);
        Dir ->
            Dir
    end.

list_bundle_apps(BundleLib) ->
    {ok, Entries} = file:list_dir(BundleLib),
    [
        {app_name_from_dir(Dir), filename:join([BundleLib, Dir, "ebin"])}
     || Dir <- Entries,
        filelib:is_dir(filename:join(BundleLib, Dir))
    ].

app_name_from_dir(Dir) ->
    [NameStr | _] = string:split(Dir, "-"),
    list_to_atom(NameStr).

add_paths(Apps) ->
    lists:foreach(
        fun({_App, Ebin}) -> code:add_pathz(Ebin) end,
        Apps
    ).

%% -- dependency closure + multi-pass module loading -------------------------
%%
%% Embedded mode never loads modules on demand, so every module of every
%% needed application has to be loaded explicitly. "Needed" is the full
%% OTP dependency closure of the bundle apps, not just the bundle itself:
%% a pruned release omits OTP library applications (:inets, and on a
%% no-Elixir host, :elixir and :logger themselves) that the SDK or the
%% bootstrapper's own code requires — the bundle carries them and this
%% closure walk picks them up.
dependency_closure(Roots) ->
    walk(Roots, sets:new()).

walk([], Seen) ->
    sets:to_list(Seen);
walk([App | Rest], Seen) ->
    case sets:is_element(App, Seen) of
        true ->
            walk(Rest, Seen);
        false ->
            Deps =
                case application:load(App) of
                    ok ->
                        app_deps(App);
                    {error, {already_loaded, App}} ->
                        app_deps(App);
                    {error, Reason} ->
                        log(io_lib:format("cannot load app spec for ~p: ~p", [App, Reason])),
                        []
                end,
            walk(Rest ++ Deps, sets:add_element(App, Seen))
    end.

app_deps(App) ->
    case application:get_key(App, applications) of
        {ok, Deps} -> Deps;
        undefined -> []
    end.

%% Modules are loaded in multiple passes because -on_load hooks may call
%% sibling modules of the same application (tls_certificate_check does
%% exactly this); a module that fails in one pass usually succeeds once
%% the rest of its application has been loaded.
load_modules_multipass(Apps) ->
    Mods = lists:flatten([app_modules_to_load(App) || App <- Apps]),
    load_passes(Mods, 5).

app_modules_to_load(App) ->
    case application:get_key(App, modules) of
        {ok, Mods} -> [M || M <- Mods, not erlang:module_loaded(M)];
        undefined -> []
    end.

load_passes([], _) ->
    ok;
load_passes(Mods, 0) ->
    log(io_lib:format("gave up loading modules: ~p", [Mods]));
load_passes(Mods, PassesLeft) ->
    Failed = lists:filter(fun(Mod) -> not try_load(Mod) end, Mods),
    case Failed of
        [] -> ok;
        _ when length(Failed) =:= length(Mods) -> load_passes(Failed, 0);
        _ -> load_passes(Failed, PassesLeft - 1)
    end.

try_load(Mod) ->
    erlang:module_loaded(Mod) orelse
        case code:load_file(Mod) of
            {module, Mod} -> true;
            _ -> false
        end.

%% -- on_load noise suppression -----------------------------------------------
%%
%% -on_load hooks that fail on their first pass (see load_passes/2 above)
%% make the code server emit an error report + a warning report before
%% every retry succeeds (tls_certificate_check does this every run). Both
%% are expected noise from a mechanism working as designed, not a real
%% fault — suppressed for the duration of the load only, so any
%% *unrelated* logging from the same window still comes through.
suppress_on_load_noise(Fun) ->
    FilterId = otel_auto_bootstrap_on_load_noise,
    Filter = fun(Event, _Extra) ->
        Text = lists:flatten(io_lib:format("~p", [Event])),
        case string:find(Text, "on_load") =/= nomatch orelse
             string:find(Text, "code_server") =/= nomatch
        of
            true -> stop;
            false -> Event
        end
    end,
    ok = logger:add_primary_filter(FilterId, {Filter, []}),
    try
        Fun()
    after
        logger:remove_primary_filter(FilterId)
    end.

log(Msg) ->
    io:format("[otel_auto_bootstrap] ~s~n", [Msg]).
