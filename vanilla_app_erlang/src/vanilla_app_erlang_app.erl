-module(vanilla_app_erlang_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    Dispatch = cowboy_router:compile([
        {'_', [{"/items", items_handler, []}]}
    ]),
    Port = list_to_integer(os:getenv("PORT", "4000")),
    %% Deliberately no `stream_handlers` override here — a real vanilla
    %% Cowboy app has no reason to know about cowboy_telemetry, let alone
    %% OpenTelemetry. Zero-code instrumentation has to retrofit this from
    %% outside, after the listener is already running.
    {ok, _} = cowboy:start_clear(vanilla_http, [{port, Port}], #{
        env => #{dispatch => Dispatch}
    }),
    vanilla_app_erlang_sup:start_link().

stop(_State) ->
    ok.
