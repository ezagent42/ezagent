defmodule Mix.Tasks.Ezagent.Feishu.List do
  @shortdoc "List all Feishu open_id → local user bindings"
  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category C (deferred).**
  > Read-only listing of `feishu_user_bindings` rows. Doesn't bypass
  > a write-path dispatch (it doesn't write), but the LV `feishu_bindings_live.ex`
  > path can grow workspace-filter or cap-gated listing tomorrow and
  > this task would silently diverge. The `mix esr feishu list`
  > equivalent does NOT exist yet. Tracked in
  > `docs/futures/todo.md` § "CLI ↔ GUI parity (audit findings #137
  > still partial)". TODO: add the matching Behavior action + cap subject (NOT a bare FacadeRegistry op — codex PR #304 round-2 HIGH: that path bypasses Invocation.dispatch + caps + audit). mix esr auto-derives the CLI from interface/0. See the deferred-table guidance in docs/futures/todo.md HIGH-2
  > `(:feishu, :list)`, then deprecate this task using the PR #302
  > stub pattern.

      mix ezagent.feishu.list
  """
  use Mix.Task

  alias EzagentPluginFeishu.UserBinding

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")

    case UserBinding.list_all() do
      [] ->
        Mix.shell().info("(no bindings)")

      rows ->
        Mix.shell().info("Feishu user bindings:")

        Enum.each(rows, fn r ->
          Mix.shell().info(
            "  #{r.open_id} → #{r.user_uri}   bound_by=#{r.bound_by} at=#{DateTime.to_iso8601(r.bound_at)}"
          )
        end)
    end
  end
end
