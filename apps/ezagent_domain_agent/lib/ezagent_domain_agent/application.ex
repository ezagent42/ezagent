defmodule EzagentDomainAgent.Application do
  @moduledoc """
  The agent domain (`im → session → agent`, PR-9a #53). Owns the Agent Kind
  (`Ezagent.Entity.Agent`), its Template Kind (`Ezagent.Entity.AgentTemplate`),
  the `agent.receive` transport seam (`Ezagent.Behavior.Agent.Receive` →
  `Ezagent.AgentBridge`), and the two Agent DynamicSupervisors.

  ## Frozen supervisor names (brief D1a)

  The DynamicSupervisor name atoms `EzagentDomainInstanceMessage.AgentSupervisor`
  and `EzagentDomainInstanceMessage.AgentTemplateSupervisor` are FROZEN: relocated
  here from the session domain's Application but NOT renamed.
  `Ezagent.Entity.Agent.supervisor/0` / `AgentTemplate.supervisor/0` return these
  atoms, and a rename would change no persisted key but would churn those call
  sites — kept stable per the brief's "module/name freeze" rule.
  """

  use Application

  alias Ezagent.CapabilityRegistry
  alias Ezagent.Entity.Agent
  alias Ezagent.Behavior.Agent.Receive, as: AgentReceive

  @impl Application
  def start(_type, _args) do
    children = [
      {EzagentDomainAgent.EtsOwner, []},
      # Agent Kind DynamicSupervisor — 0 children at boot; agents demand-spawn
      # / rehydrate lazily. Frozen name (D1a).
      {DynamicSupervisor,
       name: EzagentDomainInstanceMessage.AgentSupervisor, strategy: :one_for_one},
      # AgentTemplate Kind DynamicSupervisor — 0 children at boot; templates
      # materialize on admin create or snapshot restore. Frozen name (D1a).
      {DynamicSupervisor,
       name: EzagentDomainInstanceMessage.AgentTemplateSupervisor, strategy: :one_for_one},
      # #505 — carries AgentBridge connect events into TransportReadiness so a
      # bridge-backed agent's ReadyGate flips to :ready on the real bind even when
      # the bind lands AFTER the Kind's ready announce (fresh-spawn ordering).
      Ezagent.Agent.TransportReadinessListener
    ]

    result =
      Supervisor.start_link(children,
        strategy: :one_for_one,
        name: EzagentDomainAgent.Supervisor
      )

    # PR-2 (§OQ-4) — `agent.receive` is the Agent Kind's active live-process
    # delivery seam, owned by the agent domain. Registered here (declare-don't-call,
    # Invariant #8) now that the Agent Kind lives in this app.
    :ok = CapabilityRegistry.register(Agent, :receive, AgentReceive)
    :ok = Ezagent.Agent.TransportReadiness.init()
    :ok = Ezagent.ReadyGate.register_external_gate(Ezagent.Agent.TransportReadiness)
    :ok = Ezagent.Kind.Template.FlavorHook.register(Ezagent.Agent.FlavorTemplateHook)
    :ok = Ezagent.Plugin.FlavorPublishHook.register(Ezagent.Agent.FlavorPublishHook)
    # role-as-data (SPEC §4): register the role-seed hook impl so each plugin's
    # `roles/0` is seeded as a role ConfigObject at boot. Registered HERE (before
    # any role-declaring plugin boots — they all compile-dep domain_agent).
    :ok = Ezagent.Plugin.RoleSeedHook.register(Ezagent.Agent.RoleSeedHook)
    # Plugin-package (Q1-C): register the package seed-hook impl so a
    # hot-loaded plugin package's `seed_refs` (recipe definitions) are
    # seeded into ConfigStore at install + retired at unload. Registered
    # HERE (the host is up before any package install call).
    :ok = Ezagent.Plugin.SeedHook.register(Ezagent.Agent.PackageSeedHook)

    result
  end
end
