defmodule EzagentDomainInstanceMessage.Integration.ChatRoutingTest do
  @moduledoc """
  Phase 2b-step 2 integration test — full dispatch path through the
  live Session GenServer started by `EzagentDomainInstanceMessage.Application`.

  Verifies an owner join landed and that subsequent chat
  send/receive routes via dispatch (not via direct invoke). Also
  covers the :DOWN forwarder path by spawning a transient member,
  joining it, killing it, and asserting Session marks it offline.
  """

  # Non-async — these tests drive live Session GenServers + EzagentCore.Repo,
  # and the :DOWN path waits on supervised process teardown.
  #
  # EzagentCore.DataCase (not bare ExUnit.Case): its setup_sandbox installs
  # the P6 drain-live-kinds teardown — before this test's sandbox owner is
  # stopped, EVERY globally-registered Kind (incl. the boot-time main
  # Session) is synchronously drained so no in-flight DB query outlives the
  # owner. Without it, a concurrent async test's owner-exit reverted the
  # shared connection mid-query and crashed the Session with a
  # DBConnection.OwnershipError, dropping the :chat_message broadcast.
  use EzagentCore.DataCase, async: false
  alias Ezagent.{Invocation, KindRegistry, Message, MessageStore}
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.ActionSet.Session.Membership
  alias Ezagent.Entity.User

  setup do
    # Never share the boot-time default Session: membership is now backed by
    # single-use join authority, so rejoining a mutable global fixture makes
    # this file order-dependent under the umbrella suite.
    {:ok, session_uri: isolated_session("routing-setup")}
  end

  test "owner User landed in the created Session members", %{session_uri: session_uri} do
    {:ok, session_pid} = KindRegistry.lookup(session_uri)

    %{state: %{session: %{state: chat_slice}}} = :sys.get_state(session_pid)

    assert Map.has_key?(chat_slice.members, User.admin_uri()),
           "expected admin User in Session members; got #{inspect(chat_slice.members)}"

    assert chat_slice.members[User.admin_uri()].online == true
  end

  test "full send → broadcast → receive path through dispatch" do
    sender = User.admin_uri()
    session_uri = isolated_session("routing-send")

    msg =
      Message.new(sender, %{text: "integration-send #{System.unique_integer()}", attachments: []})

    # Subscribe to user:events for admin (the :receive path broadcasts here)
    user_topic = SessionBehavior.user_events_topic(sender)
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, user_topic)

    # Subscribe to session:events (the :send path broadcasts here)
    session_topic = SessionBehavior.session_events_topic(session_uri)
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, session_topic)

    # Dispatch send. Sender is admin; mentions empty → fan-out to all
    # members except sender. Only member besides sender is... none yet
    # (admin is the only joined member at boot). So no :receive fires.
    # The chat_message broadcast still fires for session:events.
    target = URI.new!("#{URI.to_string(session_uri)}?action=session.send")
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, sender)

    :ok =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: sender,
          authenticated_principal: sender,
          caps: MapSet.new([cap]),
          reply: :ignore
        }
      })

    # Session-level broadcast (for LV chat stream)
    assert_receive {:chat_message, _session_uri, %Message{id: received_id}}, 500
    assert received_id == msg.id

    # Message landed in MessageStore
    assert {:ok, loaded} = MessageStore.by_id(msg.id)
    assert loaded.session_uri == session_uri

    # PR-EM-6-PRE (Allen 2026-05-25) — `:send` now mutates the `:chat`
    # slice (sets last_message_id / last_message / send_cursor), and
    # Session is `{:snapshot, :on_change}`, so every send triggers a
    # Snapshot.commit which runs under the Session GenServer's
    # mailbox. Without this sync the test process may exit before the
    # snapshot finishes, killing its Sandbox-checked-out connection
    # mid-write — Exqlite logs an :owner_exited error and the test
    # appears flaky. `:sys.get_state` serializes through the
    # GenServer, so by the time it returns any prior handle_cast
    # (including commit_and_notify's Snapshot.commit) has drained.
    {:ok, session_pid} = KindRegistry.lookup(session_uri)
    %{state: %{session: %{state: chat_slice}}} = :sys.get_state(session_pid)
    assert chat_slice.last_message_id == msg.id
  end

  test ":DOWN forwarder marks member offline and records last_seen" do
    session_uri = isolated_session("routing-down")
    {:ok, session_pid} = KindRegistry.lookup(session_uri)

    transient_uri =
      URI.new!("entity://system/user/transient-down-#{System.unique_integer([:positive])}")

    {:ok, _row} =
      Ezagent.Users.create(
        transient_uri,
        "pw-not-secret-#{System.unique_integer([:positive])}",
        []
      )

    {:ok, transient_pid} = Ezagent.SpawnRegistry.spawn(transient_uri)

    # Join transient member to session
    join_target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")

    :ok =
      Membership.provision_invited_join_authority(session_uri, transient_uri, User.admin_uri())

    join_cap = Ezagent.Test.CapHelper.signed_action_cap!(join_target, transient_uri)

    :ok =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: join_target,
        mode: :cast,
        args: %{member: transient_uri},
        ctx: %{
          caller: transient_uri,
          authenticated_principal: transient_uri,
          caps: MapSet.new([join_cap]),
          reply: :ignore
        }
      })

    pre_kill_slice =
      wait_until(fn ->
        %{state: %{session: %{state: s}}} = :sys.get_state(session_pid)
        if Map.has_key?(s.members, transient_uri), do: s, else: nil
      end)

    assert pre_kill_slice.members[transient_uri].online == true

    # Issue cleanup authority while the transient user's sandbox-owned Kind is
    # still alive. Killing it intentionally invalidates that process's DB
    # checkout, but the already-signed artifact remains valid for Session.leave.
    leave_target = URI.new!("#{URI.to_string(session_uri)}?action=session.leave")
    leave_cap = Ezagent.Test.CapHelper.signed_action_cap!(leave_target, transient_uri)

    # Kill the transient process; Session.Process.monitor fires :DOWN.
    # The :DOWN is delivered to session_pid's mailbox by BEAM directly,
    # racing with any other messages we send. Poll until Session has
    # processed it (cheap — :sys.get_state at most a few times).
    :ok =
      DynamicSupervisor.terminate_child(
        EzagentDomainIdentity.Application.UserSupervisor,
        transient_pid
      )

    post_kill_slice =
      wait_until(fn ->
        %{state: %{session: %{state: s}}} = :sys.get_state(session_pid)
        if s.members[transient_uri].online == false, do: s, else: nil
      end)

    assert post_kill_slice.members[transient_uri].online == false
    assert %DateTime{} = post_kill_slice.last_seen[transient_uri]

    # Cleanup — leave transient member
    :ok =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: leave_target,
        mode: :cast,
        args: %{member: transient_uri},
        ctx: %{
          caller: transient_uri,
          authenticated_principal: transient_uri,
          caps: MapSet.new([leave_cap]),
          reply: :ignore
        }
      })
  end

  defp isolated_session(prefix) do
    short = "#{prefix}-#{System.unique_integer([:positive])}"

    assert {:ok, session_uri, _meta} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(
               short,
               User.admin_uri(),
               template_name: "default"
             )

    assert wait_until(fn ->
             case KindRegistry.lookup(session_uri) do
               {:ok, pid} ->
                 %{state: %{session: %{state: slice}}} = :sys.get_state(pid)
                 if Map.has_key?(slice.members, User.admin_uri()), do: true, else: nil

               :error ->
                 nil
             end
           end)

    session_uri
  end

  defmodule NoopServer do
    @moduledoc false
    use GenServer

    @impl true
    def init(uri) do
      # Self-register so KindRegistry.lookup returns OUR pid (Registry
      # always registers the calling process as owner — the value arg
      # to put_new is just stored metadata, not the looked-up pid).
      :ok = Ezagent.KindRegistry.put_new(uri)
      {:ok, %{}}
    end
  end

  defp wait_until(fun, retries \\ 50) do
    case fun.() do
      nil when retries > 0 ->
        Process.sleep(10)
        wait_until(fun, retries - 1)

      nil ->
        flunk("wait_until timed out")

      value ->
        value
    end
  end
end
