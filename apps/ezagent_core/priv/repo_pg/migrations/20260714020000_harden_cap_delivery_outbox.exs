defmodule EzagentCore.Repo.Migrations.HardenCapDeliveryOutbox do
  use Ecto.Migration

  def up do
    alter table(:cap_delivery_outbox) do
      add :payload_version, :integer, null: false, default: 1
      add :idempotency_key, :string
      add :claim_token, :string
      add :lease_until, :utc_datetime_usec
      add :dead_at, :utc_datetime_usec
    end

    drop constraint(:cap_delivery_outbox, :cap_delivery_outbox_status_check)

    create constraint(:cap_delivery_outbox, :cap_delivery_outbox_status_check,
             check: "status IN ('pending', 'applied', 'dead')"
           )

    create unique_index(
             :cap_delivery_outbox,
             [:workspace_uri, :target_uri, :op, :idempotency_key],
             where: "idempotency_key IS NOT NULL",
             name: :cap_delivery_outbox_idempotency_unique
           )

    create index(:cap_delivery_outbox, [:status, :lease_until])
  end

  def down do
    execute(
      "UPDATE cap_delivery_outbox SET status = 'pending', dead_at = NULL WHERE status = 'dead'"
    )

    drop index(:cap_delivery_outbox, [:status, :lease_until])
    drop index(:cap_delivery_outbox, name: :cap_delivery_outbox_idempotency_unique)
    drop constraint(:cap_delivery_outbox, :cap_delivery_outbox_status_check)

    create constraint(:cap_delivery_outbox, :cap_delivery_outbox_status_check,
             check: "status IN ('pending', 'applied')"
           )

    alter table(:cap_delivery_outbox) do
      remove :dead_at
      remove :lease_until
      remove :claim_token
      remove :idempotency_key
      remove :payload_version
    end
  end
end
