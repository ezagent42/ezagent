defmodule EzagentPluginLoom.Integration.TeamTest do
  @moduledoc """
  loom session 创建即装配一队 agent Member(orchestrator/v0/worker/meta/stitch) +
  seed 一张初始页。Members 出现在 session `:members` slice(admin Members 面板数据源)。
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.User
  alias EzagentPluginLoom.Template.LoomSession

  setup do
    ws = "loom-team-#{System.unique_integer([:positive])}"
    sid = "main-#{System.unique_integer([:positive])}"
    {:ok, _} = Ezagent.Workspace.create(ws, %{})
    wsuri = Ezagent.URI.workspace(ws)

    {:ok, [suri], _} =
      LoomSession.instantiate(
        "loom-team",
        %{
          "class" => "session.loom",
          "session_name" => sid,
          "operator_uri" => URI.to_string(User.admin_uri())
        },
        wsuri
      )

    %{ws: ws, sid: sid, session_uri: suri, ws_uri: wsuri}
  end

  test "instantiate 装配整队 loom agent Member", ctx do
    {:ok, %{members: members}} = Ezagent.Kind.get_slice(ctx.session_uri, :session)
    names = members |> Map.keys() |> Enum.map(&URI.to_string/1)

    # 编排控制器 + v0 + meta + stitch 各一(URI 名前缀携带 role,同 loom-stitch)。
    assert Enum.any?(names, &String.contains?(&1, "/agent/loomorch_#{ctx.sid}"))
    assert Enum.any?(names, &String.contains?(&1, "/agent/loomv0_#{ctx.sid}"))
    assert Enum.any?(names, &String.contains?(&1, "/agent/loommeta_#{ctx.sid}"))
    assert Enum.any?(names, &String.contains?(&1, "/agent/loomstitch_#{ctx.sid}"))
    # 至少 2 个主题 worker(WorkerConfig 空 → 默认 general/details)。
    assert Enum.count(names, &String.contains?(&1, "/agent/loomworker_#{ctx.sid}_")) >= 2
    # operator 也是成员。
    assert Enum.any?(names, &String.contains?(&1, "/user/"))
  end

  test "seed 初始页 = page_update span(真实前端 Sandpack 打开即有 starter 页)", ctx do
    # seed 作 page_update span 消息发进 session;前端从 history/stream 读它 → Sandpack。
    assert eventually(fn ->
             ctx.session_uri
             |> Ezagent.MessageStore.recent_in_session(50)
             |> Enum.any?(fn m ->
               text = (m.body || %{})["text"] || (m.body || %{})[:text] || ""
               is_binary(text) and String.contains?(text, ~s(<span type="page_update">))
             end)
           end)
  end

  defp eventually(fun, attempts \\ 100)
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
