defmodule Ezagent.Entity.AgentBehaviorDerivationTest do
  use ExUnit.Case, async: false

  alias Ezagent.Entity.Agent

  defmodule ExtraBehavior do
    @behaviour Ezagent.Behavior

    @impl true
    def actions, do: [:agent_behavior_derivation_probe]

    @impl true
    def required_caps, do: %{}

    @impl true
    def cap_subjects, do: [{:agent_behavior_derivation_probe, "test probe"}]

    @impl true
    def state_slice, do: :agent_behavior_derivation_probe

    @impl true
    def init_slice(_args), do: %{}

    @impl true
    def invoke(_action, slice, _args, _ctx), do: {:ok, slice, %{}}

    @impl true
    def interface, do: %{}
  end

  defmodule TemplateClass do
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "agent.behavior-derivation-test"

    @impl true
    def instantiate(_name, _data, _workspace_uri), do: {:ok, []}
  end

  test "behaviors/0 folds instance behaviors from registered agent flavors" do
    flavor = "behavior-derivation-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      :ets.delete(Ezagent.AgentFlavorRegistry.table(), flavor)
      Ezagent.AgentFlavorRegistry.reset_seal_for_test!()
    end)

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Agent,
        template_class: TemplateClass,
        instance_behaviors: fn -> [ExtraBehavior] end
      })

    :ok = Ezagent.AgentFlavorRegistry.seal!()

    assert ExtraBehavior in Agent.behaviors()
  end
end
