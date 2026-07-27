defmodule Ezagent.Kind.Adapters.OutboxAdapter do
  @moduledoc """
  Core-side adapter for `Ezagent.Kind.Ports.OutboxPort` (§3.4) — delegates
  1:1 to the `Ezagent.Cap.DeliveryOutbox` spine. STAYS in core when the
  framework moves to `apps/ezagent_actor`.
  """

  @behaviour Ezagent.Kind.Ports.OutboxPort

  @impl true
  def replay?(inv), do: Ezagent.Cap.DeliveryOutbox.replay?(inv)

  @impl true
  def eligible?(inv), do: Ezagent.Cap.DeliveryOutbox.eligible?(inv)

  @impl true
  def enqueue_and_attempt(inv), do: Ezagent.Cap.DeliveryOutbox.enqueue_and_attempt(inv)

  @impl true
  def mark_applied(delivery_id, inv),
    do: Ezagent.Cap.DeliveryOutbox.mark_applied(delivery_id, inv)

  @impl true
  def record_handler_failure(inv, reason),
    do: Ezagent.Cap.DeliveryOutbox.record_handler_failure(inv, reason)

  @impl true
  def pending_target?(target_uri), do: Ezagent.Cap.DeliveryOutbox.pending_target?(target_uri)

  @impl true
  def drain_target(target_uri), do: Ezagent.Cap.DeliveryOutbox.drain_target(target_uri)
end
