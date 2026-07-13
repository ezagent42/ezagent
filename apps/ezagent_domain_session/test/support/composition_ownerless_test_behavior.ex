defmodule EzagentDomainInstanceMessage.CompositionOwnerlessTestBehavior do
  @moduledoc false

  use Ezagent.Lifecycle, state_slice: :composition_ownerless_test

  action(:composition_ownerless_probe,
    args: %{},
    returns: %{ok: :boolean},
    caps: [:composition_ownerless_probe],
    modes: [:call],
    description: "test-only ownerless composition target"
  )

  def required_caps do
    %{
      composition_ownerless_probe:
        Ezagent.Capability.cap(:agent, __MODULE__, :composition_ownerless_probe)
    }
  end

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  def handle_composition_ownerless_probe(_args, _ctx), do: {:ok, %{ok: true}, []}
end
