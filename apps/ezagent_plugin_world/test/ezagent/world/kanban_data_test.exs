defmodule Ezagent.World.KanbanDataTest do
  @moduledoc "验 world kanban 面的读路径：read_tree 产出 JSON-safe 富节点树 + list_instances。"
  use ExUnit.Case, async: false

  alias Ezagent.World.KanbanData

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    uri = Ezagent.URI.resource("system", "kanban", "wd-#{System.unique_integer([:positive])}")
    {:ok, _} = Ezagent.Kind.Server.start_link({EzagentPluginKanban.Kanban, %{uri: uri}})
    :ok = wait_ready(uri)

    caller = Ezagent.URI.user(:system, :admin)
    caps = MapSet.new([Ezagent.Capability.admin_genesis_cap()])
    ctx = %{caller_uri: caller, caller_caps: caps}

    d = fn action, args -> disp(uri, action, args, caller, caps) end
    {:ok, %{id: "n1"}} = d.(:add_node, %{parent_id: "", title: "根"})
    {:ok, %{id: "n2"}} = d.(:add_node, %{parent_id: "n1", title: "功能"})
    {:ok, %{}} = d.(:set_stage, %{id: "n2", stage: "metric"})
    {:ok, %{}} = d.(:claim_node, %{id: "n2"})
    {:ok, %{}} = d.(:set_status, %{id: "n2", status: "doing"})

    %{uri: uri, ctx: ctx}
  end

  test "read_tree 返 JSON-safe 富树（stage/status 是 string、owner 带上、列表字段在）", %{uri: uri, ctx: ctx} do
    tree = KanbanData.read_tree(uri, ctx)
    assert tree["root_id"] == "n1"

    n2 = tree["nodes"]["n2"]
    assert n2["title"] == "功能"
    assert n2["stage"] == "metric", "atom 应转 string"
    assert n2["status"] == "doing"
    assert n2["owner"] == "entity://system/user/admin"
    assert is_list(n2["artifacts"]) and is_list(n2["metrics"])
  end

  test "list_instances 含刚 spawn 的实例", %{uri: uri} do
    uris = KanbanData.list_instances() |> Enum.map(& &1["uri"])
    assert URI.to_string(uri) in uris
  end

  test "state_for 列表页（entity_uri=nil）给 stages/statuses/instances", %{ctx: ctx} do
    state = KanbanData.state_for(%{component: "kanban", entity_uri: nil}, ctx)
    assert state["kanban_uri"] == nil
    assert "feature" in state["stages"] and "doing" in state["statuses"]
    assert is_list(state["instances"])
  end

  defp disp(uri, action, args, caller, caps) do
    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: Ezagent.URI.with_action(uri, :kanban, action),
      mode: :call,
      args: args,
      ctx: %{caller: caller, caps: caps, reply: {:caller_inbox, self()}}
    })
  end

  defp wait_ready(uri) do
    case Ezagent.ReadyGate.status(uri) do
      :ready ->
        :ok

      _ ->
        Process.sleep(5)
        wait_ready(uri)
    end
  end
end
