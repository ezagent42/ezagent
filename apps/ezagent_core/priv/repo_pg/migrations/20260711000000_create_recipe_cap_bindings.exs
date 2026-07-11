defmodule EzagentCore.Repo.Migrations.CreateRecipeCapBindings do
  use Ecto.Migration

  def change do
    create table(:recipe_cap_bindings, primary_key: false) do
      add :agent_uri, :string, primary_key: true
      add :workspace_uri, :string, null: false
      add :recipe_name, :string, null: false
      add :issuer_uri, :string, null: false
      add :artifacts, :map, null: false
      add :content_hash, :string, null: false
      add :version, :bigint, null: false, default: 1
      add :tombstoned_at, :utc_datetime_usec
      add :gc_pruned_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:recipe_cap_bindings, [:workspace_uri])
    create index(:recipe_cap_bindings, [:tombstoned_at])

    create constraint(:recipe_cap_bindings, :recipe_cap_bindings_positive_version,
             check: "version > 0"
           )
  end
end
