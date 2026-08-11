defmodule OtelAutoBootstrapShimTest do
  use ExUnit.Case, async: true

  # otel_auto_bootstrap_shim is plain Erlang and does the real work (code
  # path setup, module loading) via side effects on the running VM — most
  # of it can only be verified end-to-end (run_spike.sh / run_spike_erlang.sh
  # actually boot a release and check spans land). These tests cover the
  # slice of that module that IS pure/deterministic, exported only under
  # MIX_ENV=test (see the module's -ifdef(TEST) block and mix.exs's
  # erlc_options).

  describe "app_name_from_dir/1" do
    test "splits a standard hex package dir name at the version" do
      assert :otel_auto_bootstrap_shim.app_name_from_dir(~c"cowboy-2.18.0") == :cowboy
    end

    test "handles underscores in the app name" do
      assert :otel_auto_bootstrap_shim.app_name_from_dir(~c"opentelemetry_semantic_conventions-1.27.0") ==
               :opentelemetry_semantic_conventions
    end

    test "known limitation: a hyphen in the app name itself splits at the first one" do
      # Same limitation the equivalent Elixir logic had before this got
      # moved into the shim (String.split(dir, "-") |> hd()) — documented
      # here as actual behavior, not asserted as correct. No app in the
      # bundle's own dependency tree has a hyphenated name.
      assert :otel_auto_bootstrap_shim.app_name_from_dir(~c"my-hyphenated-app-1.0.0") == :my
    end
  end

  describe "list_bundle_apps/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "otel_shim_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "cowboy-2.18.0/ebin"))
      File.mkdir_p!(Path.join(dir, "cowlib-2.19.0/ebin"))
      File.write!(Path.join(dir, "not_a_dir.txt"), "should be skipped")
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "returns {app, ebin_path} for every subdirectory, skipping plain files", %{dir: dir} do
      apps = :otel_auto_bootstrap_shim.list_bundle_apps(String.to_charlist(dir))

      assert {:cowboy, cowboy_ebin} = List.keyfind(apps, :cowboy, 0)
      assert {:cowlib, cowlib_ebin} = List.keyfind(apps, :cowlib, 0)
      assert List.to_string(cowboy_ebin) == Path.join(dir, "cowboy-2.18.0/ebin")
      assert List.to_string(cowlib_ebin) == Path.join(dir, "cowlib-2.19.0/ebin")
      assert length(apps) == 2
    end
  end

  describe "dependency_closure/1" do
    test "includes every root app, even ones with no further dependencies" do
      closure = :otel_auto_bootstrap_shim.dependency_closure([:kernel])
      assert :kernel in closure
    end

    test "walks transitive deps: :crypto declares [kernel, stdlib], both end up in the closure" do
      # :kernel itself declares NO application dependencies (it's the
      # foundational app the emulator starts before the rest of the
      # dependency graph makes sense) — :crypto is a real, always-present
      # OTP app that actually declares transitive deps, so it's a
      # meaningfully different case from the "root app itself" test above.
      closure = :otel_auto_bootstrap_shim.dependency_closure([:crypto])
      assert :crypto in closure
      assert :kernel in closure
      assert :stdlib in closure
    end

    test "is a set: duplicate/overlapping roots don't duplicate entries" do
      closure = :otel_auto_bootstrap_shim.dependency_closure([:kernel, :kernel, :stdlib])
      assert length(closure) == length(Enum.uniq(closure))
    end

    test "an app with no findable spec is still included in the closure, not crashed on" do
      # Mirrors what happens for a genuinely missing OTP library app in the
      # bundle (the :inets / :compiler / :eex findings from the spikes) —
      # application:load/1 fails, gets logged, and the walk continues
      # rather than raising.
      closure = :otel_auto_bootstrap_shim.dependency_closure([:this_app_does_not_exist_anywhere])
      assert closure == [:this_app_does_not_exist_anywhere]
    end
  end

  describe "try_load/1" do
    test "returns true immediately for an already-loaded module without reloading it" do
      assert :erlang.module_loaded(:lists)
      assert :otel_auto_bootstrap_shim.try_load(:lists) == true
    end

    test "returns false for a module that cannot be found, without crashing" do
      assert :otel_auto_bootstrap_shim.try_load(:this_module_does_not_exist_anywhere) == false
    end
  end
end
