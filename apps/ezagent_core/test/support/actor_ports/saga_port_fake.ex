defmodule Ezagent.Kind.Ports.SagaPortFake do
  @moduledoc """
  Strict `:test` fake for `Ezagent.Kind.Ports.SagaPort` — lets the actor
  framework's own suite run spine-free (§3.4). Every execution returns
  `{:error, :saga_runner_not_loaded}`, the port's documented not-available
  signal. Core's suite wires the real `Ezagent.Kind.Adapters.SagaAdapter`;
  this fake is for the future `ezagent_actor` app's test env.
  """

  @behaviour Ezagent.Kind.Ports.SagaPort

  @impl true
  def execute(_saga, _ctx), do: {:error, :saga_runner_not_loaded}
end
