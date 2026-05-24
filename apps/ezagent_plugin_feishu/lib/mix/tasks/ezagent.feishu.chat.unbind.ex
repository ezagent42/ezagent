defmodule Mix.Tasks.Ezagent.Feishu.Chat.Unbind do
  @shortdoc "Remove a Feishu chat_id ↔ session binding"
  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category C (deferred).**
  > Bypasses dispatch: calls `SessionBinding.unbind/1` directly. The
  > `mix esr feishu chat_unbind` equivalent does NOT exist yet.
  > Tracked in `docs/futures/todo.md` § "CLI ↔ GUI parity (audit
  > findings #137 still partial)". TODO: register FacadeRegistry op
  > `(:feishu, :chat_unbind)`, then deprecate this task using the PR
  > #302 stub pattern.

  PR #144 SPEC v2 §5.8.

      mix ezagent.feishu.chat.unbind oc_abc123

  Drops the row from `feishu_session_bindings`. Inbound Feishu
  messages on this chat_id will subsequently be dropped (no react)
  and outbound chat sends in any session that USED to be bound to
  this chat_id will no longer mirror to Feishu.
  """
  use Mix.Task

  alias EzagentPluginFeishu.SessionBinding

  @impl Mix.Task
  def run([chat_id | _]) when is_binary(chat_id) and chat_id != "" do
    Mix.Task.run("app.start")

    case SessionBinding.unbind(chat_id) do
      :ok ->
        Mix.shell().info("✓ unbound feishu chat_id #{chat_id}")

      {:error, :not_found} ->
        Mix.raise("no binding for chat_id #{chat_id}")
    end
  end

  def run(_), do: Mix.raise("usage: mix ezagent.feishu.chat.unbind <chat_id>")
end
