defmodule EzagentPluginLoom.Integration.LiveStitchTest do
  @moduledoc """
  Stitch(preview 辅助 AI):非-live 验 HTTP 鉴；live 验真实 LLM 答 + drive。
  需 `ANTHROPIC_*` 跑 live。
  """
  use EzagentCore.DataCase, async: false
  use Plug.Test

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.Socialware.CustomerAuth
  alias EzagentPluginLoom.{Stitch, Template.LoomSession, WebPlug}

  @opts WebPlug.init([])

  setup do
    ws = "loom-st-#{System.unique_integer([:positive])}"
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

  test "POST stitch rejects a bad token", ctx do
    conn =
      conn(:post, "/c/#{ctx.ws}/#{ctx.sid}/stitch", Jason.encode!(%{text: "这页讲什么", token: "bogus"}))
      |> put_req_header("content-type", "application/json")
      |> WebPlug.call(@opts)

    assert conn.status == 401
  end

  @tag :live
  test "Stitch.reply answers in chinese with optional drive" do
    assert {:ok, %{reply: reply, drive: drive}} =
             Stitch.reply("这个页面有什么产品？", page: "一个卖手冲咖啡的落地页，含产品列表和下单按钮")

    assert is_binary(reply) and reply != ""
    assert is_nil(drive) or (is_map(drive) and is_binary(drive["op"]))
  end

  @tag :live
  test "POST stitch returns a reply end-to-end", ctx do
    conn =
      conn(:post, "/c/#{ctx.ws}/#{ctx.sid}/stitch", Jason.encode!(%{text: "帮我看看这页", token: ctx.token, page: "咖啡落地页"}))
      |> put_req_header("content-type", "application/json")
      |> WebPlug.call(@opts)

    assert conn.status == 200
    assert %{"ok" => true, "reply" => reply} = Jason.decode!(conn.resp_body)
    assert is_binary(reply) and reply != ""
  end

  test "POST aispot rejects a bad token", ctx do
    conn =
      conn(:post, "/c/#{ctx.ws}/#{ctx.sid}/aispot", Jason.encode!(%{topic: "手冲咖啡", token: "bogus"}))
      |> put_req_header("content-type", "application/json")
      |> WebPlug.call(@opts)

    assert conn.status == 401
  end

  @tag :live
  test "AiSpot generates a card with title + body" do
    assert {:ok, %{title: title, body: body}} = Stitch.aispot("手冲咖啡的风味特点")
    assert is_binary(title) and title != ""
    assert is_binary(body) and body != ""
  end

  @tag :live
  test "POST aispot returns a card end-to-end", ctx do
    conn =
      conn(:post, "/c/#{ctx.ws}/#{ctx.sid}/aispot", Jason.encode!(%{topic: "意式浓缩", token: ctx.token}))
      |> put_req_header("content-type", "application/json")
      |> WebPlug.call(@opts)

    assert conn.status == 200
    assert %{"ok" => true, "card" => %{"title" => _, "body" => _}} = Jason.decode!(conn.resp_body)
  end
end
