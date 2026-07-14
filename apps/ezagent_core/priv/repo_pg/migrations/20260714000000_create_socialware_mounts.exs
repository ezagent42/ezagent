defmodule EzagentCore.Repo.Migrations.CreateSocialwareMounts do
  use Ecto.Migration

  def change do
    create table(:socialware_mounts, primary_key: false) do
      add :id, :string, primary_key: true
      add :session_uri, :string, null: false
      add :target_uri, :string, null: false
      add :grantee_uri, :string, null: false
      add :behavior, :string, null: false
      add :actions_json, :text, null: false, default: "[]"
      add :access, :string, null: false
      add :granted_by, :string, null: false
      add :workspace_uri, :string, null: false
      add :mounted_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :socialware_mounts,
             [:session_uri, :target_uri, :grantee_uri, :behavior],
             name: :socialware_mounts_natural_key_index
           )

    create index(:socialware_mounts, [:session_uri])
    create index(:socialware_mounts, [:target_uri])
    create index(:socialware_mounts, [:grantee_uri])
  end
end
