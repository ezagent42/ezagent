defmodule EzagentPluginKanban.CapbacE2ETest do
  @moduledoc """
  增量3 DoD：per-node 授权经**真实 dispatch** 生效——非 owner 非 admin（但持 kanban
  实例 cap）改一个别人认领的节点 → 被 CapBAC 拒；owner 本人改 → 通过。
  """
  use ExUnit.Case, async: false

  alias Ezagent.Invocation
  alias EzagentPluginKanban.Kanban

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    uri = Ezagent.URI.resource("system", "kanban", "capbac-#{System.unique_integer([:positive])}")
    {:ok, _} = Ezagent.Kind.Server.start_link({Kanban, %{uri: uri}})
    :ok = wait_ready(uri)
    %{uri: uri}
  end

  test "非 owner 非 admin 被拒；owner 可改", %{uri: uri} do
    admin =
      {Ezagent.URI.new!("entity://system/user/admin"),
       MapSet.new([Ezagent.Capability.admin_genesis_cap()])}

    # 非通配的 kanban 实例 cap（kind=:kanban, action=:any）：能动 kanban、但不是 admin。
    mm = Ezagent.Capability.cap(:kanban, Ezagent.Behavior.Kanban, :any)
    alice = {Ezagent.URI.new!("entity://system/user/alice"), MapSet.new([mm])}
    bob = {Ezagent.URI.new!("entity://system/user/bob"), MapSet.new([mm])}

    assert {:ok, %{id: "n1"}} = dispatch(uri, "add_node", %{parent_id: "", title: "根"}, admin)
    assert {:ok, %{id: "n2"}} = dispatch(uri, "add_node", %{parent_id: "n1", title: "功能点"}, admin)

    # alice 认领 n2（dispatch 授权过：她持 kanban cap；handler：未分配可领）
    assert {:ok, %{}} = dispatch(uri, "claim_node", %{id: "n2"}, alice)

    # bob 持 kanban cap（实例级授权过）但非 owner 非 admin → handler 的 per-node 拒
    assert {:error, :forbidden} = dispatch(uri, "set_status", %{id: "n2", status: "doing"}, bob)

    # alice（owner）改 → 通过
    assert {:ok, %{}} = dispatch(uri, "set_status", %{id: "n2", status: "doing"}, alice)

    assert {:ok, %{}} =
             dispatch(
               uri,
               "attach_artifact",
               %{
                 id: "n2",
                 artifact: %{
                   "tool" => "github",
                   "kind" => "pr",
                   "ref" => "#1",
                   "url" => "http://x"
                 }
               },
               alice
             )

    assert {:ok, %{tree: %{nodes: nodes}}} = dispatch(uri, "get_tree", %{}, admin)
    n = nodes["n2"]
    assert n.owner == "entity://system/user/alice" and n.status == :doing
    assert [%{ref: "#1"}] = n.artifacts
  end

  defp dispatch(uri, action, args, {caller, caps}) do
    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=kanban.#{action}")

    Invocation.dispatch(%Invocation{
      target: target,
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
