defmodule EzagentPluginCc.Orchestrator.ContextAdapter do
  @moduledoc """
  CC transport adapter for the session-owned orchestrator context port.

  This adapter owns no readiness or live-join state. It only stores and removes
  the MCP routing context; transport readiness remains the generic agent-domain
  contract.
  """

  @behaviour Ezagent.Session.OrchestratorContextPort

  @impl true
  def register_context(%URI{} = orchestrator_uri, context) when is_list(context),
    do: Ezagent.Orchestrator.McpRegistry.register(orchestrator_uri, context)

  @impl true
  def unregister(%URI{} = orchestrator_uri),
    do: Ezagent.Orchestrator.McpRegistry.unregister(orchestrator_uri)
end
