defmodule Mix.Tasks.Ezagent.Feishu.Chat.Bind do
  @shortdoc "Bind a Feishu chat_id to an ESR session URI"
  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category C (deferred).**
  > Bypasses dispatch: calls `SessionBinding.bind/2` directly. The
  > `mix esr feishu chat_bind` equivalent does NOT exist yet. Tracked
  > in `docs/futures/todo.md` § "CLI ↔ GUI parity (audit findings #137
  > still partial)". TODO: add the matching Behavior action + cap subject (NOT a bare FacadeRegistry op — codex PR #304 round-2 HIGH: that path bypasses Invocation.dispatch + caps + audit). mix esr auto-derives the CLI from interface/0. See the deferred-table guidance in docs/futures/todo.md HIGH-2
  > `(:feishu, :chat_bind)`, then deprecate this task using the PR
  > #302 stub pattern.

  PR #144 SPEC v2 §5.8 — admin CLI for Feishu chat ↔ session bindings.

      mix ezagent.feishu.chat.bind oc_abc123 session://default/default/main

  Writes a row into `feishu_session_bindings` (chat_id PK). Inbound
  Feishu messages on `oc_abc123` will dispatch into `session://default/default/main`;
  outbound chat sends in `session://default/default/main` will mirror to `oc_abc123`
  via `EzagentPluginFeishu.Behavior.FeishuOutbound`.

  Replaces the pre-PR-144 `mix ezagent.template.instantiate
  feishu.chat_binding ...` flow (the `feishu.chat_binding` Template
  Class was deleted along with the `feishu://` Receiver Kind it
  used to spawn).

  Idempotent — re-binding the same chat_id silently replaces the
  prior session_uri.
  """
  use Mix.Task

  alias EzagentPluginFeishu.SessionBinding

  @impl Mix.Task
  def run([chat_id, session_uri | _]) when is_binary(chat_id) and is_binary(session_uri) do
    Mix.Task.run("app.start")

    cond do
      not String.starts_with?(chat_id, "oc_") ->
        Mix.raise("chat_id must start with `oc_` (Feishu open-chat-id convention)")

      not String.starts_with?(session_uri, "session://") ->
        Mix.raise("session_uri must be a session:// URI (got: #{inspect(session_uri)})")

      true ->
        case SessionBinding.bind(chat_id, session_uri) do
          {:ok, _row} ->
            Mix.shell().info("✓ bound feishu chat_id #{chat_id} → #{session_uri}")

          {:error, reason} ->
            Mix.raise("bind failed: #{inspect(reason)}")
        end
    end
  end

  def run(_),
    do: Mix.raise("usage: mix ezagent.feishu.chat.bind <chat_id> <session_uri>")
end
