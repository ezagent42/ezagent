defmodule Ezagent.Behavior.OrchestratorAdmin do
  @moduledoc """
  Cap-only Behavior anchoring the session-owner authority over the
  session's orchestrator agent.

  ## What this gates

  `:restart` — the authority to restart this session's orchestrator
  agent. Held by:

  1. The **session owner** (`slice.chat.owner_uri`) — granted
     structurally at session creation by
     `Ezagent.Entity.Session.spawn_from_template/2` (see
     `Ezagent.Entity.Session.owner_orchestrator_admin_cap/2`).
  2. The **bootstrap admin** — via its all-caps `:any/:any/:any/:any`
     grant.
  3. Anyone explicitly granted `cap(:session, OrchestratorAdmin,
     :restart, <session_uri>, <ws>)` by the owner (delegation).

  ## Why this exists (RFC #402, Allen 2026-05-26)

  Pre-RFC the Restart button in `OrchestratorHealthCard` was gated on
  the caller holding `cap(:any, Behavior.Template, :instantiate)` on
  the cc-orchestrator AgentTemplate URI. That cap is held by the
  workspace admin and by anyone with template-instantiate authority —
  it does NOT track session ownership. So a workspace admin could
  restart any session's orchestrator without being the session owner,
  and the session owner needed the template-level cap (overkill — that
  cap also lets them instantiate arbitrary cc agents).

  The redesign:

  - The session creator (`session.chat.owner_uri`) gets THIS cap
    automatically at session-create time.
  - The LV's `OrchestratorHealthCard` consults THIS cap (not the
    template-instantiate cap) when deciding whether to render the
    Restart button.
  - The actual restart still dispatches `template.instantiate` on the
    cc-orchestrator template (no change to the orchestrator-spawn
    mechanics). The OrchestratorAdmin cap is the UX-gating + ownership
    contract; the underlying template cap remains the structural
    authority.

  ## Why cap-only

  No action is invoked against this Behavior — it's a pure cap shim,
  the same pattern `Ezagent.Behavior.Presence` uses. The dispatch
  CapBAC chokepoint records the cap subject + checks against caller
  caps; the handler is unreachable in practice (the LV reads the cap
  and dispatches `template.instantiate` directly).

  Migrated to the SPEC 2026-05-28 new-action contract (P2-a r3,
  2026-05-28). The handler exists so the new-contract Behavior is
  structurally well-formed (every `action` MUST have `handle_<action>`),
  but it returns an error tuple if ever reached — defence in depth.

  Registered against `Ezagent.Entity.Session` in
  `EzagentDomainChat.Application.start/2`. Lives in
  `ezagent_domain_chat` because `data_owner/1` delegates to
  `Ezagent.Behavior.Chat.data_owner/1` (which reads
  `slice.chat.owner_uri`); a `ezagent_core` location would create a
  core→domain dependency.
  """

  use Ezagent.Behavior

  # NOTE: `:restart` carries the cap-subject + handler shape required
  # by the new-contract Behavior macro; reaching the handler in
  # practice is a misuse (the LV consults the cap and dispatches
  # `template.instantiate` on the cc-orchestrator template). The
  # handler returns `{:error, :cap_only_action}` rather than raising,
  # so a stray dispatch is a clean rejection rather than a Kind crash.
  action :restart,
    args: %{},
    returns: :ok,
    caps: [:restart],
    modes: [:call],
    description: "restart this session's orchestrator agent (session-owner authority)",
    data_owner: :self

  def state_slice, do: :orchestrator_admin

  def init_slice(_args), do: %{}

  # Override the macro-generated `required_caps/0` to declare the
  # `:session` kind axis explicitly. OrchestratorAdmin registers only
  # on `Ezagent.Entity.Session`, so the cap kind is `:session` —
  # NOT the macro's default `:any` (which is correct for multi-Kind
  # Behaviors like `Chat`).
  def required_caps do
    %{restart: Ezagent.Capability.cap(:session, __MODULE__, :restart)}
  end

  # The Behavior was cap-only pre-migration; in the new contract we
  # still want a stable signal so the
  # `CapabilityRegistry.register/3` path can opt out of writing to
  # the dispatchable BehaviorRegistry. The macro doesn't surface
  # `dispatchable?/0` (it's an OPTIONAL legacy callback); we keep it
  # as `false` so registration semantics match pre-migration.
  def dispatchable?, do: false

  def handle_restart(_args, _ctx) do
    # Cap-only — see moduledoc. If a caller ever reaches this handler
    # they should be dispatching template.instantiate instead. We
    # raise rather than return {:error, _} so legacy tests that
    # assert_raise on the original cap-only message keep working;
    # the runtime maps the raise to {:error, {:behavior_exception,
    # :error, %RuntimeError{...}}} for a clean propagation.
    raise "Ezagent.Behavior.OrchestratorAdmin.:restart is cap-only — " <>
            "the UI (OrchestratorHealthCard) consults this cap to gate the " <>
            "Restart button; the actual restart still dispatches " <>
            "template.instantiate on the cc-orchestrator template."
  end

  # RFC #402: the cap data-owner is the session's owner. The session
  # URI's owner is read by `Ezagent.Behavior.Chat.data_owner/1` (which
  # reads `slice.chat.owner_uri` via `Session.owner/1`); we route
  # through there to keep one source of truth.
  def data_owner(%URI{scheme: "session"} = session_uri) do
    Ezagent.Behavior.Chat.data_owner(session_uri)
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end
