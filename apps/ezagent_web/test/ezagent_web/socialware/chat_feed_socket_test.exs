defmodule EzagentWeb.Socialware.ChatFeedSocketTest do
  @moduledoc """
  P4-2 transport + P4-3 authz-boundary GATE for the chat external SPA.

  The chat_feed channel uses a windowed snapshot-refresh read (re-read the
  current latest-N on every advisory — NO cursor), gated by the LIVE
  `ChatMembership` predicate. These tests drive the REAL socket connect + the
  REAL channel join/advisory path, with members JOINED/LEFT via the production
  `chat.join` / `chat.leave` dispatch (the member is a live User Kind), so the
  membership re-check is exercised against the genuine live `:chat` slice:

    * a MEMBER / OWNER can view the chat session's external SPA;
    * a NON-MEMBER cannot (join denied);
    * an EX-MEMBER (after a real LEAVE) is denied on the next advisory replay
      via the LIVE re-check;
    * a forged / cross-session token is denied at connect.

  (The exhaustive crafted/malformed-caller matrix is the predicate's own gate —
  `Ezagent.Session.MembershipTest` — byte-equivalent to P3-3.)
  """
  use EzagentWeb.ConnCase, async: false

  import Phoenix.ChannelTest

  alias Ezagent.{Invocation, Message, MessageStore}
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.Socialware.ChatFeedAuth
  alias EzagentWeb.Socialware.{ChatFeedSocket, SessionFeedChannel}

  @endpoint EzagentWeb.Endpoint

  @sender Ezagent.URI.entity(:team_alpha, :agent, "cfs-bot")

  setup do
    owner = spawn_user("cfs-owner")

    session =
      Ezagent.URI.session(:team_alpha, :default, "cfs-#{System.unique_integer([:positive])}")

    workspace = Ezagent.Capability.workspace_of(session)
    # P5-0b — thread the explicit chat-Session behavior set so :kind_base is
    # non-nil and the scoped effective_set/2 guard does not crash the session.
    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session,
        owner_uri: owner,
        behaviors: Session.behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)

    member = spawn_user("cfs-member")
    {:ok, %{members: members}} = chat_join(session, member)
    assert member in members
    wait_until(fn -> Ezagent.Socialware.ExternalFeed.member?(session, member) end)
    wait_until(fn -> Ezagent.Socialware.ExternalFeed.member?(session, owner) end)

    %{session: session, workspace: workspace, member: member, owner: owner}
  end

  # A live User Kind to act as the runtime-added member — chat.join requires the
  # member's Kind alive in KindRegistry so Process.monitor has a live pid.
  defp spawn_user(label) do
    member =
      Ezagent.URI.entity(
        :team_alpha,
        :user,
        "#{label}-#{System.unique_integer([:positive])}"
      )

    {:ok, pid} = Ezagent.Kind.spawn(User, %{uri: member, initial_caps: MapSet.new()})

    on_exit(fn ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(
          EzagentDomainIdentity.Application.UserSupervisor,
          pid
        )
      end
    end)

    member
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("membership authority was not committed")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp chat_dispatch(session, action, member) do
    target = URI.new!("#{URI.to_string(session)}?action=session.#{action}")
    admin = User.admin_uri()
    {:ok, action_cap} = Ezagent.Cap.issue_for_action({:admin, admin}, admin, target)

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{member: member},
      ctx: %{
        caller: admin,
        caps: MapSet.new([action_cap]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp chat_join(session, member), do: chat_dispatch(session, :join, member)
  defp chat_leave(session, member), do: chat_dispatch(session, :leave, member)

  defp post_msg(session, text) do
    msg = Message.new(@sender, %{text: text, attachments: []}, visibility: :external_visible)
    {:ok, written} = MessageStore.write(msg, session)
    written
  end

  # The PRODUCTION write path: a real `chat.send` dispatch. This both persists
  # the message via the SAME `MessageStore.write/2` and broadcasts the canonical
  # `{:chat_message, session_uri, msg}` advisory on `esr:session:<uri>:events` —
  # exactly the event the chat_feed channel subscribes to in production. The
  # returned `msg.id` lets the assertion bind the live push to this send.
  defp chat_send(session, text) do
    msg = Message.new(@sender, %{text: text, attachments: []}, visibility: :external_visible)
    target = URI.new!("#{URI.to_string(session)}?action=session.send")

    {:ok, send_cap} =
      Ezagent.Cap.issue_for_action({:admin, User.admin_uri()}, @sender, target)

    {:ok, %{stored: true}} =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{message: msg},
        ctx: %{
          caller: @sender,
          caps: MapSet.new([send_cap]),
          reply: {:caller_inbox, self()}
        }
      })

    msg
  end

  defp join_as(session, caller, topic \\ nil) do
    token = ChatFeedAuth.issue_token(caller, session)
    topic = topic || "socialware:chat_feed:#{URI.to_string(session)}"

    @endpoint
    |> socket("socialware_chat_feed:#{URI.to_string(session)}", %{
      session_uri: session,
      caller: caller
    })
    |> subscribe_and_join(SessionFeedChannel, topic, %{token: token})
  end

  describe "connect — caller-identity token (P4-3)" do
    test "rejects a cross-session token", ctx do
      other =
        Ezagent.URI.session(
          :team_alpha,
          :default,
          "cfs-other-#{System.unique_integer([:positive])}"
        )

      token = ChatFeedAuth.issue_token(ctx.owner, other)

      assert :error =
               ChatFeedSocket.connect(
                 %{"session_uri" => URI.to_string(ctx.session), "token" => token},
                 %Phoenix.Socket{},
                 %{}
               )
    end

    test "rejects a forged token", ctx do
      assert :error =
               ChatFeedSocket.connect(
                 %{"session_uri" => URI.to_string(ctx.session), "token" => "forged"},
                 %Phoenix.Socket{},
                 %{}
               )
    end

    test "recovers the trusted caller from a valid token", ctx do
      token = ChatFeedAuth.issue_token(ctx.owner, ctx.session)

      assert {:ok, socket} =
               ChatFeedSocket.connect(
                 %{"session_uri" => URI.to_string(ctx.session), "token" => token},
                 %Phoenix.Socket{},
                 %{}
               )

      assert socket.assigns.caller == ctx.owner
    end
  end

  describe "join — live chat-membership authz boundary (P4-3, load-bearing)" do
    test "OWNER can view the external SPA — snapshot reflects chat messages", ctx do
      _m = post_msg(ctx.session, "hello owner")
      assert {:ok, reply, _socket} = join_as(ctx.session, ctx.owner)
      texts = reply.snapshot.page.children |> Enum.map(& &1.props.text)
      assert "hello owner" in texts
    end

    test "MEMBER can view the external SPA", ctx do
      _m = post_msg(ctx.session, "hello member")
      assert {:ok, reply, _socket} = join_as(ctx.session, ctx.member)
      assert "hello member" in (reply.snapshot.page.children |> Enum.map(& &1.props.text))
    end

    test "registered chat adapter works on the generic feed topic", ctx do
      _m = post_msg(ctx.session, "hello generic chat")
      topic = "socialware:feed:chat_feed:#{URI.to_string(ctx.session)}"

      assert {:ok, reply, _socket} = join_as(ctx.session, ctx.owner, topic)
      assert "hello generic chat" in (reply.snapshot.page.children |> Enum.map(& &1.props.text))
    end

    test "NON-MEMBER cannot join (denied)", ctx do
      stranger = Ezagent.URI.entity(:team_alpha, :user, "cfs-stranger")
      _m = post_msg(ctx.session, "secret to strangers")
      assert {:error, %{reason: "unauthorized"}} = join_as(ctx.session, stranger)
    end

    test "EX-MEMBER: a member who LEAVES is denied IMMEDIATELY on the leave event — no later chat.send needed (codex P4 HIGH)",
         ctx do
      _m = post_msg(ctx.session, "before leave")
      assert {:ok, _reply, _socket} = join_as(ctx.session, ctx.member)

      # The channel CLOSES on revocation ({:stop, :shutdown}); the test process is
      # linked to it via subscribe_and_join, so trap the expected exit.
      Process.flag(:trap_exit, true)

      # The member LEAVES via the production chat.leave path. handle_leave/2
      # broadcasts {:member_left, ...} on esr:session:<uri>:events — the SAME
      # topic the chat_feed channel subscribes to. The channel treats ANY event
      # there as an advisory → re-reads → the LIVE membership re-check now denies
      # the ex-member. NO subsequent chat.send is required.
      {:ok, _} = chat_leave(ctx.session, ctx.member)

      # The ex-member's client is cleared (explicit unauthorized push) AND the
      # channel is closed — fail-closed at the transport, immediately on leave.
      assert_push("unauthorized", %{reason: "membership_revoked"}, 1000)
      assert_receive {:EXIT, _channel_pid, :shutdown}, 1000
      refute_push("snapshot", _payload, 300)
    end
  end

  describe "live advisory replay (P4 codex finding 1 — PRODUCTION path)" do
    test "a real chat.send broadcast on esr:session:<uri>:events live-pushes the new message",
         ctx do
      # Join the chat_feed channel (subscribes to the canonical session events
      # topic). NO send(self(), ...) — drive the REAL production write path.
      assert {:ok, _reply, _socket} = join_as(ctx.session, ctx.owner)

      late = chat_send(ctx.session, "live update")

      # The chat write path's {:chat_message, ...} broadcast reaches the channel,
      # which re-reads from its durable cursor and pushes the refreshed snapshot.
      assert_push("snapshot", %{page: %{children: children}}, 1000)
      assert Enum.any?(children, &(&1.key == late.id and &1.props.text == "live update"))
    end
  end
end
