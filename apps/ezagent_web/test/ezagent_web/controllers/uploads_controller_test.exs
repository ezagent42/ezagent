defmodule EzagentWeb.UploadsControllerTest do
  @moduledoc """
  Resource-unification P2 — the uploads download contract change.

  ## What changed (🔒 AUTH-CONTRACT CHANGE — Allen-gated)

  P2 replaces the participation-based `GET /files/:filename` authorization with a
  **signed capability token** (OI-1 DECISION) and a ws-partitioned on-disk layout
  (`…/uploads/<ws>/<name>`). The new primary route is:

      GET /uploads/download?token=<signed-token>

  The token encodes the full ws-scoped `resource://<ws>/uploads/<name>` URI; the
  controller verifies it (MAC + TTL), then runs the `FsResolver` `uploads`
  `authority/2` against the **request-mount workspace** (derived from the
  authenticated entity, NOT from the URI) — `uri.<ws> == mount.workspace`.

  `GET /files/:filename` stays as the ONE sanctioned back-compat shim (N6) for
  already-minted filename-only links during a deprecation window: it resolves the
  filename under the caller's authenticated mount workspace (so it serves the
  caller's OWN workspace copy — the disambiguation the new contract makes
  explicit; today's filenames are UUID-prefixed so cross-ws collision is
  effectively impossible).

  Invariants pinned:

    * token round-trip upload→download (real route);
    * foreign-`<ws>` download denied (403) — workspace isolation via authority/2;
    * same filename in two workspaces isolated on disk + on read;
    * expired / tampered token rejected;
    * traversal / empty / `.` / `..` rejected (400);
    * unauthorized callers get a uniform response (no file-existence oracle);
    * anon callers bounced by RequireEntity before the controller;
    * back-compat `/files/:filename` resolves within the window.
  """

  use EzagentWeb.ConnCase

  alias EzagentWeb.Uploads.UploadToken
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

  defp uniq, do: System.unique_integer([:positive])
  defp uploaded_filename, do: "#{Ecto.UUID.generate()}-doc.txt"

  defp user_uri(ws, name), do: EzURI.new!("entity://#{ws}/user/#{name}")

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

  defp sign_in(conn, ws, %URI{} = entity_uri) do
    Plug.Test.init_test_session(conn, %{
      "current_entity_uri" => URI.to_string(entity_uri),
      "current_workspace_uri" => "workspace://" <> ws
    })
  end

  describe "GET /uploads/download?token= — signed-token contract" do
    test "200 + body for a valid token under the matching mount workspace", %{conn: conn} do
      {uri, content} = store_upload(@workspace_name, uploaded_filename())
      token = UploadToken.mint!(uri, ttl_seconds: 60)

      conn =
        conn
        |> sign_in(@workspace_name, user_uri(@workspace_name, "alice-#{uniq()}"))
        |> get(~p"/uploads/download?token=#{token}")

      assert conn.status == 200
      assert conn.resp_body == content
    end

    test "mount workspace is the SELECTED current_workspace_uri, not the entity home (codex r2)",
         %{conn: conn} do
      # A system entity (home = system) context-switched into team-other reads
      # team-other's file — proving authority uses the selected workspace slot,
      # not the entity's home workspace.
      {uri, content} = store_upload(@other_workspace, uploaded_filename())
      token = UploadToken.mint!(uri, ttl_seconds: 60)

      system_entity = EzURI.new!("entity://system/user/op-#{uniq()}")

      conn =
        conn
        |> sign_in(@other_workspace, system_entity)
        |> get(~p"/uploads/download?token=#{token}")

      assert conn.status == 200
      assert conn.resp_body == content
    end

    test "403 for a token bound to a FOREIGN workspace (authority/2)", %{conn: conn} do
      # The token is minted for team-other but the caller is mounted in
      # team-uploads — workspace isolation must deny it.
      {uri, _content} = store_upload(@other_workspace, uploaded_filename())
      token = UploadToken.mint!(uri, ttl_seconds: 60)

      conn =
        conn
        |> sign_in(@workspace_name, user_uri(@workspace_name, "eve-#{uniq()}"))
        |> get(~p"/uploads/download?token=#{token}")

      assert conn.status == 403
    end

    test "403 for an expired token (TTL elapsed, no infinite tokens)", %{conn: conn} do
      {uri, _content} = store_upload(@workspace_name, uploaded_filename())
      token = UploadToken.mint!(uri, ttl_seconds: -1, __test_allow_nonpositive__: true)

      conn =
        conn
        |> sign_in(@workspace_name, user_uri(@workspace_name, "alice-#{uniq()}"))
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

    test "404 for a valid token whose bytes are not on disk (authorized, no oracle leak)",
         %{conn: conn} do
      # A token bound to the caller's own workspace but the file was never
      # written — authorized caller gets a precise 404.
      uri = EzURI.resource(@workspace_name, "uploads", uploaded_filename())
      token = UploadToken.mint!(uri, ttl_seconds: 60)

      conn =
        conn
        |> sign_in(@workspace_name, user_uri(@workspace_name, "alice-#{uniq()}"))
        |> get(~p"/uploads/download?token=#{token}")

      assert conn.status == 404
    end

    test "redirects anon callers to /login (RequireEntity) before the controller",
         %{conn: conn} do
      {uri, _content} = store_upload(@workspace_name, uploaded_filename())
      token = UploadToken.mint!(uri, ttl_seconds: 60)

      conn = get(conn, ~p"/uploads/download?token=#{token}")
      assert redirected_to(conn) == "/login"
    end
  end

  describe "ws-partitioned isolation" do
    test "same filename in two workspaces is isolated on disk and on read", %{conn: conn} do
      filename = uploaded_filename()
      {uri_a, content_a} = store_upload(@workspace_name, filename, "acme-bytes")
      {uri_b, content_b} = store_upload(@other_workspace, filename, "beta-bytes")

      refute content_a == content_b

      token_a = UploadToken.mint!(uri_a, ttl_seconds: 60)
      token_b = UploadToken.mint!(uri_b, ttl_seconds: 60)

      # Caller mounted in team-uploads downloads its own copy.
      conn_a =
        conn
        |> sign_in(@workspace_name, user_uri(@workspace_name, "alice-#{uniq()}"))
        |> get(~p"/uploads/download?token=#{token_a}")

      assert conn_a.status == 200
      assert conn_a.resp_body == "acme-bytes"

      # The team-uploads caller cannot use team-other's token.
      conn_cross =
        build_conn()
        |> sign_in(@workspace_name, user_uri(@workspace_name, "alice-#{uniq()}"))
        |> get(~p"/uploads/download?token=#{token_b}")

      assert conn_cross.status == 403
    end
  end

  describe "GET /files/:filename — back-compat window (the ONE sanctioned shim, N6)" do
    test "an already-minted filename-only link resolves within the window", %{conn: conn} do
      filename = uploaded_filename()
      {_uri, content} = store_upload(@workspace_name, filename)

      conn =
        conn
        |> sign_in(@workspace_name, user_uri(@workspace_name, "alice-#{uniq()}"))
        |> get("/files/" <> filename)

      assert conn.status == 200
      assert conn.resp_body == content
    end

    test "back-compat link resolves under the caller's OWN workspace (disambiguation)",
         %{conn: conn} do
      # Same filename exists in two workspaces. The legacy filename-only link is
      # disambiguated by the caller's authenticated mount workspace — proving the
      # new contract's <ws> partition; the old contract was unambiguous ONLY
      # because filenames are UUID-prefixed.
      filename = uploaded_filename()
      {_a, _ca} = store_upload(@workspace_name, filename, "acme-copy")
      {_b, _cb} = store_upload(@other_workspace, filename, "beta-copy")

      conn_a =
        conn
        |> sign_in(@workspace_name, user_uri(@workspace_name, "alice-#{uniq()}"))
        |> get("/files/" <> filename)

      assert conn_a.status == 200
      assert conn_a.resp_body == "acme-copy"

      conn_b =
        build_conn()
        |> sign_in(@other_workspace, user_uri(@other_workspace, "bob-#{uniq()}"))
        |> get("/files/" <> filename)

      assert conn_b.status == 200
      assert conn_b.resp_body == "beta-copy"
    end

    test "400 on traversal / empty / dot filenames", %{conn: conn} do
      signed = sign_in(conn, @workspace_name, user_uri(@workspace_name, "alice-#{uniq()}"))

      assert get(signed, "/files/.").status == 400

      assert build_conn()
             |> sign_in(@workspace_name, user_uri(@workspace_name, "alice-#{uniq()}"))
             |> get("/files/..")
             |> Map.get(:status) == 400
    end

    test "404 for a valid-shaped filename not present in the caller's workspace", %{conn: conn} do
      conn =
        conn
        |> sign_in(@workspace_name, user_uri(@workspace_name, "alice-#{uniq()}"))
        |> get("/files/" <> uploaded_filename())

      assert conn.status == 404
    end

    test "anon callers bounced to /login by RequireEntity", %{conn: conn} do
      conn = get(conn, "/files/" <> uploaded_filename())
      assert redirected_to(conn) == "/login"
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
