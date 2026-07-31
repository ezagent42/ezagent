defmodule EzagentCore.Repo.Migrations.DurableRevokeFence do
  use Ecto.Migration

  # ② DeliveryOutbox P2(c) (durable revoke hardening — codex adversarial
  # review must-fixes #1/#3):
  #
  #   1. `cap_delivery_outbox.status` gains `'cancelled'` — the terminal
  #      state for a pending `:store_cap` / `:absorb_cap` delivery whose cap
  #      was REVOKED before the holder drained it. Without it, a grant to a
  #      not-ready holder survives the revoke as a pending row and the next
  #      restart's ready-drain resurrects the revoked cap.
  #
  #   2. `cap_revocations` — the MONOTONE per-cap revocation tombstone
  #      ledger. `revoke_persisted/2` records "(holder, cap identity)
  #      revoked at T" durably BEFORE deleting rows, so a cap covered by a
  #      tombstone cannot be resurrected by a stale plane: the
  #      `Identity.activate/2` invariant-20 union filters tombstoned
  #      artifacts, and every `EntityCaps.Store` write boundary
  #      (persist / update / backfill / provision) refuses to re-add one.
  #      Rows are insert-only and never deleted (monotone fence).

  def up do
    drop constraint(:cap_delivery_outbox, :cap_delivery_outbox_status_check)

    create constraint(:cap_delivery_outbox, :cap_delivery_outbox_status_check,
             check: "status IN ('pending', 'applied', 'dead', 'cancelled')"
           )

    create table(:cap_revocations, primary_key: false) do
      add :holder_uri, :string, null: false
      add :cap_digest, :string, null: false
      add :workspace_uri, :string, null: false
      add :revoked_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cap_revocations, [:holder_uri, :cap_digest],
             name: :cap_revocations_holder_digest_index
           )

    create index(:cap_revocations, [:holder_uri])
    create index(:cap_revocations, [:workspace_uri])
  end

  def down do
    # NEVER delete delivery rows on rollback (the ② must-fix #6 contract —
    # a silent DELETE would drop an offline holder's durable state).
    # `'cancelled'` rows translate to `'dead'` (a terminal, constraint-
    # compatible state preserving the row + audit trail) before the check
    # is narrowed back. The tombstone ledger is dropped WITH its rows only
    # when empty; a populated fence refuses the rollback rather than
    # silently re-arming resurrection paths.
    execute("""
    UPDATE cap_delivery_outbox SET status = 'dead', dead_at = COALESCE(dead_at, now())
    WHERE status = 'cancelled'
    """)

    %{rows: [[tombstones]]} =
      repo().query!("SELECT count(*) FROM cap_revocations", [])

    if tombstones > 0 do
      raise """
      refusing to roll back durable_revoke_fence: #{tombstones} cap revocation \
      tombstone(s) exist. Dropping the fence would silently re-arm every \
      resurrection path it closes (stale live writers, best-effort \
      projections, pending deliveries). Clear the ledger deliberately \
      (operator action) before rolling back.
      """
    end

    drop table(:cap_revocations)

    drop constraint(:cap_delivery_outbox, :cap_delivery_outbox_status_check)

    create constraint(:cap_delivery_outbox, :cap_delivery_outbox_status_check,
             check: "status IN ('pending', 'applied', 'dead')"
           )
  end
end
