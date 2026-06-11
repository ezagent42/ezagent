defmodule EzagentPluginAutoservice.Application do
  @moduledoc """
  Autoservice plugin OTP application — the `Ezagent.Plugin` contract
  module for the customer-service vertical.

  ## What this plugin is

  A thin assembly layer on top of existing ezagent primitives that turns
  the platform into a multi-tenant customer-service product:

  - a tenant = a Workspace (e.g. `workspace://cinnox`)
  - per-customer Session with socialware Turn semantics
  - **operator** — sees the workspace's customer sessions and can join
    any of them to talk to the customer directly

  ## Declarations

  - `behaviors/0` — `{CsOrchestrator Kind, action, Behavior}` triples.
  - `agent_flavors/0` — flavor `"cs_orchestrator"` → `CsOrchestrator` Kind.
  - `children/0` — `EzagentPluginAutoservice.InstanceSupervisor` (DynamicSupervisor).
  - `after_boot/0` — no-op in Phase C3; provision task (C4) seeds
    orchestrator instances per customer. Documented here for the
    re-registration hook once provisioning is in place.

  ## AgentFlavorAttributes durability note

  `AgentFlavorAttributes` is non-durable ETS. After a node restart, any
  provisioned orchestrator URIs lose their flavor tag and cannot be
  re-resolved by `SpawnRegistry`. The `after_boot/0` in Phase C4 will
  enumerate provisioned URIs (from a durable store) and re-call
  `AgentFlavorAttributes.put/2` for each. This is a KNOWN gap deferred
  to C4 — documented here per the spike's risk mitigation note.
  """

  use Application
  use Ezagent.Plugin

  # --- OTP Application -------------------------------------------------

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  # --- Ezagent.Plugin contract -----------------------------------------

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "autoservice",
      name: "Autoservice",
      description:
        "Multi-tenant customer-service vertical: per-customer sessions with " <>
          "socialware turn semantics, operator console, and workspace-scoped admin.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def behaviors do
    [
      {Ezagent.Entity.CsOrchestrator, :receive, Ezagent.Behavior.CsOrchestrator},
      {Ezagent.Entity.CsOrchestrator, :operator_claim, Ezagent.Behavior.CsOrchestrator},
      {Ezagent.Entity.CsOrchestrator, :operator_settle, Ezagent.Behavior.CsOrchestrator}
    ]
  end

  @impl Ezagent.Plugin
  def agent_flavors do
    [
      %{
        flavor: "cs_orchestrator",
        kind: Ezagent.Entity.CsOrchestrator,
        # No template class in Phase C3 — provision task (C4) owns creation.
        template_class: nil
      }
    ]
  end

  @impl Ezagent.Plugin
  def children do
    [
      {DynamicSupervisor,
       name: EzagentPluginAutoservice.InstanceSupervisor, strategy: :one_for_one}
    ]
  end

  @doc """
  Phase 3 post-register hook — no-op in Phase C3.

  Phase C4 (provision task) will seed orchestrator instances here and
  re-register `AgentFlavorAttributes` after a node restart, mirroring
  the pattern in `EzagentPluginEcho.Application.after_boot/0`.
  """
  @impl Ezagent.Plugin
  def after_boot, do: :ok
end
