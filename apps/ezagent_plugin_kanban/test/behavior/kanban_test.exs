defmodule Ezagent.ActionSet.KanbanTest do
  @moduledoc """
  Kanban Behavior handler 单元测试（直接调 handler，桩 ctx）。
  增量3：节点扩字段 + 认领/状态/挂载/指标 + per-node 授权 + 不变式。
  """
  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.Kanban
  alias EzagentPluginKanban.Application, as: KanbanApp

  @admin_cap Ezagent.Capability.admin_genesis_cap()

  # 棒链来自 recipe config 数据（layer-2）——测试经此数据路径注入 ctx，不再依赖
  # Behavior 内硬编码的 @stages（taxonomy §4.1 de-bake）。@stages / @ci_stage /
  # @import_default_stage 直接读 kanban_manager_recipe() 的 config，单一真相源。
  @recipe_config KanbanApp.kanban_manager_recipe()[:config]
  @stages @recipe_config[:stages]
  @first_stage List.first(@stages)
  @second_stage Enum.at(@stages, 1)
  @third_stage Enum.at(@stages, 2)

  defp rd(tree), do: fn k, d -> Map.get(%{tree: tree}, k, d) end
  defp admin_ctx(tree), do: Map.merge(@recipe_config, %{read: rd(tree), caps: MapSet.new([@admin_cap]), caller: nil})

  defp user_ctx(tree, user),
    do:
      Map.merge(@recipe_config, %{
        read: rd(tree),
        caps: MapSet.new(),
        caller: Ezagent.URI.new!(user)
      })

  defp committed(effects),
    do:
      Enum.find_value(effects, fn
        {:set, :tree, t} -> t
        _ -> nil
      end)

  # 建一棵 admin 起的小树，返回 {tree, ids}
  defp seed do
    t0 = %{nodes: %{}, root_id: nil, seq: 0}
    {:ok, %{id: r}, e1} = Kanban.handle_add_node(%{parent_id: "", title: "根"}, admin_ctx(t0))
    t1 = committed(e1)
    {:ok, %{id: c}, e2} = Kanban.handle_add_node(%{parent_id: r, title: "功能点"}, admin_ctx(t1))
    {committed(e2), r, c}
  end

  test "create 初始空树" do
    assert {:ok, %{tree: %{nodes: %{}, root_id: nil, seq: 0}}} = Kanban.create(%{})
  end

  describe "add_node（默认字段 + 授权）" do
    test "admin 建根：默认 stage=链首 / owner=nil / status=:unassigned / 空挂载" do
      assert {:ok, %{id: "n1"}, e} =
               Kanban.handle_add_node(
                 %{parent_id: "", title: "根"},
                 admin_ctx(%{nodes: %{}, root_id: nil, seq: 0})
               )

      n = committed(e).nodes["n1"]
      assert n.stage == @first_stage and n.owner == nil and n.status == :unassigned
      assert n.artifacts == [] and n.metrics == []
    end

    test "非 admin 不能建根" do
      assert {:error, :forbidden} =
               Kanban.handle_add_node(
                 %{parent_id: "", title: "根"},
                 user_ctx(%{nodes: %{}, root_id: nil, seq: 0}, "entity://system/user/bob")
               )
    end

    test "加子继承父 stage；非父owner非admin 不能加子" do
      {t, r, _c} = seed()

      assert {:ok, %{id: _}, e} =
               Kanban.handle_add_node(%{parent_id: r, title: "x"}, admin_ctx(t))

      assert committed(e).nodes |> Map.values() |> Enum.all?(&(&1.stage == @first_stage))

      assert {:error, :forbidden} =
               Kanban.handle_add_node(
                 %{parent_id: r, title: "x"},
                 user_ctx(t, "entity://system/user/bob")
               )
    end
  end

  describe "认领 / 状态 + 不变式" do
    test "claim 未分配 → owner=caller, status=:claimed" do
      {t, _r, c} = seed()

      assert {:ok, %{}, e} =
               Kanban.handle_claim_node(%{id: c}, user_ctx(t, "entity://system/user/alice"))

      n = committed(e).nodes[c]
      assert n.owner == "entity://system/user/alice" and n.status == :claimed
    end

    test "claim 已认领 → already_claimed" do
      {t, _r, c} = seed()

      {:ok, %{}, e} =
        Kanban.handle_claim_node(%{id: c}, user_ctx(t, "entity://system/user/alice"))

      assert {:error, :already_claimed} =
               Kanban.handle_claim_node(
                 %{id: c},
                 user_ctx(committed(e), "entity://system/user/bob")
               )
    end

    test "owner 可 set_status；非 owner 非 admin 被拒（per-node 授权）" do
      {t, _r, c} = seed()

      {:ok, %{}, e} =
        Kanban.handle_claim_node(%{id: c}, user_ctx(t, "entity://system/user/alice"))

      t2 = committed(e)

      assert {:ok, %{}, e2} =
               Kanban.handle_set_status(
                 %{id: c, status: "doing"},
                 user_ctx(t2, "entity://system/user/alice")
               )

      assert committed(e2).nodes[c].status == :doing

      assert {:error, :forbidden} =
               Kanban.handle_set_status(
                 %{id: c, status: "done"},
                 user_ctx(t2, "entity://system/user/bob")
               )
    end

    test "未认领不能 set_status（不变式 owner==nil ⟺ unassigned）" do
      {t, _r, c} = seed()
      # admin 改未认领节点状态 → 触不变式
      assert {:error, :must_claim_first} =
               Kanban.handle_set_status(%{id: c, status: "doing"}, admin_ctx(t))
    end

    test "非法 status 值被拒" do
      {t, _r, c} = seed()

      {:ok, %{}, e} =
        Kanban.handle_claim_node(%{id: c}, user_ctx(t, "entity://system/user/alice"))

      assert {:error, {:invalid_status, "wat"}} =
               Kanban.handle_set_status(
                 %{id: c, status: "wat"},
                 user_ctx(committed(e), "entity://system/user/alice")
               )
    end
  end

  describe "挂载 artifacts / metrics（owner 权限）" do
    setup do
      {t, _r, c} = seed()

      {:ok, %{}, e} =
        Kanban.handle_claim_node(%{id: c}, user_ctx(t, "entity://system/user/alice"))

      %{tree: committed(e), c: c}
    end

    test "attach + detach artifact", %{tree: t, c: c} do
      art = %{"tool" => "github", "kind" => "pr", "ref" => "#123", "url" => "http://x/123"}

      assert {:ok, %{}, e} =
               Kanban.handle_attach_artifact(
                 %{id: c, artifact: art},
                 user_ctx(t, "entity://system/user/alice")
               )

      [a] = committed(e).nodes[c].artifacts
      assert a.tool == "github" and a.ref == "#123"

      assert {:ok, %{}, e2} =
               Kanban.handle_detach_artifact(
                 %{id: c, ref: "#123"},
                 user_ctx(committed(e), "entity://system/user/alice")
               )

      assert committed(e2).nodes[c].artifacts == []
    end

    test "set_metric upsert by name", %{tree: t, c: c} do
      m = %{"name" => "周闭环数", "target" => 2, "current" => nil, "unit" => "个/周"}

      assert {:ok, %{}, e} =
               Kanban.handle_set_metric(
                 %{id: c, metric: m},
                 user_ctx(t, "entity://system/user/alice")
               )

      [met] = committed(e).nodes[c].metrics
      assert met.name == "周闭环数" and met.target == 2
      # upsert 同名
      m2 = %{"name" => "周闭环数", "target" => 3, "current" => 1, "unit" => "个/周"}

      {:ok, %{}, e2} =
        Kanban.handle_set_metric(
          %{id: c, metric: m2},
          user_ctx(committed(e), "entity://system/user/alice")
        )

      assert [%{target: 3, current: 1}] = committed(e2).nodes[c].metrics
    end

    test "非 owner 不能挂载", %{tree: t, c: c} do
      assert {:error, :forbidden} =
               Kanban.handle_attach_artifact(
                 %{id: c, artifact: %{"ref" => "x"}},
                 user_ctx(t, "entity://system/user/bob")
               )
    end
  end

  describe "set_stage / import 授权" do
    test "set_stage 改阶段（owner/admin）", %{} do
      {t, _r, c} = seed()
      # c 父=root(链首)，只能链首或第二棒(父+1)
      assert {:ok, %{}, e} =
               Kanban.handle_set_stage(%{id: c, stage: to_string(@second_stage)}, admin_ctx(t))
      assert committed(e).nodes[c].stage == @second_stage

      assert {:error, {:invalid_stage, "nope"}} =
               Kanban.handle_set_stage(%{id: c, stage: "nope"}, admin_ctx(t))
    end

    test "set_stage R1.1：stage 沿固定链推进（只父棒或父棒+1，根随子推进，不能跳棒）", %{} do
      {t, r, c} = seed()

      # 根（G4 拍板后无父约束、只受子约束）：子 c 还在链首 → 根设第二棒被子侧拒
      assert {:error, {:stage_order_violation, _}} =
               Kanban.handle_set_stage(%{id: r, stage: to_string(@second_stage)}, admin_ctx(t))

      # 子 c（父=链首=0）：设第二棒(1=父+1) → OK
      assert {:ok, %{}, e1} =
               Kanban.handle_set_stage(%{id: c, stage: to_string(@second_stage)}, admin_ctx(t))
      assert committed(e1).nodes[c].stage == @second_stage

      # G4 开口：子到位（第二棒）后，根可推进到第二棒（不再钉死链首）
      assert {:ok, %{}, er} =
               Kanban.handle_set_stage(
                 %{id: r, stage: to_string(@second_stage)},
                 admin_ctx(committed(e1))
               )

      assert committed(er).nodes[r].stage == @second_stage

      # 子 c：设第三棒(2=父+2) → 拒（跳棒）
      assert {:error, {:stage_order_violation, _}} =
               Kanban.handle_set_stage(%{id: c, stage: to_string(@third_stage)}, admin_ctx(t))

      # 子 c：设末棒 → 拒（跳棒）
      assert {:error, {:stage_order_violation, _}} =
               Kanban.handle_set_stage(%{id: c, stage: to_string(List.last(@stages))}, admin_ctx(t))
    end

    test "drop_subtree：砍子树 + 记进图级别 drop 历史(:drops, 不挂某节点)", %{} do
      {t, _r, c} = seed()
      {:ok, _, e1} = Kanban.handle_set_stage(%{id: c, stage: to_string(@second_stage)}, admin_ctx(t))
      t1 = committed(e1)
      {:ok, %{id: gc}, e2} = Kanban.handle_add_node(%{parent_id: c, title: "痛点X"}, admin_ctx(t1))
      t2 = committed(e2)
      {:ok, _, e3} = Kanban.handle_set_stage(%{id: gc, stage: to_string(@third_stage)}, admin_ctx(t2))
      t3 = committed(e3)
      {:ok, %{id: ggc}, e4} = Kanban.handle_add_node(%{parent_id: gc, title: "方案A"}, admin_ctx(t3))
      t4 = committed(e4)

      # drop 方案A 子树
      assert {:ok, %{dropped: 1}, e5} =
               Kanban.handle_drop_subtree(%{id: ggc, reason: "7天阅读<500"}, admin_ctx(t4))

      t5 = committed(e5)
      refute Map.has_key?(t5.nodes, ggc), "子树应被砍掉"
      # drop 历史进**图级别** tree.drops（经唯一 commit/1，不挂某个节点、不另开 set-effect 站点）
      assert [%{title: "方案A", reason: "7天阅读<500", count: 1}] = t5.drops
      # 痛点节点上**不再**挂 drop_record（历史是全图属性）
      refute Enum.any?(t5.nodes[gc].artifacts, &(&1.kind == "drop_record"))

      # 非 owner 非 admin → forbidden
      assert {:error, :forbidden} =
               Kanban.handle_drop_subtree(%{id: gc, reason: "x"}, user_ctx(t4, "entity://system/user/bob"))
    end

    test "import_markmap 仅 admin", %{} do
      assert {:error, :forbidden} =
               Kanban.handle_import_markmap(
                 %{markdown: "# 根\n"},
                 user_ctx(%{nodes: %{}, root_id: nil, seq: 0}, "entity://system/user/bob")
               )

      assert {:ok, %{count: 1}, e} =
               Kanban.handle_import_markmap(
                 %{markdown: "# 根\n"},
                 admin_ctx(%{nodes: %{}, root_id: nil, seq: 0})
               )

      # 导入的节点补了默认字段
      assert committed(e).nodes["n1"].status == :unassigned
    end
  end
end
