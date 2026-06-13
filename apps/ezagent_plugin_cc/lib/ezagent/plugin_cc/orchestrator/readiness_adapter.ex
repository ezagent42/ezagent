defmodule EzagentPluginCc.Orchestrator.ReadinessAdapter do
  @moduledoc """
  PR-8 cc-resident impl of `Ezagent.Session.OrchestratorReadinessPort`.

  The orchestrator-MCP transport modules (`Ezagent.Orchestrator.McpChannel` /
  `LiveJoinRegistry` / `McpRegistry` / `McpServer`) now live in THIS plugin
  (`ezagent_plugin_cc`) — relocated out of the session domain in PR-8. The
  session's orchestrator readiness logic (`Ezagent.Entity.Session.Orchestrator`)
  calls the session-owned PORT; the cc plugin registers THIS adapter at boot
  (`EzagentPluginCc.Application.after_boot/0`), which forwards to the
  cc-resident transport modules.

  This is the PR-8 successor of the PR-8a
  `Ezagent.Session.OrchestratorReadinessPassthrough` (deleted): same forwarding
  shape, but now "the current owner registers" means the cc plugin — the
  session domain is left with only the port + its neutral fallback (spec §3.6),
  and never names a transport module, keeping the `im → session → agent` graph
  acyclic.
  """

  @behaviour Ezagent.Session.OrchestratorReadinessPort

  @impl true
  def lifecycle_topic, do: Ezagent.Orchestrator.McpChannel.lifecycle_topic()

  @impl true
  def joined?(%URI{} = orchestrator_uri),
    do: Ezagent.Orchestrator.LiveJoinRegistry.joined?(orchestrator_uri)

  @impl true
  def ready?(%URI{} = orchestrator_uri),
    do: match?({:ok, _}, Ezagent.Orchestrator.McpServer.from_orchestrator_uri(orchestrator_uri))

  @impl true
  def clear(%URI{} = orchestrator_uri),
    do: Ezagent.Orchestrator.LiveJoinRegistry.clear(orchestrator_uri)

  @impl true
  def unregister(%URI{} = orchestrator_uri),
    do: Ezagent.Orchestrator.McpRegistry.unregister(orchestrator_uri)

  @impl true
  def register_context(%URI{} = orchestrator_uri, context) when is_list(context),
    do: Ezagent.Orchestrator.McpRegistry.register(orchestrator_uri, context)
end
