defmodule Ezagent.Kind.Ports.CapabilityPortFake do
  @moduledoc """
  Strict no-op `:test` fake for `Ezagent.Kind.Ports.CapabilityPort` — lets
  the actor framework's own suite run spine-free (§3.4). Core's suite wires
  the real `Ezagent.Kind.Adapters.CapabilityAdapter`; this fake is for the
  future `ezagent_actor` app's test env.
  """

  @behaviour Ezagent.Kind.Ports.CapabilityPort

  @impl true
  def workspace_of(_uri), do: :any

  @impl true
  def cross_workspace?(_cap, _caller), do: false

  @impl true
  def identity_key(_cap), do: nil
end
