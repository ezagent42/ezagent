defmodule Ezagent.Session.OrchestratorReadinessPassthrough do
  @moduledoc """
  PR-8a passthrough impl of `Ezagent.Session.OrchestratorReadinessPort`.

  In PR-8a the orchestrator-MCP transport modules
  (`Ezagent.Orchestrator.McpChannel`/`LiveJoinRegistry`/`McpRegistry`) still
  live in THIS app (`ezagent_domain_instance_message`) — the §1.6 anomaly the
  decomposition is unwinding. So the readiness logic in
  `Ezagent.Entity.Session.Orchestrator` calls the session-owned PORT, and the
  app registers THIS thin passthrough at boot
  (`EzagentDomainInstanceMessage.Application.start/2`, beside the
  `McpRegistry.init/0`/`LiveJoinRegistry.init/0` calls). The result is pure
  indirection: orchestrator.ex no longer NAMES the transport modules, but
  behavior is identical to the direct calls it replaced — including in the
  standalone orchestrator integration tests, which run without the cc plugin
  loaded (so a cc-registered impl would never fire there).

  ## Why "the current owner registers"

  The rule is: whoever the transport modules live with registers the readiness
  impl. PR-8 relocates those three modules into the cc plugin; at that point
  this passthrough moves with them and becomes
  `EzagentPluginCc.Orchestrator.ReadinessAdapter`, registered at cc boot, and
  this app is left with only the port + its neutral fallback (spec §3.6). No
  orchestrator.ex churn at that step — the port seam is already in place.
  """

  @behaviour Ezagent.Session.OrchestratorReadinessPort

  @impl true
  def lifecycle_topic, do: Ezagent.Orchestrator.McpChannel.lifecycle_topic()

  @impl true
  def joined?(%URI{} = orchestrator_uri),
    do: Ezagent.Orchestrator.LiveJoinRegistry.joined?(orchestrator_uri)

  @impl true
  def clear(%URI{} = orchestrator_uri),
    do: Ezagent.Orchestrator.LiveJoinRegistry.clear(orchestrator_uri)

  @impl true
  def register_context(%URI{} = orchestrator_uri, context) when is_list(context),
    do: Ezagent.Orchestrator.McpRegistry.register(orchestrator_uri, context)
end
