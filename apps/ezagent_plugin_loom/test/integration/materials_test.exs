defmodule EzagentPluginLoom.Integration.MaterialsTest do
  @moduledoc "素材库:上传(multipart)→ 列表 → 受控服务(download token)。"
  use EzagentCore.DataCase, async: false
  use Plug.Test

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.Socialware.CustomerAuth
  alias Ezagent.Uploads.DownloadToken
  alias EzagentPluginLoom.{Template.LoomSession, WebPlug}

  @opts WebPlug.init([])

  setup do
    ws = "loom-mat-#{System.unique_integer([:positive])}"
    sid = "main-#{System.unique_integer([:positive])}"
    workspace_uri = Ezagent.URI.workspace(ws)
    session_uri = Ezagent.URI.session(ws, :loom, sid)
    {:ok, _} = Workspace.create(ws, %{})

    {:ok, [^session_uri], _} =
      LoomSession.instantiate(
        "loom-main",
        %{"class" => "session.loom", "session_name" => sid, "operator_uri" => URI.to_string(User.admin_uri())},
        workspace_uri
      )

    %{ws: ws, sid: sid, token: CustomerAuth.issue_token(session_uri, workspace_uri)}
  end

  test "upload → list → controlled serve", ctx do
    tmp = Path.join(System.tmp_dir!(), "loom-mat-#{System.unique_integer([:positive])}.txt")
    File.write!(tmp, "hello material")
    upload = %Plug.Upload{path: tmp, filename: "note.txt", content_type: "text/plain"}

    up =
      conn(:post, "/c/#{ctx.ws}/#{ctx.sid}/materials/upload", %{"file" => upload, "token" => ctx.token})
      |> WebPlug.call(@opts)

    assert up.status == 200
    assert %{"ok" => true, "uri" => uri, "name" => "note.txt"} = Jason.decode!(up.resp_body)

    # 列表
    ls =
      conn(:get, "/c/#{ctx.ws}/#{ctx.sid}/materials?token=#{ctx.token}")
      |> WebPlug.call(@opts)

    assert %{"ok" => true, "materials" => [%{"name" => "note.txt", "uri" => ^uri}]} =
             Jason.decode!(ls.resp_body)

    # 受控服务(download token)
    dtoken = DownloadToken.mint!(Ezagent.URI.new!(uri))

    serve = conn(:get, "/m/#{dtoken}") |> WebPlug.call(@opts)
    assert serve.status == 200
    assert serve.resp_body == "hello material"
  end

  test "upload rejects bad token", ctx do
    tmp = Path.join(System.tmp_dir!(), "loom-mat-#{System.unique_integer([:positive])}.txt")
    File.write!(tmp, "x")
    upload = %Plug.Upload{path: tmp, filename: "x.txt", content_type: "text/plain"}

    conn =
      conn(:post, "/c/#{ctx.ws}/#{ctx.sid}/materials/upload", %{"file" => upload, "token" => "bogus"})
      |> WebPlug.call(@opts)

    assert conn.status == 401
  end
end
