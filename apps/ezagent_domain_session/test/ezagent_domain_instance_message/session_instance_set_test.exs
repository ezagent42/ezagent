defmodule Ezagent.SessionInstanceSetTest do
  # Non-async + EzagentCore.DataCase: drives a live Session GenServer + Repo
  # (the P6 drain-live-kinds teardown applies).
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, KindRegistry, Message, MessageStore}
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.ActionSet.Session.Membership
  alias Ezagent.Entity.User
  import Ezagent.Test.CapHelper, only: [signed_action_cap!: 2]

  setup do
    # Use an isolated concrete Session. The global default Session is mutable
    # suite state, and join authority is deliberately single-use.
    assert {:ok, session_uri, _meta} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(
               "instance-set-#{Ecto.UUID.generate()}",
               User.admin_uri(),
               template_name: "default"
             )

    {:ok, session_uri: session_uri}
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

  test "REAL chat join + send round-trips through dispatch on an explicit Session", %{
    session_uri: session_uri
  } do
    sender = User.admin_uri()
    # --- chat.join: add a transient member through dispatch ---
    member_uri =
      URI.new!("entity://system/user/parity-#{System.unique_integer([:positive])}")

    {:ok, _} = Ezagent.Users.create(member_uri, "pw-not-secret", [])
    {:ok, _member_pid} = Ezagent.SpawnRegistry.spawn(member_uri)

    join_target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")

    :ok =
      Membership.provision_invited_join_authority(session_uri, member_uri, User.admin_uri())

    :ok =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: join_target,
        mode: :cast,
        args: %{member: member_uri},
        ctx: %{
          caller: member_uri,
          authenticated_principal: member_uri,
          caps: MapSet.new([signed_action_cap!(join_target, member_uri)]),
          reply: :ignore
        }
      })

    {:ok, session_pid} = KindRegistry.lookup(session_uri)
    joined_slice = await_member(session_pid, member_uri)
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
          authenticated_principal: sender,
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
          authenticated_principal: member_uri,
          caps: MapSet.new([signed_action_cap!(leave_target, member_uri)]),
          reply: :ignore
        }
      })
  end

  defp await_member(session_pid, member_uri, attempts \\ 100)
  defp await_member(_session_pid, _member_uri, 0), do: flunk("member projection did not converge")

  defp await_member(session_pid, member_uri, attempts) do
    %{state: %{session: %{state: slice}}} = :sys.get_state(session_pid)

    if Map.has_key?(slice.members, member_uri) do
      slice
    else
      Process.sleep(10)
      await_member(session_pid, member_uri, attempts - 1)
    end
  end
end
