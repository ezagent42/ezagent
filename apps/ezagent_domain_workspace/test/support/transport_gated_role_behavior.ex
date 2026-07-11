defmodule Ezagent.Workspace.TransportGatedRoleBehavior do
  @moduledoc false

  # S7 I3 test-only role Behavior. Its real lifecycle activation arms the same
  # external transport gate used by bridge-backed agents before Kind readiness
  # can publish. The transport is intentionally never joined, so the full
  # Workspace.create_agent role lane must return while its self-store artifact
  # remains in PendingDelivery.
  use Ezagent.Lifecycle, state_slice: :transport_gated_role

  action(:ping,
    args: %{},
    returns: %{pong: :boolean},
    caps: [:ping],
    modes: [:call],
    description: "test-only transport-gated role action"
  )

  def required_caps do
    %{ping: Ezagent.Capability.cap(:agent, __MODULE__, :ping)}
  end

  def data_owner(%URI{} = entity_uri), do: Ezagent.URI.instance(entity_uri)
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{created?: true}}

  @impl Ezagent.Lifecycle
  def activate(_state, %{self_uri: self_uri}) do
    :ok =
      Ezagent.Agent.TransportReadiness.require_transport_join(
        self_uri,
        timeout_ms: 30_000
      )

    {:ok, %{transport_gate_armed?: true}}
  end

  def handle_ping(_args, _ctx), do: {:ok, %{pong: true}, []}
end
