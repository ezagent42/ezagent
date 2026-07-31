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
    # ② must-fix #6 — NEVER silently DELETE queued `store_cap` rows on
    # rollback: each is an offline holder's pending durable grant, and
    # dropping it loses the grant without any operator signal. REFUSE the
    # rollback while any exist; the operator must drain or deliberately
    # clear them first.
    %{rows: [[store_cap_rows]]} =
      repo().query!("SELECT count(*) FROM cap_delivery_outbox WHERE op = 'store_cap'", [])

    if store_cap_rows > 0 do
      raise """
      refusing to roll back widen_cap_delivery_outbox_op_check: #{store_cap_rows} \
      store_cap row(s) still exist in cap_delivery_outbox. Rolling back would \
      require deleting them, silently dropping an offline holder's pending \
      durable grant. Drain or deliberately clear those rows first, then retry.
      """
    end

    drop constraint(:cap_delivery_outbox, :cap_delivery_outbox_op_check)

    create constraint(:cap_delivery_outbox, :cap_delivery_outbox_op_check,
             check: "op IN ('absorb_cap', 'revoke_cap')"
           )
  end
end
