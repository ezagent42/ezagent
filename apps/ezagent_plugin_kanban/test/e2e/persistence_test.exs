defmodule EzagentPluginKanban.PersistenceTest do
  @moduledoc """
  增量 2 验收：Kanban Kind 的节点树跨进程重启**durable 存活**。
  spawn → 建节点 → 杀进程 → 重 spawn 同 URI → 树仍在（从 KindSnapshot rehydrate）。
  """
  use ExUnit.Case, async: false

  alias Ezagent.Invocation
  alias EzagentPluginKanban.Kanban

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    uri =
      Ezagent.URI.resource("system", "kanban", "persist-#{System.unique_integer([:positive])}")

    %{uri: uri}
  end

  test "节点树跨重启存活（snapshot rehydrate）", %{uri: uri} do
    {:ok, pid1} = Ezagent.Kind.Server.start_link({Kanban, %{uri: uri}})
    :ok = wait_until_ready(uri)

    assert {:ok, %{id: "n1"}} = dispatch(uri, "add_node", %{parent_id: "", title: "根"})
    assert {:ok, %{id: "n2"}} = dispatch(uri, "add_node", %{parent_id: "n1", title: "子"})
    assert {:ok, %{tree: %{nodes: before}}} = dispatch(uri, "get_tree", %{})
    assert map_size(before) == 2

    # 杀掉进程（模拟重启 / 冷启动）
    ref = Process.monitor(pid1)
    :ok = GenServer.stop(pid1)
    assert_receive {:DOWN, ^ref, :process, ^pid1, _}, 2000

    # 重 spawn 同 URI → 应从 snapshot 恢复
    {:ok, _pid2} = Ezagent.Kind.Server.start_link({Kanban, %{uri: uri}})
    :ok = wait_until_ready(uri)

    assert {:ok, %{tree: %{nodes: after_restart}}} = dispatch(uri, "get_tree", %{})
    assert map_size(after_restart) == 2
    assert after_restart["n1"].title == "根"
    assert after_restart["n2"].parent_id == "n1"
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
