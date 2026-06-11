defmodule Ezagent.MessageRouting do
  @moduledoc """
  Join table for "this Message landed in these Sessions" (Phase 3 fix
  for #P1-4 multi-session persist).

  Phase 2 `messages.id` is PK + identity-invariant per Decision #40 —
  same envelope across forwards. Phase 3 D8 reply may target N
  sessions in one operation; can't write `messages` table N times
  with same id. This join table stores per-session presence;
  `messages` stays single-row-per-id.

  Schema:
    message_id     :string  (FK to messages.id)
    session_uri    :string
    inserted_at    :utc_datetime_usec  (message CREATION time — `msg.inserted_at`)
    routed_at      :utc_datetime_usec  (ROUTE-INTO-THIS-SESSION time — fresh now)
  PK: composite (message_id, session_uri)

  ## `routed_at` (P4 codex r4 HIGH — additive)

  `inserted_at` is the message's creation time (`msg.inserted_at`), shared
  across every session the same `%Message{}` is routed into. The chat-feed
  cursor needs the per-session ROUTE time so a message relayed into a session
  long after it was created sorts AFTER that session's already-advanced cursor
  (not behind it, where it would be stranded forever). `routed_at` carries that
  route-into-this-session time (a fresh `DateTime.utc_now()` captured by
  `MessageStore.write/2`); `inserted_at` is left UNCHANGED so the production
  pagination (`older_than/3` / `in_session_since/2`) and the customer feed are
  unaffected.

  `MessageStore.write/2` upserts messages + inserts here.
  `MessageStore.recent_in_session/2` + `in_session_since/2` JOIN this
  table to get session-scoped Messages.

  ## PR #149 rename

  Pre-PR-149 the FK column was `message_uri` (matching the now-retired
  `Message.uri` field that stored a `message://<uuid>` URI). SPEC v2
  §5.13 retires the URI shape on Messages — the FK column is now
  `message_id`, joined against `messages.id`.
  """

  use Ecto.Schema

  @primary_key false
  schema "message_routings" do
    field :message_id, :string, primary_key: true
    field :session_uri, :string, primary_key: true
    field :inserted_at, :utc_datetime_usec
    field :routed_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          message_id: String.t(),
          session_uri: String.t(),
          inserted_at: DateTime.t() | nil,
          routed_at: DateTime.t() | nil
        }
end
