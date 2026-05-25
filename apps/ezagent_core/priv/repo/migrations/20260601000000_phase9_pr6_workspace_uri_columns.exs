defmodule EzagentCore.Repo.Migrations.Phase9Pr6WorkspaceUriColumns do
  @moduledoc """
  Phase 9 PR-6 (SPEC v3 §7) — data isolation columns.

  Adds `workspace_uri` (NOT NULL) to every per-tenant table so SELECT
  queries can scope by workspace and `INSERT`s assert presence at the
  schema layer.

  ## Mapping from SPEC §7.1 to actual tables

  The spec lists 8 logical "tables" but in our schema several of them
  are abstractions stored as JSON inside other tables, or are
  multiplexed into `kind_snapshots`. The real columns we add are:

      Spec §7.1 row | Actual table         | Source of workspace
      caps          | users.caps_json      | inherited from `users.workspace_uri` (JSON inside row)
      sessions      | kind_snapshots       | `Capability.workspace_of/1` on the Kind URI
      messages      | messages             | session's workspace via `WorkspaceRegistry.lookup/1`
      invocations   | invocations          | `Capability.workspace_of/1` on caller (preferred) or target
      snapshots     | kind_snapshots       | as above (single table, all kind_types)
      users         | users                | derived from `users.uri` (3-segment entity URI)
      agents        | kind_snapshots       | as snapshots — agents are Kind snapshots
      templates     | kind_snapshots       | as snapshots — templates are Kind snapshots

  Plus two tables not in the §7.1 list but per-tenant:
      entity_tokens   | entity_tokens     | derived from `entity_uri` (3-segment)
      entity_profiles | entity_profiles   | derived from `entity_uri` (3-segment)

  ## Exempt tables (intentionally NO `workspace_uri` column)

  - `workspaces`           — workspace IS the tenant; trivially scoped by row id
  - `routing_rules`        — already has `workspace_uri` (PR #146-149 / Phase 6 PR 8)
  - `message_routings`     — join table; inherits scope via FK to messages
  - `dlq`                  — pre-tenant boundary (failure can precede workspace
                              determination); operator triages from system scope
  - `app_settings`         — global system config (SMTP, registration domains)
  - `magic_link_tokens`    — cross-workspace by design (email-based pre-login;
                              no workspace context available at mint time)
  - `feishu_user_bindings` — plugin-owned mapping; workspace inherent in bound
                              user_uri downstream
  - `feishu_session_bindings` — plugin-owned mapping; workspace inherent in
                                bound session_uri downstream

  ## Wipe + rebuild

  Per `feedback_let_it_crash_no_workarounds` + SPEC v3 §8 — this
  migration is run against a freshly-dropped DB (`mix ezagent.db.reset`).
  No backfill. The schema enforces `null: false`; existing pre-Phase-9
  rows would fail the constraint at migration apply.
  """

  use Ecto.Migration

  # SQLite has limited ALTER TABLE support — `ALTER TABLE ... ALTER COLUMN`
  # is not supported. To enforce NOT NULL on a newly added column we use
  # the SQLite-canonical table-rebuild pattern (CREATE NEW + INSERT-SELECT
  # + DROP OLD + RENAME). Each per-tenant table has a custom rebuild
  # block below so the new schema (with `workspace_uri TEXT NOT NULL`)
  # is created precisely with the right column types — Ecto can't help
  # us here because it doesn't know about all our column types
  # transitively.
  #
  # Per SPEC v3 §8 + `feedback_let_it_crash_no_workarounds`: this
  # migration is the forward-looking schema; the canonical workflow
  # is `mix ezagent.db.reset` (wipe + replay) so backfill is admin
  # row + empty fresh tables. No legacy-data backfill scripts.

  def up do
    rebuild_messages()
    rebuild_invocations()
    rebuild_kind_snapshots()
    rebuild_users()
    rebuild_entity_tokens()
    rebuild_entity_profiles()
  end

  def down do
    # Reversal would require the symmetric drop-column-via-rebuild
    # dance for each table. Not implemented — Phase 9 is forward-only
    # per SPEC v3 §8 ("wipe + rebuild" rather than reversible).
    raise "Phase 9 PR-6 migration is not reversible — run `mix ezagent.db.reset`."
  end

  # --- per-table rebuilds ---------------------------------------------

  defp rebuild_messages do
    execute("""
    CREATE TABLE messages_new (
      id TEXT PRIMARY KEY,
      session_uri TEXT,
      workspace_uri TEXT NOT NULL,
      sender TEXT,
      mentions TEXT,
      body TEXT,
      ref_id TEXT,
      inserted_at TEXT
    )
    """)

    execute("""
    INSERT INTO messages_new
      (id, session_uri, workspace_uri, sender, mentions, body, ref_id, inserted_at)
    SELECT
      id, session_uri,
      COALESCE(NULL, 'workspace://default'),
      sender, mentions, body, ref_id, inserted_at
    FROM messages
    """)

    execute("DROP TABLE messages")
    execute("ALTER TABLE messages_new RENAME TO messages")

    # Preserve indexes from phase2_messages migration.
    execute(
      "CREATE INDEX messages_session_uri_inserted_at_index " <>
        "ON messages (session_uri, inserted_at)"
    )

    execute("CREATE INDEX messages_sender_index ON messages (sender)")
    execute("CREATE INDEX messages_workspace_uri_index ON messages (workspace_uri)")
  end

  defp rebuild_invocations do
    execute("""
    CREATE TABLE invocations_new (
      id INTEGER PRIMARY KEY,
      trace_id TEXT,
      caller TEXT,
      target TEXT NOT NULL,
      action TEXT,
      args TEXT,
      result TEXT,
      duration_us INTEGER,
      authz TEXT,
      exception TEXT,
      workspace_uri TEXT NOT NULL,
      inserted_at TEXT NOT NULL
    )
    """)

    execute("""
    INSERT INTO invocations_new
      (id, trace_id, caller, target, action, args, result, duration_us,
       authz, exception, workspace_uri, inserted_at)
    SELECT
      id, trace_id, caller, target, action, args, result, duration_us,
      authz, exception, COALESCE(NULL, 'workspace://default'), inserted_at
    FROM invocations
    """)

    execute("DROP TABLE invocations")
    execute("ALTER TABLE invocations_new RENAME TO invocations")

    execute("CREATE INDEX invocations_inserted_at_index ON invocations (inserted_at)")

    execute(
      "CREATE INDEX invocations_target_inserted_at_index ON invocations (target, inserted_at)"
    )

    execute("CREATE INDEX invocations_workspace_uri_index ON invocations (workspace_uri)")
  end

  defp rebuild_kind_snapshots do
    execute("""
    CREATE TABLE kind_snapshots_new (
      uri TEXT PRIMARY KEY,
      kind_type TEXT NOT NULL,
      state TEXT,
      state_binary BLOB,
      version INTEGER NOT NULL DEFAULT 0,
      workspace_uri TEXT NOT NULL,
      inserted_at TEXT,
      updated_at TEXT NOT NULL
    )
    """)

    execute("""
    INSERT INTO kind_snapshots_new
      (uri, kind_type, state, state_binary, version, workspace_uri, inserted_at, updated_at)
    SELECT
      uri, kind_type, state, state_binary, version,
      COALESCE(NULL, 'workspace://default'),
      inserted_at, updated_at
    FROM kind_snapshots
    """)

    execute("DROP TABLE kind_snapshots")
    execute("ALTER TABLE kind_snapshots_new RENAME TO kind_snapshots")

    execute("CREATE INDEX kind_snapshots_workspace_uri_index ON kind_snapshots (workspace_uri)")
  end

  defp rebuild_users do
    # `caps_json` default value preserved to match phase4_users migration.
    execute("""
    CREATE TABLE users_new (
      id INTEGER PRIMARY KEY,
      uri TEXT NOT NULL,
      password_hash TEXT,
      caps_json TEXT NOT NULL DEFAULT '[]',
      workspace_uri TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    # Backfill workspace_uri inline. On a fresh DB this is just the
    # admin row (`entity://user/default/admin` → workspace://default,
    # seeded by phase4_users migration); on any non-empty DB the
    # CASE WHEN parses the workspace segment out of the 3-segment URI.
    # Fallback `workspace://default` per wipe-rebuild philosophy.
    execute("""
    INSERT INTO users_new
      (id, uri, password_hash, caps_json, workspace_uri, inserted_at, updated_at)
    SELECT
      id, uri, password_hash, caps_json,
      CASE
        WHEN uri LIKE 'entity://user/%/%' THEN
          'workspace://' ||
          substr(uri, length('entity://user/') + 1,
                 instr(substr(uri, length('entity://user/') + 1), '/') - 1)
        ELSE 'workspace://default'
      END,
      inserted_at, updated_at
    FROM users
    """)

    execute("DROP TABLE users")
    execute("ALTER TABLE users_new RENAME TO users")

    execute("CREATE UNIQUE INDEX users_uri_index ON users (uri)")
    execute("CREATE INDEX users_workspace_uri_index ON users (workspace_uri)")
  end

  defp rebuild_entity_tokens do
    execute("""
    CREATE TABLE entity_tokens_new (
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

    # Empty on fresh DB (no seed inserts) — INSERT-SELECT is a no-op.
    # If a legacy DB ever has non-empty rows, they're attributed to
    # workspace://default per the wipe-rebuild philosophy (SPEC v3 §8).
    execute("""
    INSERT INTO entity_tokens_new
      (id, entity_uri, token_hash, label, expires_at, last_used_at,
       workspace_uri, inserted_at, updated_at)
    SELECT
      id, entity_uri, token_hash, label, expires_at, last_used_at,
      'workspace://default',
      inserted_at, updated_at
    FROM entity_tokens
    """)

    execute("DROP TABLE entity_tokens")
    execute("ALTER TABLE entity_tokens_new RENAME TO entity_tokens")

    execute("CREATE INDEX entity_tokens_workspace_uri_index ON entity_tokens (workspace_uri)")
  end

  defp rebuild_entity_profiles do
    # display_name was NOT NULL in the original schema.
    execute("""
    CREATE TABLE entity_profiles_new (
      entity_uri TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      email TEXT,
      workspace_uri TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    execute("""
    INSERT INTO entity_profiles_new
      (entity_uri, display_name, email, workspace_uri, inserted_at, updated_at)
    SELECT
      entity_uri, display_name, email,
      'workspace://default',
      inserted_at, updated_at
    FROM entity_profiles
    """)

    execute("DROP TABLE entity_profiles")
    execute("ALTER TABLE entity_profiles_new RENAME TO entity_profiles")

    # Preserve the partial unique index on email from entity_profiles
    # migration (email IS NOT NULL clause).
    execute(
      "CREATE UNIQUE INDEX entity_profiles_email_index " <>
        "ON entity_profiles (email) WHERE email IS NOT NULL"
    )

    execute("CREATE INDEX entity_profiles_workspace_uri_index ON entity_profiles (workspace_uri)")
  end
end
