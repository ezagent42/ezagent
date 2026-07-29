defmodule EzagentCore.Repo.Migrations.CreateIdentityCutover do
  use Ecto.Migration

  # #189 PR-3 (identity-plane cutover, FIX 5 — the persisted CUTOVER EPOCH):
  # the durable marker that makes the read-flip prod-safe. Merging PR-3 does
  # NOT flip production reads to the store; it lands the store-authoritative
  # code DORMANT behind this epoch. The operator activates the epoch ONLY after
  # `mix ezagent.identity.cutover` runs the backfill + the fleet-parity barrier
  # under a write-quiescence fence and the barrier reports COMPLETE.
  #
  # A single singleton row (`id = "identity"`) records the activation instant.
  # Before the row exists (or when it is unreadable), new code FAILS CLOSED to
  # the PR-1 legacy-authoritative semantics — the store is never consulted for
  # an authorization read. See `Ezagent.Identity.Cutover`.
  def change do
    create table(:identity_cutover, primary_key: false) do
      add :id, :string, primary_key: true
      add :activated_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
