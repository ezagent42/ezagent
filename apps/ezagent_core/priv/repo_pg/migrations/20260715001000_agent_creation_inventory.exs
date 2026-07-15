defmodule EzagentCore.Repo.Migrations.AgentCreationInventory do
  use Ecto.Migration

  def change do
    create table(:agent_creation_inventory) do
      add :creation_attempt_id, :text, null: false
      add :agent_uri, :text, null: false
      add :provenance_root_uri, :text, null: false
      add :workspace_uri, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_creation_inventory, [:creation_attempt_id, :agent_uri],
             name: :agent_creation_inventory_attempt_agent_index
           )
  end
end
