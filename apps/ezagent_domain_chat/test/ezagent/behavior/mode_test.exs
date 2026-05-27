defmodule Ezagent.Behavior.ModeTest do
  @moduledoc """
  Phase 2.6 (AutoService → ezagent migration) — session-level
  `:auto` / `:takeover` operator-control mode + AI-sender fan-out
  gating in `Ezagent.Behavior.Chat.invoke(:send, ...)`.

  Covers the five acceptance scenarios from the migration spec:

  1. `:auto` mode — AI agent sends → customer sees.
  2. Mode flip `:auto -> :takeover` — customer sees the
     `(客服已接管对话)` notice.
  3. After flip to `:takeover` — AI agent sends → customer does NOT
     see.
  4. After flip to `:takeover` — Operator (User) sends → customer DOES
     see (operator messages are never gated).
  5. Flip back to `:auto` — AI agent sends → customer sees again.

  Scenarios 1, 3, 4, 5 exercise `Chat.invoke(:send, ...)` directly
  with crafted `ctx[:sibling_slices]` so we can assert the gating
  branches in isolation; scenario 2 goes through `Mode.invoke(:set,
  ...)` to also exercise the notice-emit side effect (via a live
  Session Kind, since `Mode.invoke` dispatches `chat.send` against
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

  defp customer_uri do
    URI.new!("entity://user/team-alpha/customer-#{System.unique_integer([:positive])}")
  end

  # Build a Session-shaped ctx with the `:mode` sibling slice
  # populated — same shape `Ezagent.Kind.Runtime.maybe_inject_sibling_slices/3`
  # produces at dispatch time when Chat declares
  # `reads_sibling_slices == [:mode]`.
  defp ctx_with_mode(session_uri, sender, mode) do
    %{
      self_uri: session_uri,
      kind_module: Ezagent.Entity.Session,
      caller: sender,
      sibling_slices: %{mode: %{mode: mode}}
    }
  end

  defp send_slice(members) do
    %{
      members: members,
      monitors: %{},
      last_seen: %{},
      last_message_id: nil,
      last_message: nil,
      send_cursor: 0
    }
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

  describe "Chat.invoke(:send, ...) under :auto mode" do
    test "AI agent send: customer (User) recipient receives + session topic fires (scenario 1)" do
      session_uri = unique_session()
      bind_to_default(session_uri)

      sender = agent_uri()
      customer = customer_uri()
      msg = Message.new(sender, %{text: "Hi, I'm the AI", attachments: []})

      slice = send_slice(%{sender => %{online: true}, customer => %{online: true}})
      ctx = ctx_with_mode(session_uri, sender, :auto)

      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, Chat.session_events_topic(session_uri))

      assert {:ok, _new_slice, %{stored: true}} = Chat.invoke(:send, slice, %{message: msg}, ctx)

      # Customer-visible PubSub broadcast fires.
      assert_receive {:chat_message, _, %Message{id: id}}, 500
      assert id == msg.id

      # Persisted as normal.
      assert {:ok, _} = MessageStore.by_id(msg.id)
    end
  end

  # --- Scenarios 3 + 4 + 5: gating with mode ----------------------------

  describe "Chat.invoke(:send, ...) under :takeover mode" do
    test "AI agent send: customer does NOT receive on session topic (scenario 3)" do
      session_uri = unique_session()
      bind_to_default(session_uri)

      sender = agent_uri()
      customer = customer_uri()
      msg = Message.new(sender, %{text: "AI reply during takeover", attachments: []})

      slice = send_slice(%{sender => %{online: true}, customer => %{online: true}})
      ctx = ctx_with_mode(session_uri, sender, :takeover)

      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, Chat.session_events_topic(session_uri))

      assert {:ok, _new_slice, %{stored: true}} = Chat.invoke(:send, slice, %{message: msg}, ctx)

      # Customer-visible PubSub broadcast suppressed.
      refute_receive {:chat_message, _, _}, 200

      # Persistence still happens — operator history needs the message.
      assert {:ok, _} = MessageStore.by_id(msg.id)
    end

    test "Operator (User) send: customer DOES receive (scenario 4)" do
      session_uri = unique_session()
      bind_to_default(session_uri)

      operator = operator_uri()
      customer = customer_uri()
      msg = Message.new(operator, %{text: "operator taking over", attachments: []})

      slice = send_slice(%{operator => %{online: true}, customer => %{online: true}})
      ctx = ctx_with_mode(session_uri, operator, :takeover)

      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, Chat.session_events_topic(session_uri))

      assert {:ok, _new_slice, %{stored: true}} = Chat.invoke(:send, slice, %{message: msg}, ctx)

      # Operator (entity://user/...) is NOT an Agent URI, so the
      # takeover gate does NOT trigger — the customer-visible topic
      # broadcast fires.
      assert_receive {:chat_message, _, %Message{id: id}}, 500
      assert id == msg.id
    end
  end

  describe "Chat.invoke(:send, ...) — gate releases when mode flips back to :auto (scenario 5)" do
    test "AI send under :auto AFTER a takeover episode reaches the customer again" do
      session_uri = unique_session()
      bind_to_default(session_uri)

      sender = agent_uri()
      customer = customer_uri()

      slice = send_slice(%{sender => %{online: true}, customer => %{online: true}})

      # Episode under :takeover — confirm suppressed.
      msg_during = Message.new(sender, %{text: "during takeover", attachments: []})
      ctx_takeover = ctx_with_mode(session_uri, sender, :takeover)

      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, Chat.session_events_topic(session_uri))
      assert {:ok, _, _} = Chat.invoke(:send, slice, %{message: msg_during}, ctx_takeover)
      refute_receive {:chat_message, _, _}, 100

      # Flip back to :auto — next AI send must reach the customer.
      msg_after = Message.new(sender, %{text: "back to auto", attachments: []})
      ctx_auto = ctx_with_mode(session_uri, sender, :auto)

      assert {:ok, _, _} = Chat.invoke(:send, slice, %{message: msg_after}, ctx_auto)
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
      {:ok, _pid} =
        Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
          uri: session_uri
        })

      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, Chat.session_events_topic(session_uri))

      # Dispatch mode.set as the bootstrap admin (closed-Catalog wildcard).
      target = URI.new!("#{URI.to_string(session_uri)}?action=mode.set")

      {:ok, %{mode: :takeover, previous: :auto}} =
        Invocation.dispatch(%Invocation{
          target: target,
          mode: :call,
          args: %{mode: :takeover},
          ctx: %{
            caller: Ezagent.SystemPrincipal.uri("bootstrap"),
            caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
            reply: {:caller_inbox, self()}
          }
        })

      # The notice was cast-dispatched as chat.send — the Session
      # processes it next, broadcasting to session_events_topic.
      assert_receive {:chat_message, _, %Message{body: body} = stored}, 1_000

      text = Map.get(body, :text) || Map.get(body, "text")
      assert text == "(客服已接管对话)"

      flag = Map.get(body, :is_takeover_notice) || Map.get(body, "is_takeover_notice")
      assert flag == true

      assert URI.to_string(stored.sender) == "system://chat-router"

      # Slice was flipped — :sys.get_state serialises through the
      # Session mailbox so the chat.send cast has drained.
      {:ok, pid} = KindRegistry.lookup(session_uri)
      %{state: state} = :sys.get_state(pid)
      assert state.mode.mode == :takeover
    end

    test "no notice on takeover -> auto flip (silent reverse edge)" do
      session_uri = unique_session()
      bind_to_default(session_uri)

      {:ok, _pid} =
        Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
          uri: session_uri
        })

      # First flip to takeover (consume notice; we don't assert here
      # — covered above).
      target_set = URI.new!("#{URI.to_string(session_uri)}?action=mode.set")
      bootstrap_ctx = %{
        caller: Ezagent.SystemPrincipal.uri("bootstrap"),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }

      {:ok, _} =
        Invocation.dispatch(%Invocation{
          target: target_set,
          mode: :call,
          args: %{mode: :takeover},
          ctx: bootstrap_ctx
        })

      # The takeover notice is cast-dispatched — drain the Session
      # mailbox so the prior chat.send (notice) has fully fired
      # BEFORE we subscribe. Without this, the historical notice
      # races our subscription and pollutes the assertion.
      {:ok, pid} = KindRegistry.lookup(session_uri)
      _ = :sys.get_state(pid)
      _ = :sys.get_state(pid)

      # NOW subscribe — and flip back to :auto. No notice should fire.
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, Chat.session_events_topic(session_uri))

      {:ok, %{mode: :auto, previous: :takeover}} =
        Invocation.dispatch(%Invocation{
          target: target_set,
          mode: :call,
          args: %{mode: :auto},
          ctx: bootstrap_ctx
        })

      refute_receive {:chat_message, _, _}, 300
    end
  end
end
