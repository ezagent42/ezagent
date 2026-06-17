defmodule EzagentPluginLoom.Integration.MetaAgentTest do
  @moduledoc "团队管家:WorkerConfig roster + MetaAgent 解释(live)。"
  use EzagentCore.DataCase, async: false
  use Plug.Test

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.Socialware.CustomerAuth
  alias EzagentPluginLoom.{MetaAgent, Template.LoomSession, WebPlug, WorkerConfig}

  @opts WebPlug.init([])

  setup do
    ws = "loom-meta-#{System.unique_integer([:positive])}"
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

  test "WorkerConfig add/remove/list", ctx do
    WorkerConfig.add(ctx.session_uri, %{"key" => "painter", "desc" => "配图", "prompt" => "你负责配图"})
    WorkerConfig.add(ctx.session_uri, %{"key" => "lawyer", "desc" => "法务", "prompt" => "你负责法务"})
    assert length(WorkerConfig.list(ctx.session_uri)) == 2

    # 同 key 覆盖
    WorkerConfig.add(ctx.session_uri, %{"key" => "painter", "desc" => "视觉", "prompt" => "x"})
    assert length(WorkerConfig.list(ctx.session_uri)) == 2

    WorkerConfig.remove(ctx.session_uri, "lawyer")
    assert [%{"key" => "painter"}] = WorkerConfig.list(ctx.session_uri)
  end

  test "GET team lists roster", ctx do
    WorkerConfig.add(ctx.session_uri, %{"key" => "w1", "desc" => "通用", "prompt" => ""})

    conn = conn(:get, "/c/#{ctx.ws}/#{ctx.sid}/team?token=#{ctx.token}") |> WebPlug.call(@opts)
    assert %{"ok" => true, "workers" => [%{"key" => "w1"}]} = Jason.decode!(conn.resp_body)
  end

  test "POST team rejects bad token", ctx do
    conn =
      conn(:post, "/c/#{ctx.ws}/#{ctx.sid}/team", Jason.encode!(%{instruction: "加一个配图 worker", token: "bogus"}))
      |> put_req_header("content-type", "application/json")
      |> WebPlug.call(@opts)

    assert conn.status == 401
  end

  @tag :live
  test "MetaAgent interprets an add instruction", ctx do
    assert {:ok, %{op: "add", workers: workers}} =
             MetaAgent.interpret(ctx.session_uri, "加一个负责视觉配图的 worker")

    assert is_list(workers) and workers != []
    assert Enum.any?(workers, &is_binary(&1["key"]))
  end
end
