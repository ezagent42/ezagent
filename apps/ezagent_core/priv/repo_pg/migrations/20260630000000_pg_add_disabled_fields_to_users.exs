defmodule EzagentCore.Repo.Migrations.PgAddDisabledFieldsToUsers do
  @moduledoc """
  Admin user management v1 — soft-disable real users on PostgreSQL installs.
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add(:disabled_at, :utc_datetime_usec)
      add(:disabled_by, :string)
      add(:disabled_reason, :text)
    end

    create(index(:users, [:disabled_at]))
  end
end
