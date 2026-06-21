defmodule EzagentCore.Repo.Migrations.MessageSessionScoping do
  @moduledoc """
  Message session-scoping (2026-06-21): collapse the vestigial `message_routings`
  multi-routing into the `messages` row.

  Verified (2026-06-21) that no live path writes one `message_id` to >1 session
  (cross-session forwarding copies a NEW message into the target session, per the
  copy+ref model). So a message belongs to exactly one session — `messages.session_uri`
  is the canonical key, and the per-session `routed_at` becomes a real `messages` column.

  Fail-loud: before dropping, assert ZERO message_routings rows point at a session
  other than the message's own `session_uri` (a real multi-routed message would
  contradict the audit — abort rather than silently lose it).
  """
  use Ecto.Migration
  import Ecto.Query

  def up do
    # 1. Real `routed_at` column on messages (was virtual, surfaced from routings).
    alter table(:messages) do
      add :routed_at, :utc_datetime_usec
    end

    flush()

    # 2. Fail-loud safety: no cross-session-divergent routing may exist.
    divergent =
      EzagentCore.Repo.one(
        from(r in "message_routings",
          join: m in "messages",
          on: m.id == r.message_id,
          where: r.session_uri != m.session_uri,
          select: count(r.message_id)
        )
      ) || 0

    if divergent > 0 do
      raise "message session-scoping migration aborted: #{divergent} message_routings rows " <>
              "point at a session other than the message's own session_uri — a real " <>
              "multi-routed message exists, contradicting the vestigial-multi-routing audit. " <>
              "Resolve (split into per-session copies) before collapsing."
    end

    # 3. Backfill routed_at from the message's own routing row, else inserted_at.
    execute("""
    UPDATE messages
       SET routed_at = (
         SELECT r.routed_at FROM message_routings r
          WHERE r.message_id = messages.id AND r.session_uri = messages.session_uri
          LIMIT 1
       )
    """)

    execute("UPDATE messages SET routed_at = inserted_at WHERE routed_at IS NULL")

    # 4. Drop the now-unused routing table.
    drop table(:message_routings)
  end

  def down do
    create table(:message_routings, primary_key: false) do
      add :message_id, :string, null: false
      add :session_uri, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :routed_at, :utc_datetime_usec
    end

    create unique_index(:message_routings, [:message_id, :session_uri])

    flush()

    # Rebuild a 1:1 routing per message from the collapsed columns.
    execute("""
    INSERT INTO message_routings (message_id, session_uri, inserted_at, routed_at)
    SELECT id, session_uri, inserted_at, COALESCE(routed_at, inserted_at) FROM messages
    """)

    alter table(:messages) do
      remove :routed_at
    end
  end
end
