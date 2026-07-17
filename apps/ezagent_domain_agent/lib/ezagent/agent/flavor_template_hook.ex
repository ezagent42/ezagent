defmodule Ezagent.Agent.FlavorTemplateHook do
  @moduledoc """
  Domain-agent implementation of the core Template flavor hook.

  A1 reversed the call direction from `Ezagent.Kind.Template`; A2 moves the
  attribute store into this domain.
  """

  @behaviour Ezagent.Kind.Template.AttributeHook

  @impl true
  def store_attributes(%URI{} = agent_uri, class_module) when is_atom(class_module) do
    Ezagent.AgentFlavorAttributes.maybe_put_from_template_class(agent_uri, class_module)
  end

  @impl true
  def delete_attributes(%URI{} = agent_uri) do
    Ezagent.AgentFlavorAttributes.delete(agent_uri)
  end
end
