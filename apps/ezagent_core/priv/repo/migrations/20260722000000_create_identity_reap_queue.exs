defmodule EzagentCore.Repo.Migrations.CreateIdentityReapQueue do
  use Ecto.Migration

  def change do
    create table(:identity_reap_queue, primary_key: false) do
      add :principal_uri, :string, primary_key: true
      add :attempts, :integer, null: false, default: 0
      add :last_error, :text
      add :enqueued_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:identity_reap_queue, [:updated_at, :principal_uri])
  end
end
