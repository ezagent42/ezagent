defmodule Ezagent.Kind.Ports.DeadLetterPort do
  @moduledoc """
  §3.4 DeadLetterPort — the actor framework's dead-letter sink, resolved via
  `Application.fetch_env!(:ezagent_actor, :dead_letter)`.

  Owner (core spine): `Ezagent.DLQ`. The core adapter
  (`Ezagent.Kind.Adapters.DeadLetterAdapter`) delegates 1:1; the invocation
  crosses as opaque `term()` so the port carries no upward compile edge.
  Moves with the framework to `apps/ezagent_actor`.
  """

  @doc "Record a dropped/undeliverable invocation under `reason`. Best-effort."
  @callback put(reason :: atom(), inv :: term()) :: :ok
end
