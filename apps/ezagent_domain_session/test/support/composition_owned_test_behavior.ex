defmodule EzagentDomainInstanceMessage.CompositionOwnedTestBehavior do
  @moduledoc false

  use Ezagent.Lifecycle, state_slice: :composition_owned_test

  action(:composition_owned_probe,
    args: %{},
    returns: %{ok: :boolean},
    caps: [:composition_owned_probe],
    modes: [:call],
    description: "test-only owner-resolvable composition target"
  )

  def required_caps do
    %{
      composition_owned_probe:
        Ezagent.Capability.cap(:agent, __MODULE__, :composition_owned_probe)
    }
  end

  def data_owner(instance), do: Ezagent.ActionSet.ApiKeys.data_owner(instance)

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  def handle_composition_owned_probe(_args, _ctx), do: {:ok, %{ok: true}, []}
end
