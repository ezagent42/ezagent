defmodule Ezagent.ActionSet.OrchestratorAdmin do
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
  the same pattern `Ezagent.ActionSet.Notifications` uses. The dispatch
  CapBAC chokepoint records the cap subject + checks against caller
  caps; the handler is unreachable in practice (the LV reads the cap
  and dispatches `template.instantiate` directly).

  Migrated to the SPEC 2026-05-28 new-action contract (P2-a r3,
  2026-05-28). The handler exists so the new-contract Behavior is
  structurally well-formed (every `action` MUST have `handle_<action>`),
  but it returns an error tuple if ever reached — defence in depth.

  Registered against `Ezagent.Entity.Session` in
  `EzagentDomainInstanceMessage.Application.start/2`. Lives in
  `ezagent_domain_session` because `data_owner/1` delegates to
  `Ezagent.ActionSet.Session.data_owner/1` (which reads
  `slice.chat.owner_uri`); a `ezagent_core` location would create a
  core→domain dependency.

  ## Lifecycle migration (Phase B, SPEC 2026-05-29 §2.3 — the cap-only /
  ## no-state case)

  Converted from `use Ezagent.ActionSet` to `use Ezagent.Lifecycle`. This
  is the trivial conversion: cap-only Behavior with an EMPTY slice and NO
  transients. `init_slice/1` → `create/1` returning `{:ok, %{}}` (the
  persistent state is empty — the cap is the whole point); `activate/2`
  is the macro-injected no-op default (no transients to rebuild). The
  hand-rolled `def state_slice` is gone — the macro auto-derives
  `Ezagent.ActionSet.OrchestratorAdmin` → `:orchestrator_admin`, which is
  EXACTLY the pre-Lifecycle key, so no `state_slice:` override is needed
  (SPEC §5 step 2 / §7 OQ-7).

  `required_caps/0` / `dispatchable?/0` / `data_owner/1` / the
  `handle_restart/2` cap-only handler all pass through the Lifecycle
  macro unchanged (SPEC §3 mapping table).

  Naming (§11 NP-1/NP-2/NP-3 audit): `Ezagent.ActionSet.OrchestratorAdmin`
  — a domain module (`apps/ezagent_domain_session`); NP-2 (layer-vocabulary)
  only forbids upper-layer concept words in `apps/ezagent_core/`, so an
  `Orchestrator`-named domain module is permitted. NP-3 (width): the name
  is broader than its single `:restart` action — but it names a coherent
  authority surface (session-owner authority over the orchestrator),
  matching the `Notifications` cap-only sibling, and a rename would
  touch the `:orchestrator_admin` snapshot key + the LV's restart gate +
  the first-join owner-cap grant in `Chat.grant_first_join_owner_cap/2`
  for no clarity gain. Kept as-is.
  """

  use Ezagent.Lifecycle

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

  # `init_slice/1` → `create/1` (SPEC §3 mapping): the persistent state
  # is empty (this is a cap-only Behavior — the authority lives in the
  # cap, not in per-instance state). `activate/2` is the macro no-op
  # default (no transients). `state_slice/0` is auto-derived to
  # `:orchestrator_admin` (the pre-Lifecycle key).
  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  # Override the macro-generated `required_caps/0` to declare the
  # `:session` kind axis explicitly. OrchestratorAdmin registers only
  # on `Ezagent.Entity.Session`, so the cap kind is `:session` —
  # NOT the macro's default `:any` (which is correct for multi-Kind
  # Behaviors like `Chat`).
  @doc """
  The cap map for this Behavior's actions, overriding the macro default to pin the
  `:session` kind axis (OrchestratorAdmin registers only on `Entity.Session`, so
  `:restart`'s cap subject is `:session`, not the macro's multi-Kind `:any`).
  """
  def required_caps do
    %{restart: Ezagent.Capability.cap(:session, __MODULE__, :restart)}
  end

  # The Behavior was cap-only pre-migration; in the new contract we
  # still want a stable signal so the
  # `CapabilityRegistry.register/3` path can opt out of writing to
  # the dispatchable BehaviorRegistry. The macro doesn't surface
  # `dispatchable?/0` (it's an OPTIONAL legacy callback); we keep it
  # as `false` so registration semantics match pre-migration.
  @doc "`false` — this is a cap-only Behavior (no invokable action), so registration opts out of the dispatchable BehaviorRegistry, matching pre-migration semantics."
  def dispatchable?, do: false

  @doc """
  Cap-only handler — unreachable in normal use. The `:restart` action exists only
  to satisfy the new-contract Behavior shape; the real restart is the UI consulting
  the `:restart` cap and dispatching `template.instantiate` on the cc-orchestrator
  template. A stray dispatch here RAISES (mapped to a clean `{:error, …}` by the
  runtime) — defence in depth, and preserves the legacy cap-only assertion.
  """
  def handle_restart(_args, _ctx) do
    # Cap-only — see moduledoc. If a caller ever reaches this handler
    # they should be dispatching template.instantiate instead. We
    # raise rather than return {:error, _} so legacy tests that
    # assert_raise on the original cap-only message keep working;
    # the runtime maps the raise to {:error, {:behavior_exception,
    # :error, %RuntimeError{...}}} for a clean propagation.
    raise "Ezagent.ActionSet.OrchestratorAdmin.:restart is cap-only — " <>
            "the UI (OrchestratorHealthCard) consults this cap to gate the " <>
            "Restart button; the actual restart still dispatches " <>
            "template.instantiate on the cc-orchestrator template."
  end

  # RFC #402: the cap data-owner is the session's owner. The session
  # URI's owner is read by `Ezagent.ActionSet.Session.data_owner/1` (which
  # reads `slice.chat.owner_uri` via `Session.owner/1`); we route
  # through there to keep one source of truth.
  @doc """
  The cap data-owner for a subject URI: the session's owner. A `session://` URI
  routes through `Ezagent.ActionSet.Session.data_owner/1` (which reads
  `slice.chat.owner_uri`) so ownership has ONE source of truth (RFC #402); `:any`
  is its own owner, anything else has `:no_owner`.
  """
  def data_owner(%URI{scheme: "session"} = session_uri) do
    Ezagent.ActionSet.Session.data_owner(session_uri)
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end
