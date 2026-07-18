defmodule Ezagent.SessionInstanceSetTest do
  # Non-async + EzagentCore.DataCase: shares the live boot-time Session
  # GenServer + EzagentCore.Repo (the P6 drain-live-kinds teardown applies),
  # mirroring chat_routing_test.exs which drives the same Session.
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, KindRegistry, Message, MessageStore}
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Entity.{Session, User}
  import Ezagent.Test.CapHelper, only: [signed_action_cap!: 2]

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

  test "chat Session with nil :kind_base FAILS LOUD (P5-0b scoped guard) — sessions require an explicit set" do
    # P5-0b: the Session Kind declares requires_explicit_behavior_set? == true,
    # so a nil/missing :kind_base is INVALID for it. effective_set/2 raises
    # rather than silently expanding to the declared list (which post-P5-1
    # would be the union superset, breaking P1's per-instance denial).
    assert_raise Ezagent.Kind.BehaviorSet.MissingKindBaseError, fn ->
      Ezagent.Kind.BehaviorSet.effective_set(Ezagent.Entity.Session, %{})
    end
  end

  test "chat Session with an EXPLICIT :kind_base → declared ∩ captured + universal base behaviors" do
    declared = Ezagent.Kind.behaviors_of(Ezagent.Entity.Session)

    slice_state = %{
      kind_base: %{state: %{behaviors: declared}, transients: %{}}
    }

    effective = Ezagent.Kind.BehaviorSet.effective_set(Ezagent.Entity.Session, slice_state)

    # Every declared behavior is preserved, in declaration order.
    assert Enum.take(effective, length(declared)) == declared
    # The universal Manage (not in behaviors/0) is appended as a base behavior.
    assert Ezagent.ActionSet.Manage in effective
  end

  test "REAL chat join + send round-trips through dispatch on the default Session (unchanged)" do
    session_uri = Session.default_uri()
    sender = User.admin_uri()
    # --- chat.join: add a transient member through dispatch ---
    member_uri =
      URI.new!("entity://system/user/parity-#{System.unique_integer([:positive])}")

    {:ok, member_pid} = GenServer.start(__MODULE__.NoopMember, member_uri)
    on_exit(fn -> if Process.alive?(member_pid), do: GenServer.stop(member_pid) end)

    join_target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")

    :ok =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: join_target,
        mode: :cast,
        args: %{member: member_uri},
        ctx: %{
          caller: member_uri,
          caps: MapSet.new([signed_action_cap!(join_target, member_uri)]),
          reply: :ignore
        }
      })

    {:ok, session_pid} = KindRegistry.lookup(session_uri)
    %{state: %{session: %{state: joined_slice}}} = :sys.get_state(session_pid)
    assert joined_slice.members[member_uri].online == true

    # --- chat.send: broadcast + store + slice mutation ---
    session_topic = SessionBehavior.session_events_topic(session_uri)
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, session_topic)

    msg =
      Message.new(sender, %{text: "parity-send #{System.unique_integer()}", attachments: []})

    send_target = URI.new!("#{URI.to_string(session_uri)}?action=session.send")

    :ok =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: send_target,
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: sender,
          caps: MapSet.new([signed_action_cap!(send_target, sender)]),
          reply: :ignore
        }
      })

    # Session-level broadcast fired (LV chat stream path).
    assert_receive {:chat_message, _session_uri, %Message{id: received_id}}, 500
    assert received_id == msg.id

    # Message landed in the store.
    assert {:ok, loaded} = MessageStore.by_id(msg.id)
    assert loaded.session_uri == session_uri

    # Slice mutation persisted (serialize through the GenServer to drain the commit).
    %{state: %{session: %{state: post_send_slice}}} = :sys.get_state(session_pid)
    assert post_send_slice.last_message_id == msg.id

    # Cleanup — leave the transient member.
    leave_target = URI.new!("#{URI.to_string(session_uri)}?action=session.leave")

    :ok =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: leave_target,
        mode: :cast,
        args: %{member: member_uri},
        ctx: %{
          caller: member_uri,
          caps: MapSet.new([signed_action_cap!(leave_target, member_uri)]),
          reply: :ignore
        }
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
