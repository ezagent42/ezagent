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

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

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
          Path.join([
            @fixtures_dir,
            "ezagent_plugin_conforming",
            "lib",
            "ezagent_plugin_conforming.ex"
          ])
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

  describe "ExternalMirror PR-EM-1 — adapters/0 Grill-5 checks" do
    @moduledoc """
    SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
    §5.1 + §9 PR-EM-1 acceptance tests 4 + 5.

    Verifies the `:ezagent_plugin_check` compiler rejects:
    - (i) a plugin where a single module implements BOTH Adapter and
      Binding behaviours (Grill-5 e).
    - (ii) a plugin where `adapter.binding_module()` != binding
      module declared in `adapters/0` (Grill-5 c).

    Positive control: a plugin declaring one valid pair passes.
    """

    test "PASSES for a fixture declaring one valid (adapter, binding) pair (positive control)" do
      compile_fixture_module(
        "ezagent_plugin_em_conforming",
        "ezagent_plugin_em_conforming.ex"
      )

      result =
        in_fixture_project(:ezagent_plugin_em_conforming, "ezagent_plugin_em_conforming", fn ->
          EzagentPluginCheck.run([])
        end)

      assert {:ok, []} = result,
             "a conforming ExternalMirror plugin must pass the gate — got #{inspect(result)}"
    end

    test "FAILS for a fixture where a single module implements BOTH behaviours (test 4 / Grill-5 e)" do
      compile_fixture_module("ezagent_plugin_em_dual", "ezagent_plugin_em_dual.ex")

      # The `em_dual` fixture deliberately implements BOTH @behaviour
      # Adapter AND @behaviour Binding to exercise this COMPILE-time gate.
      # Once `Code.compile_file/1` loads it, it lingers in the BEAM's
      # module table and `:code.all_loaded/0` reflects it — which makes
      # `BindingAdapterGrill5Test`'s RUNTIME (e) sweep flag it as a real
      # production violation under cross-app concurrency. Purge it once
      # this test (the only one that needs it loaded) finishes.
      on_exit(fn ->
        :code.purge(EzagentPluginEmDual.DualModule)
        :code.delete(EzagentPluginEmDual.DualModule)
        :code.purge(EzagentPluginEmDual.DualModule)
      end)

      result =
        in_fixture_project(:ezagent_plugin_em_dual, "ezagent_plugin_em_dual", fn ->
          EzagentPluginCheck.run([])
        end)

      assert {:error, diagnostics} = result

      assert Enum.any?(diagnostics, fn %{message: msg} ->
               msg =~ "DIFFERENT modules" and msg =~ "Grill-5"
             end),
             "expected a Grill-5 (e) `DIFFERENT modules` diagnostic; got #{inspect(diagnostics)}"
    end

    test "FAILS for a fixture where adapter.binding_module() != declared binding (test 5 / Grill-5 c)" do
      compile_fixture_module("ezagent_plugin_em_mismatch", "ezagent_plugin_em_mismatch.ex")

      result =
        in_fixture_project(:ezagent_plugin_em_mismatch, "ezagent_plugin_em_mismatch", fn ->
          EzagentPluginCheck.run([])
        end)

      assert {:error, diagnostics} = result

      assert Enum.any?(diagnostics, fn %{message: msg} ->
               msg =~ "binding_module" and msg =~ "Grill-5"
             end),
             "expected a Grill-5 (c) bidirectional-mismatch diagnostic; got #{inspect(diagnostics)}"
    end

    # P3-1 Finding 1 — the compiler gate must ACCEPT a binding-less
    # `:pull` adapter declared as a BARE module (no `{adapter, binding}`
    # tuple, no binding required).
    test "PASSES for a fixture declaring a binding-less :pull adapter as a BARE module (P3-1)" do
      compile_fixture_module("ezagent_plugin_em_pull", "ezagent_plugin_em_pull.ex")

      result =
        in_fixture_project(:ezagent_plugin_em_pull, "ezagent_plugin_em_pull", fn ->
          EzagentPluginCheck.run([])
        end)

      assert {:ok, []} = result,
             "a conforming bare-module :pull adapter must pass the gate — " <>
               "got #{inspect(result)}"
    end
  end

  describe "check 7 — direct *Registry.register grep gate + build-time Mix-task exemption (#1476)" do
    # SPEC §3.2 "declare, don't call": the gate greps a plugin app's
    # source for direct `*Registry.register` / `declare_table` calls and
    # fails the build. #1476 EXEMPTS build-time Mix tasks
    # (`<elixirc_path>/mix/tasks/**.ex`) — a Mix task is dev tooling, never
    # on the running app's boot path, so seeding a registry there (e.g.
    # `mix world.e2e.fixtures`, the crash-fix that surfaced this) is
    # legitimate. These two tests pin BOTH directions so the exemption can
    # never silently become a blanket disable of the gate.
    #
    # Both fixtures reuse the conforming contract module (`:ezagent_plugin
    # -> EzagentPluginConforming`) so every check EXCEPT check 7 passes and
    # the result is attributable to check 7 alone. Ensure it is loaded.
    setup do
      compile_fixture_module("ezagent_plugin_conforming", "ezagent_plugin_conforming.ex")
      :ok
    end

    test "FAILS when RUNTIME plugin lib code calls *Registry.register directly" do
      result =
        in_fixture_project(:ezagent_plugin_reg_runtime, "ezagent_plugin_reg_runtime", fn ->
          EzagentPluginCheck.run([])
        end)

      assert {:error, diagnostics} = result

      assert Enum.any?(diagnostics, fn %{message: msg} ->
               msg =~ "Registry.register" and msg =~ "grep gate"
             end),
             "runtime plugin code calling *Registry.register directly must STILL " <>
               "be flagged by check 7 after the mix-task exemption — " <>
               "got #{inspect(diagnostics)}"

      assert Enum.any?(diagnostics, fn %{message: msg} ->
               msg =~ "runtime_bad_registration.ex"
             end),
             "the check-7 diagnostic should name the offending runtime file"
    end

    test "PASSES when the *Registry.register call is inside a build-time Mix task (exemption)" do
      result =
        in_fixture_project(:ezagent_plugin_reg_mixtask, "ezagent_plugin_reg_mixtask", fn ->
          EzagentPluginCheck.run([])
        end)

      assert {:ok, []} = result,
             "a *Registry.register call inside lib/mix/tasks/** is build-time " <>
               "tooling and MUST be exempt from check 7 (#1476) — got #{inspect(result)}"
    end
  end

  # Compile a fixture's plugin .ex file into the loaded code path so
  # `Code.ensure_compiled/1` (called inside the gate) resolves the
  # fixture modules. Same pattern as the original conforming test.
  defp compile_fixture_module(fixture_dir, source_file) do
    path = Path.join([@fixtures_dir, fixture_dir, "lib", source_file])
    Code.compile_file(path)
  rescue
    # Already loaded — that's the desired post-condition.
    _ -> :ok
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
