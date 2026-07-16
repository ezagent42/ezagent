defmodule Ezagent.ActionSet.KanbanTest do
  @moduledoc """
  Kanban Behavior handler 单元测试（直接调 handler，桩 ctx）。

  协作模型（`docs/notes/2026-07-15-kanban-collab-model.md`，带认领的 excalidraw 式）：
    - H1 加任何节点（根/子）= 创建者自动认领（owner=caller, status=:claimed）；任何持
      板 operate cap 的成员都能加（dispatch 层 gate，handler 内不再门控加节点）。
    - H5 单根先行：空板第一个节点=根；已有根再传 parent_id="" → :root_exists。
    - H3 取消认领需空：有 artifacts/metrics 的节点不能 unclaim（子节点不算内容，C3）。
    - H2 删除=drop 子树：版主/wildcard 兜底可删任何；否则子树内每个节点须
      owner==caller 或未认领，含他人已认领后代 → :forbidden_mixed_ownership。
    - C2 版主=本板 admin：全局 wildcard 或 caller==本板 data_owner，可编辑本板任何节点。
  **不变式**：`owner==nil ⟺ status==:unassigned`。
  """
  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.Kanban
  alias EzagentPluginKanban.Application, as: KanbanApp

  @alice "entity://system/user/alice"
  @bob "entity://system/user/bob"

  # 棒链来自 recipe config 数据（layer-2）——测试经此数据路径注入 ctx，不再依赖
  # Behavior 内硬编码的 @stages（taxonomy §4.1 de-bake）。@stages / @ci_stage /
  # @import_default_stage 直接读 kanban_manager_recipe() 的 config，单一真相源。
  @recipe_config KanbanApp.kanban_manager_recipe()[:config]
  @stages @recipe_config[:stages]
  @first_stage List.first(@stages)
  @second_stage Enum.at(@stages, 1)
  @third_stage Enum.at(@stages, 2)

  defp rd(tree), do: fn k, d -> Map.get(%{tree: tree}, k, d) end

  # canonical admin ctx（#1457 后 admin?=caller==canonical admin root），带 caller
  # （加节点自动认领需 caller）。
  defp admin_ctx(tree),
    do:
      Map.merge(@recipe_config, %{
        read: rd(tree),
        caps: MapSet.new(),
        caller: Ezagent.Entity.User.admin_uri()
      })

  # 无 cap 普通成员（handler 内不门控加节点；cap gate 在 dispatch 层，单测绕过）。
  defp user_ctx(tree, user),
    do:
      Map.merge(@recipe_config, %{
        read: rd(tree),
        caps: MapSet.new(),
        caller: Ezagent.URI.new!(user)
      })

  # 版主 ctx：非 canonical admin，但 caller == 本板 data_owner（经 :data_owner 直注，测试夹具）。
  defp moderator_ctx(tree, owner),
    do:
      Map.merge(@recipe_config, %{
        read: rd(tree),
        caps: MapSet.new(),
        caller: Ezagent.URI.new!(owner),
        data_owner: Ezagent.URI.new!(owner)
      })

  # 无 caller 的 ctx（触发 :no_caller）。
  defp no_caller_ctx(tree),
    do: Map.merge(@recipe_config, %{read: rd(tree), caps: MapSet.new()})

  defp committed(effects),
    do:
      Enum.find_value(effects, fn
        {:set, :tree, t} -> t
        _ -> nil
      end)

  defp empty, do: %{nodes: %{}, root_id: nil, seq: 0}

  # 由 `ctx`（已内嵌当前树）加一个节点，返回 {tree, id}。首参保留当前树仅为调用处可读。
  defp add!(_tree, parent_id, title, ctx) do
    assert {:ok, %{id: id}, e} =
             Kanban.handle_add_node(%{parent_id: parent_id, title: title}, ctx)

    {committed(e), id}
  end

  # admin 起一棵根+子（都自动认领给 admin），返回 {tree, root_id, child_id}。
  defp seed do
    {t1, r} = add!(empty(), "", "根", admin_ctx(empty()))
    {t2, c} = add!(t1, r, "功能点", admin_ctx(t1))
    {t2, r, c}
  end

  test "create 初始空树" do
    assert {:ok, %{tree: %{nodes: %{}, root_id: nil, seq: 0}}} = Kanban.create(%{})
  end

  describe "add_node（H1 自动认领 + 任何人可加）" do
    test "加根自动认领：owner=caller / status=:claimed / stage=链首 / 空挂载" do
      assert {:ok, %{id: "n1"}, e} =
               Kanban.handle_add_node(%{parent_id: "", title: "根"}, user_ctx(empty(), @alice))

      n = committed(e).nodes["n1"]
      assert n.owner == @alice and n.status == :claimed
      assert n.stage == @first_stage
      assert n.artifacts == [] and n.metrics == []
    end

    test "任何成员（无 cap）都能加根（handler 不门控，cap gate 在 dispatch 层）" do
      assert {:ok, %{id: "n1"}, e} =
               Kanban.handle_add_node(%{parent_id: "", title: "根"}, user_ctx(empty(), @bob))

      assert committed(e).nodes["n1"].owner == @bob
    end

    test "H5 单根：已有根再传 parent_id=\"\" → :root_exists" do
      {t, _r, _c} = seed()

      assert {:error, :root_exists} =
               Kanban.handle_add_node(%{parent_id: "", title: "第二个根"}, user_ctx(t, @alice))
    end

    test "任何成员可在他人节点下加子（各自认领，子树可混主）" do
      {t, r, _c} = seed()
      # 根由 admin 认领；bob 仍能在其下加子并认领这个子。
      assert {:ok, %{id: id}, e} =
               Kanban.handle_add_node(%{parent_id: r, title: "bob的子"}, user_ctx(t, @bob))

      assert committed(e).nodes[id].owner == @bob and committed(e).nodes[id].status == :claimed
    end

    test "加子继承父 stage" do
      {t, r, _c} = seed()
      {t2, id} = add!(t, r, "x", user_ctx(t, @alice))
      assert t2.nodes[id].stage == @first_stage
    end

    test "父不存在 → :parent_not_found" do
      {t, _r, _c} = seed()

      assert {:error, :parent_not_found} =
               Kanban.handle_add_node(%{parent_id: "nope", title: "x"}, user_ctx(t, @alice))
    end

    test "无 caller → :no_caller（自动认领需 caller）" do
      assert {:error, :no_caller} =
               Kanban.handle_add_node(%{parent_id: "", title: "根"}, no_caller_ctx(empty()))
    end
  end

  describe "认领 / 状态 + 不变式" do
    # 认领只作用于未认领节点；自动认领后，未认领只由 unclaim 产生。
    defp unassigned_child do
      {t, _r, c} = seed()
      {:ok, %{}, e} = Kanban.handle_unclaim_node(%{id: c}, admin_ctx(t))
      {committed(e), c}
    end

    test "claim 未认领 → owner=caller, status=:claimed" do
      {t, c} = unassigned_child()

      assert {:ok, %{}, e} = Kanban.handle_claim_node(%{id: c}, user_ctx(t, @alice))
      n = committed(e).nodes[c]
      assert n.owner == @alice and n.status == :claimed
    end

    test "claim 已认领 → already_claimed" do
      {t, _r, c} = seed()
      # seed 的 c 已被 admin 自动认领。
      assert {:error, :already_claimed} =
               Kanban.handle_claim_node(%{id: c}, user_ctx(t, @bob))
    end

    test "owner 可 set_status；非 owner 非 board_admin 被拒（per-node 授权）" do
      {t, c} = unassigned_child()
      {:ok, %{}, e} = Kanban.handle_claim_node(%{id: c}, user_ctx(t, @alice))
      t2 = committed(e)

      assert {:ok, %{}, e2} =
               Kanban.handle_set_status(%{id: c, status: "doing"}, user_ctx(t2, @alice))

      assert committed(e2).nodes[c].status == :doing

      assert {:error, :forbidden} =
               Kanban.handle_set_status(%{id: c, status: "done"}, user_ctx(t2, @bob))
    end

    test "未认领不能 set_status（不变式 owner==nil ⟺ unassigned）" do
      {t, c} = unassigned_child()

      assert {:error, :must_claim_first} =
               Kanban.handle_set_status(%{id: c, status: "doing"}, admin_ctx(t))
    end

    test "非法 status 值被拒" do
      {t, _r, c} = seed()

      assert {:error, {:invalid_status, "wat"}} =
               Kanban.handle_set_status(%{id: c, status: "wat"}, admin_ctx(t))
    end
  end

  describe "unclaim（H3 取消认领需空 + C3 子不算内容）" do
    test "空节点 owner 可取消认领 → owner=nil, status=:unassigned" do
      {t, _r, c} = seed()

      assert {:ok, %{}, e} = Kanban.handle_unclaim_node(%{id: c}, admin_ctx(t))
      n = committed(e).nodes[c]
      assert n.owner == nil and n.status == :unassigned
    end

    test "有 artifacts 的节点不能取消认领 → :has_content_cannot_unclaim" do
      {t, _r, c} = seed()

      {:ok, %{}, e} =
        Kanban.handle_attach_artifact(%{id: c, artifact: %{"ref" => "x"}}, admin_ctx(t))

      assert {:error, :has_content_cannot_unclaim} =
               Kanban.handle_unclaim_node(%{id: c}, admin_ctx(committed(e)))
    end

    test "有 metrics 的节点不能取消认领" do
      {t, _r, c} = seed()

      {:ok, %{}, e} =
        Kanban.handle_set_metric(%{id: c, metric: %{"name" => "m", "target" => 1}}, admin_ctx(t))

      assert {:error, :has_content_cannot_unclaim} =
               Kanban.handle_unclaim_node(%{id: c}, admin_ctx(committed(e)))
    end

    test "有子节点但无内容仍可取消认领（C3：子不算内容）" do
      {t, _r, c} = seed()
      # 在 c 下加子（结构容器，c 自身无 artifacts/metrics）。
      {t2, _gc} = add!(t, c, "子", admin_ctx(t))

      assert {:ok, %{}, e} = Kanban.handle_unclaim_node(%{id: c}, admin_ctx(t2))
      assert committed(e).nodes[c].owner == nil
    end

    test "非 owner 非 board_admin 不能取消认领 → :forbidden" do
      {t, _r, c} = seed()

      assert {:error, :forbidden} =
               Kanban.handle_unclaim_node(%{id: c}, user_ctx(t, @bob))
    end

    test "版主（board_admin）可取消认领他人的空节点" do
      # alice 建板（版主）+ 加根；bob 在根下加子并认领。
      {t, r} = add!(empty(), "", "根", user_ctx(empty(), @alice))
      {t2, gc} = add!(t, r, "bob子", user_ctx(t, @bob))

      assert {:ok, %{}, e} = Kanban.handle_unclaim_node(%{id: gc}, moderator_ctx(t2, @alice))
      assert committed(e).nodes[gc].owner == nil
    end
  end

  describe "挂载 artifacts / metrics（owner 权限）" do
    setup do
      {t, _r, c} = seed()
      # seed 的 c 由 admin 认领；改由 alice 持有：admin 退领 → alice 认领。
      {:ok, %{}, e0} = Kanban.handle_unclaim_node(%{id: c}, admin_ctx(t))
      {:ok, %{}, e1} = Kanban.handle_claim_node(%{id: c}, user_ctx(committed(e0), @alice))
      %{tree: committed(e1), c: c}
    end

    test "attach + detach artifact", %{tree: t, c: c} do
      art = %{"tool" => "github", "kind" => "pr", "ref" => "#123", "url" => "http://x/123"}

      assert {:ok, %{}, e} =
               Kanban.handle_attach_artifact(%{id: c, artifact: art}, user_ctx(t, @alice))

      [a] = committed(e).nodes[c].artifacts
      assert a.tool == "github" and a.ref == "#123"

      assert {:ok, %{}, e2} =
               Kanban.handle_detach_artifact(
                 %{id: c, ref: "#123"},
                 user_ctx(committed(e), @alice)
               )

      assert committed(e2).nodes[c].artifacts == []
    end

    test "set_metric upsert by name", %{tree: t, c: c} do
      m = %{"name" => "周闭环数", "target" => 2, "current" => nil, "unit" => "个/周"}

      assert {:ok, %{}, e} =
               Kanban.handle_set_metric(%{id: c, metric: m}, user_ctx(t, @alice))

      [met] = committed(e).nodes[c].metrics
      assert met.name == "周闭环数" and met.target == 2

      m2 = %{"name" => "周闭环数", "target" => 3, "current" => 1, "unit" => "个/周"}

      {:ok, %{}, e2} =
        Kanban.handle_set_metric(%{id: c, metric: m2}, user_ctx(committed(e), @alice))

      assert [%{target: 3, current: 1}] = committed(e2).nodes[c].metrics
    end

    test "非 owner 不能挂载", %{tree: t, c: c} do
      assert {:error, :forbidden} =
               Kanban.handle_attach_artifact(
                 %{id: c, artifact: %{"ref" => "x"}},
                 user_ctx(t, @bob)
               )
    end
  end

  describe "版主（board_admin）编辑他人节点（C2）" do
    test "版主可 rename 他人认领的节点" do
      # alice 建板（版主）；bob 在根下加子并认领。
      {t, r} = add!(empty(), "", "根", user_ctx(empty(), @alice))
      {t2, gc} = add!(t, r, "bob子", user_ctx(t, @bob))

      assert {:ok, %{}, e} =
               Kanban.handle_rename_node(%{id: gc, title: "版主改名"}, moderator_ctx(t2, @alice))

      assert committed(e).nodes[gc].title == "版主改名"
    end

    test "非版主非 owner 不能编辑他人节点 → :forbidden" do
      {t, r} = add!(empty(), "", "根", user_ctx(empty(), @alice))
      {t2, gc} = add!(t, r, "bob子", user_ctx(t, @bob))

      assert {:error, :forbidden} =
               Kanban.handle_rename_node(%{id: gc, title: "x"}, user_ctx(t2, @alice))
    end
  end

  describe "set_stage 授权 + R1.1 固定链推进" do
    test "set_stage 改阶段（owner/board_admin）" do
      {t, _r, c} = seed()

      assert {:ok, %{}, e} =
               Kanban.handle_set_stage(%{id: c, stage: to_string(@second_stage)}, admin_ctx(t))

      assert committed(e).nodes[c].stage == @second_stage

      assert {:error, {:invalid_stage, "nope"}} =
               Kanban.handle_set_stage(%{id: c, stage: "nope"}, admin_ctx(t))
    end

    test "R1.1：stage 沿固定链推进（只父棒或父棒+1，根随子推进，不能跳棒）" do
      {t, r, c} = seed()

      assert {:error, {:stage_order_violation, _}} =
               Kanban.handle_set_stage(%{id: r, stage: to_string(@second_stage)}, admin_ctx(t))

      assert {:ok, %{}, e1} =
               Kanban.handle_set_stage(%{id: c, stage: to_string(@second_stage)}, admin_ctx(t))

      assert committed(e1).nodes[c].stage == @second_stage

      assert {:ok, %{}, er} =
               Kanban.handle_set_stage(
                 %{id: r, stage: to_string(@second_stage)},
                 admin_ctx(committed(e1))
               )

      assert committed(er).nodes[r].stage == @second_stage

      assert {:error, {:stage_order_violation, _}} =
               Kanban.handle_set_stage(%{id: c, stage: to_string(@third_stage)}, admin_ctx(t))

      assert {:error, {:stage_order_violation, _}} =
               Kanban.handle_set_stage(
                 %{id: c, stage: to_string(List.last(@stages))},
                 admin_ctx(t)
               )
    end
  end

  describe "drop_subtree（H2 归属守卫）" do
    test "owner drop 自己整子树（都自己认领）+ 记进图级别 drops" do
      # alice 建根+子（都 alice 自动认领）。
      {t, r} = add!(empty(), "", "根", user_ctx(empty(), @alice))
      {t2, c} = add!(t, r, "子", user_ctx(t, @alice))

      assert {:ok, %{dropped: 2}, e} =
               Kanban.handle_drop_subtree(%{id: r, reason: "撤"}, user_ctx(t2, @alice))

      t3 = committed(e)
      refute Map.has_key?(t3.nodes, r)
      refute Map.has_key?(t3.nodes, c)
      assert [%{title: "根", reason: "撤", count: 2}] = t3.drops
    end

    test "子树含他人已认领后代 → :forbidden_mixed_ownership" do
      {t, r} = add!(empty(), "", "根", user_ctx(empty(), @alice))
      {t2, _gc} = add!(t, r, "bob子", user_ctx(t, @bob))

      assert {:error, :forbidden_mixed_ownership} =
               Kanban.handle_drop_subtree(%{id: r, reason: "x"}, user_ctx(t2, @alice))
    end

    test "含未认领后代不挡（未认领谁都可删，只要其余是自己的）" do
      {t, r} = add!(empty(), "", "根", user_ctx(empty(), @alice))
      {t2, gc} = add!(t, r, "结构子", user_ctx(t, @alice))
      # gc 退领（空）→ 未认领后代。
      {:ok, %{}, e0} = Kanban.handle_unclaim_node(%{id: gc}, user_ctx(t2, @alice))

      assert {:ok, %{dropped: 2}, _e} =
               Kanban.handle_drop_subtree(%{id: r, reason: "x"}, user_ctx(committed(e0), @alice))
    end

    test "版主 / wildcard 兜底可删他人任何子树" do
      {t, r} = add!(empty(), "", "根", user_ctx(empty(), @alice))
      {t2, _gc} = add!(t, r, "bob子", user_ctx(t, @bob))

      # 版主（alice=data_owner）兜底。
      assert {:ok, %{dropped: 2}, _e} =
               Kanban.handle_drop_subtree(%{id: r, reason: "版主删"}, moderator_ctx(t2, @alice))

      # wildcard admin 兜底。
      assert {:ok, %{dropped: 2}, _e2} =
               Kanban.handle_drop_subtree(%{id: r, reason: "admin删"}, admin_ctx(t2))
    end
  end

  describe "import_markmap 授权（board_admin）" do
    test "非版主非 wildcard 拒" do
      assert {:error, :forbidden} =
               Kanban.handle_import_markmap(%{markdown: "# 根\n"}, user_ctx(empty(), @bob))
    end

    test "wildcard admin 可导入；节点补默认字段（未认领）" do
      assert {:ok, %{count: 1}, e} =
               Kanban.handle_import_markmap(%{markdown: "# 根\n"}, admin_ctx(empty()))

      n = committed(e).nodes["n1"]
      assert n.status == :unassigned and n.owner == nil
    end

    test "版主（board data_owner）可导入" do
      assert {:ok, %{count: 1}, _e} =
               Kanban.handle_import_markmap(%{markdown: "# 根\n"}, moderator_ctx(empty(), @alice))
    end
  end
end
