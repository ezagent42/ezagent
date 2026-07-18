defmodule Ezagent.ActionSet.Session.MentionFailedTest do
  @moduledoc """
  Allen 2026-05-26 directive — `chat.send` MUST surface a
  `:mention_failed` notification to the sender when an @-mention's
  resolved URI is not a session member.

  3-tuple classifier:

    - resolved + in session    → normal dispatch (existing path)
    - resolved + not in session → emit notification.emit:mention_failed
    - unresolved (casual @text) → silent (existing path; never enters
      `msg.mentions` because the mention parser filters)

  The discriminator is "did `msg.mentions` contain a URI but `recipients`
  did not?". The mention parser already filters non-Kind tokens, so the
  test only exercises the URI side.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.AgentFlavorAttributes
  alias Ezagent.Invocation
  alias Ezagent.Message
  import Ezagent.Test.CapHelper, only: [signed_action_cap!: 2]

  setup do
    # #94: UNIQUE URIs per test. These spawn globally-supervised Kinds
    # (session + agents) that live in `KindRegistry` for the BEAM's lifetime —
    # `DataCase` rolls back the DB but NOT the live GenServers. With FIXED URIs
    # the same session Kind was reused across tests/runs carrying STALE
    # in-memory membership while the DB was reset underneath it, so a later
    # `refute_receive {:mention_failed}` intermittently saw a spurious
    # mention_failed (member present in the test's just-committed-then-rolled-back
    # view but absent in the carried-over live Kind). Unique URIs give every test
    # a FRESH Kind — no cross-test/cross-run carry-over. (Passed in isolation,
    # flaked under the umbrella's concurrent load precisely because of this.)
    uniq = System.unique_integer([:positive])

    # Subscribe to the sender's notification topic so we can assert.
    sender_uri = Ezagent.URI.new!("entity://system/user/test-sender-#{uniq}")
    session_uri = Ezagent.URI.new!("session://system/default/test-mention-fail-#{uniq}")
    member_uri = Ezagent.URI.new!("entity://system/agent/py_member-agent-#{uniq}")
    non_member_uri = Ezagent.URI.new!("entity://system/agent/py_non-member-agent-#{uniq}")
    :ok = AgentFlavorAttributes.put(member_uri, "py")
    :ok = AgentFlavorAttributes.put(non_member_uri, "py")

    on_exit(fn ->
      AgentFlavorAttributes.delete(member_uri)
      AgentFlavorAttributes.delete(non_member_uri)
    end)

    Phoenix.PubSub.subscribe(
      EzagentCore.PubSub,
      Ezagent.Notifications.topic(sender_uri)
    )

    {:ok,
     sender: sender_uri, session: session_uri, member: member_uri, non_member: non_member_uri}
  end

  describe "notify_dropped_mentions/4 via :send" do
    test "emits :mention_failed when mention resolves but isn't a session member", ctx do
      # Spawn the sender + non_member so the URIs are known to the system.
      {:ok, _} = Ezagent.SpawnRegistry.spawn(ctx.sender)
      {:ok, _} = Ezagent.SpawnRegistry.spawn(ctx.non_member)

      # Spawn session with ONLY the sender as a member (non_member is
      # the @-target that's NOT a member — that's the case we want).
      {:ok, _} = Ezagent.SpawnRegistry.spawn(ctx.session)
      {:ok, _members} = join_session(ctx.session, ctx.sender, ctx.sender)

      msg = %Message{
        id: "test-mf-#{System.unique_integer([:positive])}",
        session_uri: ctx.session,
        sender: ctx.sender,
        body: %{"text" => "@py_non-member-agent hi"},
        mentions: [ctx.non_member],
        inserted_at: DateTime.utc_now()
      }

      send_message(ctx.session, msg, ctx.sender)

      # Wait briefly for async notification.
      assert_receive {:notification, _target_uri, %{type: :mention_failed} = note}, 2_000
      assert note.body.mentioned_uri == URI.to_string(ctx.non_member)
      assert note.body.session_uri == URI.to_string(ctx.session)
    end

    test "does NOT emit when mention resolves AND is a session member", ctx do
      {:ok, _} = Ezagent.SpawnRegistry.spawn(ctx.sender)
      {:ok, _} = Ezagent.SpawnRegistry.spawn(ctx.member)
      {:ok, _} = Ezagent.SpawnRegistry.spawn(ctx.session)

      # Synchronously CONFIRM the member's join is committed/visible before
      # we send: the join reply's `members` snapshot MUST already contain the
      # member, so the negative `refute_receive {:mention_failed}` below can
      # never race a transiently-non-resolved member. (`:call` join commits
      # the slice before replying — this assertion proves it deterministically
      # rather than trusting timing.)
      # Add the AGENT member under admin authority: the Part C admission gate
      # (spec §C.1) pends a cross-owner AGENT add, and `ctx.sender` neither manages
      # nor spawned this agent. Admin (genesis wildcard ⇒ manages? true) mounts it
      # directly, which is all this mention-resolution test needs. (Users are exempt
      # from the gate, so the sender self-joins below still mount as themselves.)
      {:ok, members_after_member_join} =
        join_session(ctx.session, ctx.member, Ezagent.Entity.User.admin_uri())

      assert ctx.member in members_after_member_join

      {:ok, members_after_sender_join} = join_session(ctx.session, ctx.sender, ctx.sender)
      assert ctx.member in members_after_sender_join

      msg = %Message{
        id: "test-mf-ok-#{System.unique_integer([:positive])}",
        session_uri: ctx.session,
        sender: ctx.sender,
        body: %{"text" => "@py_member-agent hi"},
        mentions: [ctx.member],
        inserted_at: DateTime.utc_now()
      }

      send_message(ctx.session, msg, ctx.sender)
      refute_receive {:notification, _, %{type: :mention_failed}}, 500
    end

    test "empty mentions list is silent (casual @text case)", ctx do
      {:ok, _} = Ezagent.SpawnRegistry.spawn(ctx.sender)
      {:ok, _} = Ezagent.SpawnRegistry.spawn(ctx.session)
      {:ok, _members} = join_session(ctx.session, ctx.sender, ctx.sender)

      msg = %Message{
        id: "test-mf-empty-#{System.unique_integer([:positive])}",
        session_uri: ctx.session,
        sender: ctx.sender,
        body: %{"text" => "casual @whatever talk"},
        mentions: [],
        inserted_at: DateTime.utc_now()
      }

      send_message(ctx.session, msg, ctx.sender)
      refute_receive {:notification, _, %{type: :mention_failed}}, 500
    end
  end

  defp join_session(session_uri, member_uri, caller_uri) do
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join")
    caps = [signed_action_cap!(target, caller_uri)]

    inv = %Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{member: member_uri},
      ctx: %{caller: caller_uri, caps: caps, deadline_ms: 5_000}
    }

    # `:join` is dispatched `mode: :call`, so `Kind.Server.handle_call/3`
    # commits the `{:set, :members, ...}` effect into the Session actor's
    # slice state BEFORE it replies (server.ex — `commit_and_notify` then
    # `{:reply, ..., %{state | state: new_slice_state}}`). The `:join`
    # action also `returns: %{members: {:list, :uri}}`, so the reply carries
    # the post-join membership snapshot. Return it so callers can SYNCHRONOUSLY
    # confirm the new member is committed/visible before a subsequent
    # `send_message` evaluates membership — closing any join↔send ordering
    # window for the negative `refute_receive {:mention_failed}` assertion.
    case Invocation.dispatch(inv) do
      {:ok, %{members: members}} -> {:ok, members}
      :ok -> {:ok, []}
      {:ok, _} -> {:ok, []}
      other -> raise "join_session failed: #{inspect(other)}"
    end
  end

  defp send_message(session_uri, msg, caller_uri) do
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.send")
    caps = [signed_action_cap!(target, caller_uri)]

    inv = %Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{message: msg},
      ctx: %{caller: caller_uri, caps: caps, deadline_ms: 5_000}
    }

    case Invocation.dispatch(inv) do
      {:ok, _} -> :ok
      :ok -> :ok
      other -> raise "send_message failed: #{inspect(other)}"
    end
  end
end
