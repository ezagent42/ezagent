defmodule EzagentCore.Repo.Migrations.CredentialGrantsWorkspaceUri do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE credential_grants_new (
      id TEXT PRIMARY KEY,
      agent_uri TEXT NOT NULL,
      workspace_uri TEXT NOT NULL,
      credential_source_uri TEXT NOT NULL,
      approved_by TEXT NOT NULL,
      approved_scope TEXT NOT NULL,
      version INTEGER NOT NULL DEFAULT 1,
      revoked_at TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    execute("""
    INSERT INTO credential_grants_new
      (id, agent_uri, workspace_uri, credential_source_uri, approved_by,
       approved_scope, version, revoked_at, inserted_at, updated_at)
    SELECT
      id,
      agent_uri,
      'workspace://' || substr(agent_uri, 10, instr(substr(agent_uri, 10), '/') - 1),
      credential_source_uri,
      approved_by,
      approved_scope,
      version,
      revoked_at,
      inserted_at,
      updated_at
    FROM credential_grants
    WHERE agent_uri LIKE 'entity://%/%'
    """)

    execute("""
    INSERT INTO credential_grants_new
      (id, agent_uri, workspace_uri, credential_source_uri, approved_by,
       approved_scope, version, revoked_at, inserted_at, updated_at)
    SELECT
      id,
      agent_uri,
      NULL,
      credential_source_uri,
      approved_by,
      approved_scope,
      version,
      revoked_at,
      inserted_at,
      updated_at
    FROM credential_grants
    WHERE agent_uri NOT LIKE 'entity://%/%'
    """)

    execute("DROP TABLE credential_grants")
    execute("ALTER TABLE credential_grants_new RENAME TO credential_grants")

    create unique_index(:credential_grants, [:agent_uri],
             name: :credential_grants_agent_uri_index
           )

    create index(:credential_grants, [:workspace_uri],
             name: :credential_grants_workspace_uri_index
           )
  end

  def down do
    raise "credential_grants.workspace_uri migration is not reversible"
  end
end
