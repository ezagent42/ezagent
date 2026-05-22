defmodule Mix.Tasks.Compile.EzagentPluginCheckTest do
  @moduledoc """
  Tests for the `:ezagent_plugin_check` Mix compiler (SPEC §3.2 +
  codex PR-5 HIGH-3).

  The behaviour pinned here:

  - **A non-`ezagent_plugin_*` app with no `:ezagent_plugin` key →
    no-op pass.** `ezagent_core` (the project this suite runs in)
    sets no key and is not `ezagent_plugin_*`, so calling `run/1`
    here exercises exactly that path.

  - **An `ezagent_plugin_*` app with NO `:ezagent_plugin` key → the
    build FAILS** (codex PR-5 HIGH-3 — the bypass fix). This is the
    REAL negative test: it enters an actual non-conforming plugin Mix
    project (`test/fixtures/ezagent_plugin_broken`) via
    `Mix.Project.in_project/4` and asserts the real compiler returns
    `{:error, [diagnostic]}`. Before the fix the same project
    compiled cleanly (the gate was a no-op when un-keyed).

  - **A conforming `ezagent_plugin_*` fixture passes** — the positive
    control, proving it is the MISSING key (not "being a fixture")
    that fails the broken project.

  The cross-module / scheme / config-surface / grep checks run only
  once an app sets `:ezagent_plugin`; they are integration-exercised
  by the 5 real migrated plugins' own contract suites + a full
  `mix compile` of the umbrella.
  """

  use ExUnit.Case, async: false

  alias Mix.Tasks.Compile.EzagentPluginCheck

  @fixtures_dir Path.expand("../fixtures", __DIR__)

  test "is a no-op pass for a non-plugin app with no :ezagent_plugin key" do
    # ezagent_core declares no :ezagent_plugin key and is not an
    # ezagent_plugin_* app — the genuine no-op case.
    assert {:ok, []} = EzagentPluginCheck.run([])
  end

  test "is a Mix.Task.Compiler" do
    behaviours =
      EzagentPluginCheck.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert Mix.Task.Compiler in behaviours
  end

  describe "codex PR-5 HIGH-3 — an ezagent_plugin_* app with no :ezagent_plugin key FAILS" do
    test "the gate FAILS for a non-conforming ezagent_plugin_* project" do
      # REAL negative test: enter the actual broken plugin Mix project
      # (its mix.exs names the app `ezagent_plugin_broken`, wires the
      # :ezagent_plugin_check compiler, and OMITS the :ezagent_plugin
      # env key) and run the real compiler against it.
      result =
        in_fixture_project(:ezagent_plugin_broken, "ezagent_plugin_broken", fn ->
          EzagentPluginCheck.run([])
        end)

      assert {:error, diagnostics} = result,
             "an ezagent_plugin_* app that omits the :ezagent_plugin key must " <>
               "FAIL the build (codex PR-5 HIGH-3) — got #{inspect(result)}"

      assert [%Mix.Task.Compiler.Diagnostic{} = diag] = diagnostics
      assert diag.severity == :error
      assert diag.message =~ "ezagent_plugin_*"
      assert diag.message =~ ":ezagent_plugin"

      assert diag.message =~ "ezagent_plugin_broken",
             "the diagnostic should name the offending app"
    end

    test "the gate PASSES for a conforming ezagent_plugin_* project (positive control)" do
      # Same fixture shape, but it DOES declare the :ezagent_plugin key
      # → the gate has a contract module and the (correct) module
      # passes every check. Proves it is the MISSING key that fails
      # the broken project, not merely being a fixture.
      #
      # The gate dereferences the configured module via
      # `Code.ensure_compiled/1`, so the conforming module must be
      # loaded. Compile its real source file (the actual fixture .ex,
      # not a mock) before entering the project.
      unless Code.ensure_loaded?(EzagentPluginConforming) do
        Code.compile_file(
          Path.join([@fixtures_dir, "ezagent_plugin_conforming", "lib", "ezagent_plugin_conforming.ex"])
        )
      end

      result =
        in_fixture_project(:ezagent_plugin_conforming, "ezagent_plugin_conforming", fn ->
          EzagentPluginCheck.run([])
        end)

      assert {:ok, []} = result,
             "a conforming ezagent_plugin_* app must pass the gate — got #{inspect(result)}"
    end
  end

  # Enter a fixture Mix project so `Mix.Project.config()` (read by the
  # compiler) reflects the FIXTURE's mix.exs — `:app` becomes the
  # fixture app name, `:application[:env]` reflects its (missing or
  # present) :ezagent_plugin key. This is what makes the test REAL:
  # the compiler runs against an actual non-conforming plugin project,
  # not a mock. `Mix.Project.in_project/4` pushes/pops the project
  # stack and evaluates the fixture mix.exs.
  defp in_fixture_project(app, dir_name, fun) do
    path = Path.join(@fixtures_dir, dir_name)
    Mix.Project.in_project(app, path, fn _module -> fun.() end)
  end
end
