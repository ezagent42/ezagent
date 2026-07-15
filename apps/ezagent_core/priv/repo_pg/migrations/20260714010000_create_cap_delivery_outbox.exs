defmodule EzagentCore.Repo.Migrations.CreateCapDeliveryOutbox do
  use Ecto.Migration

  def change do
    create table(:cap_delivery_outbox) do
      add :workspace_uri, :string, null: false
      add :target_uri, :string, null: false
      add :op, :string, null: false
      add :payload, :binary, null: false
      add :payload_identity, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :next_retry_at, :utc_datetime_usec, null: false
      add :last_error, :text
      add :applied_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cap_delivery_outbox, [:workspace_uri])
    create index(:cap_delivery_outbox, [:target_uri, :status])
    create index(:cap_delivery_outbox, [:status, :next_retry_at])

    create constraint(:cap_delivery_outbox, :cap_delivery_outbox_op_check,
             check: "op IN ('absorb_cap', 'revoke_cap')"
           )

    create constraint(:cap_delivery_outbox, :cap_delivery_outbox_status_check,
             check: "status IN ('pending', 'applied')"
           )

    create constraint(:cap_delivery_outbox, :cap_delivery_outbox_attempts_check,
             check: "attempts >= 0"
           )
  end
end
