defmodule EzagentCore.Repo.Migrations.AddGrantIdToCapDeliveryOutbox do
  use Ecto.Migration

  def change do
    alter table(:cap_delivery_outbox) do
      add :grant_id, :uuid, null: false
    end

    create index(:cap_delivery_outbox, [:workspace_uri, :grant_id, :status])
  end
end
