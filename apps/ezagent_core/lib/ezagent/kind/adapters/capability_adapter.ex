defmodule Ezagent.Kind.Adapters.CapabilityAdapter do
  @moduledoc """
  Core-side adapter for `Ezagent.Kind.Ports.CapabilityPort` (§3.4) —
  delegates 1:1 to the `Ezagent.Capability` spine. STAYS in core when the
  framework moves to `apps/ezagent_actor`.
  """

  @behaviour Ezagent.Kind.Ports.CapabilityPort

  @impl true
  def workspace_of(uri), do: Ezagent.Capability.workspace_of(uri)

  @impl true
  def cross_workspace?(cap, caller), do: Ezagent.Capability.cross_workspace?(cap, caller)

  @impl true
  def identity_key(cap), do: Ezagent.Capability.identity_key(cap)
end
