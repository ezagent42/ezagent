defmodule Mix.Tasks.Ezagent.Feishu.Unbind do
  @shortdoc "Remove a Feishu open_id binding"
  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category C (deferred).**
  > Bypasses dispatch: calls `UserBinding.unbind/1` directly. The
  > `mix ezagent feishu unbind` equivalent does NOT exist yet. Tracked in
  > `docs/futures/todo.md` § "CLI ↔ GUI parity (audit findings #137
  > still partial)". TODO: add the matching Behavior action + cap subject (NOT a bare FacadeRegistry op — codex PR #304 round-2 HIGH: that path bypasses Invocation.dispatch + caps + audit). mix ezagent auto-derives the CLI from interface/0. See the deferred-table guidance in docs/futures/todo.md HIGH-2
  > `(:feishu, :unbind)`, then deprecate this task using the PR #302
  > stub pattern.

  Phase 6 PR 15.

      mix ezagent.feishu.unbind ou_6b11faf8e9...

  Drops the row from `feishu_user_bindings`. Does NOT revoke the cap
  the bound user received — the cap stays attached because the user
  may have other Feishu open_ids bound to them. Use
  `mix ezagent.user.token`-style explicit cap revocation if you want that.
  """
  use Mix.Task

  alias EzagentPluginFeishu.UserBinding

  @impl Mix.Task
  def run([open_id | _]) when is_binary(open_id) and open_id != "" do
    Mix.Task.run("app.start")

    case UserBinding.unbind(open_id) do
      :ok ->
        Mix.shell().info("✓ unbound #{open_id}")

      {:error, :not_found} ->
        Mix.raise("no binding for #{open_id}")
    end
  end

  def run(_), do: Mix.raise("usage: mix ezagent.feishu.unbind <open_id>")
end
