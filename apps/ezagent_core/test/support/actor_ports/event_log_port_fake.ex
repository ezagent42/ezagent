defmodule Ezagent.Kind.Ports.EventLogPortFake do
  @moduledoc """
  No-op `:test` fake for `Ezagent.Kind.Ports.EventLogPort` — lets the actor
  framework's own suite run spine-free (§3.4). Every append succeeds with a
  sentinel id and writes nothing. Core's suite wires the real
  `Ezagent.Kind.Adapters.EventLogAdapter`; this fake is for the future
  `ezagent_actor` app's test env.
  """

  @behaviour Ezagent.Kind.Ports.EventLogPort

  @impl true
  def append(_uri, _event, payload, ctx) when is_map(payload) and is_map(ctx), do: {:ok, 0}
end
