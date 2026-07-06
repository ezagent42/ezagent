defmodule EzagentDomainInstanceMessage.SessionBehaviorRegistration do
  @moduledoc """
  The Kind ↔ Behavior `CapabilityRegistry` registrations for the chat plugin's
  Session / User / Agent / Template Kinds, extracted verbatim from
  `EzagentDomainInstanceMessage.Application` for the oversized-module arch gate
  (`oversized_modules_gt_1000` burn-down, 2026-06-23).

  `register/0` is called once at chat-plugin boot
  (`EzagentDomainInstanceMessage.Application.start/2`) BEFORE any Kind is
  spawned, so dispatch routes correctly on the first message. Each
  `CapabilityRegistry.register(Kind, action, Behavior)` binds an action on a Kind
  to the Behavior module that implements it; the bindings live in the app that
  DEFINES the Kind (`feedback_register_lookup_key_parity` / SPEC §5.1 step 7),
  even when the Behavior module ships from another domain app. The function
  returns `:ok`.
  """

  alias Ezagent.CapabilityRegistry
  alias Ezagent.Entity.{Agent, AgentTemplate, Session, SessionTemplate, User}
  alias Ezagent.ActionSet.Session, as: SessionBehavior

  @doc """
  Register every chat-plugin Kind ↔ Behavior binding in `CapabilityRegistry`.

  Returns `:ok`. Idempotent across boots (registry register is by key).
  """
  @spec register() :: :ok
  def register do
    for action <- [
          :send,
          :join,
          :leave,
          :attach,
          :merge_member,
          :assign_role,
          # Membership-cap unification Part C (spec §C.4/§C.5) — the admission
          # approve/deny/withdraw actions (cap-exempt; in-handler manages?/
          # requested_by authz).
          :approve_admission,
          :deny_admission,
          :withdraw_admission
        ] do
      :ok = CapabilityRegistry.register(Session, action, SessionBehavior)
    end

    # LV→world parity PR-2b — `:attach` is the upload chokepoint
    # (`?action=session.attach`, cap co-granted with `:send` in the participation
    # tier; gates the HTTP upload). Phase 7 completion PR-4 (SPEC §1.6) — the
    # Generator + the orchestrator slot tools write the durable
    # `template_working_copy` field via `?action=session.set_working_copy`.
    :ok = CapabilityRegistry.register(Session, :set_working_copy, SessionBehavior)
    # team-routing-unification §3.6 (PR-6) — session-scoped legend registry via
    # `?action=session.set_legends` (orchestrator / system-internal authority).
    :ok = CapabilityRegistry.register(Session, :set_legends, SessionBehavior)
    # team-routing-unification §3.4/§3.7 (PR-7) — session-scoped named
    # prompt-template map via `?action=session.set_prompt_templates` (same
    # orchestrator authority; PR-7 materialization installs `prompt_templates`).
    :ok = CapabilityRegistry.register(Session, :set_prompt_templates, SessionBehavior)
    # PR-2 (§OQ-4) — `:receive` split per Kind into two first-class Behaviors.
    # PR-9a (#53) — `{Agent, :receive}` moved to `EzagentDomainAgent.Application`
    # (the Agent Kind now lives in the agent domain); `{User, :receive}` stays
    # here (User Kind / inbox is the session domain's concern).
    :ok = CapabilityRegistry.register(User, :receive, Ezagent.ActionSet.User.Receive)
    # Phase 6 PR 2: Identity behavior registration (list_caps / has_cap?)
    # moved to ezagent_domain_identity.Application — Identity is the identity
    # domain's concern, not chat's.
    # PR #146 (SPEC v2 §5.7) — session-scoped routing rule mutations
    # dispatch to `session://<name>?action=routing.<action>` against
    # the Session Kind. The synthetic `routing-admin://default`
    # singleton is dissolved; rules naturally cap-scope to their session.
    alias Ezagent.ActionSet.Routing, as: RB

    Enum.each(RB.actions(), fn action ->
      :ok = CapabilityRegistry.register(Session, action, RB)
    end)

    # Domain.Pty PR-B (2026-05-21 SPEC v1) — register the PTY Behavior
    # on the Agent Kind. Behavior module lives in ezagent_domain_pty;
    # the Kind ↔ Behavior binding happens here because this is where
    # `Ezagent.Entity.Agent` is defined. Previously registered from
    # the cc plugin application (PR #146); moved here so
    # the PTY runtime is no longer plugin-cc-specific (any flavor whose
    # template `spawns_with: [Ezagent.Domain.Pty.Server]` reuses the
    # same dispatch path).
    alias Ezagent.ActionSet.Pty, as: PtyB

    Enum.each(PtyB.actions(), fn action ->
      :ok = CapabilityRegistry.register(Agent, action, PtyB)
    end)

    # Phase 7 completion PR-1 (SPEC §1.0) — register the new
    # `Ezagent.ActionSet.Template` Behavior's three actions
    # (`:read` / `:write` / `:instantiate`) on BOTH Template Kinds.
    # After this, `?action=template.read` / `template.write` /
    # `template.instantiate` resolve through `BehaviorRegistry` on
    # either Template Kind and are dispatch-invocable; CapBAC step
    # 5.5 derives `behavior == Ezagent.ActionSet.Template`.
    alias Ezagent.ActionSet.Template, as: TemplateB

    Enum.each(TemplateB.actions(), fn action ->
      :ok = CapabilityRegistry.register(AgentTemplate, action, TemplateB)
      :ok = CapabilityRegistry.register(SessionTemplate, action, TemplateB)
    end)

    # ExternalMirror PR-EM-0 (SPEC §8.1) — `Publisher.SessionImpl` OWNS the
    # `:publisher` slice + the `:subscribe_from` trunk action (cap-gated).
    # P5-A — `:snapshot`/`:history` resolve to the MEMBERSHIP-gated
    # `SocialwarePublisherRead` (cap-EXEMPT, live owner/member check). Both read
    # modules read only `:chat`/`:publisher` (owned here) and live in THIS app
    # (registration-lives-with-the-Kind), so a standalone instance_message run is
    # self-sufficient. P5-1b: these are the UNIFIED `Entity.Session`'s only
    # publisher regs — the former standalone socialware-session Kind (deleted
    # in P5-3) no longer carries any duplicate regs.
    alias Ezagent.ActionSet.Publisher.SessionImpl, as: PublisherSI
    alias Ezagent.ActionSet.SocialwarePublisherRead

    :ok = CapabilityRegistry.register(Session, :subscribe_from, PublisherSI)

    Enum.each(SocialwarePublisherRead.actions(), fn action ->
      :ok = CapabilityRegistry.register(Session, action, SocialwarePublisherRead)
    end)

    # ExternalMirror PR-EM-3 (SPEC §4.1 / §9 PR-EM-3) — register the
    # `Ezagent.ActionSet.ExternalMirror` (bind / unbind / list_bindings) Behavior
    # on `Entity.Session`. Per `feedback_register_lookup_key_parity` / SPEC §5.1
    # step 7, Kind ↔ Behavior wiring lives in the app that DEFINES the Kind
    # (here), even though the module ships from `:ezagent_domain_external_mirror`.
    alias Ezagent.ActionSet.ExternalMirror, as: ExternalMirrorBehavior

    Enum.each(ExternalMirrorBehavior.actions(), fn action ->
      :ok = CapabilityRegistry.register(Session, action, ExternalMirrorBehavior)
    end)

    # P5-1b/P9 (socialware substrate collapse) — register Turn, Surface, and
    # SupervisorApproval on the now-UNIFIED `Entity.Session` (relocated from
    # socialware's `application.ex`, which registered them on the former
    # standalone socialware-session Kind).
    # SAFE under P1: a chat
    # instance's `:kind_base` (`Session.chat_behaviors/0`) excludes Turn/Surface
    # → `instance_set_gate` (runtime E9) DENIES `turn.*`/`surface.*` on it; a
    # socialware instance (`socialware_behaviors/0`) includes them → allowed.
    Enum.each(Ezagent.ActionSet.Turn.actions(), fn action ->
      :ok = CapabilityRegistry.register(Session, action, Ezagent.ActionSet.Turn)
    end)

    Enum.each(Ezagent.ActionSet.Surface.actions(), fn action ->
      :ok = CapabilityRegistry.register(Session, action, Ezagent.ActionSet.Surface)
    end)

    Enum.each(Ezagent.ActionSet.SupervisorApproval.actions(), fn action ->
      :ok =
        CapabilityRegistry.register(
          Session,
          action,
          Ezagent.ActionSet.SupervisorApproval
        )
    end)

    # Phase 7 completion PR-5 (SPEC §1.6b) — register `Behavior.Terminable`'s
    # `:terminate` action on the Agent Kind, so `?action=lifecycle.terminate`
    # is dispatch-invocable + CapBAC-gated and the orchestrator's
    # `remove_agent_slot` / `update_agent_template` tools terminate workers
    # through dispatch, NOT a bare `DynamicSupervisor.terminate_child` (which
    # would bypass CapBAC). The orchestrator's cap #2 (`{:spawned_by, orch}`)
    # permits terminating only ITS OWN workers. (`lifecycle.terminate` is a
    # cosmetic label; resolution is by the `:terminate` atom.)
    alias Ezagent.ActionSet.Terminable, as: TerminableB

    Enum.each(TerminableB.actions(), fn action ->
      :ok = CapabilityRegistry.register(Agent, action, TerminableB)
    end)

    # PR2 2026-05-24 — Sandbox Behavior registers the per-agent config_dir +
    # extension-management actions. In `Agent.behaviors/0` (init_slice fires);
    # ALSO registered so dispatch (read / update_config / destroy) goes through
    # CapBAC. Same pattern as Terminable above.
    alias Ezagent.ActionSet.Sandbox, as: SandboxB

    Enum.each(SandboxB.actions(), fn action ->
      :ok = CapabilityRegistry.register(Agent, action, SandboxB)
    end)

    # RFC #402 — `OrchestratorAdmin` is a cap-only Behavior anchoring the
    # session-owner authority over this session's orchestrator agent. `:restart`
    # is the single cap subject (held by `slice.chat.owner_uri` + bootstrap admin
    # via `:any`); `OrchestratorHealthCard` consults it to gate the Restart
    # button. `dispatchable?: false` → writes ONLY the subject row, no dispatch
    # path can invoke `:restart` (same pattern as `Behavior.Notifications`).
    alias Ezagent.ActionSet.OrchestratorAdmin, as: OrchAdminB

    Enum.each(OrchAdminB.actions(), fn action ->
      :ok = CapabilityRegistry.register(Session, action, OrchAdminB)
    end)

    # Transport #53 Decision C — the orchestrator MCP executor is a plain
    # supervised `Ezagent.Session.SessionManager` GenServer (NOT a Kind / NOT a
    # dispatch action), so there is NOTHING to register here. cc's transport
    # looks it up by orchestrator URI + `GenServer.call`s it with the bridge
    # token, which SessionManager verifies before reconstructing caps + running
    # the op. Decision C REPLACES the deadlocking O-4 `Behavior.OrchestratorTools`
    # + `Orchestrator.ToolRunner` (both deleted) and closes the authz hole: a
    # plain GenServer has no cap-exempt forgeable dispatch entry — the token is.

    # #533 §3.4 — Manage (`:delete` / `:reconfigure`) is a UNIVERSAL behavior
    # (resolves for every Kind via the registry fallback); no per-Kind
    # registration here. The manage-cap granted at create (PR-5c) gates it.

    :ok
  end
end
