defmodule Ezagent.Behavior.ModeTest do
  @moduledoc """
  Phase 2.6 (AutoService → ezagent migration) — session-level
  `:auto` / `:takeover` operator-control mode + AI-sender fan-out
  gating in `Ezagent.Behavior.Chat`'s `:send` handler.

  Covers the five acceptance scenarios from the migration spec:

  1. `:auto` mode — AI agent sends → customer sees.
  2. Mode flip `:auto -> :takeover` — customer sees the
     `(客服已接管对话)` notice.
  3. After flip to `:takeover` — AI agent sends → customer does NOT
     see.
  4. After flip to `:takeover` — Operator (User) sends → customer DOES
     see (operator messages are never gated).
  5. Flip back to `:auto` — AI agent sends → customer sees again.

  ## Post-Phase-B Lifecycle dispatch contract (2026-06-01 main merge)

  `Ezagent.Behavior.Mode` migrated from the old `use Ezagent.Behavior`
  + `invoke/4` surface to `use Ezagent.Lifecycle`. Two consequences for
  this file:

  - The pure-unit `:get` / `:set` tests no longer call the removed
    `Mode.invoke(:get|:set, slice, args, ctx)`. They drive the new
    handler entrypoints directly: `Mode.handle_get/2` and
    `Mode.handle_set/2`. `ctx` carries a `:read` closure over a slice
    map (`fn key, default -> Map.get(slice, key, default) end`) — the
    same shape the engine builds from the persisted `:state` container.
    Assertions are on the new return grammar `{:ok, result_map,
    effects}`: `handle_set` mutates via a `{:set, :mode, new}` effect
    and returns `%{mode: new, previous: prev}`; `handle_get` is a pure
    read (`[]` effects, `%{mode: cur}`).

  - `mode.set` / `mode.get` are NOW DISPATCHABLE (the whole point of the
    Lifecycle migration). The live-session scenarios therefore flip mode
    through a REAL `Ezagent.Invocation.dispatch(mode.set)` against the
    live Session Kind — the Session executes the `{:set, :mode, ...}`
    effect and (on `:auto -> :takeover`) the `emit_takeover_notice/1`
    `chat.send` cast, so the conditional customer-visible
    `{:notify, session_events_topic, {:chat_message, _, msg}}` broadcast
    fires or is suppressed for real. We observe it by subscribing to
    `Chat.session_events_topic/1`, exactly the original assertion style.
  """

  # Non-async — the live-session scenarios spawn a real Session via the
  # integration path which shares `EzagentCore.Repo` + boot supervisors.
  use ExUnit.Case
  alias Ezagent.{Invocation, KindRegistry, Message, MessageStore}
  alias Ezagent.Behavior.{Chat, Mode}
  alias EzagentCore.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok = EzagentDomainChat.AgentBridgeTestAdapter.ensure_registered()
    :ok
  end

  defp bind_to_default(session_uri) do
    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, URI.new!("workspace://team-alpha"))
    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)
    :ok
  end

  defp unique_session do
    URI.new!("session://default/team-alpha/mode-test-#{System.unique_integer([:positive])}")
  end

  defp agent_uri do
    URI.new!("entity://agent/team-alpha/ai-#{System.unique_integer([:positive])}")
  end

  defp operator_uri do
    URI.new!("entity://user/team-alpha/operator-#{System.unique_integer([:positive])}")
  end

  # Bootstrap admin ctx (closed-Catalog wildcard) — same shape the
  # integration tests use for `chat.send` / `chat.join` / `mode.set`.
  defp bootstrap_ctx do
    %{
      caller: Ezagent.SystemPrincipal.uri("bootstrap"),
      caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
      reply: {:caller_inbox, self()}
    }
  end

  # Normalise `Mode.create/1`'s return to the persistent state map. The
  # canonical Lifecycle `create/1` contract is `{:ok, state}`; tolerate a
  # bare-map return too so this contract assertion pins the DEFAULT value
  # rather than the wrapper shape.
  defp mode_create_state({:ok, state}) when is_map(state), do: state
  defp mode_create_state(state) when is_map(state), do: state

  # A `ctx` for the pure-unit handler tests: a `:read` closure over a flat
  # slice map (`%{mode: ...}`), mirroring how the Lifecycle engine surfaces
  # the persisted `:state` container to `handle_get/2` / `handle_set/2`.
  # `:self_uri` is `:not_a_session` so `emit_takeover_notice/1` short-
  # circuits (no live Session to cast `chat.send` against) — the handler's
  # return value + `{:set, :mode, _}` effect is still produced for the
  # assertion.
  defp unit_ctx(slice) do
    %{
      read: fn key, default -> Map.get(slice, key, default) end,
      self_uri: :not_a_session
    }
  end

  # Spawn a live Session Kind bound to workspace://team-alpha so dispatched
  # `chat.send` / `mode.set` invocations have somewhere to land and the
  # effect executor actually fires the `{:notify, ...}` broadcast (which is
  # what the customer-visible subscriber observes). Mirrors the integration
  # tests (`session_auto_join_test`, `mention_gated_routing_test`).
  defp spawn_live_session(session_uri) do
    {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.Session, %{uri: session_uri})
    :ok
  end

  # Flip the live Session's mode through a REAL `mode.set` dispatch (now
  # that Mode is `use Ezagent.Lifecycle`, `mode.set` is dispatchable). A
  # `:call` so the effect pipeline — the `{:set, :mode, new}` slice write
  # AND, on `:auto -> :takeover`, the `emit_takeover_notice/1` `chat.send`
  # cast — has fully executed before we return. Returns the handler result
  # (`%{mode: new, previous: prev}`).
  defp dispatch_set_mode(session_uri, mode) do
    target = URI.new!("#{URI.to_string(session_uri)}?action=mode.set")

    result =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: %{mode: mode},
        ctx: bootstrap_ctx()
      })

    # Drain the Session mailbox so any cast the effect pipeline enqueued
    # (the takeover notice `chat.send`) has fully fired before we assert.
    {:ok, pid} = KindRegistry.lookup(session_uri)
    _ = :sys.get_state(pid)

    # `mode.set` is a `:call` action — `Invocation.dispatch` wraps the
    # handler's result map in `{:ok, _}`. Unwrap so callers can match the
    # bare `%{mode:, previous:}` shape.
    {:ok, res} = result
    res
  end

  # Read the live Session's `:mode` slice (post Lifecycle migration the
  # Mode slice is the two-container `%{state: %{mode: m}, transients: _}`
  # shape; tolerate a flat fallback for robustness).
  defp live_mode(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    %{state: slices} = :sys.get_state(pid)
    mode_slice = Map.get(slices, :mode, %{})
    persistent = Map.get(mode_slice, :state, mode_slice)
    Map.get(persistent, :mode, :auto)
  end

  # Send `msg` into the live Session via a `chat.send` dispatch (cast). The
  # Session executes the effects — including the conditional
  # `{:notify, session_events_topic, {:chat_message, _, msg}}` broadcast —
  # so the customer subscriber sees (or doesn't see) the message exactly
  # as production would. Returns after the cast has drained.
  defp send_message(session_uri, msg) do
    target = URI.new!("#{URI.to_string(session_uri)}?action=chat.send")

    :ok =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :cast,
        args: %{message: msg},
        ctx: bootstrap_ctx()
      })

    # Drain the Session mailbox so the chat.send cast (and its effect
    # execution / broadcast) has fully fired before we assert.
    {:ok, pid} = KindRegistry.lookup(session_uri)
    _ = :sys.get_state(pid)
    :ok
  end

  # --- Behavior contract -------------------------------------------------

  describe "Behavior contract" do
    test "actions/0 lists :set and :get" do
      assert Mode.actions() == [:set, :get]
    end

    test "state_slice/0 returns :mode" do
      assert Mode.state_slice() == :mode
    end

    test "create/1 builds the initial :mode state defaulting to :auto" do
      # Lifecycle `create/1` builds the FIRST-EVER persistent `:state`
      # container for the slice (the Lifecycle successor to the old
      # `init_slice/1`). Fresh sessions default to `:auto`. We pull the
      # `mode` out of whatever container shape `create/1` returns so the
      # assertion pins the DEFAULT (`:auto`), not the wrapper shape.
      assert %{mode: :auto} = mode_create_state(Mode.create(%{}))
    end

    test "cap_subjects/0 covers every action" do
      subjects = Mode.cap_subjects() |> Enum.into(%{}) |> Map.keys() |> Enum.sort()
      assert subjects == Enum.sort(Mode.actions())
    end

    test "required_caps/0 covers every action with Session-kind caps" do
      assert %{set: %Ezagent.Capability{kind: :session}, get: %Ezagent.Capability{kind: :session}} =
               Mode.required_caps()
    end

    test "Chat.reads_sibling_slices/0 declares [:mode] (the gating contract)" do
      assert Chat.reads_sibling_slices() == [:mode]
    end

    test "takeover_notice_text/0 returns the verbatim Chinese notice" do
      assert Mode.takeover_notice_text() == "(客服已接管对话)"
    end
  end

  # --- handle_get / handle_set unit tests --------------------------------

  describe "handle_get/2" do
    test "returns the current mode from the slice (via ctx.read)" do
      assert {:ok, %{mode: :auto}, []} = Mode.handle_get(%{}, unit_ctx(%{mode: :auto}))
      assert {:ok, %{mode: :takeover}, []} = Mode.handle_get(%{}, unit_ctx(%{mode: :takeover}))
    end

    test "defaults to :auto for legacy (pre-Phase-2.6) slice without :mode key" do
      assert {:ok, %{mode: :auto}, []} = Mode.handle_get(%{}, unit_ctx(%{}))
    end
  end

  describe "handle_set/2 — slice mutation effect" do
    test "flipping :auto -> :takeover emits a {:set, :mode, :takeover} effect + returns previous" do
      ctx = unit_ctx(%{mode: :auto})

      assert {:ok, %{mode: :takeover, previous: :auto}, [{:set, :mode, :takeover}]} =
               Mode.handle_set(%{mode: :takeover}, ctx)
    end

    test "flipping :takeover -> :auto emits the effect + previous (no notice)" do
      ctx = unit_ctx(%{mode: :takeover})

      assert {:ok, %{mode: :auto, previous: :takeover}, [{:set, :mode, :auto}]} =
               Mode.handle_set(%{mode: :auto}, ctx)
    end

    test "setting the same mode is a no-op transition (silent reaffirm)" do
      ctx = unit_ctx(%{mode: :takeover})

      assert {:ok, %{mode: :takeover, previous: :takeover}, [{:set, :mode, :takeover}]} =
               Mode.handle_set(%{mode: :takeover}, ctx)
    end

    test "rejects unsupported mode atoms (open enum, narrow Phase 2.6 impl)" do
      ctx = unit_ctx(%{mode: :auto})

      assert {:error, {:unsupported_mode, :copilot}} =
               Mode.handle_set(%{mode: :copilot}, ctx)
    end
  end

  # --- Scenario 1: :auto — AI agent sends, customer sees ----------------

  describe "Chat.send (live dispatch) under :auto mode" do
    test "AI agent send: customer subscriber receives on session topic (scenario 1)" do
      session_uri = unique_session()
      bind_to_default(session_uri)
      spawn_live_session(session_uri)

      sender = agent_uri()
      msg = Message.new(sender, %{text: "Hi, I'm the AI", attachments: []})

      # :auto is the create/1 default — no flip needed.
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, Chat.session_events_topic(session_uri))

      :ok = send_message(session_uri, msg)

      # Customer-visible PubSub broadcast fires.
      assert_receive {:chat_message, _, %Message{id: id}}, 500
      assert id == msg.id

      # Persisted as normal.
      assert {:ok, _} = MessageStore.by_id(msg.id)
    end
  end

  # --- Scenarios 3 + 4 + 5: gating with mode ----------------------------

  describe "Chat.send (live dispatch) under :takeover mode" do
    test "AI agent send: customer does NOT receive on session topic (scenario 3)" do
      session_uri = unique_session()
      bind_to_default(session_uri)
      spawn_live_session(session_uri)

      # Flip to :takeover via a real mode.set dispatch (now dispatchable).
      assert %{mode: :takeover, previous: :auto} = dispatch_set_mode(session_uri, :takeover)

      sender = agent_uri()
      msg = Message.new(sender, %{text: "AI reply during takeover", attachments: []})

      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, Chat.session_events_topic(session_uri))

      :ok = send_message(session_uri, msg)

      # Customer-visible PubSub broadcast suppressed (agent sender + takeover).
      refute_receive {:chat_message, _, _}, 200

      # Persistence still happens — operator history needs the message.
      assert {:ok, _} = MessageStore.by_id(msg.id)
    end

    test "Operator (User) send: customer DOES receive (scenario 4)" do
      session_uri = unique_session()
      bind_to_default(session_uri)
      spawn_live_session(session_uri)

      assert %{mode: :takeover, previous: :auto} = dispatch_set_mode(session_uri, :takeover)

      operator = operator_uri()
      msg = Message.new(operator, %{text: "operator taking over", attachments: []})

      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, Chat.session_events_topic(session_uri))

      :ok = send_message(session_uri, msg)

      # Operator (entity://user/...) is NOT an Agent URI, so the
      # takeover gate does NOT trigger — the customer-visible topic
      # broadcast fires.
      assert_receive {:chat_message, _, %Message{id: id}}, 500
      assert id == msg.id
    end
  end

  describe "Chat.send (live dispatch) — gate releases when mode flips back to :auto (scenario 5)" do
    test "AI send under :auto AFTER a takeover episode reaches the customer again" do
      session_uri = unique_session()
      bind_to_default(session_uri)
      spawn_live_session(session_uri)

      sender = agent_uri()

      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, Chat.session_events_topic(session_uri))

      # Episode under :takeover — flip emits the notice; confirm the AI
      # send that follows is suppressed.
      assert %{mode: :takeover, previous: :auto} = dispatch_set_mode(session_uri, :takeover)
      # Drain the takeover-notice broadcast so it doesn't pollute the
      # AI-send assertion below.
      assert_receive {:chat_message, _, %Message{}}, 500

      msg_during = Message.new(sender, %{text: "during takeover", attachments: []})
      :ok = send_message(session_uri, msg_during)
      refute_receive {:chat_message, _, _}, 100

      # Flip back to :auto — next AI send must reach the customer (the
      # reverse edge is silent: no notice).
      assert %{mode: :auto, previous: :takeover} = dispatch_set_mode(session_uri, :auto)
      refute_receive {:chat_message, _, _}, 100

      msg_after = Message.new(sender, %{text: "back to auto", attachments: []})
      :ok = send_message(session_uri, msg_after)

      assert_receive {:chat_message, _, %Message{id: id}}, 500
      assert id == msg_after.id
    end
  end

  # --- Scenario 2: takeover notice broadcast (integration via live Session) ----

  describe "mode.set dispatch (:auto -> :takeover) emits the takeover notice (scenario 2)" do
    test "live Session: customer subscriber receives the (客服已接管对话) notice" do
      # Spawn a live Session Kind so the cast-dispatched `chat.send`
      # carrying the notice has somewhere to land. Subscribe to the
      # session events topic BEFORE flipping mode so we observe the
      # notice broadcast.
      session_uri = unique_session()
      bind_to_default(session_uri)
      spawn_live_session(session_uri)

      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, Chat.session_events_topic(session_uri))

      # Flip :auto -> :takeover via a REAL `mode.set` dispatch. The
      # handler's `emit_takeover_notice/1` side effect dispatches a
      # genuine `chat.send` cast against the session, so the live Session
      # processes it and broadcasts the notice.
      assert %{mode: :takeover, previous: :auto} = dispatch_set_mode(session_uri, :takeover)

      # The notice was cast-dispatched as chat.send — the Session
      # processes it, broadcasting to session_events_topic.
      assert_receive {:chat_message, _, %Message{body: body} = stored}, 1_000

      text = Map.get(body, :text) || Map.get(body, "text")
      assert text == "(客服已接管对话)"

      flag = Map.get(body, :is_takeover_notice) || Map.get(body, "is_takeover_notice")
      assert flag == true

      assert URI.to_string(stored.sender) == "system://chat-router"

      # The `{:set, :mode, :takeover}` effect was executed by the Session
      # as part of the same dispatch, so the live slice now reads
      # :takeover — subsequent customer-facing sends would be gated.
      assert live_mode(session_uri) == :takeover
    end

    test "no notice on takeover -> auto flip (silent reverse edge)" do
      session_uri = unique_session()
      bind_to_default(session_uri)
      spawn_live_session(session_uri)

      # First flip to takeover (consume notice; covered above). REAL
      # `mode.set` dispatch — the `{:set, :mode, :takeover}` effect lands
      # on the live slice.
      assert %{mode: :takeover, previous: :auto} = dispatch_set_mode(session_uri, :takeover)
      assert live_mode(session_uri) == :takeover

      # NOW subscribe — and flip back to :auto. No notice should fire
      # (`emit_takeover_notice/1` only fires on :auto -> :takeover).
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, Chat.session_events_topic(session_uri))

      assert %{mode: :auto, previous: :takeover} = dispatch_set_mode(session_uri, :auto)

      refute_receive {:chat_message, _, _}, 300
      assert live_mode(session_uri) == :auto
    end
  end
end
