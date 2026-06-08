defmodule Ezagent.UriQuery.ScanHomePathTest do
  use ExUnit.Case, async: true

  alias Ezagent.UriQuery.Scan
  alias Ezagent.UriQuery.Scan.HomePathBaseline
  alias Ezagent.UriQuery.Scan.HomePathExceptions

  describe "S-1: hard-fail-new" do
    test "a new unbaselined runtime Home.path call is flagged home_path_in_runtime_code" do
      path =
        fixture!("new_raw_home_call.ex", """
        defmodule Fixture.NewRawHomeCall do
          def bad, do: Path.join(Ezagent.Home.path("uploads"), "x")
        end
        """)

      violations = Scan.scan_paths([path], baseline: [], exceptions: [])
      assert Enum.any?(violations, &(&1.category == :home_path_in_runtime_code))
    end

    test "matches the aliased `Home.path` form (alias Ezagent.Home; Home.path(...))" do
      path =
        fixture!("aliased_home_call.ex", """
        defmodule Fixture.AliasedHomeCall do
          alias Ezagent.Home
          def bad, do: Path.join(Home.path(:uploads), "x")
        end
        """)

      violations = Scan.scan_paths([path], baseline: [], exceptions: [])
      assert Enum.any?(violations, &(&1.category == :home_path_in_runtime_code))
    end

    test "matches profile_dir/0 and home/0" do
      path =
        fixture!("profile_dir_home_call.ex", """
        defmodule Fixture.ProfileDirHomeCall do
          def a, do: Ezagent.Home.profile_dir()
          def b, do: Ezagent.Home.home()
        end
        """)

      violations =
        Scan.scan_paths([path], baseline: [], exceptions: [])
        |> Enum.filter(&(&1.category == :home_path_in_runtime_code))

      assert length(violations) == 2
    end

    test "matches a RENAMED alias form (alias Ezagent.Home, as: H; H.path(...)) — codex HIGH" do
      path =
        fixture!("renamed_alias_home_call.ex", """
        defmodule Fixture.RenamedAlias do
          alias Ezagent.Home, as: H
          def bad, do: Path.join(H.path(:uploads), "x")
        end
        """)

      violations =
        Scan.scan_paths([path], baseline: [], exceptions: [])
        |> Enum.filter(&(&1.category == :home_path_in_runtime_code))

      assert length(violations) == 1
    end

    test "matches an imported bare call (import Ezagent.Home; path(...)) — codex HIGH" do
      path =
        fixture!("imported_home_call.ex", """
        defmodule Fixture.ImportedHome do
          import Ezagent.Home
          def bad, do: Path.join(path(:uploads), "x")
        end
        """)

      violations =
        Scan.scan_paths([path], baseline: [], exceptions: [])
        |> Enum.filter(&(&1.category == :home_path_in_runtime_code))

      assert length(violations) == 1
    end

    test "matches the __MODULE__.Home.path(...) shape (codex round-2 HIGH)" do
      path =
        fixture!("module_home_call.ex", """
        defmodule Fixture.ModuleHome do
          def bad, do: Path.join(__MODULE__.Home.path(:uploads), "x")
        end
        """)

      violations =
        Scan.scan_paths([path], baseline: [], exceptions: [])
        |> Enum.filter(&(&1.category == :home_path_in_runtime_code))

      assert length(violations) == 1
    end

    test "respects `import Ezagent.Home, only: [...]` excluding path (no false positive)" do
      path =
        fixture!("import_only_home.ex", """
        defmodule Fixture.ImportOnly do
          import Ezagent.Home, only: [home: 0]
          def local_path(x), do: x
          def use_it, do: local_path(:something)
        end
        """)

      violations =
        Scan.scan_paths([path], baseline: [], exceptions: [])
        |> Enum.filter(&(&1.category == :home_path_in_runtime_code))

      # `path` was NOT imported; the bare local `local_path` is irrelevant.
      assert violations == []
    end

    test "respects `import Ezagent.Home, except: [...]` (path still in scope fires)" do
      path =
        fixture!("import_except_home.ex", """
        defmodule Fixture.ImportExcept do
          import Ezagent.Home, except: [home: 0]
          def bad, do: Path.join(path(:uploads), "x")
        end
        """)

      violations =
        Scan.scan_paths([path], baseline: [], exceptions: [])
        |> Enum.filter(&(&1.category == :home_path_in_runtime_code))

      assert length(violations) == 1
    end

    test "does NOT match a bare local `path/1` call when Home is not imported" do
      path =
        fixture!("local_path_fn.ex", """
        defmodule Fixture.LocalPathFn do
          def path(x), do: x
          def use_it, do: path(:something)
        end
        """)

      violations =
        Scan.scan_paths([path], baseline: [], exceptions: [])
        |> Enum.filter(&(&1.category == :home_path_in_runtime_code))

      assert violations == []
    end

    test "does NOT flag a local `Home` struct/var field access" do
      path =
        fixture!("local_home_field.ex", """
        defmodule Fixture.LocalHomeField do
          def ok(%{home: home}), do: home.path
        end
        """)

      violations =
        Scan.scan_paths([path], baseline: [], exceptions: [])
        |> Enum.filter(&(&1.category == :home_path_in_runtime_code))

      assert violations == []
    end
  end

  describe "exempt anchors" do
    test "an exact-anchor exemption passes (no violation for the matching def)" do
      path =
        fixture!("exempt_anchor.ex", """
        defmodule Fixture.Boot do
          def cookie_path do
            Path.join(Ezagent.Home.profile_dir(), "runtime/cookie")
          end
        end
        """)

      # Home.profile_dir() is on line 3 of the fixture, enclosed by
      # Fixture.Boot.cookie_path/0.
      exceptions = [{path, "Fixture.Boot.cookie_path/0", 3, "test boot exemption"}]

      violations =
        Scan.scan_paths([path], baseline: [], exceptions: exceptions)
        |> Enum.filter(&(&1.category == :home_path_in_runtime_code))

      assert violations == []
    end

    test "an exemption with a WRONG enclosing function does NOT exempt the call" do
      path =
        fixture!("wrong_anchor.ex", """
        defmodule Fixture.Boot do
          def cookie_path do
            Path.join(Ezagent.Home.profile_dir(), "runtime/cookie")
          end
        end
        """)

      # Same {path, line} but a function id that does not match the enclosing fn.
      exceptions = [{path, "Fixture.Boot.something_else/0", 3, "mismatched anchor"}]

      violations =
        Scan.scan_paths([path], baseline: [], exceptions: exceptions)
        |> Enum.filter(&(&1.category == :home_path_in_runtime_code))

      assert length(violations) == 1
    end

    test "a baselined call at its recorded {path, line} is tolerated" do
      path =
        fixture!("baselined_call.ex", """
        defmodule Fixture.Baselined do
          def dir, do: Ezagent.Home.path(:uploads)
        end
        """)

      violations =
        Scan.scan_paths([path], baseline: [{path, 2, "Home.path(:uploads)"}], exceptions: [])
        |> Enum.filter(&(&1.category == :home_path_in_runtime_code))

      assert violations == []
    end

    test "a SECOND Home call on a baselined line is NOT tolerated (codex MEDIUM)" do
      path =
        fixture!("dup_on_baselined_line.ex", """
        defmodule Fixture.DupOnLine do
          def dir, do: {Ezagent.Home.path(:uploads), Ezagent.Home.path(:logs)}
        end
        """)

      # Baseline records ONE call on line 2; the file now has TWO. The second is
      # a new caller and must fire even though the line is baselined.
      violations =
        Scan.scan_paths([path], baseline: [{path, 2, "Home.path(:uploads)"}], exceptions: [])
        |> Enum.filter(&(&1.category == :home_path_in_runtime_code))

      assert length(violations) == 1
    end

    test "two baselined calls on one line (budget 2) are both tolerated" do
      path =
        fixture!("two_baselined_on_line.ex", """
        defmodule Fixture.TwoOnLine do
          def dir, do: {Ezagent.Home.path(:uploads), Ezagent.Home.path(:logs)}
        end
        """)

      violations =
        Scan.scan_paths([path],
          baseline: [{path, 2, "Home.path(:uploads)"}, {path, 2, "Home.path(:logs)"}],
          exceptions: []
        )
        |> Enum.filter(&(&1.category == :home_path_in_runtime_code))

      assert violations == []
    end

    test "a baselined call MOVED to a different line is NOT tolerated" do
      path =
        fixture!("moved_baseline_call.ex", """
        defmodule Fixture.Moved do
          # a comment to push the call down a line
          def dir, do: Ezagent.Home.path(:uploads)
        end
        """)

      # Baseline records line 2, but the call is on line 3 now.
      violations =
        Scan.scan_paths([path], baseline: [{path, 2, "Home.path(:uploads)"}], exceptions: [])
        |> Enum.filter(&(&1.category == :home_path_in_runtime_code))

      assert length(violations) == 1
    end
  end

  describe "category registration" do
    test "category is registered in known_categories" do
      assert :home_path_in_runtime_code in Scan.known_categories()
    end
  end

  describe "S-2: exact-anchor exemptions (no glob/prefix)" do
    test "every exception is a strict Module.function/arity anchor (no glob/prefix)" do
      assert HomePathExceptions.malformed_entries() == []
      refute HomePathExceptions.any_glob_or_prefix?()
    end

    test "each apps/ exception matches EXACTLY one current Home call at its anchor" do
      for {path, fun_id, line, _reason} <- HomePathExceptions.app_anchors() do
        assert Scan.home_call_anchor_matches?(path, fun_id, line),
               "exception #{fun_id} @ #{path}:#{line} does not map to exactly one Home call"
      end
    end
  end

  describe "S-3: green on the live tree" do
    test "category is GREEN on the live tree (baseline + exceptions cover all callers)" do
      violations =
        Scan.scan()
        |> Enum.filter(&(&1.category == :home_path_in_runtime_code))

      assert violations == [],
             "unbaselined runtime Home.path callers: #{inspect(violations)}"
    end

    test "every baseline entry maps to a real Home call at its {path, line}" do
      for {path, line, _call} <- HomePathBaseline.all() do
        assert Scan.home_call_at_line?(path, line),
               "baseline #{path}:#{line} no longer maps to a Home call (stale anchor)"
      end
    end
  end

  defp fixture!(name, source) do
    dir =
      Path.join(System.tmp_dir!(), "ezagent-home-path-scan-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    on_exit(fn -> File.rm_rf(dir) end)
    path
  end
end
