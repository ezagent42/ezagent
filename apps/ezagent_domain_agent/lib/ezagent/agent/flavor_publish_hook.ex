defmodule Ezagent.Agent.FlavorPublishHook do
  @moduledoc """
  Domain-agent implementation of core's flavor publish hook.
  """

  @behaviour Ezagent.Plugin.FlavorPublishHook

  @impl true
  def publish_agent_flavor(decl) when is_map(decl) do
    Ezagent.AgentFlavorRegistry.register(decl)
  end

  @impl true
  def after_plugin_publish(plugin_module) when is_atom(plugin_module) do
    Ezagent.AgentFlavorRegistry.note_plugin_published(plugin_module)
  end
end
