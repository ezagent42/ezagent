defmodule EzagentPluginLoom.Integration.KnowledgeTest do
  @moduledoc "知识库:HTTP 读写 + fork 复制。grounding 注入由 stitch/aispot live 覆盖。"
  use EzagentCore.DataCase, async: false
  use Plug.Test

  alias Ezagent.{Invocation, Workspace}
  alias Ezagent.Entity.User
  alias Ezagent.Socialware.CustomerAuth
  alias EzagentPluginLoom.{Fork, Knowledge, Template.LoomSession, WebPlug}

  @opts WebPlug.init([])

  setup do
    ws = "loom-kb-#{System.unique_integer([:positive])}"
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

  test "write then read knowledge over HTTP", ctx do
    w =
      conn(:post, "/c/#{ctx.ws}/#{ctx.sid}/knowledge", Jason.encode!(%{markdown: "# 咖啡\n手冲水温 90-94℃", token: ctx.token}))
      |> put_req_header("content-type", "application/json")
      |> WebPlug.call(@opts)

    assert w.status == 200

    r =
      conn(:get, "/c/#{ctx.ws}/#{ctx.sid}/knowledge?token=#{ctx.token}")
      |> WebPlug.call(@opts)

    assert %{"ok" => true, "knowledge" => "# 咖啡\n手冲水温 90-94℃"} = Jason.decode!(r.resp_body)
  end

  test "knowledge read rejects bad token", ctx do
    conn = conn(:get, "/c/#{ctx.ws}/#{ctx.sid}/knowledge?token=bogus") |> WebPlug.call(@opts)
    assert conn.status == 401
  end

  test "fork copies knowledge to the new session", ctx do
    :ok = Knowledge.put(ctx.session_uri, "源知识库内容")

    # 源需有 approved page 才能 fork
    seed_page(ctx.session_uri)

    assert {:ok, new_uri} = Fork.fork(ctx.session_uri, "kbfork-#{System.unique_integer([:positive])}", URI.to_string(User.admin_uri()))
    assert Knowledge.get(new_uri) == "源知识库内容"
  end

  defp seed_page(session_uri) do
    {:ok, %{turn_id: tid}} = dispatch(session_uri, "turn.open", %{trigger: %{message_id: "s"}, opened_at: 1})

    {:ok, _} =
      dispatch(session_uri, "turn.compose", %{
        turn_id: tid,
        result_refs: [%{kind: :page, tree: %{"type" => "text", "props" => %{}, "children" => []}}]
      })

    {:ok, _} = dispatch(session_uri, "turn.settle", %{turn_id: tid})

    eventually(fn ->
      match?({:ok, %{approved: a}} when not is_nil(a), Ezagent.Kind.get_slice(session_uri, :surface))
    end)
  end

  defp eventually(fun, n \\ 100)
  defp eventually(_f, 0), do: false
  defp eventually(f, n), do: if(f.(), do: true, else: (Process.sleep(20); eventually(f, n - 1)))

  defp dispatch(session_uri, action, args) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{action}"),
      mode: :call,
      args: args,
      ctx: %{caller: User.admin_uri(), caps: Ezagent.SystemPrincipal.caps("system://bootstrap"), reply: {:caller_inbox, self()}}
    })
  end
end
