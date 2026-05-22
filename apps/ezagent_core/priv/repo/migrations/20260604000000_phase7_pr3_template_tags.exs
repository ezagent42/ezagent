defmodule EzagentCore.Repo.Migrations.Phase7Pr3TemplateTags do
  @moduledoc """
  Phase 7 completion PR-3 (SPEC §1.7 (c)) — the `template_tags` registry table.

  `Ezagent.TemplateTags` is a small persisted registry — the same shape
  as `routing_rules`/`Ezagent.Routing.RuleStore`: an Ecto schema over a
  SQLite table, hydrated into ETS at boot, read from ETS at runtime.

  A row maps a `(workspace, template-name, tag) → version_hash`. Tags
  are mutable git-style refs — a tag can be re-pointed at any existing
  hash for the same `(workspace, name)`; a SessionTemplate version
  (a `kind_snapshots` row) is immutable.

  ## Schema

      id            integer primary key
      workspace_uri TEXT NOT NULL  (invariant 14 — template_tags is per-tenant)
      name          TEXT NOT NULL  (the SessionTemplate name)
      tag           TEXT NOT NULL  (the mutable ref — "stable", "v1.0", ...)
      version_hash  TEXT NOT NULL  (the SessionTemplate version hash it points at)
      created_by    TEXT
      inserted_at / updated_at

  ## UNIQUE (workspace_uri, name, tag)

  A tag is unique per `(workspace, template-name)`. Crucially the key
  includes `workspace_uri` — workspace A's `stable` and workspace B's
  `stable` are DISTINCT rows and never resolve to each other (SPEC §1.2
  cross-workspace non-collision; codex rev-2 CRITICAL).

  ## SQLite-safe — invariant 14

  `template_tags` is a brand-new table, so the NOT NULL `workspace_uri`
  column is created directly in the `CREATE TABLE` statement. The
  CREATE-NEW-TABLE step of invariant 14's CREATE-NEW/INSERT-SELECT
  pattern is exactly this `CREATE TABLE ... workspace_uri TEXT NOT NULL`
  — there is no pre-existing `template_tags` table to INSERT-SELECT
  FROM (that half of the dance only applies when ALTERing an existing
  table, which SQLite cannot do for a NOT NULL column add). The
  `null: false` constraint is therefore enforced from row 1.

  Per `feedback_let_it_crash_no_workarounds` + SPEC v3 §8 the canonical
  workflow is `mix ezagent.db.reset` (wipe + replay) — no backfill.
  """

  use Ecto.Migration

  def change do
    # CREATE-NEW-TABLE — invariant 14. A fresh per-tenant table is
    # created with `workspace_uri TEXT NOT NULL` directly; SQLite only
    # needs the rebuild/INSERT-SELECT dance when ADDING a NOT NULL
    # column to an EXISTING table.
    create table(:template_tags) do
      add :workspace_uri, :string, null: false
      add :name, :string, null: false
      add :tag, :string, null: false
      add :version_hash, :string, null: false
      add :created_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    # A tag is unique per (workspace, template-name). The workspace_uri
    # in the key is what makes `stable` in workspace A and `stable` in
    # workspace B distinct rows (SPEC §1.2 non-collision).
    create unique_index(:template_tags, [:workspace_uri, :name, :tag])

    # Workspace-scoped read path (`list/1`) — invariant 14 index.
    create index(:template_tags, [:workspace_uri])
  end
end
