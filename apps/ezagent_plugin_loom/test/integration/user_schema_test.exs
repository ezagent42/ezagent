defmodule EzagentPluginLoom.Integration.UserSchemaTest do
  @moduledoc "per-visitor 页面增强:加 op + feed 按 visitor 附 ops(前端叠加)。loom 内部,不改 surface。"
  use EzagentCore.DataCase, async: false
  use Plug.Test

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.Socialware.CustomerAuth
  alias EzagentPluginLoom.{Template.LoomSession, UserSchema, WebPlug}

  @opts WebPlug.init([])

  setup do
    ws = "loom-us-#{System.unique_integer([:positive])}"
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

    %{ws: ws, sid: sid, session_uri: session_uri, token: CustomerAuth.issue_token(session_uri, workspace_uri)}
  end

  test "per-visitor ops are isolated", ctx do
    UserSchema.add(ctx.session_uri, "v1", %{"op" => "highlight", "id" => "a"})
    UserSchema.add(ctx.session_uri, "v1", %{"op" => "filter", "tag" => "x"})
    UserSchema.add(ctx.session_uri, "v2", %{"op" => "highlight", "id" => "b"})

    assert length(UserSchema.ops(ctx.session_uri, "v1")) == 2
    assert length(UserSchema.ops(ctx.session_uri, "v2")) == 1
    assert UserSchema.ops(ctx.session_uri, "v3") == []
  end

  test "POST user-schema then GET feed returns that visitor's ops", ctx do
    add =
      conn(:post, "/c/#{ctx.ws}/#{ctx.sid}/user-schema", Jason.encode!(%{visitor: "v1", op: %{"op" => "reveal"}, token: ctx.token}))
      |> put_req_header("content-type", "application/json")
      |> WebPlug.call(@opts)

    assert add.status == 200

    feed =
      conn(:get, "/c/#{ctx.ws}/#{ctx.sid}/feed?token=#{ctx.token}&visitor=v1")
      |> WebPlug.call(@opts)

    assert %{"ok" => true, "user_schema_ops" => [%{"op" => "reveal"}]} = Jason.decode!(feed.resp_body)

    # 另一访客无此 op
    feed2 =
      conn(:get, "/c/#{ctx.ws}/#{ctx.sid}/feed?token=#{ctx.token}&visitor=other")
      |> WebPlug.call(@opts)

    assert %{"user_schema_ops" => []} = Jason.decode!(feed2.resp_body)
  end

  test "POST user-schema rejects bad token", ctx do
    conn =
      conn(:post, "/c/#{ctx.ws}/#{ctx.sid}/user-schema", Jason.encode!(%{visitor: "v1", op: %{}, token: "bogus"}))
      |> put_req_header("content-type", "application/json")
      |> WebPlug.call(@opts)

    assert conn.status == 401
  end
end
