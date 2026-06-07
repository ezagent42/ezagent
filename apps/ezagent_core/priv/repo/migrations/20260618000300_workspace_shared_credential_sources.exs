defmodule EzagentCore.Repo.Migrations.WorkspaceSharedCredentialSources do
  use Ecto.Migration

  def change do
    create table(:workspace_shared_credential_sources, primary_key: false) do
      # synthetic PK = "<workspace_uri>|<flavor>"
      add :id, :string, primary_key: true
      add :workspace_uri, :string, null: false
      add :flavor, :string, null: false
      add :source_uri, :string, null: false
      add :set_by, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspace_shared_credential_sources, [:workspace_uri, :flavor],
             name: :workspace_shared_credential_sources_natural_key_index
           )
  end
end
