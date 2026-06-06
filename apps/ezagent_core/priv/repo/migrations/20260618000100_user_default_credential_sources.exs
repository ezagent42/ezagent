defmodule EzagentCore.Repo.Migrations.UserDefaultCredentialSources do
  use Ecto.Migration

  def change do
    create table(:user_default_credential_sources, primary_key: false) do
      # synthetic PK = "<owner>|<workspace>|<flavor>"
      add :id, :string, primary_key: true
      add :owner_uri, :string, null: false
      add :workspace_uri, :string, null: false
      add :flavor, :string, null: false
      add :source_uri, :string, null: false
      add :set_by, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_default_credential_sources, [:owner_uri, :workspace_uri, :flavor],
             name: :user_default_credential_sources_natural_key_index
           )
  end
end
