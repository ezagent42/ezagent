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

  ## Post-Phase-B dispatch contract (2026-06-01 main merge)

  PR #464 deleted the old-style `invoke/4` dispatch contract; `Chat`
  migrated to `use Ezagent.Lifecycle`, so the removed
  `Chat.invoke(:send, slice, args, ctx)` direct entry these scenarios
  used is gone. They now drive the GENUINELY LIVE path: a real Session
  Kind is spawned, the `:mode` sibling slice is set on it, and the
  message goes in via `Ezagent.Invocation.dispatch(chat.send)` — the
  Session executes the effects, so the conditional
  `{:notify, session_events_topic, {:chat_message, _, msg}}` broadcast
  (the customer-visible surface) fires or is suppressed for real. We
  observe it by subscribing to `Chat.session_events_topic/1`, exactly
  the original assertion style.

  The `:mode` slice is written directly on the live Session
  (`:sys.replace_state`, test-only) rather than via a `mode.set`
  dispatch: `Ezagent.Behavior.Mode` is itself still an old-style
  `@behaviour Ezagent.Behavior` (the Phase-B Lifecycle migration has
  not reached it yet), so the new dispatch path refuses `mode.set`
  with `{:not_a_behavior, _}`. Its `invoke/4` is unchanged and
  callable directly, which is how scenario 2 still exercises the real
  notice-emit side effect (`Mode.invoke(:set, ...)` →
  `emit_takeover_notice/1` → live `chat.send` cast against
  `ctx.self_uri`).
  """

  # Non-async — scenario 2 spawns a live Session via the integration
  # path which shares `EzagentCore.Repo` + boot supervisors.
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
  # integration tests use for `chat.send` / `chat.join`.
  defp bootstrap_ctx do
    %{
      caller: Ezagent.SystemPrincipal.uri("bootstrap"),
      caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
      reply: {:caller_inbox, self()}
    }
  end

  # Spawn a live Session Kind bound to workspace://team-alpha so dispatched
  # `chat.send` / `mode.set` invocations have somewhere to land and the
  # effect executor actually fires the `{:notify, ...}` broadcast (which is
  # what the customer-visible subscriber observes). Mirrors scenario 2 +
  # the integration tests (`session_auto_join_test`, `mention_gated_*`).
  defp spawn_live_session(session_uri) do
    {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.Session, %{uri: session_uri})
    :ok
  end

  # Set the live Session's `:mode` slice directly on the GenServer state.
  #
  # The `:mode` slice is what `Chat.reads_sibling_slices() == [:mode]`
  # causes `Kind.Runtime.maybe_inject_sibling_slices/3` to surface on
  # `ctx.sibling_slices` at `chat.send` time — i.e. exactly the value the
  # Phase 2.6 takeover gate reads. We write it via `:sys.replace_state`
  # (test-only) rather than a `mode.set` dispatch: post-Phase-B,
  # `Ezagent.Behavior.Mode` is still an old-style `@behaviour
  # Ezagent.Behavior` (its `invoke/4` is callable directly — see the
  # `invoke(:set/:get, ...)` unit tests above — but the new dispatch path
  # refuses non-`use Ezagent.Lifecycle` Behaviors). Writing the slice
  # directly keeps the customer-visible assertion on the genuinely-live
  # `chat.send` broadcast while sidestepping the unmigrated dispatch entry.
  #
  # The GenServer wrapper holds per-Behavior slices under `:state`
  # (`Ezagent.Kind.Server` struct field `state: %{atom() => map()}`); the
  # `:mode` slice is a flat `%{mode: atom()}` (Mode is not yet a
  # two-container Lifecycle slice).
  defp set_mode(session_uri, mode) do
    {:ok, pid} = KindRegistry.lookup(session_uri)

    _ =
      :sys.replace_state(pid, fn wrapper ->
        slices = Map.get(wrapper, :state, %{})
        %{wrapper | state: Map.put(slices, :mode, %{mode: mode})}
      end)

    :ok
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

    test "init_slice/1 defaults to :auto" do
      assert Mode.init_slice(%{}) == %{mode: :auto}
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

  # --- :get / :set unit tests --------------------------------------------

  describe "invoke(:get, ...)" do
    test "returns the current mode from the slice" do
      assert {:ok, _slice, %{mode: :auto}} = Mode.invoke(:get, %{mode: :auto}, %{}, %{})
      assert {:ok, _slice, %{mode: :takeover}} = Mode.invoke(:get, %{mode: :takeover}, %{}, %{})
    end

    test "defaults to :auto for legacy (pre-Phase-2.6) slice without :mode key" do
      assert {:ok, _slice, %{mode: :auto}} = Mode.invoke(:get, %{}, %{}, %{})
    end
  end

  describe "invoke(:set, ...) — slice mutation" do
    test "flipping :auto -> :takeover sets the slice + returns previous" do
      ctx = %{self_uri: :not_a_session}
      slice = %{mode: :auto}

      assert {:ok, %{mode: :takeover}, %{mode: :takeover, previous: :auto}} =
               Mode.invoke(:set, slice, %{mode: :takeover}, ctx)
    end

    test "flipping :takeover -> :auto sets the slice + previous (no notice)" do
      ctx = %{self_uri: :not_a_session}
      slice = %{mode: :takeover}

      assert {:ok, %{mode: :auto}, %{mode: :auto, previous: :takeover}} =
               Mode.invoke(:set, slice, %{mode: :auto}, ctx)
    end

    test "setting the same mode is a no-op transition (silent reaffirm)" do
      ctx = %{self_uri: :not_a_session}
      slice = %{mode: :takeover}

      assert {:ok, %{mode: :takeover}, %{mode: :takeover, previous: :takeover}} =
               Mode.invoke(:set, slice, %{mode: :takeover}, ctx)
    end

    test "rejects unsupported mode atoms (open enum, narrow Phase 2.6 impl)" do
      ctx = %{self_uri: :not_a_session}
      slice = %{mode: :auto}

      assert {:error, {:unsupported_mode, :copilot}} =
               Mode.invoke(:set, slice, %{mode: :copilot}, ctx)
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

      # :auto is the init default — no flip needed.
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

      :ok = set_mode(session_uri, :takeover)

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

      :ok = set_mode(session_uri, :takeover)

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

      # Episode under :takeover — confirm suppressed.
      :ok = set_mode(session_uri, :takeover)
      msg_during = Message.new(sender, %{text: "during takeover", attachments: []})
      :ok = send_message(session_uri, msg_during)
      refute_receive {:chat_message, _, _}, 100

      # Flip back to :auto — next AI send must reach the customer.
      :ok = set_mode(session_uri, :auto)
      msg_after = Message.new(sender, %{text: "back to auto", attachments: []})
      :ok = send_message(session_uri, msg_after)

      assert_receive {:chat_message, _, %Message{id: id}}, 500
      assert id == msg_after.id
    end
  end

  # --- Scenario 2: takeover notice broadcast (integration via live Session) ----

  describe "Mode.invoke(:set, :auto -> :takeover) emits the takeover notice (scenario 2)" do
    test "live Session: customer subscriber receives the (客服已接管对话) notice" do
      # Spawn a live Session Kind so the cast-dispatched `chat.send`
      # carrying the notice has somewhere to land. Subscribe to the
      # session events topic BEFORE flipping mode so we observe the
      # notice broadcast.
      session_uri = unique_session()
      bind_to_default(session_uri)

      # Spawn the Session (uses snapshot:on_change, which Sandbox
      # tolerates because we're shared-mode).
      spawn_live_session(session_uri)

      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, Chat.session_events_topic(session_uri))

      # Flip :auto -> :takeover via a DIRECT `Mode.invoke(:set, ...)`
      # call with the live session ctx. Post-Phase-B, `mode.set` is no
      # longer dispatchable (Mode is still old-style `@behaviour
      # Ezagent.Behavior`), but `Mode.invoke/4` itself is unchanged and
      # callable — its `emit_takeover_notice/1` side effect dispatches a
      # genuine `chat.send` cast against `ctx.self_uri`, so the live
      # Session processes it and broadcasts the notice exactly as before.
      assert {:ok, %{mode: :takeover}, %{mode: :takeover, previous: :auto}} =
               Mode.invoke(:set, %{mode: :auto}, %{mode: :takeover}, %{self_uri: session_uri})

      # The notice was cast-dispatched as chat.send — the Session
      # processes it next, broadcasting to session_events_topic.
      assert_receive {:chat_message, _, %Message{body: body} = stored}, 1_000

      text = Map.get(body, :text) || Map.get(body, "text")
      assert text == "(客服已接管对话)"

      flag = Map.get(body, :is_takeover_notice) || Map.get(body, "is_takeover_notice")
      assert flag == true

      assert URI.to_string(stored.sender) == "system://chat-router"

      # Persist the flip onto the live Session's `:mode` slice (the direct
      # invoke above returns the new slice but does not write it back
      # through the Kind) so the customer-facing gate would observe
      # :takeover on subsequent sends.
      :ok = set_mode(session_uri, :takeover)

      {:ok, pid} = KindRegistry.lookup(session_uri)
      %{state: state} = :sys.get_state(pid)
      assert state.mode.mode == :takeover
    end

    test "no notice on takeover -> auto flip (silent reverse edge)" do
      session_uri = unique_session()
      bind_to_default(session_uri)

      spawn_live_session(session_uri)

      # First flip to takeover (consume notice; we don't assert here
      # — covered above). DIRECT `Mode.invoke/4` call (mode.set is not
      # dispatchable post-Phase-B — see the test above).
      assert {:ok, %{mode: :takeover}, %{previous: :auto}} =
               Mode.invoke(:set, %{mode: :auto}, %{mode: :takeover}, %{self_uri: session_uri})

      # The takeover notice is cast-dispatched — drain the Session
      # mailbox so the prior chat.send (notice) has fully fired
      # BEFORE we subscribe. Without this, the historical notice
      # races our subscription and pollutes the assertion.
      {:ok, pid} = KindRegistry.lookup(session_uri)
      _ = :sys.get_state(pid)
      _ = :sys.get_state(pid)

      # NOW subscribe — and flip back to :auto. No notice should fire.
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, Chat.session_events_topic(session_uri))

      # Reverse edge via DIRECT `Mode.invoke/4` — :takeover -> :auto is
      # the silent edge (`emit_takeover_notice/1` only fires on
      # :auto -> :takeover), so no `chat.send` cast is dispatched.
      assert {:ok, %{mode: :auto}, %{mode: :auto, previous: :takeover}} =
               Mode.invoke(:set, %{mode: :takeover}, %{mode: :auto}, %{self_uri: session_uri})

      refute_receive {:chat_message, _, _}, 300
    end
  end
end
