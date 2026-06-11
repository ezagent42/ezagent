defmodule Ezagent.Entity.CsOrchestrator do
  @moduledoc """
  CS Orchestrator Kind — agent-flavor entity for the AutoService customer path.

  Each customer gets one orchestrator instance: URI
  `entity://<workspace>/agent/orch_cs_<customer>`, flavor `"cs_orchestrator"`.

  The Kind composes only `Ezagent.Behavior.CsOrchestrator` and uses
  `:snapshot, :on_change` persistence so the open_turn_id / operator_active
  state survives node restarts.

  ## Agent-flavor wiring

  `EzagentPluginAutoservice.Application.agent_flavors/0` declares:

      %{flavor: "cs_orchestrator", kind: __MODULE__,
        template_class: nil}

  `AgentFlavorAttributes.put(uri, "cs_orchestrator")` + `SpawnRegistry.spawn(uri)`
  provision the orchestrator. The provision task (C4) owns the
  provision flow; tests inline it.

  ## Supervisor

  Uses the plugin's own `EzagentPluginAutoservice.InstanceSupervisor` so
  orchestrator instances are isolated from the instance_message domain
  supervisor (correct per P9 — tier ownership follows data).
  """

  use Ezagent.Kind,
    pattern: :entity,
    type_name: :cs_orchestrator,
    supervisor: EzagentPluginAutoservice.InstanceSupervisor

  @behaviour Ezagent.Kind

  attach(Ezagent.Behavior.CsOrchestrator)

  # Kind.Server still reads behaviors/0.
  def behaviors, do: [Ezagent.Behavior.CsOrchestrator]

  # Durable state: open_turn_id + operator_active must survive restarts.
  def persistence, do: {:snapshot, :on_change}
end
