defmodule EzagentCore.Repo.Migrations.CreateProtocolApiKeys do
  @moduledoc """
  PostgreSQL migration for `protocol_api_keys` (ezagent_plugin_protocol_api, #82).

  The plugin originally shipped its create + add_target_agent migrations under
  `priv/repo/migrations` (the pre-PG SQLite repo path). After the PostgreSQL-only
  migration the Repo reads `priv/repo_pg`, so those never ran on PG. This single
  migration recreates the table (with `target_agent` folded in) for the PG repo.
  Pure Ecto DSL — identical schema to the SQLite original.
  """
  use Ecto.Migration

  def change do
    create table(:protocol_api_keys, primary_key: false) do
      add :key_id, :string, null: false, primary_key: true
      add :secret_hash, :string, null: false
      add :entity_uri, :string, null: false
      add :workspace_uri, :string, null: false
      add :label, :string
      add :allowed_models, {:array, :string}, default: []
      add :cap_policy, :map, default: %{}
      add :target_agent, :string, default: nil
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:protocol_api_keys, [:key_id])
    create index(:protocol_api_keys, [:entity_uri])
  end
end
