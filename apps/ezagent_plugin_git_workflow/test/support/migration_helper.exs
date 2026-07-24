# Temporary migration helper — applies migration DDL directly
alias EzagentCore.Repo

Repo.query!("""
CREATE TABLE IF NOT EXISTS git_workflow_bindings (
  id VARCHAR NOT NULL PRIMARY KEY,
  generation INTEGER NOT NULL DEFAULT 1,
  workspace_uri VARCHAR NOT NULL,
  task_receiver_uri VARCHAR NOT NULL,
  credential_owner_uri VARCHAR NOT NULL,
  repository_uri VARCHAR NOT NULL,
  provider_adapter VARCHAR NOT NULL,
  provider_host VARCHAR NOT NULL,
  external_id VARCHAR NOT NULL,
  owner_path VARCHAR NOT NULL,
  base_ref VARCHAR NOT NULL,
  visibility VARCHAR NOT NULL,
  allowed_head_namespace VARCHAR NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
)
""")

Repo.query!("""
CREATE TABLE IF NOT EXISTS git_workflow_runs (
  id VARCHAR NOT NULL PRIMARY KEY,
  binding_id VARCHAR NOT NULL,
  binding_generation INTEGER NOT NULL,
  external_task_id VARCHAR NOT NULL,
  authenticated_principal_uri VARCHAR NOT NULL,
  status VARCHAR NOT NULL DEFAULT 'accepted',
  state_version INTEGER NOT NULL DEFAULT 1,
  input_digest VARCHAR NOT NULL,
  source_task_uri VARCHAR NOT NULL,
  source_revision VARCHAR,
  requested_head_ref VARCHAR,
  last_error_code VARCHAR,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
)
""")

Repo.query!("""
CREATE UNIQUE INDEX IF NOT EXISTS git_workflow_runs_binding_task_unique
ON git_workflow_runs (binding_id, binding_generation, external_task_id)
""")

Repo.query!("""
INSERT INTO schema_migrations (version, inserted_at)
VALUES (20260724010000, NOW())
ON CONFLICT DO NOTHING
""")

IO.puts("Migration applied: git_workflow_bindings + git_workflow_runs created")
