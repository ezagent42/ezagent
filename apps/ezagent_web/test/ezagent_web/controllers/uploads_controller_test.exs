defmodule EzagentWeb.UploadsControllerTest do
  @moduledoc """
  Resource-unification P2 — the uploads download contract change.

  ## What changed (🔒 AUTH-CONTRACT CHANGE — Allen-gated)

  P2 replaces the participation-based `GET /files/:filename` route with a
  **signed capability token** (OI-1 DECISION) and a ws-partitioned on-disk layout
  (`…/uploads/<ws>/<name>`). The legacy `/files/:filename` route is FULLY RETIRED
  (Allen-approved 2026-06-08) — NO back-compat shim. The SOLE internal route is:

      GET /uploads/download?token=<signed-token>

  The token encodes the full ws-scoped `resource://<ws>/uploads/<name>` URI; the
  controller verifies it (MAC + TTL), then runs the `FsResolver` `uploads`
  `authority/2` against the **request-mount workspace** (derived from the
  authenticated entity, NOT from the URI) — `uri.<ws> == mount.workspace`.

  Invariants pinned:

    * token round-trip upload→download (real route);
    * foreign-`<ws>` download denied (403) — workspace isolation via authority/2;
    * same filename in two workspaces isolated on disk + on read;
    * expired / tampered token rejected;
    * unauthorized callers get a uniform response (no file-existence oracle);
    * anon callers bounced by RequireEntity before the controller;
    * the retired `/files/:filename` route is GONE (404) — no shim.
  """

  use EzagentWeb.ConnCase

  alias Ezagent.Uploads.DownloadToken
  alias Ezagent.URI, as: EzURI

  @workspace_name "team-uploads"
  @other_workspace "team-other"

  setup do
    home =
      Path.join(System.tmp_dir!(), "ezagent_uploads_test_#{System.unique_integer([:positive])}")

    prior_home = System.get_env("EZAGENT_HOME")
    System.put_env("EZAGENT_HOME", home)

    on_exit(fn ->
      if prior_home,
        do: System.put_env("EZAGENT_HOME", prior_home),
        else: System.delete_env("EZAGENT_HOME")

      _ = File.rm_rf(home)
    end)

    for ws <- [@workspace_name, @other_workspace] do
      case Ezagent.Workspace.Store.get_by_name(ws) do
        nil -> {:ok, _} = Ezagent.Workspace.Store.create(ws, %{})
        _ -> :ok
      end
    end

    %{home: home}
  end

  alias Ezagent.{Message, MessageStore}

  defp uniq, do: System.unique_integer([:positive])
  defp uploaded_filename, do: "#{Ecto.UUID.generate()}-doc.txt"

  defp user_uri(ws, name), do: EzURI.new!("entity://#{ws}/user/#{name}")

  defp session_uri(ws, name) do
    uri = EzURI.new!("session://#{ws}/#{ws}/#{name}")
    :ok = Ezagent.WorkspaceRegistry.bind(uri, EzURI.new!("workspace://" <> ws))
    uri
  end

  # Write bytes into the ws-partitioned upload store via the production path
  # (Ezagent.Uploads.store!/3), returning the resource URI + content.
  defp store_upload(ws, filename, content \\ nil) do
    content = content || "payload-#{:rand.uniform(999_999)}"
    tmp = Path.join(System.tmp_dir!(), "tmp-#{System.unique_integer([:positive])}")
    File.write!(tmp, content)
    uri = Ezagent.Uploads.store!(ws, filename, tmp)
    File.rm(tmp)
    {uri, content}
  end

  # Persist a message in `session` whose attachments include the upload — this is
  # what makes `sender` an "uploader" (and lets later senders be participants).
  # The token download path runs an uploader/participant authz at serve time
  # (the admin bypass was DELETED — admin/business decoupling 2026-07-09), so a
  # stored file alone is NOT downloadable.
  defp attach_in_message(sender, ws, session, filename) do
    msg =
      Message.new(sender, %{
        text: "see attached",
        attachments: [EzURI.resource(ws, "uploads", filename)]
      })

    {:ok, _} = MessageStore.write(msg, session)
    :ok
  end

  defp sent_text_message(sender, session) do
    msg = Message.new(sender, %{text: "hello", attachments: []})
    {:ok, _} = MessageStore.write(msg, session)
    :ok
  end

  # Store bytes + attach them in a fresh session sent by `uploader`, returning
  # everything the happy-path tests need (the upload URI, content, session).
  defp upload_and_attach(ws, uploader, filename, content \\ nil) do
    {uri, content} = store_upload(ws, filename, content)
    session = session_uri(ws, "s-#{uniq()}")
    :ok = attach_in_message(uploader, ws, session, filename)
    {uri, content, session}
  end

  defp sign_in(conn, ws, %URI{} = entity_uri) do
    Plug.Test.init_test_session(conn, %{
      "current_entity_uri" => URI.to_string(entity_uri),
      "current_workspace_uri" => "workspace://" <> ws
    })
  end

  describe "GET /uploads/download?token= — signed-token contract" do
    test "200 + body for the UPLOADER with a valid token under the matching mount workspace",
         %{conn: conn} do
      filename = uploaded_filename()
      uploader = user_uri(@workspace_name, "alice-#{uniq()}")
      {uri, content, _session} = upload_and_attach(@workspace_name, uploader, filename)
      token = DownloadToken.mint!(uri, ttl_seconds: 60)

      conn =
        conn
        |> sign_in(@workspace_name, uploader)
        |> get(~p"/uploads/download?token=#{token}")

      assert conn.status == 200
      assert conn.resp_body == content
    end

    test "200 for a SESSION PARTICIPANT who is not the uploader", %{conn: conn} do
      filename = uploaded_filename()
      uploader = user_uri(@workspace_name, "alice-#{uniq()}")
      participant = user_uri(@workspace_name, "bob-#{uniq()}")
      {uri, content, session} = upload_and_attach(@workspace_name, uploader, filename)
      # bob becomes a participant by sending into the same session.
      :ok = sent_text_message(participant, session)
      token = DownloadToken.mint!(uri, ttl_seconds: 60)

      conn =
        conn
        |> sign_in(@workspace_name, participant)
        |> get(~p"/uploads/download?token=#{token}")

      assert conn.status == 200
      assert conn.resp_body == content
    end

    test "403 for a same-workspace OBSERVER who never participated (NO auth widening, codex HIGH)",
         %{conn: conn} do
      # The crux of the P2 revision: an authenticated same-workspace caller who
      # can VIEW the session (and thus could be handed a rendered token link) but
      # is neither uploader nor participant must NOT be able to download.
      # A leaked/observer token is useless — serve-time authz matches pre-P2.
      filename = uploaded_filename()
      uploader = user_uri(@workspace_name, "alice-#{uniq()}")
      observer = user_uri(@workspace_name, "eve-#{uniq()}")
      {uri, _content, _session} = upload_and_attach(@workspace_name, uploader, filename)
      token = DownloadToken.mint!(uri, ttl_seconds: 60)

      conn =
        conn
        |> sign_in(@workspace_name, observer)
        |> get(~p"/uploads/download?token=#{token}")

      assert conn.status == 403
    end

    test "403 for a non-participant ADMIN (NO operator bypass — admin/business decoupling)",
         %{conn: conn} do
      # Attachments are business content: the genesis admin downloads exactly
      # what any caller does — files from sessions it participates in. The
      # pre-2026-07-09 admin bypass is deleted (`business_context_admin_checks`
      # arch gate); this pins the observable behavior.
      filename = uploaded_filename()
      uploader = user_uri(@workspace_name, "alice-#{uniq()}")
      {uri, _content, _session} = upload_and_attach(@workspace_name, uploader, filename)
      token = DownloadToken.mint!(uri, ttl_seconds: 60)

      conn =
        conn
        |> sign_in(@workspace_name, Ezagent.Entity.User.admin_uri())
        |> get(~p"/uploads/download?token=#{token}")

      assert conn.status == 403
    end

    test "200 for an ADMIN who IS a session participant (membership, not identity, governs)",
         %{conn: conn} do
      filename = uploaded_filename()
      uploader = user_uri(@workspace_name, "alice-#{uniq()}")
      admin = Ezagent.Entity.User.admin_uri()
      {uri, content, session} = upload_and_attach(@workspace_name, uploader, filename)
      # The admin becomes a participant like anyone else — by sending into the
      # attaching session.
      :ok = sent_text_message(admin, session)
      token = DownloadToken.mint!(uri, ttl_seconds: 60)

      conn =
        conn
        |> sign_in(@workspace_name, admin)
        |> get(~p"/uploads/download?token=#{token}")

      assert conn.status == 200
      assert conn.resp_body == content
    end

    test "mount workspace is the SELECTED current_workspace_uri, not the entity home (codex r2)",
         %{conn: conn} do
      # A system-HOME entity context-switched into team-other reads team-other's
      # file — proving authority uses the selected workspace slot, not the
      # entity's home workspace. (The caller is the UPLOADER so the participant
      # gate passes on membership — no admin bypass exists anymore — and this
      # test isolates the workspace-derivation behavior.)
      filename = uploaded_filename()
      uploader = user_uri("system", "carol-#{uniq()}")
      {uri, content, _session} = upload_and_attach(@other_workspace, uploader, filename)
      token = DownloadToken.mint!(uri, ttl_seconds: 60)

      conn =
        conn
        |> sign_in(@other_workspace, uploader)
        |> get(~p"/uploads/download?token=#{token}")

      assert conn.status == 200
      assert conn.resp_body == content
    end

    test "403 for a token bound to a FOREIGN workspace (authority/2)", %{conn: conn} do
      # The token is minted for team-other but the caller is mounted in
      # team-uploads. Even the UPLOADER (who clears the participant gate) is
      # denied — workspace isolation via authority/2 still applies.
      filename = uploaded_filename()
      uploader = user_uri(@other_workspace, "carol-#{uniq()}")
      {uri, _content, _session} = upload_and_attach(@other_workspace, uploader, filename)
      token = DownloadToken.mint!(uri, ttl_seconds: 60)

      conn =
        conn
        |> sign_in(@workspace_name, uploader)
        |> get(~p"/uploads/download?token=#{token}")

      assert conn.status == 403
    end

    test "403 for an expired token (TTL elapsed, no infinite tokens)", %{conn: conn} do
      filename = uploaded_filename()
      uploader = user_uri(@workspace_name, "alice-#{uniq()}")
      {uri, _content, _session} = upload_and_attach(@workspace_name, uploader, filename)
      token = DownloadToken.mint!(uri, ttl_seconds: -1, __test_allow_nonpositive__: true)

      conn =
        conn
        |> sign_in(@workspace_name, uploader)
        |> get(~p"/uploads/download?token=#{token}")

      assert conn.status == 403
    end

    test "403 for a tampered / forged token (MAC)", %{conn: conn} do
      conn =
        conn
        |> sign_in(@workspace_name, user_uri(@workspace_name, "alice-#{uniq()}"))
        |> get(~p"/uploads/download?token=#{"not-a-real-token"}")

      assert conn.status == 403
    end

    test "404 for an AUTHORIZED token whose bytes are not on disk (no oracle leak)",
         %{conn: conn} do
      # Uploader-authorized for a filename that was attached in a message but
      # whose bytes were never written — authorized caller gets a precise 404.
      filename = uploaded_filename()
      uploader = user_uri(@workspace_name, "alice-#{uniq()}")
      session = session_uri(@workspace_name, "s-#{uniq()}")
      :ok = attach_in_message(uploader, @workspace_name, session, filename)
      uri = EzURI.resource(@workspace_name, "uploads", filename)
      token = DownloadToken.mint!(uri, ttl_seconds: 60)

      conn =
        conn
        |> sign_in(@workspace_name, uploader)
        |> get(~p"/uploads/download?token=#{token}")

      assert conn.status == 404
    end

    test "redirects anon callers to /login (RequireEntity) before the controller",
         %{conn: conn} do
      filename = uploaded_filename()
      uploader = user_uri(@workspace_name, "alice-#{uniq()}")
      {uri, _content, _session} = upload_and_attach(@workspace_name, uploader, filename)
      token = DownloadToken.mint!(uri, ttl_seconds: 60)

      conn = get(conn, ~p"/uploads/download?token=#{token}")
      assert redirected_to(conn) == "/login"
    end
  end

  describe "ws-partitioned isolation" do
    test "same filename in two workspaces is isolated on disk and on read", %{conn: conn} do
      # The UPLOADER clears the participant gate (no admin bypass exists — the
      # filename-keyed participant check even matches uploader_a against BOTH
      # same-named attachments) so this test isolates the ws-partition behavior
      # (same filename, two workspaces, two bodies).
      filename = uploaded_filename()
      uploader_a = user_uri(@workspace_name, "alice-#{uniq()}")
      uploader_b = user_uri(@other_workspace, "carol-#{uniq()}")

      {uri_a, content_a, _sa} =
        upload_and_attach(@workspace_name, uploader_a, filename, "acme-bytes")

      {uri_b, content_b, _sb} =
        upload_and_attach(@other_workspace, uploader_b, filename, "beta-bytes")

      refute content_a == content_b

      token_a = DownloadToken.mint!(uri_a, ttl_seconds: 60)
      token_b = DownloadToken.mint!(uri_b, ttl_seconds: 60)

      # Uploader-a mounted in team-uploads downloads team-uploads' copy.
      conn_a =
        conn
        |> sign_in(@workspace_name, uploader_a)
        |> get(~p"/uploads/download?token=#{token_a}")

      assert conn_a.status == 200
      assert conn_a.resp_body == "acme-bytes"

      # The team-uploads mount cannot use team-other's token (ws isolation) —
      # even though the same-named attachment lets the caller clear the
      # participant gate, authority/2 still denies the foreign workspace.
      conn_cross =
        build_conn()
        |> sign_in(@workspace_name, uploader_a)
        |> get(~p"/uploads/download?token=#{token_b}")

      assert conn_cross.status == 403
    end
  end

  describe "GET /files/:filename — RETIRED (no back-compat shim, Allen-approved 2026-06-08)" do
    test "the legacy filename route is GONE — a stored file is NOT served via /files", %{
      conn: conn
    } do
      # Even with a real stored file AND an authenticated caller in its workspace,
      # `/files/<name>` must NOT resolve to the bytes — the route no longer exists,
      # so it falls through to the catch-all 404 (never 200, never the file body).
      filename = uploaded_filename()
      {_uri, content} = store_upload(@workspace_name, filename)

      conn =
        conn
        |> sign_in(@workspace_name, user_uri(@workspace_name, "alice-#{uniq()}"))
        |> get("/files/" <> filename)

      assert conn.status == 404
      refute conn.resp_body == content
    end

    test "the /files route is absent from the router (no controller action bound)" do
      refute Enum.any?(EzagentWeb.Router.__routes__(), fn route ->
               String.starts_with?(route.path, "/files")
             end),
             "expected ZERO /files routes after P2 retirement; the back-compat shim must be gone"
    end
  end

  describe "GET /admin/uploads/:filename — legacy admin route still removed" do
    test "404 on the old admin-prefixed URL", %{conn: conn} do
      conn =
        conn
        |> sign_in(@workspace_name, user_uri(@workspace_name, "alice-#{uniq()}"))
        |> get("/admin/uploads/" <> uploaded_filename())

      assert conn.status == 404
    end
  end
end
