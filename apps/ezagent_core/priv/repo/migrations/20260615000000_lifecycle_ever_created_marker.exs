defmodule EzagentCore.Repo.Migrations.LifecycleEverCreatedMarker do
  @moduledoc """
  Lifecycle migration Phase A (SPEC `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md`
  §9 OQ-1) — the **ever-created marker**.

  ## Why

  The Lifecycle macro splits a Behavior's boot into two moments:

  - `create/1` — runs ONCE in the entity's entire history (build the
    initial PERSISTENT state).
  - `activate/2` — runs on EVERY process start (rebuild transients +
    self-heal), including cold-load-from-snapshot.

  The engine today has no "has this URI ever been created?" bit — its
  `init_slice/1` runs on every cold-load. To honor the create-once
  contract the boot path needs a durable marker.

  ## Decision (§9 OQ-1 → option (b), Allen-delegated)

  A **dedicated column** on `kind_snapshots`, not a reserved state key
  (option a) and not snapshot-row-presence (option c). Option (c) was
  rejected because a `create` that legitimately returns empty state, or
  a crash between create's state-write and the first snapshot, would
  wrongly re-run `create`. An explicit column is unambiguous and
  survives a legitimately-empty initial `state`.

  `ever_created` is a boolean, default `false`. The Lifecycle boot path
  flips it to `true` once `create/1` has run for a URI. A `destroy/2`
  clears the snapshot row (and therefore the marker) so a respawn at the
  same URI goes through `create` again.

  ## Cutover note (NOT run here — Phase A is additive)

  Per the task brief and SPEC §10-R4: this migration FILE is written but
  MUST NOT be run against the live dev DB (phx is using it). It is run
  during the verified ordered cutover.
  """

  use Ecto.Migration

  def up do
    alter table(:kind_snapshots) do
      add :ever_created, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:kind_snapshots) do
      remove :ever_created
    end
  end
end
