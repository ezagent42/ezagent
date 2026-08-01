defmodule EzagentCore.Repo.Migrations.CreateCapRevocationEpoch do
  use Ecto.Migration

  def change do
    create table(:cap_revocation_epoch, primary_key: false) do
      add :id, :string, primary_key: true
      add :activated_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
