defmodule EzagentPluginLoom.Integration.DashboardUiTest do
  @moduledoc "Dashboard operator UI:数据端点(summary JSON)+ UI 壳服务(浏览器验证待 agent-browser)。"
  use EzagentCore.DataCase, async: false
  use Plug.Test

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.Socialware.CustomerAuth
  alias EzagentPluginLoom.{DashboardSPA, Template.LoomSession, WebPlug}

  @opts WebPlug.init([])

  setup do
    ws = "loom-dui-#{System.unique_integer([:positive])}"
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

  test "dashboard data endpoint returns summary", ctx do
    conn = conn(:get, "/c/#{ctx.ws}/#{ctx.sid}/dashboard?token=#{ctx.token}") |> WebPlug.call(@opts)

    assert conn.status == 200
    assert %{"ok" => true, "summary" => %{"tokens" => _, "calls" => _, "materials" => _, "knowledge_bytes" => _}} =
             Jason.decode!(conn.resp_body)
  end

  test "dashboard data endpoint rejects bad token", ctx do
    conn = conn(:get, "/c/#{ctx.ws}/#{ctx.sid}/dashboard?token=bogus") |> WebPlug.call(@opts)
    assert conn.status == 401
  end

  test "dashboard UI shell is served", ctx do
    conn = conn(:get, "/dashboard/#{ctx.ws}/#{ctx.sid}?token=#{ctx.token}") |> WebPlug.call(@opts)

    assert conn.status == 200
    assert conn.resp_body =~ "Loom 运营看板"
    assert conn.resp_body =~ "/dashboard?token="
  end

  test "dashboard shell is self-contained" do
    refute DashboardSPA.html() =~ ~r/<script\s+src=/
  end
end
