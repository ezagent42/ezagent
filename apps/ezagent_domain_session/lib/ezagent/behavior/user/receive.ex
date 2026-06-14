defmodule Ezagent.Behavior.User.Receive do
  @moduledoc """
  `user.receive` — the User Kind's passive-inbox `:receive` Behavior.

  ## Why this exists (im/session/agent decomposition — PR-2)

  The single `Ezagent.Behavior.Session.handle_receive/2` used to branch
  internally on `ctx[:kind_module]` (`Entity.User` → inbox slice;
  `Entity.Agent` → AgentBridge). SPEC
  `docs/superpowers/specs/2026-06-12-im-session-agent-decomposition-design.md`
  §OQ-4 / §3.3 splits that one action into TWO first-class Behaviors —
  `user.receive` (this module, passive inbox) and `agent.receive`
  (`Ezagent.Behavior.Agent.Receive`, active live-process delivery) — each
  registered for `:receive` on its own Kind. They are genuinely different
  (passive inbox vs active process delivery) and are NOT merged. The
  internal `case kind_module` is retired.

  ## What `user.receive` does (extracted VERBATIM from the User branch)

  PR-N3 (SPEC v2 notification-architecture-v2 §2.4 + §3, Allen
  2026-05-25) — the PRODUCER pattern. This handler does NO PubSub
  broadcast: it just mutates its receive-state slice, and the runtime
  detects `new_slice != old_slice` and emits the slice-change event
  post-commit via `Ezagent.SliceChange.emit/1`. AdminLive's PR-N2
  subscription on `Ezagent.Notifications.subscribe_slice_change/1` picks
  it up. **The slice mutation IS the notification.**

  Two structural writes:

  - `:last_received` — `%{message_id, at}`. `at` is `DateTime.utc_now/0`,
    so the value differs across calls and the auto-hook fires on every
    legitimate receive.
  - `:recent_messages` — the cursor-indexed bounded ring (PR-N3 r4,
    Allen 2026-05-25, codex r3 HIGH-1 race fix). Each entry is
    `{slice_change_cursor, msg_id}`; the cursor matches the SliceChange
    broadcast envelope cursor (pre-allocated by `Ezagent.Kind.Runtime`
    and threaded via `ctx.slice_change_cursor`), so AdminLive's flash
    bridge can resolve the correct message even under burst via
    `List.keyfind(ring, C, 0)`. Newest-first; HEAD is the most recent.
    Ring depth is SPEC-pinned (NOT a runtime config knob — per
    `feedback_let_it_crash_no_workarounds`) via
    `recent_messages_ring_depth/0`.

  ## Slice ownership / key (no snapshot migration)

  This Behavior OWNS the User Kind's receive-state slice. The slice key
  is pinned to `:session` (NOT the auto-derived `:receive`) so the data
  lands in the SAME slice the User Kind's `:receive` wrote to before the
  split (when it ran under `Ezagent.Behavior.Session`, whose auto-derived
  slice key is `:session`). Keeping the key avoids a snapshot migration —
  a pre-split User snapshot's `:session` slice (with `:last_received` /
  `:recent_messages`) round-trips unchanged through cold restart. The
  `# lifecycle:state_slice_override` marker below is the contract the
  Phase C gate requires for a deliberate `state_slice:` override.

  ## State shape

      %{
        last_received:   nil | %{message_id: String.t(), at: DateTime.t()},
        recent_messages: [{cursor :: pos_integer() | nil, msg_id :: String.t()}]
      }

  Both default to "absent" semantics — a fresh User has no `:session`
  slice (the User Kind does NOT list a session Behavior in `behaviors/0`;
  `Kind.Runtime` defaults a missing slice to `%{}`), and pre-PR-N3-r4
  snapshots have no `:recent_messages` key, so the handler reads via
  `ctx[:read].(:recent_messages, [])`.

  ## Naming (§11 NP-1/NP-2/NP-3 audit)

  `Ezagent.Behavior.User.Receive` — a domain module
  (`apps/ezagent_domain_session`, the session/im domain) naming
  its own concept; the name tracks the single action's intent
  (`receive`) at the narrowest accurate scope (NP-1), in its own layer's
  vocabulary (NP-2), with a width that matches its one action (NP-3). No
  violation.
  """

  # lifecycle:state_slice_override
  use Ezagent.Lifecycle, state_slice: :session

  require Logger

  alias Ezagent.Message

  # PR-N3 r4 (Allen 2026-05-25) — bounded cursor-indexed ring depth for
  # the `:recent_messages` ring. SPEC-pinned (NOT a runtime config knob —
  # per `feedback_let_it_crash_no_workarounds`). Mirrors the constant that
  # lived on `Ezagent.Behavior.Session` before the PR-2 split; the ring is
  # now owned here, so the constant moves here with it.
  #
  # Why 20: AdminLive's flash bridge re-fetches the slice on each
  # `:slice_changed` event. Between "envelope cursor C broadcast" and "LV
  # process pulls slice", N more `:receive` events may have committed (LV
  # mailbox under burst). Ring depth caps the worst-case backlog the
  # bridge can resolve — 20 is ~10x typical bursts and well below the
  # cost-of-carry threshold (each entry ~40 bytes; 20 entries ~800 bytes
  # added to every persisted User snapshot). Older events fall off the
  # tail; the bridge gracefully degrades to the generic "New chat update
  # on <uri>" line for any cursor no longer in the ring.
  @recent_messages_ring_depth 20

  @doc """
  Ring depth for the `:recent_messages` cursor-indexed ring (PR-N3 r4
  cursor-race fix). Exposed as a function so tests assert against the
  SPEC-pinned constant without coupling to compile-time internals.
  """
  @spec recent_messages_ring_depth() :: pos_integer()
  def recent_messages_ring_depth, do: @recent_messages_ring_depth

  action(:receive,
    args: %{message: :map},
    returns: %{},
    caps: [:receive],
    modes: [:cast],
    description: "Record an inbound session message into this User's inbox slice"
  )

  # `create/1` — the User Kind does NOT list this Behavior in its
  # `behaviors/0`; it is registered for `{Entity.User, :receive}` directly
  # via `CapabilityRegistry.register/3`. `Kind.Runtime` defaults a missing
  # slice to `%{}`, so a fresh User never runs this `create/1` — but the
  # Lifecycle contract requires it. It builds the empty receive-state
  # shape so the keys are present-by-default for any caller that DOES
  # materialize the slice (and documents the slice's owned fields).
  @impl Ezagent.Lifecycle
  def create(_args) do
    {:ok, %{last_received: nil, recent_messages: []}}
  end

  # --- :receive ----------------------------------------------------------

  @doc """
  Record an inbound session message into the User's inbox slice
  (extracted VERBATIM from the User branch of
  `Ezagent.Behavior.Session.handle_receive/2`).

  Mutates `:last_received` (message id + arrival timestamp) and pushes a
  `{cursor, msg_id}` tuple onto the cursor-indexed `:recent_messages`
  ring (trimmed to `recent_messages_ring_depth/0`). The slice mutation IS
  the notification — the runtime emits the slice-change event post-commit
  (PR-N3 producer pattern); this handler does NO broadcast.
  """
  def handle_receive(%{message: %Message{} = msg}, ctx) do
    cursor = Map.get(ctx, :slice_change_cursor)
    prior_ring = ctx[:read].(:recent_messages, [])
    new_entry = {cursor, msg.id}

    trimmed_ring =
      [new_entry | prior_ring]
      |> Enum.take(@recent_messages_ring_depth)

    {:ok, %{},
     [
       {:set, :last_received, %{message_id: msg.id, at: DateTime.utc_now()}},
       {:set, :recent_messages, trimmed_ring}
     ]}
  end

  # caps-data-ownership-v2 (SPEC #306 §7) — a Behavior with caps MUST declare
  # data_owner/1. `user.receive` writes the User's OWN inbox slice
  # (`:last_received` / `:recent_messages`), so the data owner is the User
  # entity itself (the inbox is per-recipient).
  def data_owner(%URI{scheme: "entity"} = uri), do: Ezagent.URI.instance(uri)
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end
