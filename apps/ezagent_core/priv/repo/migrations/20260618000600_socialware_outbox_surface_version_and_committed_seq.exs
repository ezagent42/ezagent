defmodule EzagentCore.Repo.Migrations.SocialwareOutboxSurfaceVersionAndCommittedSeq do
  use Ecto.Migration

  # P2.5b — durable commit-order delivery cursor + committed page version on the
  # customer outbox. `committed_seq` is the per-session monotonic COMMIT-ORDER
  # cursor (NULL until the settlement commits; assigned at the commit boundary).
  # `surface_version` is the committed page version (mirrors
  # SettlementRecord.target_surface_version) carried on the durable delivery row
  # for the P3 ExternalAdapter and read by the committed-page projection.
  # Non-destructive adds + a one-time backfill of existing committed rows so the
  # cursor is dense from deploy (else legacy committed pages would vanish — the
  # page read is committed_seq based).
  def up do
    alter table(:socialware_customer_outbox) do
      add :surface_version, :integer
      add :committed_seq, :integer
    end

    # Backfill delegated to a PERMANENT idempotent helper (only touches committed
    # rows whose committed_seq IS NULL), so it is unit-testable and safe to keep
    # across future refactors (a re-run on a fresh DB finds no NULL-seq committed
    # rows and no-ops).
    flush()
    Ezagent.Socialware.Settlement.backfill_committed_seq!()

    # A per-session unique index — a backstop against a committed_seq collision
    # (per-session commits are serialized by the single SocialwareSession
    # GenServer, so a collision would be a real bug → fail loudly, not corrupt).
    create unique_index(:socialware_customer_outbox, [:session_uri, :committed_seq],
             name: :socialware_customer_outbox_session_committed_seq_index
           )
  end

  def down do
    drop index(:socialware_customer_outbox, [:session_uri, :committed_seq],
           name: :socialware_customer_outbox_session_committed_seq_index
         )

    alter table(:socialware_customer_outbox) do
      remove :committed_seq
      remove :surface_version
    end
  end
end
