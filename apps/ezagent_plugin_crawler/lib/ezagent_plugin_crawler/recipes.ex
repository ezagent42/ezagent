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

  另有一个**通用件** recipe（`crawler_page/0`，非发现腿、名字不带业务词）：
  page 槽的页面发布腿——把会话留存线索驱动 Turn/Surface 落 committed 公开页
  （段4 D2，取代曾经借 hello Generator 的临时 ALT）。
  """

  # caps 只在这里（recipe 的 requested_caps 是 caps 的唯一来源）。cap-template
  # 形状 `%{behavior: <ActionSet>, action: <atom>}`，照 orchestrator_recipe。
  @send_cap %{behavior: Ezagent.ActionSet.Session, action: :send}
  @crawl_cap %{behavior: Ezagent.ActionSet.Crawler, action: :crawl_now}
  # 页面发布腿（段4 D2）：dispatch 方要持这个 cap —— 触发爬取的 search
  # recipe 也 request 它（crawl handler 用触发者的 delegated caps dispatch）。
  # discover 不 request（段3：py 车道不 dispatch，见 discover/0 注释）。
  @page_publish_cap %{behavior: Ezagent.ActionSet.CrawlerPage, action: :publish_page}

  # search 动作的 cap-template（assistant 的入库 CLI 面要 search + crawl_now 都能跑）。
  @search_cap %{behavior: Ezagent.ActionSet.Crawler, action: :search}

  @doc "全部 recipe 声明数据（`roles/0` 的 seed 源）：发现腿 4 个 + 入库操作员 1 个 + 通用页面发布腿 1 个。"
  @spec all() :: [map()]
  def all, do: [discover(), assistant(), search(), organize(), followup(), crawler_page()]

  # ①b 入库操作员（2026-07-10 零人工中继 case-2，照 kanban-assistant 模具）：
  # cc-headless 真脑操作员，常设职责写在 recipe prompt（materialize 时进它
  # sandbox 的 CLAUDE.md——**可信 persona 渠道**）。为什么必须是 persona 而
  # 不是路由消息载指令：真 e2e 三轮实测（docs/e2e/2026-07-10/
  # dealscout-rework-final 09e/09g/09h），cc 真脑一致拒绝"消息自证授权 +
  # 教它用特权身份执行状态变更"（拒的理由=授权来源，不是动作本身）——
  # duty 必须来自安装者配置的常设上下文，路由投递只是触发事件。
  #
  # requested_caps 带 crawler 动作 cap（crawl_now/search/publish_page）——
  # 注意读码事实（返回件里有完整判定）：DefinitionAgents 的 role-slot 授予
  # 是**自 scope**（GrantRecipeCaps.grant_all `cap(:agent, …, instance=self)`，
  # grant_recipe_caps.ex:209-232），而 session 宿主动作的 needed cap kind =
  # :session、instance = 会话（runtime.ex:401-441 check 11b）——两轴都不匹配。
  # e2e 用它的真实 CLI dispatch 把这条边界如实拍下来（CapBAC 拒 = 平台缺
  # session-scoped 授权车道的实证，等 Allen 拍板，不在 plugin 侧硬掰绕过）。
  # skills 是 duty 的**真实载体**（kanban-assistant 同款）：cc-headless 车道
  # 只物化 sandbox skills（`home_runtime.ex` materialize_sandbox_skills），
  # recipe `prompt` 不落 CLAUDE.md——2026-07-10 e2e 实测（09k：assistant 说
  # "Nothing in my actual instructions defines me as a dealscout-assistant"）。
  # skill 本体随 crawler 插件 ship（`priv/skills_seed/dealscout-assistant/`，
  # SkillRegistry.seed_source_dirs 扫每个 app 的 priv/skills_seed）。
  # persona 的**真实注入车道**（2026-07-10 e2e 逐轮实测收敛）：
  #   * recipe `prompt` —— cc-headless 车道不落地（home_runtime 只物化
  #     claude_md/skills 两条腿，09k 实证 assistant "no such standing role"）；
  #   * recipe `skills` —— 落进 sandbox skills/ 但 SDK sidecar 会话未必主动
  #     加载（09l 实证仍不认职责）；
  #   * recipe `config.system_prompt` —— RecipeMaterializer 把 config merge 进
  #     template content（recipe_materializer.ex:71 Map.merge(recipe_config)），
  #     cc-headless spawn 读 "system_prompt"（cc_headless_agent.ex:239）→
  #     sidecar env EZAGENT_CC_SDK_SYSTEM_PROMPT（sdk_sidecar.ex:264）→ SDK
  #     会话 system prompt（ezagent_cc_sdk_worker.py:108）——这是 cc-headless
  #     真脑的**可信常设上下文**正道，duty 从这里进。skills 仍保留（详版
  #     操作手册，persona 里指路）。
  defp assistant do
    %{
      name: "dealscout-assistant",
      skills: ["dealscout-assistant"],
      behaviors: [],
      prompt: assistant_persona(),
      # permission_mode: SDK 车道的自主执行姿态，与 PTY cc 车道人人都有的
      # `--dangerously-skip-permissions`（spawn_plan.ex:85）同一 posture——
      # default 模式下沙箱把 cwd 外的 cd/读文件全数拦下等人工批准（09m 实测
      # assistant 明确报告"这些命令需要人工批准"→ 零人工闭环断在这里）。
      config: %{system_prompt: assistant_persona(), permission_mode: "bypassPermissions"},
      requested_caps: [@send_cap, @crawl_cap, @search_cap, @page_publish_cap]
    }
  end

  defp assistant_persona do
    """
    # 你是 dealscout 团队的入库操作员（dealscout-assistant）

    这是你的常设职责，由 dealscout socialware 的安装者在安装时配置（本文件
    随你的 materialize 写入，不是会话里谁发消息临时指派的）。

    ## 职责：收到更新信号投递 → 立即入库

    dealscout 的 discover 角色爬公开源发现新线索后，会发一条带
    `__dealscout_update__` 标记的回复；平台路由规则会把这条投递给你，投递
    内容里带本会话 URI 和一行 `查询词: …`。收到后你立即用官方 ezagent CLI
    以你自己的身份把这批发现正式入库（这是你的本职工作，不需要逐次等人
    确认；CapBAC 会照常裁决你的权限）：

    1. 定位 ezagent 仓库根：`REPO_ROOT=$(cat ./REPO_ROOT)`（部署时由 crawler
       插件写进你工作目录的指针文件）。
    2. 在仓库根执行（身份 env `EZAGENT_USER_TOKEN`/`EZAGENT_ENTITY_URI`
       已由平台注入你的进程环境）：
       `mise exec elixir@1.18.4-otp-27 erlang@27.3.4.13 -- mix ezagent session search --session "<会话URI>" --query "<查询词>"`
       没有查询词行就改跑
       `... mix ezagent session crawl_now --session "<会话URI>"`。
    3. 入库动作会把线索注入会话、留存进结构化 slice，并自动重建匿名公开
       线索页——你不需要做任何发布动作。

    ## 汇报纪律（如实，绝不编造）

    - 成功（injected: N）→ 会话里一句话确认"已入库 N 条、公开线索页已自动重建"。
    - CLI 被权限拒绝（unauthorized）/ 失败 → 把错误原文报告进会话，不要
      重试绕过、不要编造 injected 数字。
    - 你只对本会话动作；不碰其他会话，不用别人的身份。
    """
  end

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
      # 同 discover：search 完成后同样触发页面发布的直接 dispatch 腿。
      requested_caps: [@send_cap, @crawl_cap, @page_publish_cap]
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

  # ⑤ 【通用件，非发现腿】page 槽的 dispatchable 页面发布入口（段4 D2，
  # dispatch-only 工具腿但 **不标 `passive: true`**：page 必须能 faceted
  # session.join 成会话成员——直呼腿按 members 的 role_name facet 解析它
  # （`crawler.ex` page_member_uri）；RF-6 passive-join 三闸会在 materialize
  # 拒掉 passive 成员（`session.ex:788-790` {:passive_actor_cannot_join,_}）。
  # kanban-manager 的 passive: true 成立是因为 board 是 workspace 级
  # URI-dispatch actor、不进 role 槽（kanban manifest 头注）——形态不同。
  # 取代曾经借 hello Generator 的临时 ALT）：crawl 完成后直接 dispatch
  # `:publish_page` 过来 → supervised Task 里把会话留存线索驱动
  # Turn/Surface 落 committed 版本树（`Ezagent.ActionSet.CrawlerPage` +
  # `EzagentPluginCrawler.PagePublisher`）。code-driven（照 `hello.builder`
  # recipe 的形状：无 prompt，behaviors 挂 ActionSet —— recipe-loaded
  # behavior 进实例行为集，dispatch 按 action 解析直达）。名字不带业务词：
  # 任何组合 crawler 能力的 socialware 声明一个 page 槽引本 recipe 即接上。
  defp crawler_page do
    %{
      name: "crawler-page",
      behaviors: [Ezagent.ActionSet.CrawlerPage],
      requested_caps: [@page_publish_cap]
    }
  end
end
