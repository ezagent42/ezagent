defmodule EzagentCore.Repo.Migrations.VersionEntityTokenDigests do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE entity_tokens_hmac (
      id INTEGER PRIMARY KEY,
      entity_uri TEXT NOT NULL,
      token_hash TEXT,
      token_digest BLOB,
      digest_version INTEGER,
      label TEXT,
      expires_at TEXT,
      last_used_at TEXT,
      workspace_uri TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    execute("""
    INSERT INTO entity_tokens_hmac
      (id, entity_uri, token_hash, label, expires_at, last_used_at,
       workspace_uri, inserted_at, updated_at)
    SELECT id, entity_uri, token_hash, label, expires_at, last_used_at,
           workspace_uri, inserted_at, updated_at
    FROM entity_tokens
    """)

    execute("DROP TABLE entity_tokens")
    execute("ALTER TABLE entity_tokens_hmac RENAME TO entity_tokens")
    execute("CREATE INDEX entity_tokens_entity_uri_index ON entity_tokens (entity_uri)")
    execute("CREATE INDEX entity_tokens_workspace_uri_index ON entity_tokens (workspace_uri)")

    execute(
      "CREATE UNIQUE INDEX entity_tokens_token_digest_index " <>
        "ON entity_tokens (token_digest) WHERE token_digest IS NOT NULL"
    )
  end

  def down do
    execute("""
    CREATE TABLE entity_tokens_bcrypt (
      id INTEGER PRIMARY KEY,
      entity_uri TEXT NOT NULL,
      token_hash TEXT NOT NULL,
      label TEXT,
      expires_at TEXT,
      last_used_at TEXT,
      workspace_uri TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    execute("""
    INSERT INTO entity_tokens_bcrypt
      (id, entity_uri, token_hash, label, expires_at, last_used_at,
       workspace_uri, inserted_at, updated_at)
    SELECT id, entity_uri, token_hash, label, expires_at, last_used_at,
           workspace_uri, inserted_at, updated_at
    FROM entity_tokens
    WHERE token_hash IS NOT NULL
    """)

    execute("DROP TABLE entity_tokens")
    execute("ALTER TABLE entity_tokens_bcrypt RENAME TO entity_tokens")
    execute("CREATE INDEX entity_tokens_entity_uri_index ON entity_tokens (entity_uri)")
    execute("CREATE INDEX entity_tokens_workspace_uri_index ON entity_tokens (workspace_uri)")
  end
end
