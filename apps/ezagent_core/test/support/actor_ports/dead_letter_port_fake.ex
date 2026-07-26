defmodule Ezagent.Kind.Ports.DeadLetterPortFake do
  @moduledoc """
  No-op `:test` fake for `Ezagent.Kind.Ports.DeadLetterPort` — lets the actor
  framework's own suite run spine-free (§3.4). Core's suite wires the real
  `Ezagent.Kind.Adapters.DeadLetterAdapter`; this fake is for the future
  `ezagent_actor` app's test env.
  """

  @behaviour Ezagent.Kind.Ports.DeadLetterPort

  @impl true
  def put(_reason, _inv), do: :ok
end
