defmodule Ezagent.Behavior.Mode do
  @moduledoc """
  Mode Behavior — session-level operator-vs-agent control mode.

  ## What this is

  A generic primitive: each Session carries a `:mode` flag that
  describes WHO is currently driving conversation with the customer.
  Any chat-business (customer-service, sales-pilot, education-tutor,
  …) can register this Behavior on its Session-like Kind to gain a
  takeover knob without re-implementing the gating logic in the
  business layer.

  ## Modes

  | Mode        | Customer sees Agent messages? | Customer sees Operator (public) messages? |
  |-------------|-------------------------------|-------------------------------------------|
  | `:auto`     | yes                           | yes                                       |
  | `:takeover` | NO (suppressed by Chat.send)  | yes                                       |

  The enum is intentionally open — `:copilot` and other business modes
  may join later. Only `:auto` and `:takeover` are implemented in
  Phase 2.6 of the AutoService → ezagent migration; everything else
  raises at `:set`.

  ## Actions

  - `:set` (call) — mutates `slice.mode`. Emits a system notice
    `"(客服已接管对话)"` (verbatim from AutoService) when transitioning
    `:auto -> :takeover` so the customer sees a handoff cue.
  - `:get` (call) — returns the current mode atom.

  ## State slice (`:mode`)

      %{mode: :auto | :takeover}

  Read by `Ezagent.Behavior.Chat` via `reads_siblings [:mode]`
  to gate the agent-sender fan-out in `Chat.handle_send/2`.

  ## Defaults & legacy snapshots

  Fresh sessions init to `:auto`. A pre-Phase-2.6 Session snapshot has
  no `:mode` slice — `Ezagent.Kind.Runtime`'s sibling-slice injection
  defaults missing slices to `%{}`, so the Chat-side reader uses
  `Map.get(sibling, :mode, :auto)` for the safe fallback.

  ## Why a Behavior (not a `:chat` slice field)

  Migration design constraint §2 (preserve ezagent generic abstraction):
  the mode primitive must stay reusable across chat-businesses. A
  dedicated Behavior with its own slice keeps the wiring clean,
  matches the `OrchestratorAdmin` precedent, and avoids growing the
  already-heavy `:chat` slice with cross-business state.

  ## Lifecycle migration (SPEC 2026-05-29)

  New module — written directly for `use Ezagent.Lifecycle`. The
  slice key auto-derives from `Ezagent.Behavior.Mode` → `:mode`
  (no `state_slice:` override needed).

  The `:auto → :takeover` notice is returned as a `{:dispatch, %Cmd{}}`
  effect (Lifecycle DON'T rule: no `Invocation.dispatch/1` from handler
  body). The dispatch uses `:cast`-equivalent `reply: :ignore` so the
  Session's own Kind.Server doesn't deadlock waiting on itself.
  """

  use Ezagent.Lifecycle

  alias Ezagent.{Cmd, Message}

  @notice_text "(客服已接管对话)"

  @doc """
  Verbatim takeover notice text (matches AutoService's
  `gateway/message_router.py:2715-2741` decision — Allen lock).
  Exposed so tests + future internationalisation layers can match
  against a single source of truth.
  """
  @spec takeover_notice_text() :: String.t()
  def takeover_notice_text, do: @notice_text

  # ---- Actions -----------------------------------------------------------

  action(:get,
    args: %{},
    returns: %{mode: :atom},
    caps: [:get],
    modes: [:call],
    description: "Read the session's current operator-control mode."
  )

  action(:set,
    args: %{mode: :atom},
    returns: %{mode: :atom, previous: :atom},
    caps: [:set],
    modes: [:call],
    description:
      "Set the session's operator-control mode (`:auto` / `:takeover`). " <>
        "On `:auto -> :takeover` a system notice is pushed to the session " <>
        "so the customer sees the handoff."
  )

  # ---- Lifecycle hooks ---------------------------------------------------

  # `create/1` — initial persistent state. Fresh sessions start in :auto.
  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{mode: :auto}}

  # ---- Action handlers ---------------------------------------------------

  @impl Ezagent.Lifecycle
  def handle_get(_args, ctx) do
    mode = ctx[:read].(:mode, :auto)
    {:ok, %{mode: mode}, []}
  end

  @impl Ezagent.Lifecycle
  def handle_set(%{mode: new_mode}, ctx) when new_mode in [:auto, :takeover] do
    prev_mode = ctx[:read].(:mode, :auto)

    # Notice only on the auto -> takeover edge. The reverse edge
    # (takeover -> auto) is silent — customer sees the next AI reply
    # land naturally; no banner needed. (AutoService's behavior on
    # the reverse edge is also silent at the customer surface.)
    notice_effects =
      if prev_mode == :auto and new_mode == :takeover do
        takeover_notice_effect(ctx)
      else
        []
      end

    {:ok, %{mode: new_mode, previous: prev_mode}, [{:set, :mode, new_mode} | notice_effects]}
  end

  def handle_set(%{mode: bad}, _ctx) do
    {:error, {:unsupported_mode, bad}}
  end

  # ---- Overrides ---------------------------------------------------------

  # Override the macro-generated `required_caps/0` to declare the
  # `:session` kind axis explicitly. Mode registers only on
  # `Ezagent.Entity.Session`, so the cap kind is `:session` —
  # NOT the macro's default `:any` (check 11(b) escape; same pattern
  # as `OrchestratorAdmin.required_caps/0`).
  def required_caps do
    %{
      set: Ezagent.Capability.cap(:session, __MODULE__, :set),
      get: Ezagent.Capability.cap(:session, __MODULE__, :get)
    }
  end

  # PR-OWN-2 ownership shape: Mode caps on a Session ride the session's
  # own ownership (the session owner controls who can flip mode). We
  # delegate to `Chat.data_owner/1` for a single source of truth — same
  # pattern `OrchestratorAdmin.data_owner/1` uses.
  def data_owner(%URI{scheme: "session"} = session_uri) do
    Ezagent.Behavior.Chat.data_owner(session_uri)
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # ---- Private helpers ---------------------------------------------------

  # Build a {:dispatch, %Cmd{}} effect for the takeover notice.
  #
  # The sender is `system://chat-router` (closest system principal that
  # already legitimately fans out system-side chat messages). We use
  # `reply: :ignore` so the Session's own Kind.Server doesn't deadlock
  # waiting on itself (equivalent to the :cast in the old invoke/4 path,
  # but expressed as a Lifecycle effect so no direct Invocation.dispatch/1
  # call escapes the handler — Lifecycle DON'T rule).
  defp takeover_notice_effect(ctx) do
    session_uri = ctx[:self_uri]

    if not match?(%URI{scheme: "session"}, session_uri) do
      # Defensive: if called outside a session ctx (unit-testing a raw
      # Mode handler without ctx.self_uri set), skip the side effect.
      # The {:set, :mode, new_mode} effect already happened; callers can
      # still observe the mode flip.
      []
    else
      sender = Ezagent.SystemPrincipal.uri("chat-router")

      # Body is `%{text, attachments}` per the Message contract; we
      # tag it with `:is_takeover_notice` so customer-side renderers
      # can spot the notice without parsing text.
      msg = Message.new(sender, %{text: @notice_text, attachments: []})
      msg = %{msg | body: Map.put(msg.body, :is_takeover_notice, true)}

      send_target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=chat.send")

      [
        {:dispatch,
         %Cmd{
           target: send_target,
           action: :send,
           args: %{message: msg},
           ctx: %{
             caller: sender,
             caps: Ezagent.SystemPrincipal.caps("system://chat-router"),
             reply: :ignore
           }
         }}
      ]
    end
  end
end
