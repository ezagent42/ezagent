defmodule EzagentCore.Repo.Migrations.Pr144FeishuSessionBindings do
  @moduledoc """
  PR #144 SPEC v2 §5.8 — Feishu chat_id ↔ session_uri binding table.

  Replaces the implicit binding that used to live in the
  `MentionRouting` routing-rules table (`in_session(S) → [feishu://oc_X]`).
  Per §5.8 plugins MUST NOT own a top-level scheme, so the
  `feishu://oc_xxx` Receiver Kind is deleted in this PR and the
  binding becomes a first-class join table here.

  ## Direction

  - Inbound (Feishu → Ezagent): chat_id → session_uri lookup → dispatch
    `<session_uri>?action=session.send`.
  - Outbound (Ezagent → Feishu): session_uri → chat_id reverse lookup
    in `Behavior.FeishuOutbound` (registered on Session Kind for
    `:notify_external` action). If a binding exists, mirror the
    send to the Feishu Open API.

  ## Cardinality

  One chat_id maps to exactly one session_uri (PK on chat_id). One
  session_uri may currently be bound by at most one chat_id (UI / mix
  task enforces this), but the schema doesn't add a UNIQUE constraint
  on session_uri so future fan-out (one session mirrored to multiple
  Feishu chats) is a schema-compatible addition.

  ## `enabled` flag

  Allows toggling a binding off without deleting the row (e.g.
  temporarily silence Feishu mirror while debugging). Outbound
  Behavior checks `enabled == 1` before sending.
  """

  use Ecto.Migration

  def change do
    create table(:feishu_session_bindings, primary_key: false) do
      add :chat_id, :string, primary_key: true
      add :session_uri, :string, null: false
      add :enabled, :boolean, default: true, null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    create index(:feishu_session_bindings, [:session_uri],
             name: :feishu_session_bindings_session_uri_index
           )
  end
end
