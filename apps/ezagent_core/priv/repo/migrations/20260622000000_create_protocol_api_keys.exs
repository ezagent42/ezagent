defmodule EzagentPluginProtocolApi.Repo.Migrations.CreateProtocolApiKeys do
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
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:protocol_api_keys, [:key_id])
    create index(:protocol_api_keys, [:entity_uri])
  end
end
