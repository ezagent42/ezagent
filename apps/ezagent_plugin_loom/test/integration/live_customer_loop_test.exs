defmodule EzagentPluginLoom.Integration.LiveCustomerLoopTest do
  @moduledoc """
  LIVE: 完整 customer 闭环 —— customer HTTP 发消息 → auto-started 编排进程(真实 LLM
  多 agent)→ Turn → customer HTTP feed 出 page。全经 WebPlug(真实入站/读出路径),无人工。

  需 `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY`,默认排除(`:live`)。跑:
  `ANTHROPIC_BASE_URL=... ANTHROPIC_API_KEY=... mix test --include live \
     apps/ezagent_plugin_loom/test/integration/live_customer_loop_test.exs`
  """
  use EzagentCore.DataCase, async: false
  use Plug.Test
  @moduletag :live
  @moduletag timeout: 180_000

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.Socialware.CustomerAuth
  alias EzagentPluginLoom.{Template.LoomSession, WebPlug}

  @opts WebPlug.init([])
  @valid_node_types ~w(text services companies detail steps form choices notice application intent page)

  test "customer HTTP message auto-drives orchestration; HTTP feed serves the page" do
    ws = "loom-loop-#{System.unique_integer([:positive])}"
    sid = "main-#{System.unique_integer([:positive])}"
    workspace_uri = Ezagent.URI.workspace(ws)
    session_uri = Ezagent.URI.session(ws, :loom, sid)

    {:ok, _} = Workspace.create(ws, %{})

    {:ok, [^session_uri], _} =
      LoomSession.instantiate(
        "loom-main",
        %{
          "class" => "session.loom",
          "session_name" => sid,
          "operator_uri" => URI.to_string(User.admin_uri())
        },
        workspace_uri
      )

    token = CustomerAuth.issue_token(session_uri, workspace_uri)

    # customer 经 HTTP 发消息(真实入站路径)
    post =
      conn(:post, "/c/#{ws}/#{sid}/messages", Jason.encode!(%{text: "帮我做一个卖手冲咖啡的落地页，要有产品和下单", token: token}))
      |> put_req_header("content-type", "application/json")
      |> WebPlug.call(@opts)

    assert post.status == 200
    assert %{"ok" => true} = Jason.decode!(post.resp_body)

    # 等编排(真实 LLM)→ Turn settle → feed。轮询 HTTP feed。
    snapshot = poll_feed(ws, sid, token)

    assert %{"type" => root_type} = snapshot["page"]
    assert root_type in @valid_node_types
    assert snapshot["messages"] != []
  end

  defp poll_feed(ws, sid, token, attempts \\ 300)
  defp poll_feed(_ws, _sid, _token, 0), do: flunk("feed never served an orchestrated page")

  defp poll_feed(ws, sid, token, attempts) do
    conn =
      conn(:get, "/c/#{ws}/#{sid}/feed?token=#{token}")
      |> WebPlug.call(@opts)

    body = Jason.decode!(conn.resp_body)

    if conn.status == 200 and is_map(body["page"]) do
      body
    else
      Process.sleep(50)
      poll_feed(ws, sid, token, attempts - 1)
    end
  end
end
