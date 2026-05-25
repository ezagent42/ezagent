defmodule EzagentCore.Repo.Migrations.Phase4Workspaces do
  use Ecto.Migration

  def change do
    create table(:workspaces) do
      add :name, :string, null: false
      add :uri, :string, null: false

      # JSON-encoded list of member URIs (e.g. ["entity://user/default/admin","entity://agent/default/test_x"])
      add :member_uris, :text, null: false, default: "[]"
      # JSON-encoded map name → template_data
      add :session_templates, :text, null: false, default: "{}"
      # JSON-encoded list of routing rule maps
      add :routing_rules, :text, null: false, default: "[]"
      add :created_by, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspaces, [:name])
    create unique_index(:workspaces, [:uri])
  end
end
