defmodule EzagentPluginDealScout.Recipes do
  @moduledoc """
  DealScout 发现腿的 **recipe 集**（AI 千人千面发现流的 agent 配方）。

  每个 recipe 三要素照 `Ezagent.Orchestrator.OrchestratorRecipe.recipe/0`
  （`orchestrator_recipe.ex:64-79`）：`prompt`（persona）+ `requested_caps`
  （cap 只来自 recipe，Definition struct 无 caps 字段）+ `behaviors`。

  ## flavor 不在 recipe 上

  recipe 是 **flavor-agnostic** 的：`Ezagent.Agent.Recipe.new/1` 显式 **拒绝**
  任何 flavor 字段（`{:flavor_field_in_role, _}`，`recipe.ex:80-82,92,111`），而
  `roles/0` 的 recipe 在 boot 时经 `RecipeRegistry.seed_role_if_absent →
  validate_recipe → Recipe.new` 校验（`recipe_registry.ex:256-259,353-354`）—— 带
  flavor 会 boot fail-loud。**flavor 是 per-agent，落在 Definition 的角色槽**
  （`%{role_name, fill: :agent, recipe, flavor}`，#1180 role-slot）—— Definition
  seed 是后续 Stage 的活，本 Stage 只出 flavor-agnostic recipe。

  这些 recipe 经 `EzagentPluginDealScout.Application.roles/0` 声明进插件契约，
  boot 时按 `name` 注册进 `Ezagent.Agent.RecipeRegistry`。

  另有一个**显式临时 ALT** recipe（`page_refresh_alt/0`，非发现腿）：A①
  （#1201 ③，hello builder `from_user?` 门放行带标记信号）落地后随
  `Ezagent.ActionSet.DealScoutPageRefreshAlt` 一起整体删除。
  """

  # caps 只在这里（recipe 的 requested_caps 是 caps 的唯一来源）。cap-template
  # 形状 `%{behavior: <ActionSet>, action: <atom>}`，照 orchestrator_recipe。
  @send_cap %{behavior: Ezagent.ActionSet.Session, action: :send}
  @crawl_cap %{behavior: Ezagent.ActionSet.DealScoutCrawl, action: :crawl_now}
  @page_refresh_cap %{behavior: Ezagent.ActionSet.DealScoutPageRefreshAlt, action: :receive}

  @doc "全部 recipe 声明数据（`roles/0` 的 seed 源）：发现腿 4 个 + 临时 ALT 1 个。"
  @spec all() :: [map()]
  def all, do: [discover(), search(), organize(), followup(), page_refresh_alt()]

  # ① 主动发现 —— 按 profile 千人千面挑高分机会（驱动爬取的主体之一：持 crawl cap，
  # 可主动触发 :crawl_now；爬完注入新线索后 ActionSet 自动 emit 更新信号
  # `__dealscout_update__`，由 Definition routing_rules 转给 hello 的页面 agent 更新展示）。
  defp discover do
    %{
      name: "dealscout-discover",
      behaviors: [],
      prompt:
        "你是 DealScout 的发现副驾。读用户 profile + 新抓回的线索条目，按千人千面匹配" <>
          "挑出高分机会，主动推进发现流（可触发 crawl_now 主动爬取）；每条机会保留来源" <>
          "类型（public / directed）标注。",
      requested_caps: [@send_cap, @crawl_cap]
    }
  end

  # ② 主动搜索 —— 把 query 转成检索，注入发现流。
  defp search do
    %{
      name: "dealscout-search",
      behaviors: [],
      prompt: "你把用户的 query 转成对全网 / 指定源的检索，汇总候选，注入发现流并标记为搜索结果。",
      requested_caps: [@send_cap, @crawl_cap]
    }
  end

  # ③ 整理 —— 把杂乱发现流按来源类型组织成结构化清单。
  defp organize do
    %{
      name: "dealscout-organize",
      behaviors: [],
      prompt: "你把杂乱的发现流条目组织成结构化清单，按来源类型（public / directed）分组呈现。",
      requested_caps: [@send_cap]
    }
  end

  # ④ 深挖追问 —— 对单条机会多轮追问，产出可下载材料。
  defp followup do
    %{
      name: "dealscout-followup",
      behaviors: [],
      prompt: "你对单条机会做多轮深挖追问，逐步产出可下载的尽调材料。",
      requested_caps: [@send_cap]
    }
  end

  # ⑤ 【显式临时 ALT，非发现腿】page 槽的更新信号 receiver：收到带
  # `__dealscout_update__` 的消息 → 调 hello 公开生成入口重建页面
  # （`Ezagent.ActionSet.DealScoutPageRefreshAlt`）。code-driven（照
  # `hello.builder` recipe 的形状：无 prompt，behaviors 挂 ActionSet，
  # requested_caps 只有自己的 `:receive`）。**A①（#1201 ③）落地后随 ALT
  # ActionSet 一起整体删除，Demo 的 page 槽回切 `hello.builder`。**
  defp page_refresh_alt do
    %{
      name: "dealscout-page-alt",
      behaviors: [Ezagent.ActionSet.DealScoutPageRefreshAlt],
      requested_caps: [@page_refresh_cap]
    }
  end
end
