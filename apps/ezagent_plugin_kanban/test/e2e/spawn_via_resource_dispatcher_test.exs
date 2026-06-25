defmodule EzagentPluginKanban.SpawnViaResourceDispatcherTest do
  @moduledoc """
  df-tech (kanban-clean / Plan B) 验收：kanban Kind 经 **`resource` scheme
  spawn dispatcher** 起活——而非旧的 plugin-owned `SpawnRegistry.register`
  boot hook（被 invariant 8 / check 7 禁）。

  本测试复刻 `EzagentDomainWorkspace.Application` 注册的 `resource` 派发器
  逻辑（按 `Ezagent.URI.type/1` 查 `Ezagent.ResourceKindRegistry` → 起活 Kind）。
  workspace domain 不在 kanban 的 per-app test 依赖里（kanban 只 dep core），
  故此处显式注册同构闭包；真正的端到端（真 boot 两域同载）由 umbrella
  `mix test` + `ezagent_web` 覆盖。

  断言链：ResourceKindRegistry 登记 `kanban → Kanban` → `SpawnRegistry.spawn`
  按 `resource://<ws>/kanban/<name>` 起活 → add_node / per-node CapBAC / drop 正常。
  """
  use ExUnit.Case, async: false

  alias Ezagent.{Invocation, ResourceKindRegistry, SpawnRegistry}
  alias EzagentPluginKanban.Kanban

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    # plugin 声明 → registry（boot/1 在真节点上做的那一步）。幂等。
    :ok = ResourceKindRegistry.register("kanban", Kanban)

    # 复刻 EzagentDomainWorkspace.Application.register_resource_spawn_fn/0 的
    # 同构闭包——按 type 段查 ResourceKindRegistry 起活。
    :ok =
      SpawnRegistry.register("resource", fn %URI{} = uri ->
        case Ezagent.URI.type(uri) do
          {:ok, type} ->
            case ResourceKindRegistry.lookup(type) do
              {:ok, kind_module} -> Ezagent.Kind.spawn(kind_module, %{uri: uri})
              :error -> {:error, {:no_resource_kind, type}}
            end

          :error ->
            {:error, {:resource_uri_has_no_type, URI.to_string(uri)}}
        end
      end)

    uri =
      Ezagent.URI.resource("system", "kanban", "rdisp-#{System.unique_integer([:positive])}")

    :ok
    %{uri: uri}
  end

  test "经 resource dispatcher 起活 kanban，并跑 add_node / CapBAC / drop", %{uri: uri} do
    # —— 关键断言：经 SpawnRegistry（resource scheme）起活，非直引 Kind 模块 ——
    assert {:ok, pid} = SpawnRegistry.spawn(uri)
    assert is_pid(pid)
    assert {:ok, ^pid} = Ezagent.KindRegistry.lookup(uri)
    :ok = wait_ready(uri)

    admin =
      {Ezagent.URI.new!("entity://system/user/admin"),
       MapSet.new([Ezagent.Capability.admin_genesis_cap()])}

    # 非通配 kanban 实例 cap：能动 kanban、但非 admin。
    mm = Ezagent.Capability.cap(:kanban, Ezagent.Behavior.Kanban, :any)
    alice = {Ezagent.URI.new!("entity://system/user/alice"), MapSet.new([mm])}
    bob = {Ezagent.URI.new!("entity://system/user/bob"), MapSet.new([mm])}

    # add_node
    assert {:ok, %{id: "n1"}} = dispatch(uri, "add_node", %{parent_id: "", title: "根"}, admin)
    assert {:ok, %{id: "n2"}} = dispatch(uri, "add_node", %{parent_id: "n1", title: "功能点"}, admin)

    # per-node CapBAC：alice 认领 n2 → owner；bob 持 cap 但非 owner → handler 拒；alice 改 → 过。
    assert {:ok, %{}} = dispatch(uri, "claim_node", %{id: "n2"}, alice)
    assert {:error, :forbidden} = dispatch(uri, "set_status", %{id: "n2", status: "doing"}, bob)
    assert {:ok, %{}} = dispatch(uri, "set_status", %{id: "n2", status: "doing"}, alice)

    # drop：alice（owner）砍掉 n2 子树 → 通过；树只剩 n1。
    assert {:ok, %{}} = dispatch(uri, "drop_subtree", %{id: "n2", reason: "指标不达"}, alice)
    assert {:ok, %{tree: %{nodes: nodes}}} = dispatch(uri, "get_tree", %{}, admin)
    assert Map.has_key?(nodes, "n1")
    refute Map.has_key?(nodes, "n2")
  end

  test "无对应 type 段 → dispatcher reject（不误起活）" do
    # 没注册的 resource type → :no_resource_kind，spawn 失败（不静默起空 Kind）。
    other =
      Ezagent.URI.resource("system", "no-such-type", "x-#{System.unique_integer([:positive])}")

    assert {:error, {:no_resource_kind, "no-such-type"}} = SpawnRegistry.spawn(other)
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
