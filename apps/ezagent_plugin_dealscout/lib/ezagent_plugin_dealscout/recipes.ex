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
  """

  # caps 只在这里（recipe 的 requested_caps 是 caps 的唯一来源）。cap-template
  # 形状 `%{behavior: <ActionSet>, action: <atom>}`，照 orchestrator_recipe。
  @send_cap %{behavior: Ezagent.ActionSet.Session, action: :send}
  @crawl_cap %{behavior: Ezagent.ActionSet.DealScoutCrawl, action: :crawl_now}

  @doc "发现腿 4 个 recipe 的声明数据（`roles/0` 的 seed 源）。"
  @spec all() :: [map()]
  def all, do: [discover(), search(), organize(), followup()]

  # ① 主动发现 —— 按 profile 千人千面挑高分机会。
  defp discover do
    %{
      name: "dealscout-discover",
      behaviors: [],
      prompt:
        "你是 DealScout 的发现副驾。读用户 profile + 新抓回的线索条目，按千人千面匹配" <>
          "挑出高分机会，主动推进发现流；每条机会保留来源类型（public / directed）标注。",
      requested_caps: [@send_cap]
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
end
