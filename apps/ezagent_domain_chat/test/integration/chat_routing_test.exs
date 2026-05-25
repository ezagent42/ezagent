defmodule EzagentDomainChat.Integration.ChatRoutingTest do
  @moduledoc """
  Phase 2b-step 2 integration test — full dispatch path through the
  live Session GenServer started by `EzagentDomainChat.Application`.

  Verifies the boot-time admin join landed and that subsequent chat
  send/receive routes via dispatch (not via direct invoke). Also
  covers the :DOWN forwarder path by spawning a transient member,
  joining it, killing it, and asserting Session marks it offline.
  """

  # Non-async — we share the live Session GenServer + EzagentCore.Repo across
  # examples and the :DOWN test will pollute the shared Session's slice.
  use ExUnit.Case
  alias Ezagent.{Invocation, KindRegistry, Message, MessageStore}
  alias Ezagent.Behavior.Chat
  alias Ezagent.Entity.{Session, User}
  alias EzagentCore.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "admin User landed in session://default/system/main members after boot" do
    {:ok, session_pid} = KindRegistry.lookup(Session.default_uri())

    %{state: %{chat: chat_slice}} = :sys.get_state(session_pid)

    assert Map.has_key?(chat_slice.members, User.admin_uri()),
           "expected admin User in Session members; got #{inspect(chat_slice.members)}"

    assert chat_slice.members[User.admin_uri()].online == true
  end

  test "full send → broadcast → receive path through dispatch" do
    sender = User.admin_uri()
    session_uri = Session.default_uri()
    msg = Message.new(sender, %{text: "integration-send #{System.unique_integer()}", attachments: []})

    # Subscribe to user:events for admin (the :receive path broadcasts here)
    user_topic = Chat.user_events_topic(sender)
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, user_topic)

    # Subscribe to session:events (the :send path broadcasts here)
    session_topic = Chat.session_events_topic(session_uri)
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, session_topic)

    # Dispatch send. Sender is admin; mentions empty → fan-out to all
    # members except sender. Only member besides sender is... none yet
    # (admin is the only joined member at boot). So no :receive fires.
    # The chat_message broadcast still fires for session:events.
    target = URI.new!("#{URI.to_string(session_uri)}?action=chat.send")

    :ok =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :cast,
        args: %{message: msg},
        ctx: %{caller: sender, caps: Ezagent.SystemPrincipal.caps("system://bootstrap"), reply: :ignore}
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
    %{state: %{chat: chat_slice}} = :sys.get_state(session_pid)
    assert chat_slice.last_message_id == msg.id
  end

  test ":DOWN forwarder marks member offline and records last_seen" do
    session_uri = Session.default_uri()
    {:ok, session_pid} = KindRegistry.lookup(session_uri)

    transient_uri = URI.new!("entity://user/team-alpha/transient-down-#{System.unique_integer([:positive])}")
    {:ok, transient_pid} = GenServer.start(__MODULE__.NoopServer, transient_uri)

    # Join transient member to session
    :ok =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(session_uri)}?action=chat.join"),
        mode: :cast,
        args: %{member: transient_uri},
        ctx: %{caller: transient_uri, caps: Ezagent.SystemPrincipal.caps("system://bootstrap"), reply: :ignore}
      })

    # Allow cast to process
    %{state: %{chat: pre_kill_slice}} = :sys.get_state(session_pid)
    assert pre_kill_slice.members[transient_uri].online == true

    # Kill the transient process; Session.Process.monitor fires :DOWN.
    # The :DOWN is delivered to session_pid's mailbox by BEAM directly,
    # racing with any other messages we send. Poll until Session has
    # processed it (cheap — :sys.get_state at most a few times).
    Process.exit(transient_pid, :kill)

    post_kill_slice =
      wait_until(fn ->
        %{state: %{chat: s}} = :sys.get_state(session_pid)
        if s.members[transient_uri].online == false, do: s, else: nil
      end)

    assert post_kill_slice.members[transient_uri].online == false
    assert %DateTime{} = post_kill_slice.last_seen[transient_uri]

    # Cleanup — leave transient member
    :ok =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(session_uri)}?action=chat.leave"),
        mode: :cast,
        args: %{member: transient_uri},
        ctx: %{caller: transient_uri, caps: Ezagent.SystemPrincipal.caps("system://bootstrap"), reply: :ignore}
      })
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
