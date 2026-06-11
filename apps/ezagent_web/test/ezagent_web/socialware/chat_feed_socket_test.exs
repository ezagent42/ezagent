defmodule EzagentWeb.Socialware.ChatFeedSocketTest do
  @moduledoc """
  P4-2 transport + P4-3 authz-boundary GATE for the chat external SPA.

  The chat_feed channel reuses the P3-2 lower-bound cursor join + advisory
  replay machinery over the chat `inserted_at` cursor, gated by the LIVE
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
  `Ezagent.Socialware.ChatMembershipTest` — byte-equivalent to P3-3.)
  """
  use EzagentWeb.ConnCase, async: false

  import Phoenix.ChannelTest

  alias Ezagent.{Invocation, Message, MessageStore}
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.Socialware.ChatFeedAuth
  alias EzagentWeb.Socialware.{ChatFeedChannel, ChatFeedSocket}

  @endpoint EzagentWeb.Endpoint

  @owner Ezagent.URI.entity(:team_alpha, :user, "cfs-owner")
  @sender Ezagent.URI.entity(:team_alpha, :agent, "cfs-bot")

  setup do
    session =
      Ezagent.URI.session(:team_alpha, :default, "cfs-#{System.unique_integer([:positive])}")

    workspace = Ezagent.Capability.workspace_of(session)
    {:ok, _pid} = Ezagent.Kind.spawn(Session, %{uri: session, owner_uri: @owner})
    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)

    member = spawn_member()
    {:ok, %{members: members}} = chat_join(session, member)
    assert member in members

    %{session: session, workspace: workspace, member: member}
  end

  # A live User Kind to act as the runtime-added member — chat.join requires the
  # member's Kind alive in KindRegistry so Process.monitor has a live pid.
  defp spawn_member do
    member =
      Ezagent.URI.entity(:team_alpha, :user, "cfs-member-#{System.unique_integer([:positive])}")

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

  defp chat_dispatch(session, action, member) do
    target = URI.new!("#{URI.to_string(session)}?action=chat.#{action}")

    Invocation.dispatch(%Invocation{
      target: target,
      mode: :call,
      args: %{member: member},
      ctx: %{
        caller: User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp chat_join(session, member), do: chat_dispatch(session, :join, member)
  defp chat_leave(session, member), do: chat_dispatch(session, :leave, member)

  defp post_msg(session, text) do
    msg = Message.new(@sender, %{text: text, attachments: []}, visibility: :customer_visible)
    {:ok, written} = MessageStore.write(msg, session)
    written
  end

  defp join_as(session, caller) do
    token = ChatFeedAuth.issue_token(caller, session)

    @endpoint
    |> socket("socialware_chat_feed:#{URI.to_string(session)}", %{
      session_uri: session,
      caller: caller
    })
    |> subscribe_and_join(
      ChatFeedChannel,
      "socialware:chat_feed:#{URI.to_string(session)}",
      %{token: token}
    )
  end

  describe "connect — caller-identity token (P4-3)" do
    test "rejects a cross-session token", ctx do
      other =
        Ezagent.URI.session(
          :team_alpha,
          :default,
          "cfs-other-#{System.unique_integer([:positive])}"
        )

      token = ChatFeedAuth.issue_token(@owner, other)

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
      token = ChatFeedAuth.issue_token(@owner, ctx.session)

      assert {:ok, socket} =
               ChatFeedSocket.connect(
                 %{"session_uri" => URI.to_string(ctx.session), "token" => token},
                 %Phoenix.Socket{},
                 %{}
               )

      assert socket.assigns.caller == @owner
    end
  end

  describe "join — live chat-membership authz boundary (P4-3, load-bearing)" do
    test "OWNER can view the external SPA — snapshot reflects chat messages", ctx do
      _m = post_msg(ctx.session, "hello owner")
      assert {:ok, reply, _socket} = join_as(ctx.session, @owner)
      texts = reply.snapshot.page.children |> Enum.map(& &1.props.text)
      assert "hello owner" in texts
    end

    test "MEMBER can view the external SPA", ctx do
      _m = post_msg(ctx.session, "hello member")
      assert {:ok, reply, _socket} = join_as(ctx.session, ctx.member)
      assert "hello member" in (reply.snapshot.page.children |> Enum.map(& &1.props.text))
    end

    test "NON-MEMBER cannot join (denied)", ctx do
      stranger = Ezagent.URI.entity(:team_alpha, :user, "cfs-stranger")
      _m = post_msg(ctx.session, "secret to strangers")
      assert {:error, %{reason: "unauthorized"}} = join_as(ctx.session, stranger)
    end

    test "EX-MEMBER: a member who LEAVES is denied on the next advisory replay (live re-check)",
         ctx do
      _m = post_msg(ctx.session, "before leave")
      assert {:ok, _reply, socket} = join_as(ctx.session, ctx.member)

      # The member LEAVES via the production chat.leave path — removed from the
      # live :chat slice members map.
      {:ok, _} = chat_leave(ctx.session, ctx.member)

      # A new message + advisory arrives; the channel replays — and the LIVE
      # re-check now denies the ex-member, so NO snapshot is pushed.
      _late = post_msg(ctx.session, "after leave")
      send(socket.channel_pid, {:chat_feed_delivery, %{}})

      refute_push("snapshot", _payload, 200)
    end
  end

  describe "advisory replay — wake-up + live push" do
    test "a delivery advisory replays the new message to a current member", ctx do
      assert {:ok, _reply, socket} = join_as(ctx.session, @owner)
      late = post_msg(ctx.session, "live update")
      send(socket.channel_pid, {:chat_feed_delivery, %{}})

      assert_push("snapshot", %{page: %{children: children}})
      assert Enum.any?(children, &(&1.key == late.id and &1.props.text == "live update"))
    end
  end
end
