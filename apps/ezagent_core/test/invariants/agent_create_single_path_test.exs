defmodule EzagentCore.Invariants.AgentCreateSinglePathTest do
  @moduledoc """
  Single-path invariant for agent creation (SPEC
  `docs/superpowers/specs/2026-05-25-agent-create-cli-gui-parity.md` §4).

  After SPEC 2026-05-25 (Allen directive — CLI ↔ GUI parity), the
  unified entry for operator-facing agent creation is
  `Ezagent.Workspace.create_agent/3` which dispatches
  `Behavior.Workspace.:create_agent`. The action body owns the only
  legitimate `SpawnRegistry.spawn(...)` call site for
  `entity://agent/` URIs in production code outside the allowlist.

  This test fails if a future PR re-introduces a CLI / LV / mix task /
  controller that directly spawns an `entity://agent/` URI without
  going through the dispatched action — the exact "bypasses dispatch"
  failure mode the 2026-05-24 audit flagged (`docs/futures/todo.md`
  § "CLI ↔ GUI parity").

  Mirrors the pattern of
  `single_capability_registration_entry_test.exs` /
  `single_spawn_entry_test.exs`.
  """

  use ExUnit.Case, async: true

  # Forbidden: any production-code call to `SpawnRegistry.spawn` or
  # `SpawnRegistry.spawn_detailed` where the argument string contains
  # the entity-agent URI scheme.
  #
  # The regex catches:
  #   SpawnRegistry.spawn(entity://agent/...)
  #   Ezagent.SpawnRegistry.spawn(entity://agent/...)
  #   SpawnRegistry.spawn(URI.new!("entity://agent/..."))  (the URI
  #     literal inside the call appears verbatim)
  #
  # The arg may also be a variable — those cases need contextual
  # judgement and are NOT caught by this regex; the allowlist captures
  # the modules that legitimately call spawn with an `entity://agent/`
  # variable argument (e.g. the action body, the reconciler).
  @forbidden_with_literal ~r/(?<![\.\w])SpawnRegistry\.spawn(?:_detailed)?\s*\(\s*[^)]*entity:\/\/agent/

  # Modules allowed to call `SpawnRegistry.spawn(...)` with an
  # `entity://agent/` URI. Each entry has a justification in
  # `docs/superpowers/specs/2026-05-25-agent-create-cli-gui-parity.md`.
  @allowlist [
    # The unified create_agent action body — the ONE operator-facing
    # legitimate create path.
    "apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex",
    # Reconciler / spawn_fresh path (orchestrator-spawned workers).
    # PR-9a (#53): Agent Kind relocated to the ezagent_domain_agent app.
    "apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex",
    # The reconciler module itself.
    "apps/ezagent_domain_session/lib/ezagent/orchestrator/reconciler.ex",
    # SpawnRegistry itself.
    "apps/ezagent_actor/lib/ezagent/spawn_registry.ex"
  ]

  test "operator-facing agent create goes through Behavior.Workspace.:create_agent only" do
    apps_root = Path.expand("../../../..", __DIR__)
    production_files = list_production_files(apps_root)

    violations =
      Enum.flat_map(production_files, fn rel_path ->
        full = Path.join(apps_root, rel_path)

        # Strip single-line comments first — moduledoc / @doc strings
        # routinely describe the spawn call as documentation
        # (`# We DELIBERATELY do SpawnRegistry.spawn(entity://agent/...)`).
        content =
          full
          |> File.read!()
          |> String.split("\n")
          |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
          |> Enum.join("\n")

        if Regex.match?(@forbidden_with_literal, content) and rel_path not in @allowlist do
          [rel_path]
        else
          []
        end
      end)

    assert violations == [],
           """
           Direct `SpawnRegistry.spawn(entity://agent/...)` calls in production code
           outside the unified `Behavior.Workspace.:create_agent` action body:

             #{Enum.join(violations, "\n             ")}

           Use `Ezagent.Workspace.create_agent/3` (the unified facade) — see SPEC
           `docs/superpowers/specs/2026-05-25-agent-create-cli-gui-parity.md`.
           If your call site is legitimate (e.g. plugin defensive ensure / reconciler),
           add it to `@allowlist` in this file with a one-line justification.
           """
  end

  defp list_production_files(apps_root) do
    apps_root
    |> Path.join("apps")
    |> File.ls!()
    |> Enum.flat_map(fn app ->
      lib_dir = Path.join(["apps", app, "lib"])
      full_lib = Path.join(apps_root, lib_dir)

      if File.dir?(full_lib) do
        list_ex_files(full_lib)
        |> Enum.map(&Path.relative_to(&1, apps_root))
      else
        []
      end
    end)
  end

  defp list_ex_files(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      full = Path.join(dir, entry)

      cond do
        File.dir?(full) -> list_ex_files(full)
        String.ends_with?(entry, ".ex") -> [full]
        true -> []
      end
    end)
  end
end
