defmodule EzagentCore.Repo.Migrations.CreateDerivationEdges do
  use Ecto.Migration

  def change do
    create table(:derivation_edges) do
      add :child_uri, :string, null: false
      add :parent_uri, :string, null: false
      add :edge_kind, :string, null: false
      add :attempt_id, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:derivation_edges, [:child_uri, :edge_kind])
    create index(:derivation_edges, [:parent_uri])

    execute("""
    INSERT INTO derivation_edges
      (child_uri, parent_uri, edge_kind, attempt_id, inserted_at)
    SELECT agent_uri, spawned_by, 'spawned_by',
           'backfill:agent-lineage:' || agent_uri, inserted_at
      FROM agent_lineage
     WHERE spawned_by IS NOT NULL
    ON CONFLICT (child_uri, edge_kind) DO NOTHING
    """)

    execute("""
    INSERT INTO derivation_edges
      (child_uri, parent_uri, edge_kind, attempt_id, inserted_at)
    SELECT uri, created_by, 'workspace_ownership',
           'backfill:workspace:' || uri, inserted_at
      FROM workspaces
     WHERE created_by IS NOT NULL AND created_by != ''
    ON CONFLICT (child_uri, edge_kind) DO NOTHING
    """)
  end
end
