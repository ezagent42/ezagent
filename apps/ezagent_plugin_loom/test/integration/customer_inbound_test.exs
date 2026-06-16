defmodule EzagentPluginLoom.Integration.CustomerInboundTest do
  @moduledoc """
  Customer 入站 transport adapter(WebPlug)的 HTTP 层验证(非 live):token 鉴权 +
  发消息进 session + feed 读。完整「customer HTTP → 编排 → feed 出 page」走 live_*。
  """
  use EzagentCore.DataCase, async: false
  use Plug.Test

  alias Ezagent.{Workspace, MessageStore}
  alias Ezagent.Entity.User
  alias Ezagent.Socialware.CustomerAuth
  alias EzagentPluginLoom.{Template.LoomSession, WebPlug}

  @opts WebPlug.init([])

  setup do
    ws = "loom-in-#{System.unique_integer([:positive])}"
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

    %{ws: ws, sid: sid, session_uri: session_uri, token: CustomerAuth.issue_token(session_uri, workspace_uri)}
  end

  test "POST messages rejects a bad token", ctx do
    conn =
      conn(:post, "/c/#{ctx.ws}/#{ctx.sid}/messages", Jason.encode!(%{text: "hi", token: "bogus"}))
      |> put_req_header("content-type", "application/json")
      |> WebPlug.call(@opts)

    assert conn.status == 401
    assert %{"ok" => false} = Jason.decode!(conn.resp_body)
  end

  test "POST messages with a valid token writes a customer message into the session", ctx do
    conn =
      conn(:post, "/c/#{ctx.ws}/#{ctx.sid}/messages", Jason.encode!(%{text: "卖咖啡落地页", token: ctx.token}))
      |> put_req_header("content-type", "application/json")
      |> WebPlug.call(@opts)

    assert conn.status == 200
    assert %{"ok" => true, "id" => msg_id} = Jason.decode!(conn.resp_body)
    assert is_binary(msg_id)

    # 消息确实进了 session(异步 cast,稍等)
    assert eventually(fn ->
             ctx.session_uri
             |> MessageStore.recent_in_session(20)
             |> Enum.any?(fn m -> (m.body["text"] || m.body[:text]) == "卖咖啡落地页" end)
           end)
  end

  test "GET feed rejects a bad token", ctx do
    conn =
      conn(:get, "/c/#{ctx.ws}/#{ctx.sid}/feed?token=bogus")
      |> WebPlug.call(@opts)

    assert conn.status == 401
  end

  test "GET feed with a valid token returns the visibility-gated snapshot", ctx do
    conn =
      conn(:get, "/c/#{ctx.ws}/#{ctx.sid}/feed?token=#{ctx.token}")
      |> WebPlug.call(@opts)

    assert conn.status == 200
    # 无 settled turn → customer 看不到任何东西(operator gate)
    assert %{"ok" => true, "messages" => [], "page" => nil} = Jason.decode!(conn.resp_body)
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
