defmodule EzagentCore.Repo.Migrations.RenameAdvisorBehaviorToAgentSoul do
  @moduledoc """
  Rename the default config-cascade KEY `advisor.behavior` → `agent.soul`
  (SPEC `docs/together/2026-06-26/specs/soul-config-key-rename.md`).

  `advisor` was misleading historical residue (the retired advisor-demo's key,
  #606); the default key should describe what it is — the agent's soul (its
  body's `soul_md` field projects to `CLAUDE.md` via
  `Ezagent.Socialware.ConfigProjection.render_soul/1`). Only the KEY changes; the
  body field `soul_md` is UNCHANGED.

  ## SELF-CONTAINED (no `Ezagent.Socialware.*` call)

  This `ezagent_core` migration uses migration-local raw SQL ONLY. Core does NOT
  depend on `ezagent_domain_identity`; a core-only/release migration context may
  not have `Ezagent.Socialware.ConfigKeyRename` loaded, and historical replay
  must not depend on current app shape (precedent:
  `20260618000600_socialware_outbox_surface_version_and_committed_seq.exs`). The
  SQL below mirrors `Ezagent.Socialware.ConfigKeyRename` (kept as the unit-tested
  runtime helper, driven by `config_key_rename_test.exs`) but is frozen here.

  ## What is rewritten

  - `socialware_config_objects.key` — plain column.
  - `socialware_config_pointers.key` — plain column AND embedded in the `id`
    primary key (`id = layer|workspace_uri|subject_uri|key`, see
    `Ezagent.Socialware.ConfigPointer.id/4`). The `id` is rebuilt by re-joining
    the columns with the new key, provably matching `id/4`
    (`Enum.join([layer, workspace_uri, subject_uri, key], "|")`).
    `config_id` / `previous_config_id` UUIDs are untouched.

  ## One-time exception to ConfigObject immutability

  `socialware_config_objects` rows are append-only/immutable: a new config is
  created by INSERTing a new object, never by mutating an existing row. `up/0`
  DOES `UPDATE` the `key` COLUMN on existing object rows — a deliberate one-time
  exception, acceptable because it rewrites a **routing label** (`key`), NOT the
  config `body`, and the object `id` /
  `resource://…/socialware-config-object/<b64(id)>` URI are UNTOUCHED, so no
  materialized projection changes. The pointer table has no immutability
  contract (it is the mutable layer), so rewriting it is unremarkable.

  ## Safety

  - **Non-destructive, forward-only, idempotent** — only `UPDATE`s guarded by
    `WHERE key = 'advisor.behavior'`; a re-run is a no-op once migrated.
  - **Collision preflight (MANDATORY, codex r1):** `up/0` ABORTS loudly if any
    pre-existing `agent.soul` row would collide with one to be renamed. The
    Postgres baseline gives the pointer table ONLY a `workspace_uri` index (no
    `(layer, ws, subject, key)` unique index), so the unique constraint cannot
    be relied on to abort the rename cleanly — the preflight is the defense. The
    objects table has a `(workspace_uri, subject_uri, key, source_turn_id)`
    unique index, so its key collision is preflighted too.
  - **`down/0` limitation:** renames EVERY `agent.soul` row back, including any
    created legitimately after this ships. Valid ONLY as the inverse of the
    coordinated one-shot deploy (SPEC §4.5 strategy 1 — disposable / single-node
    infra, no multi-node rolling fleet) inside the same maintenance window
    before fresh `agent.soul` rows exist. A post-window rollback must be a
    forward-fix.

  The interpolated key values are compile-time module-attribute constants
  (`@old` / `@new`), NOT external input — no injection surface.
  """

  use Ecto.Migration

  @old "advisor.behavior"
  @new "agent.soul"

  def up, do: rename_key(@old, @new)

  def down, do: rename_key(@new, @old)

  defp rename_key(from, to) do
    preflight_no_collision!(from, to)

    # Objects — plain column (one-time immutability exception, see moduledoc).
    execute("UPDATE socialware_config_objects SET key = '#{to}' WHERE key = '#{from}'")

    # Pointers — column AND the id PK, rebuilt to match ConfigPointer.id/4.
    execute("""
    UPDATE socialware_config_pointers
       SET key = '#{to}',
           id  = layer || '|' || workspace_uri || '|' || subject_uri || '|' || '#{to}'
     WHERE key = '#{from}'
    """)
  end

  # Abort if renaming `from` → `to` would collide a pre-existing `to` row.
  defp preflight_no_collision!(from, to) do
    pointer_collisions =
      single_count!("""
      SELECT count(*)
        FROM socialware_config_pointers a
        JOIN socialware_config_pointers b
          ON a.layer = b.layer
         AND a.workspace_uri = b.workspace_uri
         AND a.subject_uri = b.subject_uri
       WHERE a.key = '#{from}' AND b.key = '#{to}'
      """)

    if pointer_collisions > 0 do
      raise "config-key rename collision: #{pointer_collisions} pointer tuple(s) " <>
              "already hold '#{to}' alongside a '#{from}' row to be renamed"
    end

    object_collisions =
      single_count!("""
      SELECT count(*)
        FROM socialware_config_objects a
        JOIN socialware_config_objects b
          ON a.workspace_uri = b.workspace_uri
         AND a.subject_uri = b.subject_uri
         AND a.source_turn_id = b.source_turn_id
       WHERE a.key = '#{from}' AND b.key = '#{to}'
      """)

    if object_collisions > 0 do
      raise "config-key rename collision: #{object_collisions} object tuple(s) " <>
              "already hold '#{to}' alongside a '#{from}' row to be renamed"
    end
  end

  defp single_count!(sql) do
    %{rows: [[n]]} = repo().query!(sql)
    n
  end
end
