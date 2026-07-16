defmodule EzagentCore.Repo.Migrations.CreateKindCapAuthorities do
  use Ecto.Migration

  def change do
    create table(:kind_cap_authorities, primary_key: false) do
      add :uri, :text, primary_key: true
      add :generation, :integer, primary_key: true
      add :kind_type, :text, null: false
      add :key_id, :text, null: false
      add :public_key, :binary, null: false
      add :private_key, :binary, null: false
      add :anchor, :binary, null: false
      add :sealed, :boolean, null: false, default: true
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:kind_cap_authorities, [:uri, :generation])

    create unique_index(:kind_cap_authorities, [:uri],
             where: "active = TRUE",
             name: :kind_cap_authorities_one_active_per_uri
           )
  end
end
