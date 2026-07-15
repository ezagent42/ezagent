defmodule EzagentCore.Repo.Migrations.AddCapHealDelivery do
  use Ecto.Migration

  def up do
    drop constraint(:cap_delivery_outbox, :cap_delivery_outbox_op_check)

    create constraint(:cap_delivery_outbox, :cap_delivery_outbox_op_check,
             check: "op IN ('absorb_cap', 'revoke_cap', 'heal_cap')"
           )
  end

  def down do
    execute("DELETE FROM cap_delivery_outbox WHERE op = 'heal_cap'")
    drop constraint(:cap_delivery_outbox, :cap_delivery_outbox_op_check)

    create constraint(:cap_delivery_outbox, :cap_delivery_outbox_op_check,
             check: "op IN ('absorb_cap', 'revoke_cap')"
           )
  end
end
