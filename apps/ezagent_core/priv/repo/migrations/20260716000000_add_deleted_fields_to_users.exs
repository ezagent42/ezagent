defmodule EzagentCore.Repo.Migrations.AddDeletedFieldsToUsers do
  @moduledoc """
  Operator user offboarding (task #180) — a HARD, admin-only `delete_user`
  that TOMBSTONES the provisioning row rather than purging it.

  `Users.tombstone/3` sets these `deleted_*` fields (and, symmetrically,
  the existing `disabled_*` fields so the `verify_password` login gate
  fails closed) and tears down the live User Kind snapshot via
  `Ezagent.Lifecycle.destroy/2`. The row is PRESERVED so that:

    - the `users_uri_index` unique constraint keeps the URI OCCUPIED —
      `create_user` cannot silently re-mint the identity of an offboarded
      user (no silent URI reclaim; the safe default per the offboarding
      design note), and
    - the append-only audit trail (the row itself + the `:user_deleted`
      EventLog event the Router injects on dispatch) survives teardown.

  Distinct from `Users.delete/1`, the HARD-purge reserved for anon-User
  garbage collection (`ezagent_domain_socialware` GC sweeper), which
  removes the row entirely because an anon viewer carries no durable
  identity worth tombstoning.
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add(:deleted_at, :utc_datetime_usec)
      add(:deleted_by, :string)
      add(:deleted_reason, :text)
    end

    create(index(:users, [:deleted_at]))
  end
end
