defmodule EzagentDomainInstanceMessage.MaterializedRoleTestBehavior do
  @moduledoc false

  use Ezagent.Lifecycle, state_slice: :materialized_role_test

  action(:ping,
    args: %{},
    returns: %{pong: :boolean},
    caps: [:ping],
    modes: [:call],
    description: "test-only recipe behavior for socialware materialized role members"
  )

  def required_caps do
    %{ping: Ezagent.Capability.cap(:agent, __MODULE__, :ping)}
  end

  def data_owner(%URI{} = entity_uri), do: Ezagent.URI.instance(entity_uri)
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{pinged: false}}

  def handle_ping(_args, _ctx) do
    {:ok, %{pong: true}, [{:set, :pinged, true}]}
  end
end
