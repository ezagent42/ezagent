defmodule EzagentDomainAgent.Application do
  @moduledoc """
  The agent domain (`im → session → agent`, PR-9a #53). Owns the Agent Kind
  (`Ezagent.Entity.Agent`), its Template Kind (`Ezagent.Entity.AgentTemplate`),
  the `agent.receive` transport seam (`Ezagent.ActionSet.Agent.Receive` →
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
  alias Ezagent.ActionSet.Agent.Receive, as: AgentReceive

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

    # Test-only: register the per-boot role-seed registry reset so the shared
    # `EzagentCore.DataCase` clears it between tests (one test == one fresh boot).
    # Core must not name `RecipeRegistry` (the `no_role_concept_in_core` gate), so
    # the reset is registered HERE into a plain-atom persistent_term hook list that
    # core drains without referencing the domain layer.
    if test_env?() do
      register_boot_seed_reset_hook()
    end

    result
  end

  defp register_boot_seed_reset_hook do
    hooks = :persistent_term.get(:ezagent_test_boot_reset_hooks, [])

    :persistent_term.put(
      :ezagent_test_boot_reset_hooks,
      Enum.uniq([(&Ezagent.Agent.RecipeRegistry.reset_boot_seed_registry/0) | hooks])
    )

    :ok
  end

  defp test_env? do
    Code.ensure_loaded?(Mix) and Mix.env() == :test
  rescue
    _ -> false
  end
end
