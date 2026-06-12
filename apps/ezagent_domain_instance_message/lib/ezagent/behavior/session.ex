defmodule Ezagent.Behavior.Session do
  @moduledoc """
  Session Behavior — the SINGLE public entry verb a Session exposes for
  posting a message (`session.send`).

  ## Why this exists (PR-1, im/session/agent decomposition)

  Before PR-1, IM inbound and every agent reply dispatched
  `<session_uri>?action=chat.send` — the `Ezagent.Behavior.Chat` `:send`
  action. That conflated two concerns: the PUBLIC "post into this session"
  verb and the session-INTERNAL persist+route+fan-out machinery.

  PR-1 splits them:

      dispatch <session_uri>?action=session.send   ← PUBLIC entry (this module)
        └─ (session-internal) Chat fan-out          ← Ezagent.Behavior.Chat.handle_send/2

  `session.send` is now the ONLY action external callers (Feishu inbound,
  cc/codex/curl/echo/np replies, LiveView compose, cross-session re-entry,
  operator tools) dispatch. `chat.send` is demoted to a session-internal
  fan-out verb: its `{Session/SocialwareSession, :send}` PUBLIC registration
  is REPLACED by this module (`register_chat_behaviors/0` /
  `EzagentDomainSocialware.Application`), and `Ezagent.Behavior.Chat.handle_send/2`
  is reached ONLY by this module's delegation — never by a public dispatch.

  ## Routing mechanics (why this is registered at `{Session, :send}`)

  `Ezagent.BehaviorRegistry` keys dispatch on `{kind_module, action_atom}`
  ONLY — the `<behavior>` prefix in `?action=<behavior>.<action>` is
  telemetry-only (see `Ezagent.URI.behavior_action/1` +
  `Ezagent.Kind.Runtime`). So `?action=session.send` and the legacy
  `?action=chat.send` BOTH resolve action atom `:send`. This module
  therefore OWNS `{Session, :send}` (and `{SocialwareSession, :send}`); the
  uniform PUBLIC spelling is `session.send` and the arch invariant test
  (`SessionSendIsSolePublicVerbTest`) forbids the `chat.send` spelling
  outside the session domain.

  ## Delegation — Chat stays the single source of truth for fan-out

  `handle_send/2` delegates DIRECTLY to `Ezagent.Behavior.Chat.handle_send/2`
  (a plain function call, NOT a re-dispatch). The persist (MessageStore),
  route (Routing.Resolver), and fan-out (`chat.receive` dispatch to each
  recipient) logic stays in ONE place. There is no copy-paste of the fan-out.

  ## Slice — registry-only reader/writer of `:chat`

  This module declares `state_slice :chat` so the runtime hands its handler
  the SAME `:chat` slice the `Chat` Behavior owns + materializes, and the
  `{:set, ...}` effects Chat returns land back on `:chat`. It is REGISTRY-ONLY
  (NOT in `Session.behaviors/0` / `SocialwareSession.behaviors/0`), so it
  never `init_slice`/materializes `:chat` — exactly ONE behavior (Chat) owns
  it. Same registry-only-reads-a-sibling-owner's-slice pattern as
  `Ezagent.Behavior.SocialwarePublisherRead` (reads `:publisher`).

  ## Caps — `session.send` mirrors `chat.send`'s required cap (Invariant #19)

  Caps normalize at this chokepoint. `required_caps/0` is hand-declared to
  keep `behavior: Ezagent.Behavior.Chat` (NOT this module), so every existing
  grant — the Feishu binding-policy `kind: :session, behavior: Chat, action:
  :send` cap, every operator-granted session-chat cap — authorizes
  `session.send` UNCHANGED. The IM caller URI + caps flow through verbatim.
  `cap_subjects/0` + `data_owner/1` likewise defer to Chat so the cap surface
  (the grantable subject + its grant authority) is identical to before PR-1.

  ## Naming (§11 NP-1/NP-2/NP-3 audit)

  `Ezagent.Behavior.Session` — a domain module (`apps/ezagent_domain_instance_message`)
  naming its own domain concept (`Session`), with a single action (`:send`)
  that IS the session's public post verb. The name tracks the responsibility
  (the public Session entry) at the narrowest accurate scope. NO violation.
  """

  # lifecycle:state_slice_override
  #
  # Read/write the `:chat` slice — the SAME slice `Ezagent.Behavior.Chat`
  # owns + materializes. The macro would otherwise derive `:session` from the
  # module name and hand this module an empty slice, so `handle_send`'s
  # delegated `ctx[:read].(:members, ...)` would see no members and the
  # `{:set, :last_message_id, ...}` effects would land on the wrong slice.
  # This module does NOT init/materialize `:chat` (registry-only — not in
  # either Session Kind's `behaviors/0`); Chat is the SOLE owner.
  use Ezagent.Lifecycle, state_slice: :chat

  alias Ezagent.Behavior.Chat

  action(:send,
    args: %{message: :map},
    returns: %{stored: :boolean},
    caps: [:send],
    modes: [:call, :cast],
    description:
      "Post a message into the session (the SINGLE public entry verb) and " <>
        "fan it out to members via the session-internal Chat fan-out"
  )

  # ----- Cap surface — DEFER to Chat (Invariant #19, cap parity) ------------
  #
  # The `action/3` macro would auto-derive `required_caps/0` keyed on
  # `behavior: __MODULE__` (Ezagent.Behavior.Session). That would BREAK every
  # existing grant (all keyed on `Ezagent.Behavior.Chat`). We hand-declare it
  # to keep the cap subject identical to `chat.send` so no grant has to be
  # re-minted and the IM caller's existing caps authorize `session.send`
  # verbatim. (Macro only injects the derived callback if NOT already
  # defined — see `Ezagent.Behavior.LegacyCallbacks.maybe_add_unless_defined/4`.)

  @impl Ezagent.Behavior
  def required_caps do
    %{send: Ezagent.Capability.cap(:any, Chat, :send)}
  end

  @impl Ezagent.Behavior
  def cap_subjects do
    [{:send, "Post a message into the session (public entry; cap parity with chat.send)."}]
  end

  # `data_owner/1` — grant authority for the `session.send` cap subject is the
  # SAME as `chat.send`'s: the session's `:owner_uri` (the entity that created
  # it). Defer to Chat so `default_grants_from_data_owner/2` resolves the same
  # authority. (CapsDataOwnerTest requires this whenever cap_subjects/0 is
  # declared.)
  @impl Ezagent.Behavior
  def data_owner(target), do: Chat.data_owner(target)

  # ----- Handler — delegate to the session-internal Chat fan-out -----------

  @doc """
  Post a message into the session. Delegates DIRECTLY to
  `Ezagent.Behavior.Chat.handle_send/2` (plain function call, NOT a
  re-dispatch) — Chat remains the single source of truth for persist + route
  + fan-out. The `mode` (`:call` | `:cast`) is the transport choice the
  caller already encoded in the dispatch; this handler is mode-agnostic (it
  returns the same effect list either way, exactly as `chat.send` did).
  """
  def handle_send(args, ctx) do
    Chat.handle_send(args, ctx)
  end
end
