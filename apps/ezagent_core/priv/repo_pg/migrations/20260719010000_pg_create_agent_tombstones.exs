defmodule EzagentCore.Repo.Migrations.PgCreateAgentTombstones do
  @moduledoc """
  Owned-agent authority cascade (task #180 / #1469) — the durable tombstone
  marker for agents whose authority derived from a deleted user, on
  PostgreSQL installs. Parallel to the SQLite `priv/repo` migration of the
  same change; see `Ezagent.Identity.AgentTombstone` for the semantics
  (row retained → fail-closed fence + PAT rejection + audit).
  """
  use Ecto.Migration

  def change do
    create table(:agent_tombstones, primary_key: false) do
      add(:agent_uri, :string, primary_key: true)
      add(:workspace_uri, :string, null: false)
      add(:tombstoned_by, :string)
      add(:tombstoned_reason, :text)
      add(:tombstoned_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:agent_tombstones, [:workspace_uri]))
  end
end
