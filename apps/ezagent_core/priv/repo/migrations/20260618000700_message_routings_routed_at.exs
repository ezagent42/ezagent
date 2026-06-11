defmodule EzagentCore.Repo.Migrations.MessageRoutingsRoutedAt do
  @moduledoc """
  P4 codex r4 HIGH (additive fix) — add a per-session ROUTE-INTO-THIS-SESSION
  timestamp column `routed_at` to `message_routings`, used ONLY by the chat-feed
  cursor.

  ## Why a separate column (do NOT repurpose `inserted_at`)

  `message_routings.inserted_at` is set from `msg.inserted_at` (the message's
  CREATION time). The cross-session relay path routes the SAME `%Message{}`
  (original `inserted_at`) into a target session, so a message created earlier
  in session A and later relayed into chat session B gets an OLD routing
  `inserted_at` in B — it can sort BEHIND B's already-advanced chat-feed cursor
  and be excluded from the chat external SPA forever.

  Changing `inserted_at` to route-time has WIDE blast radius (production
  pagination `older_than/3` + `in_session_since/2` + the customer feed order by
  `r.inserted_at`). Instead this ADDITIVE column carries the real
  route-into-this-session time; `MessageStore.write/2` sets it to a fresh
  `DateTime.utc_now()` and the chat-feed cursor orders/filters/cursors on it.

  Self-contained + reversible (the P2.5b lesson — no app-code dependency in the
  migration). Backfills existing rows `routed_at = inserted_at` so the chat-feed
  cursor keeps working for pre-migration history.
  """
  use Ecto.Migration

  def up do
    alter table(:message_routings) do
      add :routed_at, :utc_datetime_usec
    end

    # Backfill existing rows from their creation timestamp (self-contained — no
    # app-code dependency). For pre-migration history the route-into-session
    # time is unknown, so `inserted_at` is the best available approximation and
    # preserves the chat-feed cursor's existing behaviour for old rows.
    execute("UPDATE message_routings SET routed_at = inserted_at WHERE routed_at IS NULL")

    create index(:message_routings, [:session_uri, :routed_at],
             name: :message_routings_session_routed_at_index
           )
  end

  def down do
    drop index(:message_routings, [:session_uri, :routed_at],
           name: :message_routings_session_routed_at_index
         )

    alter table(:message_routings) do
      remove :routed_at
    end
  end
end
