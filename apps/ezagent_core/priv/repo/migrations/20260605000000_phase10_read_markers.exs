defmodule EzagentCore.Repo.Migrations.Phase10ReadMarkers do
  @moduledoc """
  Phase 10 / Read Receipts SPEC §5 — `read_markers` table.

  Per-`(workspace, session, user, source)` upsert. Tracks the latest
  message_uri this user has seen in this session via this source.

  Sources (TEXT enum, app-side validated):
  - `"delivered"` — transport sent the envelope (Feishu HTTP 200, LV WS ack)
  - `"displayed"` — UI rendered the message in viewport
  - `"read"` — recipient explicitly confirmed (Feishu message_read event)

  See SPEC `docs/superpowers/specs/2026-05-23-read-receipts.md`.
  """

  use Ecto.Migration

  def change do
    create table(:read_markers) do
      add :workspace_uri, :string, null: false
      add :session_uri, :string, null: false
      add :user_uri, :string, null: false
      add :source, :string, null: false

      add :last_read_message_uri, :string, null: false
      add :observed_at, :utc_datetime_usec, null: false

      timestamps()
    end

    create unique_index(
             :read_markers,
             [:workspace_uri, :session_uri, :user_uri, :source],
             name: :read_markers_unique
           )

    create index(:read_markers, [:session_uri, :user_uri])
  end
end
