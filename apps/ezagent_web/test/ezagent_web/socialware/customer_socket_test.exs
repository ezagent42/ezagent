defmodule EzagentWeb.Socialware.CustomerSocketTest do
  use EzagentWeb.ConnCase, async: false

  import Phoenix.ChannelTest

  alias Ezagent.{Message, MessageStore}
  alias Ezagent.Entity.SocialwareSession
  alias Ezagent.Socialware.{CustomerAuth, Settlement}
  alias EzagentWeb.Socialware.{CustomerChannel, CustomerSocket}

  @endpoint EzagentWeb.Endpoint

  setup do
    session = session_uri()
    workspace = Ezagent.Capability.workspace_of(session)
    {:ok, _pid} = Ezagent.Kind.spawn(SocialwareSession, %{uri: session})
    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)

    token = CustomerAuth.issue_token(session, workspace)

    %{session: session, workspace: workspace, token: token}
  end

  test "connect rejects unauthorized and cross-session tokens", ctx do
    other = session_uri()
    :ok = Ezagent.WorkspaceRegistry.bind(other, Ezagent.Capability.workspace_of(other))

    assert :error =
             CustomerSocket.connect(
               %{"session_uri" => URI.to_string(other), "token" => ctx.token},
               %Phoenix.Socket{},
               %{}
             )

    assert :error =
             CustomerSocket.connect(
               %{"session_uri" => URI.to_string(ctx.session), "token" => "bad"},
               %Phoenix.Socket{},
               %{}
             )
  end

  test "join returns only committed customer-visible snapshot", ctx do
    {:ok, committed} = write_message(ctx.session, "committed", :customer_visible)
    {:ok, _draft} = write_message(ctx.session, "draft", :operator_only)
    commit_message(ctx, "turn-socket-snapshot", committed.id)

    {:ok, reply, _socket} = join_customer(ctx)

    assert get_in(reply, [:snapshot, :messages]) == [
             %{id: committed.id, text: "committed", sender: URI.to_string(committed.sender)}
           ]
  end

  test "history request uses the same gated query", ctx do
    {:ok, committed} = write_message(ctx.session, "history", :customer_visible)
    {:ok, _uncommitted} = write_message(ctx.session, "not yet", :customer_visible)
    commit_message(ctx, "turn-socket-history", committed.id)

    {:ok, _reply, socket} = join_customer(ctx)
    ref = Phoenix.ChannelTest.push(socket, "history", %{})

    assert_reply(ref, :ok, %{messages: [%{id: id, text: "history"}]})
    assert id == committed.id
  end

  test "delivery signal refetches through CustomerFeed before pushing", ctx do
    {:ok, _reply, socket} = join_customer(ctx)
    {:ok, committed} = write_message(ctx.session, "live", :customer_visible)
    commit_message(ctx, "turn-socket-live", committed.id)

    send(socket.channel_pid, {:customer_delivery, %{message_ids: [committed.id]}})

    assert_push("snapshot", %{messages: [%{id: id, text: "live"}]})
    assert id == committed.id
  end

  test "public customer page authenticates before bootstrapping SPA", %{conn: conn} = ctx do
    path =
      "/socialware/customer?session_uri=#{URI.encode_www_form(URI.to_string(ctx.session))}&token=#{URI.encode_www_form(ctx.token)}"

    conn = get(conn, path)
    assert html_response(conn, 200) =~ ~s(id="socialware-customer-root")
    assert html_response(conn, 200) =~ ~s(src="/assets/js/customer_app.js")

    denied =
      get(
        build_conn(),
        "/socialware/customer?session_uri=#{URI.encode_www_form(URI.to_string(ctx.session))}&token=bad"
      )

    assert text_response(denied, 403) == "unauthorized"
  end

  test "customer web route modules do not use raw feed sources" do
    web_root = Path.expand("../../../lib/ezagent_web", __DIR__)

    for relative <- [
          "socialware/customer_channel.ex",
          "socialware/customer_socket.ex",
          "controllers/socialware/customer_controller.ex"
        ] do
      source = File.read!(Path.join(web_root, relative))

      refute source =~ "MessageStore"
      refute source =~ "Publisher"
      refute source =~ "ExternalMirror"
      assert source =~ "CustomerFeed"
    end
  end

  defp join_customer(ctx) do
    @endpoint
    |> socket("socialware_customer:#{URI.to_string(ctx.session)}", %{
      session_uri: ctx.session,
      token: ctx.token
    })
    |> subscribe_and_join(
      CustomerChannel,
      "socialware:customer:#{URI.to_string(ctx.session)}",
      %{}
    )
  end

  defp write_message(session, text, visibility) do
    sender = Ezagent.URI.entity(:team_alpha, :agent, "orchestrator")
    message = Message.new(sender, %{text: text, attachments: []}, visibility: visibility)
    MessageStore.write(message, session)
  end

  defp commit_message(ctx, turn_id, message_id) do
    assert {:ok, _} =
             Settlement.begin(%{
               turn_id: turn_id,
               session_uri: ctx.session,
               workspace_uri: ctx.workspace,
               target_message_ids: [message_id],
               target_surface_version: nil,
               expected_prior_approved: nil
             })

    assert {:ok, _} = Settlement.mark_committed_for_test(turn_id)
  end

  defp session_uri do
    Ezagent.URI.session(
      :team_alpha,
      :socialware,
      "customer-socket-#{System.unique_integer([:positive])}"
    )
  end
end
