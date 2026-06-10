defmodule Ezagent.SessionInstanceSetTest do
  # Non-async + EzagentCore.DataCase: shares the live boot-time Session
  # GenServer + EzagentCore.Repo (the P6 drain-live-kinds teardown applies),
  # mirroring chat_routing_test.exs which drives the same Session.
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, KindRegistry, Message, MessageStore}
  alias Ezagent.Behavior.Chat
  alias Ezagent.Entity.{Session, User}

  setup do
    # session://system/default/main is a DynamicSupervisor child spawned once
    # at chat-app boot; ensure it via the idempotent facade (adopts the live
    # Session if already running) — same pattern as chat_routing_test.exs.
    _ =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        "main",
        User.admin_uri(),
        template_name: "default"
      )

    :ok
  end

  test "chat Session's effective set = full declared list + universal base behaviors (no :behaviors arg)" do
    # no :kind_base captured → fallback to declared (+ base)
    slice_state = %{}
    declared = Ezagent.Kind.behaviors_of(Ezagent.Entity.Session)

    effective = Ezagent.Kind.BehaviorSet.effective_set(Ezagent.Entity.Session, slice_state)

    # Every declared behavior is preserved, in declaration order.
    assert Enum.take(effective, length(declared)) == declared
    # The universal Manage (not in behaviors/0) is appended as a base behavior.
    assert Ezagent.Behavior.Manage in effective
  end

  test "REAL chat join + send round-trips through dispatch on the default Session (unchanged)" do
    session_uri = Session.default_uri()
    sender = User.admin_uri()
    bootstrap_caps = Ezagent.SystemPrincipal.caps("system://bootstrap")

    # --- chat.join: add a transient member through dispatch ---
    member_uri =
      URI.new!("entity://team-alpha/user/parity-#{System.unique_integer([:positive])}")

    {:ok, member_pid} = GenServer.start(__MODULE__.NoopMember, member_uri)
    on_exit(fn -> if Process.alive?(member_pid), do: GenServer.stop(member_pid) end)

    :ok =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(session_uri)}?action=chat.join"),
        mode: :cast,
        args: %{member: member_uri},
        ctx: %{caller: member_uri, caps: bootstrap_caps, reply: :ignore}
      })

    {:ok, session_pid} = KindRegistry.lookup(session_uri)
    %{state: %{chat: %{state: joined_slice}}} = :sys.get_state(session_pid)
    assert joined_slice.members[member_uri].online == true

    # --- chat.send: broadcast + store + slice mutation ---
    session_topic = Chat.session_events_topic(session_uri)
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, session_topic)

    msg =
      Message.new(sender, %{text: "parity-send #{System.unique_integer()}", attachments: []})

    :ok =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(session_uri)}?action=chat.send"),
        mode: :cast,
        args: %{message: msg},
        ctx: %{caller: sender, caps: bootstrap_caps, reply: :ignore}
      })

    # Session-level broadcast fired (LV chat stream path).
    assert_receive {:chat_message, _session_uri, %Message{id: received_id}}, 500
    assert received_id == msg.id

    # Message landed in the store.
    assert {:ok, loaded} = MessageStore.by_id(msg.id)
    assert loaded.session_uri == session_uri

    # Slice mutation persisted (serialize through the GenServer to drain the commit).
    %{state: %{chat: %{state: post_send_slice}}} = :sys.get_state(session_pid)
    assert post_send_slice.last_message_id == msg.id

    # Cleanup — leave the transient member.
    :ok =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(session_uri)}?action=chat.leave"),
        mode: :cast,
        args: %{member: member_uri},
        ctx: %{caller: member_uri, caps: bootstrap_caps, reply: :ignore}
      })
  end

  defmodule NoopMember do
    @moduledoc false
    use GenServer

    @impl true
    def init(uri) do
      # Self-register so KindRegistry.lookup returns OUR pid (Registry registers
      # the calling process as owner) — mirrors chat_routing_test.exs's NoopServer.
      :ok = Ezagent.KindRegistry.put_new(uri)
      {:ok, %{}}
    end
  end
end
