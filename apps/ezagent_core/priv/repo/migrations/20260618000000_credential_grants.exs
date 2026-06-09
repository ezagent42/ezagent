defmodule EzagentCore.Repo.Migrations.CredentialGrants do
  use Ecto.Migration

  def change do
    create table(:credential_grants, primary_key: false) do
      # synthetic PK = agent_uri (one active grant per agent)
      add :id, :string, primary_key: true
      add :agent_uri, :string, null: false
      add :credential_source_uri, :string, null: false
      add :approved_by, :string, null: false
      add :approved_scope, :string, null: false
      add :version, :integer, null: false, default: 1
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:credential_grants, [:agent_uri],
             name: :credential_grants_agent_uri_index
           )
  end
end
