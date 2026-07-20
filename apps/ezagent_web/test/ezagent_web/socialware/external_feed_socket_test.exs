defmodule EzagentWeb.Socialware.ExternalFeedSocketTest do
  @moduledoc """
  Transport + authz-boundary gate for the external surface SPA.

  The external feed now authorizes reads via the LIVE `Membership` predicate (a
  ChatFeedAuth caller-identity token → principal → owner/member check), exactly
  as the chat feed does — there is NO identity-less session token. These tests
  drive the REAL socket connect + channel join/advisory path with the session
  OWNER as the viewer principal.
  """
  use EzagentWeb.ConnCase, async: false

  import Phoenix.ChannelTest

  alias Ezagent.{Message, MessageStore}
  alias Ezagent.Entity.Session
  alias Ezagent.Socialware.{ChatFeedAuth, Settlement}
  alias EzagentWeb.Socialware.{ExternalFeedSocket, SessionFeedChannel}

  @endpoint EzagentWeb.Endpoint

  @owner Ezagent.URI.entity(:team_alpha, :user, "external-socket-owner")

  setup do
    session = session_uri()
    workspace = Ezagent.Capability.workspace_of(session)

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session,
        owner_uri: @owner,
        behaviors: Session.socialware_behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)

    # The viewer's caller-identity token (the auth carrier the SPA sends). The
    # live membership re-check at the channel is the real authorization.
    token = ChatFeedAuth.issue_token(@owner, session)

    %{session: session, workspace: workspace, token: token}
  end

  test "connect rejects unauthorized and cross-session tokens", ctx do
    other = session_uri()
    :ok = Ezagent.WorkspaceRegistry.bind(other, Ezagent.Capability.workspace_of(other))

    # A token minted for ctx.session is bound to it — it does not verify for `other`.
    assert :error =
             ExternalFeedSocket.connect(
               %{"session_uri" => URI.to_string(other), "token" => ctx.token},
               %Phoenix.Socket{},
               %{}
             )

    assert :error =
             ExternalFeedSocket.connect(
               %{"session_uri" => URI.to_string(ctx.session), "token" => "bad"},
               %Phoenix.Socket{},
               %{}
             )
  end

  test "join returns only committed external-visible snapshot", ctx do
    {:ok, committed} = write_message(ctx.session, "committed", :external_visible)
    {:ok, _draft} = write_message(ctx.session, "draft", :internal)
    commit_message(ctx, "turn-socket-snapshot", committed.id)

    {:ok, reply, _socket} = join_external(ctx)

    assert get_in(reply, [:snapshot, :messages]) == [
             %{
               id: committed.id,
               text: "committed",
               sender: URI.to_string(committed.sender),
               render: nil,
               render_css: nil,
               nav: nil
             }
           ]
  end

  test "registered external adapter works on the generic feed topic", ctx do
    {:ok, committed} = write_message(ctx.session, "generic external", :external_visible)
    commit_message(ctx, "turn-socket-generic", committed.id)

    topic = "socialware:feed:external_feed:#{URI.to_string(ctx.session)}"
    {:ok, reply, _socket} = join_external(ctx, topic)

    assert get_in(reply, [:snapshot, :messages]) == [
             %{
               id: committed.id,
               text: "generic external",
               sender: URI.to_string(committed.sender),
               render: nil,
               render_css: nil,
               nav: nil
             }
           ]
  end

  test "history request uses the same gated query", ctx do
    {:ok, committed} = write_message(ctx.session, "history", :external_visible)
    {:ok, _uncommitted} = write_message(ctx.session, "not yet", :external_visible)
    commit_message(ctx, "turn-socket-history", committed.id)

    {:ok, _reply, socket} = join_external(ctx)
    ref = Phoenix.ChannelTest.push(socket, "history", %{})

    assert_reply(ref, :ok, %{messages: [%{id: id, text: "history"}]})
    assert id == committed.id
  end

  test "delivery signal refetches through ExternalFeed before pushing", ctx do
    {:ok, _reply, socket} = join_external(ctx)
    {:ok, committed} = write_message(ctx.session, "live", :external_visible)
    commit_message(ctx, "turn-socket-live", committed.id)

    send(socket.channel_pid, {:external_delivery, %{message_ids: [committed.id]}})

    assert_push("snapshot", %{messages: [%{id: id, text: "live"}]})
    assert id == committed.id
  end

  test "external web route modules do not use raw feed sources" do
    web_root = Path.expand("../../../lib/ezagent_web", __DIR__)

    for relative <- [
          "socialware/session_feed_channel.ex",
          "socialware/external_feed_socket.ex",
          "controllers/socialware/external_feed_controller.ex"
        ] do
      source = File.read!(Path.join(web_root, relative))

      refute source =~ "MessageStore"
      refute source =~ "Publisher"
      assert source =~ "ExternalFeed"
    end
  end

  defp join_external(ctx, topic \\ nil) do
    topic = topic || "socialware:external:#{URI.to_string(ctx.session)}"

    @endpoint
    |> socket("socialware_external:#{URI.to_string(ctx.session)}", %{
      session_uri: ctx.session,
      caller: @owner
    })
    |> subscribe_and_join(SessionFeedChannel, topic, %{})
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
      "external-socket-#{System.unique_integer([:positive])}"
    )
  end

  describe "GET /socialware/external/download — external bearer attachment (P2a, codex HIGH)" do
    setup ctx do
      home =
        Path.join(System.tmp_dir!(), "ezagent_ext_dl_#{System.unique_integer([:positive])}")

      File.mkdir_p!(home)
      prior = System.get_env("EZAGENT_HOME")
      System.put_env("EZAGENT_HOME", home)

      on_exit(fn ->
        if prior,
          do: System.put_env("EZAGENT_HOME", prior),
          else: System.delete_env("EZAGENT_HOME")

        File.rm_rf(home)
      end)

      ws_name = Ezagent.URI.workspace_name!(ctx.workspace)
      %{ws_name: ws_name}
    end

    # Store bytes via the production uploads path + attach the upload in a
    # committed external-visible message so it is "approved".
    defp store_approved_attachment(ctx, content) do
      filename = "#{Ecto.UUID.generate()}-feed.pdf"
      tmp = Path.join(System.tmp_dir!(), "tmp-#{System.unique_integer([:positive])}")
      File.write!(tmp, content)
      upload_uri = Ezagent.Uploads.store!(ctx.ws_name, filename, tmp)
      File.rm(tmp)

      msg =
        Message.new(
          Ezagent.URI.entity(:team_alpha, :agent, "orchestrator"),
          %{text: "see attached", attachments: [upload_uri]},
          visibility: :external_visible
        )

      {:ok, written} = MessageStore.write(msg, ctx.session)
      commit_message(ctx, "turn-feed-#{System.unique_integer([:positive])}", written.id)
      {upload_uri, written}
    end

    defp dl_path(session, token, file_token) do
      "/socialware/external/download?session_uri=#{URI.encode_www_form(URI.to_string(session))}" <>
        "&token=#{URI.encode_www_form(token)}&file_token=#{URI.encode_www_form(file_token)}"
    end

    test "a member with valid identity + file tokens downloads an approved file", ctx do
      {upload_uri, _} = store_approved_attachment(ctx, "feed-bytes")

      file_token =
        Ezagent.Uploads.DownloadToken.mint!(upload_uri,
          ttl_seconds: 60,
          __test_allow_unbound__: true
        )

      conn = get(build_conn(), dl_path(ctx.session, ctx.token, file_token))

      assert conn.status == 200
      assert conn.resp_body == "feed-bytes"
    end

    test "403 when the caller identity token is forged", ctx do
      {upload_uri, _} = store_approved_attachment(ctx, "feed-bytes")

      file_token =
        Ezagent.Uploads.DownloadToken.mint!(upload_uri,
          ttl_seconds: 60,
          __test_allow_unbound__: true
        )

      conn = get(build_conn(), dl_path(ctx.session, "forged", file_token))
      assert conn.status == 403
    end

    test "403 after approval is revoked (serve-time re-validation)", ctx do
      {upload_uri, written} = store_approved_attachment(ctx, "feed-bytes")

      file_token =
        Ezagent.Uploads.DownloadToken.mint!(upload_uri,
          ttl_seconds: 60,
          __test_allow_unbound__: true
        )

      # Works first.
      assert get(build_conn(), dl_path(ctx.session, ctx.token, file_token)).status == 200

      # Operator flips visibility back — the already-minted token must stop working.
      {:ok, _} = MessageStore.mark_visibility([written.id], :internal)
      assert get(build_conn(), dl_path(ctx.session, ctx.token, file_token)).status == 403
    end

    test "403 when the file token names a non-approved attachment", ctx do
      bogus = Ezagent.URI.resource(ctx.ws_name, "uploads", "#{Ecto.UUID.generate()}-x.pdf")

      file_token =
        Ezagent.Uploads.DownloadToken.mint!(bogus, ttl_seconds: 60, __test_allow_unbound__: true)

      conn = get(build_conn(), dl_path(ctx.session, ctx.token, file_token))
      assert conn.status == 403
    end

    test "PR-3: a member downloads with a grantee-bound token minted via the approved gate",
         ctx do
      {upload_uri, _} = store_approved_attachment(ctx, "feed-bytes")

      # Mint INSIDE the cap-gated read — the token is person-bound to @owner.
      assert {:ok, file_token} =
               Ezagent.Socialware.ExternalFeed.mint_approved_token(
                 @owner,
                 ctx.session,
                 upload_uri,
                 &Ezagent.Uploads.DownloadToken.mint!/2
               )

      conn = get(build_conn(), dl_path(ctx.session, ctx.token, file_token))

      assert conn.status == 200
      assert conn.resp_body == "feed-bytes"
    end

    test "PR-3 AUTHZ-REJECTION: a leaked grantee-bound token replayed by a NON-grantee member is rejected",
         ctx do
      {upload_uri, _} = store_approved_attachment(ctx, "feed-bytes")

      assert {:ok, leaked_file_token} =
               Ezagent.Socialware.ExternalFeed.mint_approved_token(
                 @owner,
                 ctx.session,
                 upload_uri,
                 &Ezagent.Uploads.DownloadToken.mint!/2
               )

      # The attacker is a LEGITIMATE viewer: roster-joined via the production
      # session.join dispatch AND holding the session member-cap (injected
      # signed at spawn — the at-join grant is best-effort async, A1, and does
      # not deterministically land in-test). Session authz + the approved
      # re-validation therefore PASS for the attacker — only the grantee
      # binding can reject their replay.
      attacker =
        Ezagent.URI.entity(:team_alpha, :user, "ext-replay-#{System.unique_integer([:positive])}")

      member_cap =
        Ezagent.Test.CapHelper.signed_cap!(
          ctx.session,
          attacker,
          Ezagent.Capability.cap(
            :session,
            Ezagent.ActionSet.Session,
            :receive,
            ctx.session,
            ctx.workspace
          )
        )

      {:ok, _pid} =
        Ezagent.Kind.spawn(Ezagent.Entity.User, %{
          uri: attacker,
          initial_caps:
            attacker |> Ezagent.Entity.User.initial_caps_for_spawn() |> MapSet.put(member_cap)
        })

      assert {:ok, _} = join_session(ctx.session, attacker)
      assert Ezagent.Socialware.SessionReads.authorized?(attacker, ctx.session)

      attacker_token = ChatFeedAuth.issue_token(attacker, ctx.session)

      # POSITIVE CONTROL: the attacker IS an authorized viewer — a token bound
      # to THEM mints + serves fine (session authz + approved re-validation all
      # pass), so the replay rejection below is the GRANTEE binding, not any
      # earlier gate.
      assert {:ok, attacker_file_token} =
               Ezagent.Socialware.ExternalFeed.mint_approved_token(
                 attacker,
                 ctx.session,
                 upload_uri,
                 &Ezagent.Uploads.DownloadToken.mint!/2
               )

      assert get(build_conn(), dl_path(ctx.session, attacker_token, attacker_file_token)).status ==
               200

      # The leaked token (bound to @owner) replayed BY the attacker → 403.
      conn = get(build_conn(), dl_path(ctx.session, attacker_token, leaked_file_token))
      assert conn.status == 403
    end

    test "PR-3 ZERO-BREAKAGE: an absent-grantee (legacy) file token still serves a member", ctx do
      {upload_uri, _} = store_approved_attachment(ctx, "feed-bytes")

      legacy_file_token =
        Ezagent.Uploads.DownloadToken.mint!(upload_uri,
          ttl_seconds: 60,
          __test_allow_unbound__: true
        )

      conn = get(build_conn(), dl_path(ctx.session, ctx.token, legacy_file_token))

      assert conn.status == 200
      assert conn.resp_body == "feed-bytes"
    end

    # Join `member_uri` to the session via the PRODUCTION `session.join`
    # dispatch (the at-join grant lands the member-cap LIVE, which the
    # serve-time `SessionReads.authorized?/2` predicate requires).
    defp join_session(session_uri, member_uri) do
      target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join")
      caller = Ezagent.Entity.User.admin_uri()
      cap = Ezagent.Test.CapHelper.signed_action_cap!(target, caller)

      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{member: member_uri},
        ctx: %{caller: caller, caps: MapSet.new([cap]), reply: :ignore}
      })
    end
  end

  describe "GET /socialware/external — the SPA shell" do
    test "renders the viewer SPA shell for the session owner", %{conn: conn} = ctx do
      # Sign in as the owner so the controller resolves a real principal (no anon
      # mint needed) and the live membership read passes.
      conn = Plug.Test.init_test_session(conn, %{current_entity_uri: URI.to_string(@owner)})

      path = "/socialware/external?session_uri=#{URI.encode_www_form(URI.to_string(ctx.session))}"

      conn = get(conn, path)
      body = html_response(conn, 200)
      assert body =~ ~s(id="socialware-viewer-root")
      assert body =~ ~s(src="/assets/js/viewer_app.js")
      assert body =~ ~s(data-topic-prefix="socialware:external")
    end

    test "missing session_uri is a 400", %{conn: conn} do
      conn = get(conn, "/socialware/external")
      assert text_response(conn, 400) =~ "session_uri"
    end
  end

  describe "legacy 301 redirect" do
    test "/socialware/customer 301-redirects to /socialware/external", %{conn: conn} = ctx do
      qs = "session_uri=#{URI.encode_www_form(URI.to_string(ctx.session))}"
      conn = get(conn, "/socialware/customer?" <> qs)
      assert redirected_to(conn, 301) == "/socialware/external?" <> qs
    end

    test "/socialware/customer/download 301-redirects to /socialware/external/download", %{
      conn: conn
    } do
      conn = get(conn, "/socialware/customer/download?token=x")
      assert redirected_to(conn, 301) == "/socialware/external/download?token=x"
    end
  end
end
