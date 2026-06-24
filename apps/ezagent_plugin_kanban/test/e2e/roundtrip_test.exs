defmodule EzagentPluginKanban.RoundtripTest do
  @moduledoc """
  增量 1 e2e 验收 gate：真实 spawn 一个 Kanban Kind 实例 → 经
  `Ezagent.Invocation.dispatch/1`（P14）建节点 → 导出 markmap 文件 → 模拟人改文件
  → 导入回来 → 读树反映改动。证明思维导图与文件**双向打通**、ezagent 是真相源。
  """
  use ExUnit.Case, async: false

  alias Ezagent.Invocation
  alias EzagentPluginKanban.Kanban

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    uri =
      Ezagent.URI.resource("system", "kanban", "e2e-#{System.unique_integer([:positive])}")

    {:ok, _pid} = Ezagent.Kind.Server.start_link({Kanban, %{uri: uri}})
    :ok = wait_until_ready(uri)

    %{uri: uri}
  end

  test "双向往返：建节点 → 导出 → 改文件 → 导入 → 树反映改动", %{uri: uri} do
    # ezagent 侧建树
    assert {:ok, %{id: "n1"}} = dispatch(uri, "add_node", %{parent_id: "", title: "根"})
    assert {:ok, %{id: "n2"}} = dispatch(uri, "add_node", %{parent_id: "n1", title: "子1"})
    assert {:ok, %{id: "n3"}} = dispatch(uri, "add_node", %{parent_id: "n1", title: "子2"})

    # 导出到文件
    assert {:ok, %{markdown: md}} = dispatch(uri, "export_markmap", %{})
    assert md == "# 根\n## 子1\n## 子2\n"

    file = Path.join(System.tmp_dir!(), "mm_e2e_#{System.unique_integer([:positive])}.md")
    File.write!(file, md)

    # 模拟人在 XMind/markmap 改：加一个新节点，存盘覆盖
    edited = File.read!(file) <> "## 子3\n"
    File.write!(file, edited)

    # 从（改过的）文件导入回 ezagent（文件覆盖）
    assert {:ok, %{count: 4}} = dispatch(uri, "import_markmap", %{markdown: File.read!(file)})

    # ezagent 树反映了人的改动
    assert {:ok, %{tree: %{nodes: nodes}}} = dispatch(uri, "get_tree", %{})
    titles = nodes |> Map.values() |> Enum.map(& &1.title)
    assert "子3" in titles
    assert map_size(nodes) == 4

    File.rm(file)
  end

  defp dispatch(uri, action, args) do
    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=kanban.#{action}")

    Invocation.dispatch(%Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: Ezagent.URI.new!("entity://system/user/admin"),
        caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp wait_until_ready(uri) do
    case Ezagent.ReadyGate.status(uri) do
      :ready ->
        :ok

      _ ->
        Process.sleep(5)
        wait_until_ready(uri)
    end
  end
end
