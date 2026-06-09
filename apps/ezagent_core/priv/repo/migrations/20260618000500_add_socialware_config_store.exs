defmodule EzagentCore.Repo.Migrations.AddSocialwareConfigStore do
  use Ecto.Migration

  def change do
    create table(:socialware_config_objects, primary_key: false) do
      add :id, :string, primary_key: true
      add :workspace_uri, :string, null: false
      add :subject_uri, :string, null: false
      add :key, :string, null: false
      add :body, :map, null: false
      add :created_by, :string, null: false
      add :source_turn_id, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:socialware_config_objects, [:workspace_uri, :subject_uri, :key],
             name: :socialware_config_objects_lookup_index
           )

    create table(:socialware_config_pointers, primary_key: false) do
      add :id, :string, primary_key: true
      add :layer, :string, null: false
      add :workspace_uri, :string, null: false
      add :subject_uri, :string, null: false
      add :key, :string, null: false
      add :config_id, :string, null: false
      add :previous_config_id, :string
      add :pointed_by, :string, null: false
      add :source_turn_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:socialware_config_pointers, [:layer, :workspace_uri, :subject_uri, :key],
             name: :socialware_config_pointers_unique_layer_subject_key
           )

    create index(:socialware_config_pointers, [:config_id],
             name: :socialware_config_pointers_config_id_index
           )
  end
end
