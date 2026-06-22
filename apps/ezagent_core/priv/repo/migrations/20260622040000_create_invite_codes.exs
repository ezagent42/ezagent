defmodule EzagentCore.Repo.Migrations.CreateInviteCodes do
  @moduledoc """
  Login email+password (task #87) Decision 10 — invite codes to gate early
  self-registration. A code carries an authoritative target workspace (+ optional
  role), a quota (`max_uses`), and an expiry. Consuming a code is a conditional
  `UPDATE ... WHERE used_count < max_uses` (the SQLite single-writer race gate),
  run in the same transaction as user creation.

  NOTE on CHECK constraints (Codex plan-review #10): SQLite does not support
  `ALTER TABLE ADD CONSTRAINT`, so the quota invariants are enforced inline in
  the CREATE TABLE below (raw SQL) plus changeset validations; the conditional
  UPDATE remains the concurrency gate.
  """
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE invite_codes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      code TEXT NOT NULL,
      workspace_uri TEXT NOT NULL,
      role TEXT,
      max_uses INTEGER NOT NULL DEFAULT 1 CHECK (max_uses >= 1),
      used_count INTEGER NOT NULL DEFAULT 0 CHECK (used_count >= 0 AND used_count <= max_uses),
      expires_at TEXT,
      created_by TEXT NOT NULL,
      revoked_at TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    create(unique_index(:invite_codes, [:code], name: :invite_codes_code_index))
  end

  def down do
    drop_if_exists(index(:invite_codes, [:code], name: :invite_codes_code_index))
    execute("DROP TABLE IF EXISTS invite_codes")
  end
end
