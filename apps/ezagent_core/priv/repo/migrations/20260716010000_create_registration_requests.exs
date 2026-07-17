defmodule EzagentCore.Repo.Migrations.CreateRegistrationRequests do
  use Ecto.Migration

  def change do
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
