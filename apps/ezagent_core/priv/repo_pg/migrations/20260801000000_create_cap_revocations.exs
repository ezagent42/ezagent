defmodule EzagentCore.Repo.Migrations.CreateCapRevocations do
  use Ecto.Migration

  def change do
    create table(:cap_revocations, primary_key: false) do
      add :grant_id, :string, primary_key: true
      add :workspace_uri, :string, null: false
      add :holder_uri, :string
      add :cap_identity_key, :binary
      add :revoked_at, :utc_datetime_usec, null: false
      add :target_uri, :string
      add :key_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cap_revocations, [:workspace_uri, :grant_id])
    create index(:cap_revocations, [:workspace_uri, :revoked_at])
  end
end
