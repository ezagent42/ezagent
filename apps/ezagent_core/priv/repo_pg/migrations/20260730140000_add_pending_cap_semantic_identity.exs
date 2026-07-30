defmodule EzagentCore.Repo.Migrations.AddPendingCapSemanticIdentity do
  use Ecto.Migration

  def change do
    alter table(:cap_delivery_outbox) do
      add :semantic_identity, :string
    end

    create unique_index(
             :cap_delivery_outbox,
             [:workspace_uri, :target_uri, :op, :semantic_identity],
             name: :cap_delivery_outbox_pending_absorb_semantic_identity_index,
             where: "status = 'pending' AND op = 'absorb_cap' AND semantic_identity IS NOT NULL"
           )
  end
end
