Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.SpawnChokepointTest do
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  alias Mix.Tasks.Ezagent.Arch.Scan

  test "SpawnRegistry spawn writers do not grow beyond baseline" do
    assert_at_or_below(:spawn_registry_call_sites)
    assert_at_or_below(:spawn_registry_modules)
    assert_at_or_below(:spawn_registry_off_chokepoint_modules)
  end

  test "create_session/3 caller surface does not grow beyond baseline" do
    assert_at_or_below(:create_session_call_sites)
    assert_at_or_below(:create_session_modules)
  end

  test "spawn_fresh audit surface is frozen and unsanctioned calls stay zero" do
    assert_at_or_below(:spawn_fresh_audit_references)
    assert_zero(:spawn_fresh_unsanctioned)
  end

  # --- teeth-tests for the 2026-07 batch-1 AST conversion --------------------
  #
  # Each proves the AST matcher STILL FIRES and — the robustness gain — catches
  # an ALIASED call a raw `SpawnRegistry.spawn(` / `.create_session(` grep would
  # miss, while ignoring the moduledoc/comment/capture forms grep over-counted.

  describe "spawn_registry AST matcher (teeth)" do
    test "counts an ALIASED SR.spawn(...) a raw grep would miss" do
      source = """
      defmodule Caller do
        @moduledoc "prose mentioning SpawnRegistry.spawn(uri) — must NOT count"
        alias Ezagent.SpawnRegistry, as: SR

        def go(uri), do: SR.spawn(uri)
      end
      """

      # robustness gain, made explicit: the raw per-line regex the old gate used
      # does NOT see the aliased CALL line; the AST matcher does. (The moduledoc
      # prose line DOES contain the literal text — exactly the doc/comment
      # over-count the AST also eliminates: total stays 1, the real SR.spawn call.)
      refute Regex.match?(~r/SpawnRegistry\.spawn\(/, "def go(uri), do: SR.spawn(uri)")
      assert Scan.count_spawn_registry_calls_in_source(source) == 1
    end

    test "counts a fully-qualified spawn_detailed; ignores captures + doc mentions" do
      source = """
      defmodule Caller do
        # a commented-out Ezagent.SpawnRegistry.spawn(uri) — must NOT count
        def go(uri), do: Ezagent.SpawnRegistry.spawn_detailed(uri)
        def cap, do: &Ezagent.SpawnRegistry.spawn/1
      end
      """

      assert Scan.count_spawn_registry_calls_in_source(source) == 1
    end

    test "`# arch-allow:` suppresses a flagged call site" do
      source = """
      defmodule Caller do
        alias Ezagent.SpawnRegistry, as: SR
        def go(uri), do: SR.spawn(uri) # arch-allow: sanctioned in test fixture
      end
      """

      assert Scan.count_spawn_registry_calls_in_source(source) == 0
    end

    test "does NOT count an unrelated *SpawnRegistry look-alike or a plain .spawn" do
      source = """
      defmodule Caller do
        def a(uri), do: MyOwnSpawnRegistry.spawn(uri)
        def b(pid), do: Task.Supervisor.spawn(pid)
      end
      """

      assert Scan.count_spawn_registry_calls_in_source(source) == 0
    end
  end

  describe "create_session AST matcher (teeth)" do
    test "counts an ALIASED WS.create_session(...) a raw grep would miss" do
      source = """
      defmodule Caller do
        alias Ezagent.Workspace, as: WS

        def go(a, b, c), do: WS.create_session(a, b, c)
      end
      """

      refute Enum.any?(
               String.split(source, "\n"),
               &Regex.match?(~r/Ezagent\.Workspace\.create_session\(/, &1)
             )

      assert Scan.count_create_session_calls_in_source(source) == 1
    end

    test "ignores a `&Mod.create_session/3` capture (grep never matched it either)" do
      source = """
      defmodule Caller do
        def go, do: run(&Ezagent.Workspace.create_session/3)
        defp run(f), do: f
      end
      """

      assert Scan.count_create_session_calls_in_source(source) == 0
    end

    test "counts a variable-receiver facade.create_session(...) call" do
      source = """
      defmodule Caller do
        def go(facade, a, b), do: facade.create_session(a, b)
      end
      """

      assert Scan.count_create_session_calls_in_source(source) == 1
    end
  end
end
