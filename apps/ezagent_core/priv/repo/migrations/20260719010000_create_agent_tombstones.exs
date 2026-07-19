defmodule EzagentCore.Repo.Migrations.CreateAgentTombstones do
  @moduledoc """
  Owned-agent authority cascade (task #180 / #1469) — the durable tombstone
  marker for agents whose authority derived from a deleted user.

  `Ezagent.Identity.Offboarding.tombstone_agent/3` inserts one row per
  cascaded agent; the spawn fence (`Ezagent.SpawnFence` +
  `Ezagent.ActionSet.Identity`) and `Token.authenticate/1` read it to
  refuse re-spawn / re-authentication of the revoked agent. The row is
  RETAINED (never purged) as the fail-closed audit record, mirroring the
  `users.deleted_*` tombstone shape. `workspace_uri` is NOT NULL per the
  Phase 9 per-tenant discipline (invariant #14).
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
