defmodule Ezagent.Kind.Ports.OutboxPortFake do
  @moduledoc """
  Strict no-op `:test` fake for `Ezagent.Kind.Ports.OutboxPort` — lets the
  actor framework's own suite run spine-free (§3.4). Core's suite wires the
  real `Ezagent.Kind.Adapters.OutboxAdapter`; this fake is for the future
  `ezagent_actor` app's test env.
  """

  @behaviour Ezagent.Kind.Ports.OutboxPort

  @impl true
  def replay?(_inv), do: false

  @impl true
  def eligible?(_inv), do: false

  @impl true
  def enqueue_and_attempt(_inv), do: {:error, :outbox_not_configured}

  @impl true
  def mark_applied(_delivery_id, _inv), do: :ok

  @impl true
  def record_handler_failure(_inv, _reason), do: :ok

  @impl true
  def pending_target?(_target_uri), do: false

  @impl true
  def drain_target(_target_uri), do: :ok
end
