defmodule EzagentPluginLoom.Integration.PublishTest do
  @moduledoc "发布/分享:冻结当前 page_update 页 → token + 链接 → /snapshot/:token 只读 → /p/:token/open 建新 session。"
  use EzagentCore.DataCase, async: false
  use Plug.Test

  alias Ezagent.{Invocation, Workspace}
  alias Ezagent.Entity.User
  alias EzagentPluginLoom.{Template.LoomSession, WebPlug}

  @opts WebPlug.init([])

  setup do
    ws = "loom-pub-#{System.unique_integer([:positive])}"
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

    %{ws: ws, sid: sid, session_uri: session_uri}
  end

  test "fresh session 的 seed starter 页即可发布(publish ok)", ctx do
    # instantiate 会 seed 一张 starter page_update span → 立即可发布(不再 no_page_yet)。
    assert eventually(fn ->
             resp =
               conn(:post, "/api/#{ctx.ws}/#{ctx.sid}/publish", "{}")
               |> put_req_header("content-type", "application/json")
               |> WebPlug.call(@opts)

             match?(%{"ok" => true}, Jason.decode!(resp.resp_body))
           end)
  end

  test "有页 → publish 出 token+link → /snapshot 只读 → /p/:token/open 建新 session", ctx do
    # 注入一条 page_update span 消息(模拟 v0 产出),current_page 据此冻结。
    page = %{
      "files" => %{"/App.jsx" => "export default function App(){return <div>hi</div>}"},
      "summary" => "首页"
    }

    seed_page_update(ctx.session_uri, page)

    pub =
      conn(:post, "/api/#{ctx.ws}/#{ctx.sid}/publish", "{}")
      |> put_req_header("content-type", "application/json")
      |> WebPlug.call(@opts)
      |> then(&Jason.decode!(&1.resp_body))

    assert %{"ok" => true, "token" => token, "link" => "/loom/p/" <> _} = pub
    assert is_binary(token)

    # /snapshot/:token 只读返回冻结页。
    snap =
      conn(:get, "/snapshot/#{token}")
      |> WebPlug.call(@opts)
      |> then(&Jason.decode!(&1.resp_body))

    assert %{"ok" => true, "page" => %{"files" => %{"/App.jsx" => _}}} = snap

    # published 列表含本 session。
    listed =
      conn(:get, "/api/#{ctx.ws}/#{ctx.sid}/published")
      |> WebPlug.call(@opts)
      |> then(&Jason.decode!(&1.resp_body))

    assert %{"ok" => true, "items" => [%{"token" => ^token} | _]} = listed

    # /p/:token/open 从快照建新 session。
    opened =
      conn(:post, "/p/#{token}/open", "{}")
      |> put_req_header("content-type", "application/json")
      |> WebPlug.call(@opts)
      |> then(&Jason.decode!(&1.resp_body))

    assert %{"ok" => true, "ws" => opened_ws, "sid" => "pub_" <> _} = opened
    assert opened_ws == ctx.ws
  end

  test "/snapshot 未知 token → unknown(合法 JSON)" do
    resp = conn(:get, "/snapshot/nope") |> WebPlug.call(@opts) |> then(& &1)
    assert %{"ok" => false, "error" => "unknown token"} = Jason.decode!(resp.resp_body)
  end

  defp seed_page_update(session_uri, page) do
    %URI{host: ws, path: "/loom/" <> sid} = session_uri
    sender = Ezagent.URI.agent(ws, "loomv0_#{sid}")
    span = ~s(<span type="page_update">#{Jason.encode!(page)}</span>)
    msg = Ezagent.Message.new(sender, %{text: span})

    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.send"),
      mode: :call,
      args: %{message: msg},
      ctx: %{
        caller: sender,
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    })

    eventually(fn ->
      Enum.any?(Ezagent.MessageStore.recent_in_session(session_uri, 50), &(&1.id == msg.id))
    end)
  end

  defp eventually(f, n \\ 100)
  defp eventually(_f, 0), do: false

  defp eventually(f, n),
    do:
      if(f.(),
        do: true,
        else:
          (
            Process.sleep(20)
            eventually(f, n - 1)
          )
      )
end
