defmodule EzagentPluginCrawler.Recipes do
  @moduledoc """
  dealscout demo socialware 的 **recipe 集**（AI 千人千面发现流的 agent 配方）。

  ## 分层（2026-07-07 rename 拍板）

  这些 recipe 是 **dealscout 业务配置**（科技创业/新品动态线索的 persona
  prompt），不是通用能力——判据"换个 socialware 还能原样用吗"：prompt 全是
  dealscout 业务措辞，不能。persona 措辞与真实数据源一致（D4 数据源诚实化，
  2026-07-10 段2）：当前唯一真源是 Hacker News 公开检索 API，prompt 不冒充
  商业/投融资数据。
  所以 recipe **名字保留 dealscout-*** 前缀，随 demo socialware 一起 ship 在
  本（通用 crawler）plugin 里；真正的通用件是 recipe 挂的能力面——
  `Ezagent.ActionSet.Crawler` 的 crawl/search cap。

  每个 recipe 三要素照 `Ezagent.Orchestrator.OrchestratorRecipe.recipe/0`
  （`orchestrator_recipe.ex:64-79`）：`prompt`（persona）+ `requested_caps`
  （cap 只来自 recipe，Definition struct 无 caps 字段）+ `behaviors`。
  例外是 `discover/0`——它是 **script-carrying recipe**（np 先例，RF-5b
  role-script 通道：`Recipe.script` → sandbox_content → config_dir
  `agent.py`），无 prompt/caps，见其注释。

  ## flavor 不在 recipe 上

  recipe 是 **flavor-agnostic** 的：`Ezagent.Agent.Recipe.new/1` 显式 **拒绝**
  任何 flavor 字段（`{:flavor_field_in_role, _}`，`recipe.ex:80-82,92,111`），而
  `roles/0` 的 recipe 在 boot 时经 `RecipeRegistry.seed_role_if_absent →
  validate_recipe → Recipe.new` 校验（`recipe_registry.ex:256-259,353-354`）—— 带
  flavor 会 boot fail-loud。**flavor 是 per-agent，落在 Definition 的角色槽**
  （`%{role_name, fill: :agent, recipe, flavor}`，#1180 role-slot）—— Definition
  seed 是后续 Stage 的活，本 Stage 只出 flavor-agnostic recipe。

  这些 recipe 经 `EzagentPluginCrawler.Application.roles/0` 声明进插件契约，
  boot 时按 `name` 注册进 `Ezagent.Agent.RecipeRegistry`。

  另有一个**显式临时 ALT** recipe（`page_refresh_alt/0`，非发现腿）：A①
  （#1201 ③，hello builder `from_user?` 门放行带标记信号）落地后随
  `Ezagent.ActionSet.DealScoutPageRefreshAlt` 一起整体删除。
  """

  # caps 只在这里（recipe 的 requested_caps 是 caps 的唯一来源）。cap-template
  # 形状 `%{behavior: <ActionSet>, action: <atom>}`，照 orchestrator_recipe。
  @send_cap %{behavior: Ezagent.ActionSet.Session, action: :send}
  @crawl_cap %{behavior: Ezagent.ActionSet.Crawler, action: :crawl_now}
  # v2 dispatch 式（ALT moduledoc）：ALT 的 action 从 `:receive` 改成
  # `:refresh_page`。dispatch 方要持这个 cap —— 触发爬取的 search recipe
  # 也 request 它（crawl handler 用触发者的 delegated caps dispatch）。
  # discover 不再 request（段3：py 车道不 dispatch，见 discover/0 注释）。
  @page_refresh_cap %{behavior: Ezagent.ActionSet.DealScoutPageRefreshAlt, action: :refresh_page}

  @doc "全部 recipe 声明数据（`roles/0` 的 seed 源）：发现腿 4 个 + 临时 ALT 1 个。"
  @spec all() :: [map()]
  def all, do: [discover(), search(), organize(), followup(), page_refresh_alt()]

  # ① 主动发现 —— **script-carrying recipe**（2026-07-10 段3，D1 落地形态）。
  #
  # discover 槽从 cc-headless 换到 py flavor（cc-headless 物化必崩的平台 gap
  # 绕开不修；py 是 hello builder/responser 已验证的物化车道）。py 车道的真实
  # 契约是单方法 `receive → {"text": ...} | None`（Domain.Python V1 刻意不支持
  # Python→BEAM 请求），所以 discover **不能**像 cc 大脑那样 dispatch
  # `crawler.crawl_now`——改为"回复中自带触发"形态：script 在自己的 sandbox 里
  # 真实爬 HN 公开检索源，把线索连同更新信号标记一起回进会话，manifest 的
  # and(text_contains, from_role discover) 规则命中这条回复 → 触发 page。
  # 详见 `priv/python/discover.py` 的 moduledoc。
  #
  # 无 requested_caps（np 先例）：py 的回复腿自带 inline `session.send`
  # self-cap（#154，`Ezagent.ActionSet.PyAgent.maybe_reply_effect`），script
  # 又不 dispatch 任何 action —— 空 recipe 铸 0 个 cap，fail-closed 且诚实
  # （持有永远用不上的 crawl cap 才是假配置）。
  defp discover do
    %{
      name: "dealscout-discover",
      script: discover_script()
    }
  end

  # 更新信号占位符：script 模板里的 `{{update_signal}}` 在 recipe 装配时替换为
  # emit 侧代码常量 `Crawler.update_signal/0`（其与 manifest YAML 权威字面量的
  # 一致性由 `dealscout_manifest_test.exs` 契约锁）——单一契约点，script 不
  # 硬编码第二份字面量。
  @update_signal_placeholder "{{update_signal}}"

  @doc "discover script 的占位符（测试断言替换发生用）。"
  @spec update_signal_placeholder() :: String.t()
  def update_signal_placeholder, do: @update_signal_placeholder

  defp discover_script do
    :ezagent_plugin_crawler
    |> :code.priv_dir()
    |> Path.join("python/discover.py")
    |> File.read!()
    |> String.replace(@update_signal_placeholder, Ezagent.ActionSet.Crawler.update_signal())
  end

  # ② 主动搜索 —— 把 query 转成检索，注入发现流。
  defp search do
    %{
      name: "dealscout-search",
      behaviors: [],
      prompt:
        "你把用户的 query 转成对公开科技社区（Hacker News 检索 API）/ 已配置定向源的" <>
          "检索，汇总候选，注入发现流并标记为搜索结果。",
      # 同 discover：search 完成后同样触发直接 dispatch 腿。
      requested_caps: [@send_cap, @crawl_cap, @page_refresh_cap]
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

  # ④ 深挖追问 —— 对单条线索多轮追问，产出可下载材料。
  defp followup do
    %{
      name: "dealscout-followup",
      behaviors: [],
      prompt: "你对单条线索做多轮深挖追问，逐步产出可下载的调研材料。",
      requested_caps: [@send_cap]
    }
  end

  # ⑤ 【显式临时 ALT，非发现腿】page 槽的 dispatchable 重建入口（v2
  # caller-dispatch 式，ALT moduledoc）：crawl 完成后直接 dispatch
  # `:refresh_page` 过来 → 调 hello 公开生成入口重建页面
  # （`Ezagent.ActionSet.DealScoutPageRefreshAlt`）。code-driven（照
  # `hello.builder` recipe 的形状：无 prompt，behaviors 挂 ActionSet ——
  # recipe-loaded behavior 进实例行为集，dispatch 按 action 解析直达）。
  # **A①（#1201 ③，hello 暴露 dispatchable rebuild action）落地后随 ALT
  # ActionSet 一起整体删除，manifest 的 page 槽回切 `hello.builder`。**
  defp page_refresh_alt do
    %{
      name: "dealscout-page-alt",
      behaviors: [Ezagent.ActionSet.DealScoutPageRefreshAlt],
      requested_caps: [@page_refresh_cap]
    }
  end
end
