defmodule EzagentCore.Repo.Migrations.PgAddDeletedFieldsToUsers do
  @moduledoc """
  Operator user offboarding (task #180) — HARD, admin-only `delete_user`
  that TOMBSTONES the provisioning row on PostgreSQL installs. Parallel to
  the SQLite `priv/repo` migration of the same name. See
  `Ezagent.Users.tombstone/3` for the semantics (row retained → URI stays
  occupied, no silent re-mint; audit preserved).
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
