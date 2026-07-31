defmodule EzagentCore.Repo.Migrations.WidenCapDeliveryOutboxOpCheck do
  use Ecto.Migration

  # ② DeliveryOutbox P1/P2(a) (plan Q3 — EXTEND the existing
  # `cap_delivery_outbox` table, no new table): the grant cutover routes the
  # `:identity_grant` producer's `:store_cap` dispatch through the durable
  # outbox, so the `op` check constraint must admit `'store_cap'` alongside
  # the existing `'absorb_cap'` / `'revoke_cap'`.

  def up do
    drop constraint(:cap_delivery_outbox, :cap_delivery_outbox_op_check)

    create constraint(:cap_delivery_outbox, :cap_delivery_outbox_op_check,
             check: "op IN ('absorb_cap', 'revoke_cap', 'store_cap')"
           )
  end

  def down do
    execute("DELETE FROM cap_delivery_outbox WHERE op = 'store_cap'")

    drop constraint(:cap_delivery_outbox, :cap_delivery_outbox_op_check)

    create constraint(:cap_delivery_outbox, :cap_delivery_outbox_op_check,
             check: "op IN ('absorb_cap', 'revoke_cap')"
           )
  end
end
