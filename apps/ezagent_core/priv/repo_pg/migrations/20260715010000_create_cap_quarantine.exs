defmodule EzagentCore.Repo.Migrations.CreateCapQuarantine do
  use Ecto.Migration

  def change do
    create table(:cap_quarantine) do
      add :workspace_uri, :string, null: false
      add :holder_uri, :string, null: false
      add :cap_identity, :string, null: false
      add :granted_by, :string, null: false
      add :class, :string, null: false
      add :reason, :text, null: false
      add :status, :string, null: false, default: "open"
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      add :closed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cap_quarantine, [:holder_uri, :cap_identity],
             name: :cap_quarantine_holder_identity_index
           )

    create index(:cap_quarantine, [:workspace_uri, :status])
    create index(:cap_quarantine, [:status, :last_seen_at])

    create constraint(:cap_quarantine, :cap_quarantine_status_check,
             check: "status IN ('open', 'resolved')"
           )
  end
end
