defmodule EzagentCore.Repo.Migrations.CreateOutboundGrants do
  use Ecto.Migration

  def change do
    create table(:outbound_grants, primary_key: false) do
      add :id, :string, primary_key: true
      add :workspace_uri, :string, null: false
      add :issuer_uri, :string, null: false
      add :decision_owner_uri, :string, null: false
      add :grantee_uri, :string, null: false
      add :cap, :map, null: false
      add :cap_identity, :string, null: false
      add :subtype, :string, null: false
      add :session_scope_uri, :string
      add :access, :map, null: false
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:outbound_grants, [:workspace_uri])
    create index(:outbound_grants, [:issuer_uri, :inserted_at, :id])
    create index(:outbound_grants, [:workspace_uri, :grantee_uri, :inserted_at, :id])
    create index(:outbound_grants, [:cap_identity])

    create constraint(:outbound_grants, :outbound_grants_subtype,
             check:
               "subtype IN ('runtime_mount', 'composition', 'recipe', 'ownership', 'structural', 'genesis')"
           )
  end
end
