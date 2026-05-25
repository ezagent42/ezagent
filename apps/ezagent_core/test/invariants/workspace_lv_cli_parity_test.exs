defmodule EzagentCore.Invariants.WorkspaceLvCliParityTest do
  @moduledoc """
  Parity invariant for `Ezagent.Workspace.*` operations (Allen
  2026-05-25 directive — `CLI/LV 同源派生`).

  Every `Ezagent.Workspace.<op>(...)` function called from a
  LiveView `handle_event/3` must have a corresponding
  `Mix.Tasks.Ezagent.Workspace.<Op>` mix task. CLI and LV both
  delegate to the same source-of-truth function in
  `Ezagent.Workspace`; the LV is the user-facing form shell and
  the mix task is the shell-script-facing shell.

  This test fail-louds when a future PR adds a LV-driven workspace
  operation without the matching CLI task — the exact gap Allen
  flagged on 2026-05-25 when `Workspace.add_member` had a LV form
  but no mix task. The existing `agent_create_single_path_test`
  is a SINGLE-PATH invariant (one impl for one operation); this is
  the PARITY invariant (every operation has both shells).

  ## What is checked

  The test greps every `apps/ezagent_plugin_liveview/lib/**/*.ex`
  file for calls of the form `Ezagent.Workspace.<op>(...)` inside
  a `handle_event/3` clause body, then for each distinct `<op>`,
  asserts a file `apps/ezagent_domain_workspace/lib/mix/tasks/
  ezagent.workspace.<op>.ex` exists.

  ## Exemptions

  - LV-internal helpers (`Ezagent.Workspace.list_visible/0` etc.)
    that are pure reads with no side-effects do NOT require a CLI
    task — read-only listing is well-served by `iex -S mix` and a
    one-line `mix run -e`. The exemption list below should stay
    short; if it grows, consider whether the read deserves a CLI
    after all.
  """
  use ExUnit.Case, async: true

  @lv_dir Path.join([
            File.cwd!(),
            "../../apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview"
          ])

  @tasks_dir Path.join([
               File.cwd!(),
               "../../apps/ezagent_domain_workspace/lib/mix/tasks"
             ])

  # Read-only operations that are LV-only by design. Keep this list
  # short and justified.
  @read_only_exemptions ~w(list_visible list_persisted list_all)

  # Operations that have a CLI counterpart under a DIFFERENT mix-task
  # namespace, OR that are not operator-facing in their own right
  # (chain-internal helpers called by another operation's mix task).
  # Each exemption needs a one-line justification.
  @aliased_or_internal_exemptions %{
    # `Workspace.create_agent` has its own dedicated CLI at
    # `mix ezagent.agent.create` (predates this parity invariant; see
    # SPEC `docs/superpowers/specs/2026-05-25-agent-create-cli-gui-parity.md`).
    # That task IS the single-path entrypoint per
    # `agent_create_single_path_test`.
    "create_agent" => "mix ezagent.agent.create",
    # `Workspace.grant_initial_caps` is composed inside the
    # `mix ezagent.agent.create` with-chain after `create_agent`
    # returns; it is not operator-facing in isolation. The LV's
    # AgentNewLive composes the same chain.
    "grant_initial_caps" => "chain-internal, composed inside agent.create"
  }

  test "every LV-driven Workspace mutation has a corresponding mix task" do
    if not File.dir?(@lv_dir) do
      flunk(
        "LV directory not found at #{@lv_dir} — this invariant runs from " <>
          "the umbrella root via `mix test apps/ezagent_core/test/invariants/...`"
      )
    end

    lv_files = Path.wildcard(Path.join(@lv_dir, "**/*.ex"))
    ops_in_lv = extract_workspace_ops_from_lv(lv_files)

    mutation_ops =
      ops_in_lv
      |> Enum.reject(&(&1 in @read_only_exemptions))
      |> Enum.reject(&Map.has_key?(@aliased_or_internal_exemptions, &1))

    missing =
      for op <- Enum.uniq(mutation_ops),
          not mix_task_exists?(op),
          do: op

    assert missing == [],
           """
           Workspace LV/CLI parity gap (#{length(missing)} operations):
             #{Enum.join(missing, ", ")}

           Per Allen 2026-05-25 directive, every Ezagent.Workspace.<op>(...)
           called from a LiveView handle_event MUST have a matching mix task
           at apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.workspace.<op>.ex.

           Both shells (LV form + CLI task) delegate to the same
           Ezagent.Workspace.<op>/N source-of-truth function. Adding the
           mix task is a 30-line wrapper; copy the shape from
           apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.workspace.create.ex.

           If the operation is genuinely read-only and a `mix run -e` one-liner
           suffices, add it to @read_only_exemptions in this test with a
           one-line justification.
           """
  end

  defp extract_workspace_ops_from_lv(files) do
    Enum.flat_map(files, fn path ->
      content = File.read!(path)

      # Match `Ezagent.Workspace.<snake_case_op>(`. Captures only the
      # operation name. We deliberately don't try to scope the regex
      # to `handle_event` blocks — any direct call from LV code to a
      # mutating Workspace API merits a CLI counterpart.
      Regex.scan(~r/Ezagent\.Workspace\.([a-z_][a-z0-9_]*)\s*\(/, content)
      |> Enum.map(fn [_, op] -> op end)
    end)
  end

  defp mix_task_exists?(op) do
    File.exists?(Path.join(@tasks_dir, "ezagent.workspace.#{op}.ex"))
  end
end
