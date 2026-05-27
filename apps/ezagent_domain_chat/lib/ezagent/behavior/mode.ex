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

  Read by `Ezagent.Behavior.Chat` via `reads_sibling_slices/0 == [:mode]`
  to gate the agent-sender fan-out in `Chat.invoke(:send, ...)`.

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
  """

  @behaviour Ezagent.Behavior

  alias Ezagent.{Invocation, Message}

  @notice_text "(客服已接管对话)"

  @doc """
  Verbatim takeover notice text (matches AutoService's
  `gateway/message_router.py:2715-2741` decision — Allen lock).
  Exposed so tests + future internationalisation layers can match
  against a single source of truth.
  """
  @spec takeover_notice_text() :: String.t()
  def takeover_notice_text, do: @notice_text

  @impl Ezagent.Behavior
  def actions, do: [:set, :get]

  @impl Ezagent.Behavior
  def required_caps do
    %{
      set: Ezagent.Capability.cap(:session, __MODULE__, :set),
      get: Ezagent.Capability.cap(:session, __MODULE__, :get)
    }
  end

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:set, "set this session's operator/agent control mode (auto/takeover)"},
      {:get, "read this session's current operator/agent control mode"}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :mode

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{mode: :auto}

  # `:get` — pure read.
  @impl Ezagent.Behavior
  def invoke(:get, slice, _args, _ctx) do
    {:ok, slice, %{mode: Map.get(slice, :mode, :auto)}}
  end

  # `:set` — flip the mode, emit the handoff notice on auto→takeover.
  def invoke(:set, slice, %{mode: new_mode}, ctx)
      when new_mode in [:auto, :takeover] do
    prev_mode = Map.get(slice, :mode, :auto)
    new_slice = Map.put(slice, :mode, new_mode)

    # Notice only on the auto -> takeover edge. The reverse edge
    # (takeover -> auto) is silent — customer sees the next AI reply
    # land naturally; no banner needed. (AutoService's behavior on
    # the reverse edge is also silent at the customer surface.)
    if prev_mode == :auto and new_mode == :takeover do
      emit_takeover_notice(ctx)
    end

    {:ok, new_slice, %{mode: new_mode, previous: prev_mode}}
  end

  def invoke(:set, _slice, %{mode: bad}, _ctx) do
    {:error, {:unsupported_mode, bad}}
  end

  @impl Ezagent.Behavior
  def interface do
    %{
      set: %{
        description:
          "Set the session's operator-control mode (`:auto` / `:takeover`). " <>
            "On `:auto -> :takeover` a system notice is pushed to the session " <>
            "so the customer sees the handoff.",
        args: %{mode: :atom},
        returns: %{mode: :atom, previous: :atom},
        modes: [:call]
      },
      get: %{
        description: "Read the session's current operator-control mode.",
        args: %{},
        returns: %{mode: :atom},
        modes: [:call]
      }
    }
  end

  # PR-OWN-2 ownership shape: Mode caps on a Session ride the session's
  # own ownership (the session owner controls who can flip mode). We
  # delegate to `Chat.data_owner/1` for a single source of truth — same
  # pattern `OrchestratorAdmin.data_owner/1` uses.
  @impl Ezagent.Behavior
  def data_owner(%URI{scheme: "session"} = session_uri) do
    Ezagent.Behavior.Chat.data_owner(session_uri)
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # ---- Internals ------------------------------------------------------

  # Build a synthetic system Message and dispatch `chat.send` on the
  # session — the Session's Chat Behavior will persist it + broadcast
  # to subscribers normally. Sender is the closed-Catalog system
  # principal `system://chat-router` (closest fit — it already
  # legitimately fans out system-side chat messages, e.g. for the
  # cross-session dispatch path).
  defp emit_takeover_notice(ctx) do
    session_uri = Map.get(ctx, :self_uri)

    if not match?(%URI{scheme: "session"}, session_uri) do
      # Defensive: if called outside a session ctx (unit-testing a raw
      # Mode invoke without ctx.self_uri set), skip the side effect.
      # The slice mutation already happened — callers can still observe
      # the mode flip.
      :ok
    else
      sender = Ezagent.SystemPrincipal.uri("chat-router")

      # Body is `%{text, attachments}` per the Message contract; we
      # tag it with `:is_takeover_notice` so customer-side renderers
      # can spot the notice without parsing text. Message.new
      # preserves arbitrary body keys (only :attachments is defaulted).
      msg = Message.new(sender, %{text: @notice_text, attachments: []})
      msg = %{msg | body: Map.put(msg.body, :is_takeover_notice, true)}

      target = URI.new!("#{URI.to_string(session_uri)}?action=chat.send")

      # `:cast` — we're inside the Session's own Kind.Server call
      # processing `mode.set`; a `:call` to ourselves would deadlock.
      # The cast enqueues the chat.send invocation to run after the
      # current invoke returns; the customer sees the notice in the
      # same tick the mode flip completes (sub-ms).
      _ =
        Invocation.dispatch(%Invocation{
          target: target,
          mode: :cast,
          args: %{message: msg},
          ctx: %{
            caller: sender,
            caps: Ezagent.SystemPrincipal.caps("system://chat-router"),
            reply: :ignore
          }
        })

      :ok
    end
  end
end
