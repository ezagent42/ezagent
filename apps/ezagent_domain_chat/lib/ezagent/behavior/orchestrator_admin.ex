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

  ## Why cap-only (`dispatchable?/0 == false`)

  No action is invoked against this Behavior — it's a pure cap shim,
  the same pattern `Ezagent.Behavior.Presence` uses. The
  `CapabilityRegistry.register/3` writes the cap subject to the
  subjects table only; `BehaviorRegistry` is untouched, so
  `Invocation.dispatch/1` can never accidentally route to `:restart`.
  `invoke/4` raises with a clear error if dispatch ever reaches it
  (defence in depth).

  Registered against `Ezagent.Entity.Session` in
  `EzagentDomainChat.Application.start/2`. Lives in
  `ezagent_domain_chat` because `data_owner/1` delegates to
  `Ezagent.Behavior.Chat.data_owner/1` (which reads
  `slice.chat.owner_uri`); a `ezagent_core` location would create a
  core→domain dependency.
  """

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:restart]

  @impl Ezagent.Behavior
  def required_caps do
    %{
      restart: Ezagent.Capability.cap(:session, __MODULE__, :restart)
    }
  end

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:restart, "restart this session's orchestrator agent (session-owner authority)"}
    ]
  end

  @impl Ezagent.Behavior
  def dispatchable?, do: false

  @impl Ezagent.Behavior
  def state_slice, do: :orchestrator_admin

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{}

  @impl Ezagent.Behavior
  def invoke(:restart, _slice, _args, _ctx) do
    raise "Ezagent.Behavior.OrchestratorAdmin.:restart is cap-only — " <>
            "the UI (OrchestratorHealthCard) consults this cap to gate the " <>
            "Restart button; the actual restart still dispatches " <>
            "template.instantiate on the cc-orchestrator template."
  end

  @impl Ezagent.Behavior
  def interface, do: %{}

  # RFC #402: the cap data-owner is the session's owner. The session
  # URI's owner is read by `Ezagent.Behavior.Chat.data_owner/1` (which
  # reads `slice.chat.owner_uri` via `Session.owner/1`); we route
  # through there to keep one source of truth.
  @impl Ezagent.Behavior
  def data_owner(%URI{scheme: "session"} = session_uri) do
    Ezagent.Behavior.Chat.data_owner(session_uri)
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end
