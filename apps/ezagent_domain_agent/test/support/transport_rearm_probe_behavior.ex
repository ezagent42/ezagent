defmodule Ezagent.Agent.TransportRearmProbeBehavior do
  @moduledoc false

  use Ezagent.Lifecycle, state_slice: :transport_rearm_probe

  action(:probe,
    args: %{},
    returns: %{ok: :boolean},
    caps: [:probe],
    modes: [:call],
    description: "test-only transport re-arm lifecycle probe"
  )

  def required_caps do
    %{probe: Ezagent.Capability.cap(:agent, __MODULE__, :probe)}
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

  @impl Ezagent.Lifecycle
  def activated(_state, %{self_uri: self_uri}) do
    case :persistent_term.get({__MODULE__, :test_pid}, nil) do
      pid when is_pid(pid) -> send(pid, {:transport_rearm_activated, self_uri})
      _ -> :ok
    end

    :ok
  end

  def handle_probe(_args, _ctx), do: {:ok, %{ok: true}, []}
end
