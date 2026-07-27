defmodule Ezagent.Kind.Ports.OutboxPort do
  @moduledoc """
  §3.4 OutboxPort — the actor framework's cap-delivery outbox surface,
  resolved via `Application.fetch_env!(:ezagent_actor, :outbox)`.

  Owner (core spine): `Ezagent.Cap.DeliveryOutbox`. SEVEN functions: the
  dispatch/server quintet (`replay?/1`, `eligible?/1`,
  `enqueue_and_attempt/1`, `mark_applied/2`, `record_handler_failure/2`)
  plus the ready-transition drain pair (`pending_target?/1`,
  `drain_target/1`). The core adapter
  (`Ezagent.Kind.Adapters.OutboxAdapter`) delegates 1:1; callback types are
  deliberately loose (`term()`) so the port carries no upward compile edge.
  Moves with the framework to `apps/ezagent_actor`.
  """

  @doc "Is this invocation a durable-outbox REPLAY (claimed delivery row)?"
  @callback replay?(inv :: term()) :: boolean()

  @doc "Is this invocation eligible for durable-outbox enqueue?"
  @callback eligible?(inv :: term()) :: boolean()

  @doc "Enqueue the invocation into the durable outbox and attempt delivery."
  @callback enqueue_and_attempt(inv :: term()) :: term()

  @doc "Mark a claimed delivery row applied after the handler committed."
  @callback mark_applied(delivery_id :: term(), inv :: term()) :: :ok | {:error, term()}

  @doc "Record a handler failure against the invocation's delivery row."
  @callback record_handler_failure(inv :: term(), reason :: term()) :: :ok | {:error, term()}

  @doc "Are there pending outbox rows for this target URI string?"
  @callback pending_target?(target_uri :: term()) :: boolean()

  @doc "Retry all pending rows for one target after its ready transition."
  @callback drain_target(target_uri :: term()) :: :ok
end
