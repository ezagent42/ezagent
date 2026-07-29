defmodule Ezagent.Socialware.ConfigKeyRename do
  @moduledoc """
  Forward-only data rename of the default config-cascade KEY
  `advisor.behavior` → `agent.soul` across the two socialware config tables.

  This is the testable logic the Ecto migration
  `EzagentCore.Repo.Migrations.RenameAdvisorBehaviorToAgentSoul` is a thin
  caller of — mirroring the house pattern (`Ezagent.Identity.GrantMigration`):
  the rewrite SQL lives in a plain module tested in `EzagentCore.DataCase`,
  while the migration `up/0` / `down/0` just call `run/0` / `rollback/0`.

  ## What is rewritten

  - `socialware_config_objects.key` — plain column.
  - `socialware_config_pointers.key` — plain column AND embedded in the `id`
    primary key (`id = layer|workspace_uri|subject_uri|key`, see
    `Ezagent.Socialware.ConfigPointer.id/4`). The `id` is rebuilt by
    re-joining the columns with the new key, provably matching `id/4`
    (`Enum.join([layer, workspace_uri, subject_uri, key], "|")`).

  ## One-time exception to ConfigObject immutability

  `socialware_config_objects` rows are append-only/immutable: a new config is
  created by INSERTing a new object, never by mutating an existing row.
  `run/0` DOES `UPDATE` the `key` COLUMN on existing object rows. This is a
  deliberate one-time exception, acceptable because it rewrites a **routing
  label** (`key`), NOT the config `body`, and the object `id` /
  `resource://…/socialware-config-object/<b64(id)>` URI are UNTOUCHED — so no
  materialized projection changes. `config_id` / `previous_config_id` UUID
  references are likewise untouched. The pointer table has no immutability
  contract (it is the mutable layer), so rewriting it is unremarkable.

  ## Safety

  - **Non-destructive, forward-only, idempotent** — only `UPDATE`s guarded by
    `WHERE key = 'advisor.behavior'`; a re-run is a no-op once migrated.
  - **Collision preflight (MANDATORY, codex r1):** `run/0` ABORTS loudly if any
    pre-existing `agent.soul` row would collide with one to be renamed. The
    Postgres baseline gives the pointer table ONLY a `workspace_uri` index (no
    `(layer, ws, subject, key)` unique index), so the unique constraint cannot
    be relied on to abort the rename cleanly — the preflight is the defense.
  - **`rollback/0` limitation:** renames EVERY `agent.soul` row back, including
    any created legitimately after this ships. Valid ONLY as the inverse of the
    coordinated one-shot deploy (disposable / single-node infra, no multi-node
    rolling fleet) inside the same maintenance window before fresh `agent.soul`
    rows exist. A post-window rollback must be a forward-fix.
  """

  alias EzagentCore.Repo

  @old "advisor.behavior"
  @new "agent.soul"

  @doc "The pre-rename key literal."
  @spec old_key() :: String.t()
  def old_key, do: @old

  @doc "The post-rename key literal (== `Ezagent.Agent.Config`'s default key)."
  @spec new_key() :: String.t()
  def new_key, do: @new

  @doc """
  Forward rename `advisor.behavior` → `agent.soul` on both tables (preflight
  first, then the two UPDATEs). Raises on collision.
  """
  @spec run() :: :ok
  def run, do: rename(@old, @new)

  @doc "Inverse rename (see moduledoc rollback limitation)."
  @spec rollback() :: :ok
  def rollback, do: rename(@new, @old)

  defp rename(from, to) do
    preflight_no_collision!(from, to)

    # Objects — plain column (one-time immutability exception, see moduledoc).
    Repo.query!("UPDATE socialware_config_objects SET key = $1 WHERE key = $2", [to, from])

    # Pointers — column AND the id PK, rebuilt to match ConfigPointer.id/4.
    # `$1::text` casts are explicit so Postgres can deduce the parameter type
    # used both as the `key` column value and inside the `||` id concat.
    Repo.query!(
      """
      UPDATE socialware_config_pointers
         SET key = $1::text,
             id  = layer || '|' || workspace_uri || '|' || subject_uri || '|' || $1::text
       WHERE key = $2::text
      """,
      [to, from]
    )

    :ok
  end

  # Abort if renaming `from` → `to` would collide a pre-existing `to` row.
  defp preflight_no_collision!(from, to) do
    pointer_collisions =
      single_count!(
        """
        SELECT count(*)
          FROM socialware_config_pointers a
          JOIN socialware_config_pointers b
            ON a.layer = b.layer
           AND a.workspace_uri = b.workspace_uri
           AND a.subject_uri = b.subject_uri
         WHERE a.key = $1 AND b.key = $2
        """,
        [from, to]
      )

    if pointer_collisions > 0 do
      raise "config-key rename collision: #{pointer_collisions} pointer tuple(s) " <>
              "already hold '#{to}' alongside a '#{from}' row to be renamed"
    end

    object_collisions =
      single_count!(
        """
        SELECT count(*)
          FROM socialware_config_objects a
          JOIN socialware_config_objects b
            ON a.workspace_uri = b.workspace_uri
           AND a.subject_uri = b.subject_uri
           AND a.source_turn_id = b.source_turn_id
         WHERE a.key = $1 AND b.key = $2
        """,
        [from, to]
      )

    if object_collisions > 0 do
      raise "config-key rename collision: #{object_collisions} object tuple(s) " <>
              "already hold '#{to}' alongside a '#{from}' row to be renamed"
    end
  end

  defp single_count!(sql, params) do
    %{rows: [[n]]} = Repo.query!(sql, params)
    n
  end
end
