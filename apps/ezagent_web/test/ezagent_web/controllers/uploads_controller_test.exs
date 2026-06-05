defmodule EzagentWeb.UploadsControllerTest do
  @moduledoc """
  Regression test for PR #305 r4 HIGH — uploads-route scope mismatch.

  Pins the cross-user isolation invariant that
  `EzagentWeb.UploadsController` enforces:

  - A signed-in user who is NEITHER the uploader NOR a participant
    in any session the file is attached to gets `403 Forbidden`
    when guessing another user's upload filename. This is THE
    invariant the route move + per-user authz was designed to
    establish — without it, `RequireEntity` would prove only
    "some signed-in entity", which is too weak.

  - The uploading user (sender of a message attaching the file)
    gets `200` + the file body.

  - A session participant (sent at least one message in a session
    that contains a message attaching the file) gets `200` — even
    if they didn't upload the file themselves.

  - Admin entities (`Ezagent.Entity.User.admin_uri/0`) bypass the
    relationship check entirely (operator/debugging powers).

  - Path-traversal attempts (`..`, empty, `.`) get `400`.

  - Anonymous callers (no `:current_entity_uri` in session) are
    bounced to `/login` by the `RequireEntity` plug BEFORE reaching
    the controller.

  Files live under `$EZAGENT_HOME/<profile>/uploads/`. Each test
  redirects `EZAGENT_HOME` to a per-test tmp dir to keep test runs
  hermetic.
  """

  use EzagentWeb.ConnCase

  alias Ezagent.{Message, MessageStore}

  @workspace_name "team-uploads"

  setup tags do
    # Per-test isolated EZAGENT_HOME so the uploads dir doesn't
    # leak across tests or into developer state.
    home =
      Path.join(System.tmp_dir!(), "ezagent_uploads_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join([home, Ezagent.Home.profile(), "uploads"]))
    prior_home = System.get_env("EZAGENT_HOME")
    System.put_env("EZAGENT_HOME", home)

    on_exit(fn ->
      if prior_home,
        do: System.put_env("EZAGENT_HOME", prior_home),
        else: System.delete_env("EZAGENT_HOME")

      _ = File.rm_rf(home)
    end)

    # Workspace binding for the session URIs used below — MessageStore.write/2
    # calls `Ezagent.Persistence.workspace_uri_for!/1` which raises if the
    # session isn't bound.
    workspace_uri = URI.new!("workspace://" <> @workspace_name)

    # Ensure the workspace row exists (some default-workspace tests
    # depend on this — defensive create_if_missing).
    case Ezagent.Workspace.Store.get_by_name(@workspace_name) do
      nil -> {:ok, _} = Ezagent.Workspace.Store.create(@workspace_name, %{})
      _ -> :ok
    end

    %{home: home, workspace_uri: workspace_uri, workspace_name: @workspace_name, tags: tags}
  end

  defp uniq, do: System.unique_integer([:positive])

  defp user_uri(name), do: URI.new!("entity://user/#{@workspace_name}/#{name}")

  defp session_uri(name) do
    uri = URI.new!("session://#{@workspace_name}/#{@workspace_name}/#{name}")
    workspace = URI.new!("workspace://" <> @workspace_name)
    :ok = Ezagent.WorkspaceRegistry.bind(uri, workspace)
    uri
  end

  defp write_upload(filename, content \\ "payload-#{:rand.uniform(999_999)}") do
    full = Path.join(Ezagent.Home.path("uploads"), filename)
    File.write!(full, content)
    {filename, content, full}
  end

  defp attach_in_message(sender_uri, session_uri, filename) do
    attachment_uri =
      URI.parse("resource://uploads/#{@workspace_name}/#{filename}")

    msg = Message.new(sender_uri, %{text: "see attached", attachments: [attachment_uri]})
    {:ok, _} = MessageStore.write(msg, session_uri)
    :ok
  end

  defp sent_text_message(sender_uri, session_uri) do
    msg = Message.new(sender_uri, %{text: "hello", attachments: []})
    {:ok, _} = MessageStore.write(msg, session_uri)
    :ok
  end

  defp sign_in(conn, %URI{} = entity_uri) do
    Plug.Test.init_test_session(conn, %{
      "current_entity_uri" => URI.to_string(entity_uri),
      "current_workspace_uri" => "workspace://" <> @workspace_name
    })
  end

  defp uploaded_filename, do: "#{Ecto.UUID.generate()}-doc.txt"

  describe "GET /files/:filename — authz" do
    test "200 + body when caller is the uploading user", %{conn: conn} do
      uploader = user_uri("alice-#{uniq()}")
      session = session_uri("s-#{uniq()}")
      filename = uploaded_filename()
      {_, content, _} = write_upload(filename)
      :ok = attach_in_message(uploader, session, filename)

      conn = conn |> sign_in(uploader) |> get("/files/" <> filename)

      assert conn.status == 200
      assert conn.resp_body == content
    end

    test "200 when caller is a session participant (uploader is someone else)",
         %{conn: conn} do
      uploader = user_uri("alice-#{uniq()}")
      participant = user_uri("bob-#{uniq()}")
      session = session_uri("s-#{uniq()}")
      filename = uploaded_filename()
      {_, content, _} = write_upload(filename)

      # Alice uploads + attaches.
      :ok = attach_in_message(uploader, session, filename)
      # Bob participated in the same session (sent his own text).
      :ok = sent_text_message(participant, session)

      conn = conn |> sign_in(participant) |> get("/files/" <> filename)

      assert conn.status == 200
      assert conn.resp_body == content
    end

    test "403 when caller has no relationship to the file (cross-user guessing)",
         %{conn: conn} do
      uploader = user_uri("alice-#{uniq()}")
      stranger = user_uri("eve-#{uniq()}")
      session = session_uri("s-#{uniq()}")
      filename = uploaded_filename()
      {_, _content, _} = write_upload(filename)
      :ok = attach_in_message(uploader, session, filename)

      # Eve is signed in but has NEVER touched this file or its session.
      conn = conn |> sign_in(stranger) |> get("/files/" <> filename)

      assert conn.status == 403
      assert conn.resp_body == "forbidden"
    end

    test "403 even if file exists on disk but is referenced by no message",
         %{conn: conn} do
      # Orphan file — uploaded but never attached. Without an attachment
      # record there's no way to prove ANYONE owns it, so non-admin
      # callers must be rejected.
      stranger = user_uri("eve-#{uniq()}")
      filename = uploaded_filename()
      {_, _content, _} = write_upload(filename)

      conn = conn |> sign_in(stranger) |> get("/files/" <> filename)

      assert conn.status == 403
    end

    test "200 when caller is admin (operator bypass)", %{conn: conn} do
      uploader = user_uri("alice-#{uniq()}")
      session = session_uri("s-#{uniq()}")
      filename = uploaded_filename()
      {_, content, _} = write_upload(filename)
      :ok = attach_in_message(uploader, session, filename)

      admin_uri = Ezagent.Entity.User.admin_uri()
      conn = conn |> sign_in(admin_uri) |> get("/files/" <> filename)

      assert conn.status == 200
      assert conn.resp_body == content
    end
  end

  describe "GET /files/:filename — bypass attempts (codex r1 HIGH)" do
    test "403 when caller sent a message whose TEXT mentions the filename (not attachments)",
         %{conn: conn} do
      # The pre-codex-r1 implementation matched a SQL LIKE against the
      # whole `CAST(body AS TEXT)` — so an attacker could put the
      # victim's filename in `body.text` (with `attachments: []`) and
      # the LIKE pattern `%/<filename>"%` would hit the JSON-quoted
      # text. Authoritative check now verifies the resource URI is
      # actually in the decoded attachments list.
      uploader = user_uri("alice-#{uniq()}")
      attacker = user_uri("eve-#{uniq()}")
      uploader_session = session_uri("alice-s-#{uniq()}")
      attacker_session = session_uri("eve-s-#{uniq()}")
      filename = uploaded_filename()
      {_, _content, _} = write_upload(filename)
      :ok = attach_in_message(uploader, uploader_session, filename)

      # Attacker sends a TEXT message (not attachment) referencing the
      # filename in their own, unrelated session.
      attachment_uri =
        URI.parse("resource://uploads/#{@workspace_name}/#{filename}")

      bad_msg =
        Message.new(attacker, %{
          text: "please fetch #{URI.to_string(attachment_uri)}",
          attachments: []
        })

      {:ok, _} = MessageStore.write(bad_msg, attacker_session)

      # Attacker must still be denied — they have no attachment record
      # for `filename` and aren't a participant in uploader's session.
      conn = conn |> sign_in(attacker) |> get("/files/" <> filename)

      assert conn.status == 403
      assert conn.resp_body == "forbidden"
    end

    test "filenames with `_` still authz-match for the real uploader (SQLite LIKE ESCAPE)",
         %{conn: conn} do
      # The pre-codex-r1 implementation built a LIKE pattern with `\_`
      # but never passed `ESCAPE '\'` to SQLite, so legitimate filenames
      # containing `_` (e.g. `my_file.txt` — sanitize_filename allows
      # underscores) silently failed the participant search. Fix uses
      # an explicit `ESCAPE '\'` clause. Pin the legitimate path so a
      # future refactor can't silently re-break it.
      uploader = user_uri("alice-#{uniq()}")
      session = session_uri("s-#{uniq()}")
      filename = "#{Ecto.UUID.generate()}-my_file_with_underscores.txt"
      {_, content, _} = write_upload(filename)
      :ok = attach_in_message(uploader, session, filename)

      conn = conn |> sign_in(uploader) |> get("/files/" <> filename)

      assert conn.status == 200
      assert conn.resp_body == content
    end
  end

  describe "GET /files/:filename — input validation" do
    test "400 on empty filename slug", %{conn: conn} do
      uploader = user_uri("alice-#{uniq()}")

      # Phoenix's `:filename` segment can't actually match ""; the
      # invalid-name branch handles the `"."` / `".."` edge.
      conn = conn |> sign_in(uploader) |> get("/files/.")
      assert conn.status == 400

      conn = build_conn() |> sign_in(uploader) |> get("/files/..")
      assert conn.status == 400
    end

    test "404 for valid-shaped filename that doesn't exist on disk (authorized caller)",
         %{conn: conn} do
      # Filename never written but caller is admin to bypass authz
      # (so we can isolate the "not on disk" branch). Authorized
      # callers get a precise signal — file existence is INFORMATION
      # they're allowed to learn (codex r1 LOW oracle fix applies
      # only to UNAUTHORIZED callers).
      admin = Ezagent.Entity.User.admin_uri()

      conn =
        conn
        |> sign_in(admin)
        |> get("/files/" <> uploaded_filename())

      assert conn.status == 404
      assert conn.resp_body == "upload not found"
    end

    test "403 (not 404) when unauthorized caller asks for a non-existent file (no existence oracle)",
         %{conn: conn} do
      # Codex r1 LOW: previously, an unauthorized caller could probe
      # whether a filename existed on disk by comparing 403 (exists,
      # forbidden) vs 404 (not found). Fix: authorize BEFORE checking
      # disk, so unauthorized callers ALWAYS get 403 regardless of
      # whether the file is present.
      stranger = user_uri("eve-#{uniq()}")
      bogus_filename = uploaded_filename()
      # Do NOT write the file to disk.

      conn = conn |> sign_in(stranger) |> get("/files/" <> bogus_filename)

      assert conn.status == 403
      assert conn.resp_body == "forbidden"
    end
  end

  describe "GET /files/:filename — auth pipeline" do
    test "redirects to /login when there's no signed-in entity",
         %{conn: conn} do
      filename = uploaded_filename()
      {_, _content, _} = write_upload(filename)

      # No sign_in/2 — RequireEntity should bounce before the
      # controller runs.
      conn = get(conn, "/files/" <> filename)
      assert redirected_to(conn) == "/login"
    end
  end

  describe "GET /admin/uploads/:filename — legacy route removed" do
    test "404 on the old admin-prefixed URL", %{conn: conn} do
      filename = uploaded_filename()
      uploader = user_uri("alice-#{uniq()}")

      # The pre-2026-05-25 path is gone — falls into the catch-all
      # `/*path → FallbackController :not_found`.
      conn =
        conn
        |> sign_in(uploader)
        |> get("/admin/uploads/" <> filename)

      # FallbackController renders the branded 404 — status 404,
      # body contains the i18n'd message; we just assert on status
      # to keep the test resilient to copy changes.
      assert conn.status == 404
    end
  end
end
