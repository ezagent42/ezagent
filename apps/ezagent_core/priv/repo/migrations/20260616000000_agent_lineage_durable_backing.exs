defmodule EzagentCore.Repo.Migrations.AgentLineageDurableBacking do
  @moduledoc """
  Remediation C-B (#114) — durable backing for `Ezagent.AgentLineage`.

  ## Why

  `Ezagent.AgentLineage` was a pure `:ets` table (`record/2` / `lookup/1`
  / `forget/1` / `spawned_in_lineage?/3`), created empty by
  `EzagentCore.EtsOwner` on every boot. The lineage `agent_uri →
  spawned_by` mapping was therefore LOST on restart: a previously-owned
  agent became "foreign", and `{:spawned_by, P}` CapBAC matching
  (Decision #137 / step 5.5) broke for every agent spawned before the
  restart.

  codex confirmed there is NO durable `spawned_by` field on the Agent
  Kind to rebuild the ETS index from (SPEC C-B: the "rebuild ETS from
  agent snapshots" option has no source). So we add a durable table as
  the rebuild source — the `Ezagent.TemplateTags` / `Routing.RuleStore`
  pattern: SQLite is the source of truth, the ETS table is the runtime
  read cache, and `Ezagent.AgentLineage.rehydrate/0` re-populates ETS
  from this table at boot.

  ## Shape

  - `agent_uri` — PRIMARY KEY (the lineage child), URI string.
  - `spawned_by` — the direct spawner, URI string.
  - `inserted_at` — provenance timestamp.

  `record/2` upserts; `forget/1` deletes; both keep the ETS cache and
  the row in sync. The PK on `agent_uri` makes the upsert idempotent
  (re-recording the same `(agent, spawned_by)` pair is a no-op, matching
  the prior ETS `:ets.insert` overwrite semantics).

  ## Cutover note

  Additive (a fresh table) — safe to run on `mix ecto.migrate`. Per the
  task brief this file is NOT run against the live dev DB here; the test
  alias (`ecto.migrate --quiet`) applies it to the test DB.
  """

  use Ecto.Migration

  def up do
    create table(:agent_lineage, primary_key: false) do
      add :agent_uri, :string, primary_key: true
      add :spawned_by, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end

  def down do
    drop table(:agent_lineage)
  end
end
