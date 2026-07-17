defmodule EzagentCore.Repo.Migrations.CreateRegistrationRequests do
  use Ecto.Migration

  def change do
    # Pre-tenant by design: the requester has not selected or created a
    # workspace yet, so assigning workspace_uri here would invent ownership.
    create table(:registration_requests) do
      add(:email, :string, null: false)
      add(:status, :string, null: false, default: "pending")
      add(:requested_from_ip, :string)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:registration_requests, [:email]))
    create(index(:registration_requests, [:status, :inserted_at]))
  end
end
