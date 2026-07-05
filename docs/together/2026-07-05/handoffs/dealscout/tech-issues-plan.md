# dealscout 开发 issue plan（技术层 · 前缀 I）

> **用 superpowers writing-plans 纪律写**：每个 issue = 一个能独立测试、独立交付的单元；每个开发点（I-n.m）= 一个 bite-sized step（明确碰哪些文件的 file:line、做什么、一句 DoD）。这里是**规划级颗粒度**——给"issue → 切分开发点 → 每点碰哪些文件 + DoD"，**不做逐行 TDD 代码**（那是执行时的事）。
> **Date:** 2026-07-03（2026-07-04 撮合根重构 → 2026-07-05 找为主重构：两条腿 + 15 issue 新骨架 → **2026-07-05 撮合腿换轨（证据版）：撮合 = hello 公开面聊天（组合 hello+concierge / session_feed_channel 登录自助 join+发言 / 匿名只读硬禁 / founder invite 深聊），删旧 `#1178` admission-gate 玩法**）· **Base:** upstream/main `90e8ee29`（file:line 现读核实）
> **底稿三件套**：同目录 `../README.md`（§1 组件清单 + §2 分步 Plan + §3 权威编号骨架 I-1..I-15）+ `../../../2026-07-05/handoffs/dealscout-code-review-and-dev-plan.md`（**Part 2** = 现有代码基础上的分步开发计划 + 今天能做 vs 缺口 + file:line）+ `../spec-vs-code-gaps.md`（flavor gap、规范纪律）。上游 F 层：`../product/4-features.md`（F 骨架 F-1..F-13，两条腿）。

## 追溯（本文 I 层 ↑ F-x，两条腿）

**发现腿（地基·找为主，I-1..I-9）**

| issue | 标题 | ↑ 上游 F | 状态标 |
|---|---|---|---|
| **I-1** | 爬取 plugin 骨架 | ↑F-1 定时+手动爬取 | 今天能做 |
| **I-2** | AI 主动发现 recipe + push | ↑F-2 AI 主动发现（千人千面 profile 匹配推送） | 今天能做（发现腿地基核心） |
| **I-3** | 主动搜索 recipe | ↑F-3 主动搜索（全网/指定源 query） | 今天能做（发现腿地基核心） |
| **I-4** | 配置（profile+关键词+token 存储） | ↑F-4 配置：profile+关键词+源+token | 今天能做 |
| **I-5** | DealScoutRender + SessionView + 发现流视图 | ↑F-5 发现流渲染 | 今天能做（首个走 Definition.views 匿名链的用户） |
| **I-6** | 多轮追问 agent + Definition seed | ↑F-6 多轮追问 agent | 今天能做（flavor per-agent 声明层已通 #1164、非 cc runnable 待验） |
| **I-7** | artifact → upload seam | ↑F-7 artifact 生成+下载 | 需协调（碰 core upload seam，agent-facing 入口是平台缺口） |
| **I-8** | world tab 接线 | ↑F-5 发现流渲染 | 需协调（碰 world 非自己文件，Phase 3 未完） |
| **I-9** | 数据保留 sweeper | ↑F-1 定时+手动爬取（F-1.5 数据保留） | 今天能做 |

**撮合腿（亮点·涌现，I-10..I-15）—— 撮合 = hello 公开面聊天**

| issue | 标题 | ↑ 上游 F | 状态标 |
|---|---|---|---|
| **I-10** | 组合 hello+concierge 的 Definition seed + 发布公开面 | ↑F-8 组合 hello+concierge（公开面 + 客服 agent） | 今天能做（仿 hello code-seed 经 governance publish） |
| **I-11** | 公开面登录写接线（复用 `session_feed_channel` 自助 join+post） | ↑F-9 登录自助 join+发言（@orchestrator 路由 concierge） | 今天能做（复用 web 现成 channel） |
| **I-12** | founder 身份看板 + 匿名只读验证 | ↑F-10 匿名只读硬禁 + 看发言者身份 + 全量白板 | 今天能做（两处 gate 已在 main） |
| **I-13** | founder invite 深聊 wiring | ↑F-11 founder 主动 invite 深聊者进私有 session | 今天能做（riding `invite_member`） |
| **I-14** | 平台跨用户推荐（关系网层） | ↑F-12 平台跨用户推荐（发现层第③腿） | **discuss-first / 缺口**（riding registry track，非阻塞） |
| **I-15** | email reach out（后续） | ↑F-13 email reach out | 需平台补（语义错配，后续另设计） |

## 全局约束（每个 issue 都遵守）

1. **代码全进 dealscout plugin 自己的文件**：新建 `apps/ezagent_plugin_dealscout/`，所有代码（爬取/搜索逻辑 / DealScoutRender / SessionView / recipe / Definition seed）都住这里，dev/热装下**零改已有代码**——例外只有 I-7（碰 core upload seam）和 I-8（碰 world），这两个显式标"需协调"。
2. **ActionSet 不是 Elixir behaviour**：render/view 是 `use Ezagent.Lifecycle` 的 ActionSet（照 `apps/ezagent_plugin_hello/lib/ezagent/behavior/hello_render.ex:29`），不是手写 `invoke/4`。
3. **caps 只来自 recipe**：Definition struct 里根本没 `requested_caps` 字段（`apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex` struct 定义核实）——dealscout Definition 从不声明/追加/override caps，全部 caps 在 recipe 的 `requested_caps` 里（照 `apps/ezagent_plugin_cc/lib/ezagent/orchestrator/orchestrator_recipe.ex:65-79`）。
4. **flavor per-agent 声明已通（#1180 role-slot）**：Definition.roles 的 agent 槽按规范写 `%{role_name, fill: :agent, recipe, flavor}`——`role_slot/1` `definition.ex:275-303` 读取并**要求** agent 槽 flavor 非空（`:282-286`），materialize 时 `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex:321-326` `flavor_of` 透传到 `create_agent_from_recipe`（缺省回填 `"cc"`）——**不再静默丢弃**。今天各 agent 仍可统一跑 cc，是因为非 cc flavor 的 runtime materialize hook 未齐（**运行时能力问题**），**不是"Definition 表达不了 flavor"**（`../spec-vs-code-gaps.md` §2 已标 CLOSED）。
5. **Definition 是纯数据 DATA**：只引用 dealscout plugin 的模块名（`views: [Ezagent.ActionSet.DealScoutRender]`、`bases/shape: [Ezagent.ActionSet.Turn/Surface]`），本身不含一行代码，经 `DefinitionRegistry` 持久化。
6. **dispatch 是 Kind 间唯一通路（P14）**：抓回/搜到的数据经 `Ezagent.Router.dispatch(%Cmd{})`（`apps/ezagent_core/lib/ezagent/router.ex:79`）注入 `session.send`，禁止 `PubSub.broadcast` 到 inbound topic。chat 命令构造 action URI 用 sanctioned `with_action`（照 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/miro_sync.ex:172`）不裸拼 `?action=`。

---

# 发现腿（地基·找为主）

## I-1 · 爬取 plugin 骨架 ↑F-1

**目标**：一个能起来的新 plugin，带一个周期性轮询 GenServer + 一个手动触发的抓取 action，抓回的公开源数据经 dispatch 注入 session。先固定一个不需登录的公开源（RSS / HN），验证"外网→ezagent 会话"这条链。

**Files（创建）**：
- `apps/ezagent_plugin_dealscout/mix.exs`（新 OTP app `:ezagent_plugin_dealscout`）
- `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/application.ex`（plugin 契约回调宿主）
- `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/poller.ex`（轮询 GenServer）
- `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/fetch.ex`（`:httpc` 抓取 client）

**开发点**：

- **I-1.1 新 plugin app 脚手架 + 契约回调骨架** ↑I-1
  - 做什么：建 `mix.exs`（app atom `:ezagent_plugin_dealscout`，依赖 `ezagent_core` + `ezagent_domain_session`）；`application.ex` 实现 plugin 契约回调，先只填 `plugin_info/0` + `children/0`。契约回调全集见 `apps/ezagent_core/lib/ezagent/plugin.ex:246-257`；`children/0` 挂 supervise 树的先例照 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex:117`。
  - DoD：`mise exec -- mix compile` 过，新 app 被 umbrella 识别、启动时不崩。
- **I-1.2 轮询 GenServer（照 email inbound 的 poll 循环）** ↑I-1
  - 做什么：`poller.ex` 写一个 GenServer，`init/1` 里 `schedule_poll()` + `handle_info(:poll, state)` 处理后再 `schedule_poll()`——**逐行照** `apps/ezagent_plugin_email/lib/ezagent/email/inbound.ex:57-58,63-65,71-72`（`Process.send_after(self(), :poll, interval)` idiom，间隔走 app env）。挂进 `children/0`；**测试启动时跳过 live poller**（照 email `application.ex:67-68` 的 test-boot skip）。若要 per-源/per-keyword 动态起多个 worker，照 kanban `miro_sync.ex:24,37-40,83,94`（Registry + DynamicSupervisor + `{:via, Registry, ...}`）。
  - DoD：dev 起 server 后 poller 按 interval 触发 `:poll`，测试环境不起真 poller（不打外网）。
- **I-1.3 `:httpc` 抓取 client（治中文乱码）** ↑I-1
  - 做什么：`fetch.ex` 用 `:httpc` 直连固定公开源（RSS/HN JSON），**必带 `body_format: :binary`**（照 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/miro.ex:141` 实证——不带会中文乱码）；解析成 `[%{title, url, summary, source, ts}]` 的信息条目列表。
  - DoD：抓一次固定源，返回结构化条目列表；中文标题不乱码。
- **I-1.4 手动触发 action + dispatch 注入 session.send** ↑I-1
  - 做什么：轮询和手动触发都走同一条注入路径——抓回条目后构造 `%Cmd{}` 经 `Ezagent.Router.dispatch/1`（`apps/ezagent_core/lib/ezagent/router.ex:79`）投 `session.send`（chat 消息=action，先例 `apps/ezagent_domain_agent/.../receive.ex` 投递链）。手动命令的 action URI 用 sanctioned `with_action` 构造（照 `miro_sync.ex:172`，不裸拼 `?action=`）。**注入点问"失败了谁知道"**：dispatch 失败要有 telemetry / DLQ 兜底，不 silent drop。
  - DoD：手动触发一次，抓回条目以 session 消息形式落进目标会话历史，会话里能看到这批情报条目。

**标注**：今天能做（发现腿地基第一块，全在 dealscout plugin 自己文件）。

---

## I-2 · AI 主动发现 recipe + push ↑F-2

**目标**：发现腿地基核心之一——一个**副驾型 recipe**，按用户 profile（画像/关注领域/历史追问）**千人千面主动匹配**抓回来的机会，主动 push 匹配度高的条目进发现流（不是等用户翻，而是 agent 替你挑）。复用 I-1 的爬取基建 + message_store 历史，纯靠 recipe（agent 能力）实现，无需新机制。

**Files（创建/修改）**：
- 修改 `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/application.ex`（`roles/0` 加 discover recipe）
- `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/recipes.ex`（recipe 定义集，本 issue 起头）

**开发点**：

- **I-2.1 `dealscout-discover` 副驾 recipe（可用 cc-headless）** ↑I-2
  - 做什么：`roles/0`（回调名 rename 后没改，`plugin.ex:212`；先例 kanban `application.ex:64`）声明一个副驾 recipe，三要素照 `apps/ezagent_plugin_cc/lib/ezagent/orchestrator/orchestrator_recipe.ex:65-79`：`prompt`（"读用户 profile + 新抓回条目，挑出匹配度高的主动推"）+ `requested_caps`（读会话历史 + 写发现流 DealScoutRender/session.send 的 cap，caps 全在这里，全局约束 3）+ `behaviors: []`。flavor 可声明 `"cc-headless"`（#1180 agent 角色槽 flavor 必填、真读真路由 `definition.ex:282-286`），非 cc runnable 待验、起步可统一 cc。
  - DoD：`dealscout-discover` recipe 进 `RecipeRegistry`，`mix ezagent` CLI 能看到；caps 齐。
- **I-2.2 profile 驱动匹配 + 主动 push 进发现流** ↑I-2
  - 做什么：副驾读 profile（存 I-4 的 config slice）+ 新抓批次，算匹配后把高分条目经 P14 dispatch（`router.ex:79`）以 session 消息形式 push 进发现流（同 I-1.4 注入路径，不新造机制）。**push 是投递动作，问"失败谁知道"**：dispatch 失败 telemetry，不 silent drop。
  - DoD：给一个 profile + 一批抓回条目，副驾 push 出按 profile 排序/筛选的匹配条目进会话；换 profile 结果不同（千人千面可见）。

**标注**：今天能做（发现腿地基核心；纯 recipe，复用 I-1 爬取 + 现成 dispatch 投递链，无平台缺口）；**依赖 I-1**（先有抓回数据可匹配）+ I-4（profile slice 提供画像）。

---

## I-3 · 主动搜索 recipe ↑F-3

**目标**：发现腿地基核心之二——用户在 chat 里发一条手动 query（"帮我搜 xx 领域最近的融资"），一个**搜索型 recipe** 对全网/指定源即时 query、把结果结构化后注入发现流。区别于 I-1 的周期爬取（被动定时）和 I-2 的副驾主动 push（profile 驱动）——这是**用户主动发问的即时搜索**。

**Files（修改）**：
- 修改 `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/recipes.ex`（加 search recipe）
- 修改 `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/fetch.ex`（query 参数化抓取，复用 I-1.3 client）

**开发点**：

- **I-3.1 `dealscout-search` 搜索 recipe（cc-headless）** ↑I-3
  - 做什么：`roles/0` 声明搜索 recipe，三要素照 `orchestrator_recipe.ex:65-79`：`prompt`（"把用户 query 转成对源的检索、汇总结果"）+ `requested_caps`（读 query + 调 fetch + 写发现流 session.send 的 cap）+ `behaviors: []`。flavor 声明 `"cc-headless"`（#1180 agent 角色槽 flavor `definition.ex:282-286`）。
  - DoD：`dealscout-search` recipe 进 `RecipeRegistry`，caps 齐。
- **I-3.2 query 参数化抓取 + 结果注入发现流** ↑I-3
  - 做什么：`fetch.ex` 加一个按 query + 指定源参数化的抓取入口（复用 I-1.3 `:httpc` + `body_format: :binary` client）；搜到的结构化条目经 P14 dispatch（`router.ex:79`，同 I-1.4 注入路径）落进发现流，标记为"搜索结果"。search action URI 用 sanctioned `with_action`（照 `miro_sync.ex:172`）。
  - DoD：chat 里发一条 query → 该 query 对固定源即时搜 → 结果以 session 消息落进会话、可与周期爬取条目区分。

**标注**：今天能做（发现腿地基核心；纯 recipe + 复用 I-1 fetch client，无平台缺口）；**依赖 I-1**（fetch client 基建先有）。

---

## I-4 · 配置（profile+关键词+token 存储） ↑F-4

**目标**：用户 profile（画像/关注领域，喂 I-2 千人千面匹配）+ 关键词/源描述可在运行期改（存 Lifecycle state slice，自动 snapshot）；登录源的 access token 可自定义存进凭证库、抓取时注入 header。

**Files（创建/修改）**：
- `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/config.ex`（profile + keywords slice 读写 + token 写入）
- 修改 `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/fetch.ex`（抓取时读 token）

**开发点**：

- **I-4.1 profile + keywords 运行期可变（state slice）** ↑I-4
  - 做什么：profile（画像/关注领域）+ 关键词/源描述存在 poller（或专门配置 Kind）的 Lifecycle **`state` 容器**里，写用 `{:set, :profile, ...}` / `{:set, :keywords, ...}` effect、读用 `ctx.read`（元数据先例 `apps/ezagent_plugin_kb/lib/ezagent_plugin_kb/kb.ex:80-83`——`state` 自动 auto-snapshot，重启不丢）。静态默认值可放 recipe config（照 kanban `application.ex:99-103`）。**profile slice 是 I-2 千人千面匹配的数据源**。
  - DoD：chat 里改 profile/关键词 → 下一次轮询/发现用新值；重启会话后还在（snapshot 生效）。
- **I-4.2 自定义 access token 写入凭证库（write_creds idiom）** ↑I-4
  - 做什么：照 kanban `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/github.ex:32-54` 的 `write_creds/1`——把 token 写到 `system://credentials/dealscout_<src>.yaml`（admin-gated）。这是四档凭证里最简的一档，起步够用；per-源多 token 可后续升级到 `TokenStore`（`token_store.ex:18` constant-time verify）。
  - DoD：调 `write_creds` 后凭证落到 `system://credentials/`，读回一致。
- **I-4.3 抓取时读 token 注入 header** ↑I-4
  - 做什么：`fetch.ex` 抓需登录源前从 `system://credentials/dealscout_<src>.yaml` 读 token，拼进 `:httpc` 请求 header（`Authorization` / cookie）。无 token 时 fail-closed（跳过该源 + telemetry），不 silent 抓空。
  - DoD：给一个需 token 的源配 token，抓取带上 header 成功；不配 token 时该源被显式跳过并有日志。

**标注**：今天能做（全在 dealscout plugin 自己文件）。

---

## I-5 · DealScoutRender + SessionView + 发现流视图 ↑F-5

**目标**：把抓回/发现/搜到的信息条目渲染成一个 session tab 里的发现流列表页。三件套：一个 cap-only 的 render ActionSet（看的权限门）+ 一个 SessionView module（列表视图）+ json-render 页面。**都住 dealscout plugin**，Definition 只引用模块名。dealscout 是**首个真实走 Definition.views 匿名链的用户**（hello 的 Definition 没写 views 键，这条链没跑过）。

**Files（创建）**：
- `apps/ezagent_plugin_dealscout/lib/ezagent/behavior/dealscout_render.ex`（cap-only render ActionSet）
- `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/dealscout_view.ex`（SessionView module）

**开发点**：

- **I-5.1 DealScoutRender ActionSet（cap-only，唯一 `:dealscout_render` action）** ↑I-5
  - 做什么：**逐结构照** `apps/ezagent_plugin_hello/lib/ezagent/behavior/hello_render.ex`——`use Ezagent.Lifecycle`（`:29`）、`def actions, do: [:dealscout_render]`（照 `:32` 的 `[:hello_render]`）。**action 名必须唯一**：`{Session, :dealscout_render}` cap pair 全仓唯一，否则 `CapabilityRegistry.check_conflict!` 会 RAISE（`hello_render.ex:6-19` 的 Allen decision 说明）。这是"看的权限门"不是渲染器——不能复用 HelloRender（`:hello_render` 名已被占）。
  - DoD：plugin 启动时 DealScoutRender 注册成功，`{Session, :dealscout_render}` cap 无冲突。
- **I-5.2 SessionView module（照 PageView）** ↑I-5
  - 做什么：**照** `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/page_view.ex`——`@behaviour Ezagent.UI.SessionView`（`:19`）、`def id, do: :dealscout_feed`（照 `:31` 的 `:hello_page`）、`def match` 匹配 dealscout session type（照 `:52` 的 `URI.type?(session_uri, :hello)`，换成 dealscout 的 type）、`def render/1`（`:64`）。**不能复用 PageView**：它 `def match` 硬匹配 `:hello` session。视图经 `authorize_view/3` 统一 cap 门（`apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view.ex:120-126`）。
  - DoD：SessionView 注册进 registry，操作员会话里能命中 dealscout view 并渲染（authorize_view 放行）。
- **I-5.3 json-render 发现流列表页（走 Surface catalog）** ↑I-5
  - 做什么：视图内容用 json-render catalog 约束的信息列表（每条：标题/源/摘要/匹配标记/追问入口），经 Surface 出生（内看最新、外看 approved 版本门 `surface.ex:114/121`）。catalog 约束照 hello 的 `spec.ex:29`。列表每条挂一个"追问"入口，点了对同一 agent URI 连发 `session.send`（追问机制在 I-6 的 recipe + 现成 cc 投递链，无需新机制）。
  - DoD：会话 tab 里能看到抓回/发现条目的列表页，每条可点进追问。

**标注**：今天能做（首个走 Definition.views 匿名链，顺带给平台验证 T2 views 设计）。

---

## I-6 · 多轮追问 agent + Definition seed ↑F-6

**目标**：声明追问/整理 recipe，用 `after_boot` 代码 seed 一个 kanban 式的 Definition（含 `roles`（角色槽）/ `views` / `routing_rules` / `visibility_policy`），materialize 时自动把发现腿全部 recipe（I-2 discover + I-3 search + 本 issue 整理/追问）的 agent 角色槽落成 live 成员。追问投递链复用现成 cc，无需新机制。

**Files（创建/修改）**：
- 修改 `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/application.ex`（补 `roles/0` 追问/整理 recipe + `after_boot/0` + `config_surface/0`）
- 修改 `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/recipes.ex`（整理/追问 recipe）
- `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/definition_seed.ex`（Definition seed 逻辑）

**开发点**：

- **I-6.1 `roles/0` 补整理 + 追问 recipe** ↑I-6
  - 做什么：`roles/0` 再声明两个 recipe——**信息整理**（native flavor，把杂乱条目组织成结构）+ **多轮追问回应**（cc，对单条深挖）。每个照 `orchestrator_recipe.ex:65-79` 三要素：`prompt` + `requested_caps`（整理要读会话历史 cap、追问要 session.send cap，caps 全在这里，全局约束 3）+ `behaviors: []`。flavor per-agent 声明（#1180 agent 角色槽 flavor `definition.ex:282-286`），今天统一 cc 无碍。
  - DoD：两 recipe 进 `RecipeRegistry`；连同 I-2/I-3 共 4 个发现腿 recipe 都在，caps 齐。
- **I-6.2 `after_boot` seed 含 `roles` 角色槽的 Definition** ↑I-6
  - 做什么：`after_boot/0` 里调 `seed_definition_if_absent`（照 hello `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex:238`）seed 一个 Definition。字段（Definition 共 17 个，`definition.ex:12-28` struct）：`views: [Ezagent.ActionSet.DealScoutRender]`、`roles: [发现腿 4 个 agent 角色槽 %{role_name, fill: :agent, recipe, flavor}]`（**顶层无 flavor，flavor 在每个 agent 角色槽条目**——`role_slot/1` `definition.ex:275-303` 读取并要求 agent 槽 flavor 非空 `:282-286`、`@type` `:34-36`，materialize `definition_agents.ex:321-326` 缺省回填 `"cc"`，#1180）、`bases/shape: [Ezagent.ActionSet.Turn, Ezagent.ActionSet.Surface]`、`routing_rules: [%{match: :in_session, receiver: {:role, "..."}}]`（**receiver 只能是已声明角色名、不能塞实例 URI**）、`visibility_policy: %{web_anon_access: true}`、`owner_policy: %{type: :installer}`（**`:fixed` 已被拒**）。materialize 只把 `fill: :agent` 的角色槽落成 live 成员（`definition_agents.ex:61`，human 槽运行期才分配，grant recipe caps LAST `:241-246`）。**发布走独立 config registry（Allen 决策 #1147/#1152，非缺口、非"待补"）**：socialware 是纯数据 Definition，**有意不打进 plugin 包**——plugin 包只管代码 + recipe（`PluginPackage.Manifest` 的 seed_ref kind 必须 `:recipe`、拒 `:socialware`，`apps/ezagent_core/lib/ezagent/plugin_package/manifest.ex:54-56` 在 parse 时 REJECT 而非静默丢弃）。Definition 走独立 config registry（ConfigStore + governance + discover + install），今天像 hello 那样**仿 code-seed**（boot 写 config map + 经真 governance publish `ConfigGovernance.Socialware.publish_or_upgrade` `config_governance/socialware.ex:116`），未来 registry P3 从外部 config 源发布（不写 Elixir）。
  - DoD：boot 后 Definition 进 `DefinitionRegistry`；创建 session 时发现腿 agent 自动 materialize 成成员（都跑 cc）。
- **I-6.3 过 conformance gate** ↑I-6
  - 做什么：跑 `mise exec -- mix ezagent.socialware.check`（有序断言，CI 接入红即非零退出 `conformance.ex:61-74`、`mix/tasks/ezagent.socialware.check.ex:63-64`）。重点过 `routing_receivers_resolve`（routing_rules 的 receiver 能解析到已声明 agent）。
  - DoD：`mix ezagent.socialware.check` 对 dealscout Definition 全绿。

**标注**：今天能做；**per-agent flavor 差异（整理用 native / 发现搜索用 cc-headless）声明层已通**（#1180，agent 角色槽 flavor `definition.ex:282-286` + `definition_agents.ex:321-326`，`../spec-vs-code-gaps.md` §2 CLOSED），今天统一 cc 无碍——剩下只是非 cc flavor 的 runtime materialize hook 是否补齐（运行时能力，非声明缺口）。

---

## I-7 · artifact → upload seam ↑F-7

**目标**：agent 追问后产出的文件（材料/模板/素材）登记进 uploads，回复里带可下载 attachment。当前 `Uploads.store!` 只有 web 上传控制器调，**没有 agent-facing 入口**——这是要新建的 seam。

**Files（碰 core seam，需协调）**：
- 新 effect 或 MCP tool（位置待 discuss：dealscout 私有 vs 平台通用 effect）
- 复用 `apps/ezagent_core/lib/ezagent/uploads.ex:99`（`store!/3`）+ `apps/ezagent_core/lib/ezagent/uploads/download_token.ex`（`mint!/2`）

**开发点**：

- **I-7.1 agent 产出 → `Uploads.store!` 的 seam** ↑I-7
  - 做什么：加一个 effect 或 MCP tool，让 agent 把 cwd 里的产出文件搬进 uploads——调 `apps/ezagent_core/lib/ezagent/uploads.ex:99` 的 `store!(workspace_name, stored_name, tmp_path)`。**这是平台缺口**（`store!` 现在只有 web controller 调），建议做成平台 effect/MCP tool 而非 dealscout 私有（`../README.md` §4 discuss #1）——要 discuss 归属。
  - DoD：agent 产出一个文件，经 seam 登记进对应 workspace 的 uploads，能查到 upload 记录。
- **I-7.2 回复带 attachment + mint 下载 href** ↑I-7
  - 做什么：登记后在 agent 回复消息里挂 upload 附件——渲染缝已就绪：`conversation_data.ex:331-343` 会自动给 upload 附件 mint 下载 href（走 `DownloadToken.mint!/2`，TTL≤24h type-lock）。匿名下载走 `/socialware/external/download`（`router.ex:166`，只放 approved surface）。
  - DoD：追问产出的文件在会话里显示为可点下载的附件；点击能下到文件；匿名用户经 approved 面也能下。

**标注**：需协调（碰 core upload seam，agent-facing 入口是平台缺口，归属要 discuss）。

---

## I-8 · world tab 接线 ↑F-5

**目标**：让注册的 DealScoutRender SessionView 在 world UI 自动冒一个 tab。当前 world tab 是**硬编码** chat/pty/page 三个，注册的 SessionView 不会自动出 tab（Phase 3 未完项）。

**Files（碰 world，非自己文件，需协调）**：
- 修改 `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex`

**开发点**：

- **I-8.1 switch_view 白名单纳入 dealscout view** ↑I-8
  - 做什么：`conversation_actions.ex:369` 附近的 `switch_view` 现在硬卡 `view in ["chat", "pty", "page"]`（注释明说 "page (TEMPORARY)... Proper world surfacing of registered SessionViews is Phase 3"）。最小接线是把 dealscout view 加进白名单让它能被切换。
  - DoD：world 里能手动切到 dealscout 发现流 tab 并渲染。
- **I-8.2 registered SessionView 自动冒 tab（Phase 3 泛化）** ↑I-8
  - 做什么：把硬编码白名单泛化成"从 SessionView registry 读已注册视图动态出 tab"。**这是 world 的 Phase 3 未完项**，动到 world owner 的代码，要 Allen / world owner 协调排期（`../README.md` §4 discuss #2）。
  - DoD：任意注册的 SessionView（含 dealscout）在 world 自动出 tab，不再硬编码。

**标注**：需协调（碰 world 非自己文件，Phase 3 未完，可能要 Allen / world owner）。

---

## I-9 · 数据保留 sweeper ↑F-1（F-1.5 数据保留）

**目标**：爬取/发现数据持续流入 KB slice，要有保留策略防无限膨胀。**默认保留最近 10 次爬取**（或最近 1 个月，取先到者）+ **可选 pin 某几次长期保存**。一个周期 GenServer 扫 KB slice、丢弃超期且未 pin 的批次。dealscout 自建（**非平台缺口**），照现成周期清扫先例。

**Files（创建/修改）**：
- `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/retention_sweeper.ex`（周期 GenServer）
- 修改 `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/config.ex`（pin 列表读写，与 I-4.1 的 slice 同一 state 容器）

**开发点**：

- **I-9.1 保留 sweeper 周期 GenServer** ↑I-9
  - 做什么：`retention_sweeper.ex` 写一个 GenServer，`init/1` 里 `schedule_sweep()` + `handle_info(:sweep, state)` 处理后再 `schedule_sweep()`——照 `Process.send_after(self(), :sweep, interval)` idiom（同 I-1.2 的 email inbound poll 先例 `apps/ezagent_plugin_email/lib/ezagent/email/inbound.ex:57-58,63-65,71-72`）。周期清扫结构照 `apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user/gc.ex` + `apps/ezagent_core/lib/ezagent/idempotency/sweeper.ex` 的 sweeper 先例。挂进 `children/0`；**测试启动时跳过 live sweeper**（照 email `application.ex:67-68` test-boot skip）。
  - DoD：dev 起 server 后 sweeper 按 interval 触发 `:sweep`；测试环境不起真 sweeper。
- **I-9.2 扫 KB slice + 丢超期未 pin 批次** ↑I-9
  - 做什么：每次爬取批次在 KB slice 里有批次 id + ts（I-1.4 注入时写），pin 列表也存 slice（`{:set, :pinned_batches, [...]}` effect，读用 `ctx.read`，同 I-4.1 slice 先例 `apps/ezagent_plugin_kb/lib/ezagent_plugin_kb/kb.ex:80-83`）。sweep 时算"最近 10 次 / 1 月"窗口，丢弃窗口外且不在 pin 列表的批次（`{:set, ...}` effect 写回精简后的批次集）。**丢弃是写动作，问"失败谁知道"**：清扫失败要 telemetry，不 silent。
  - DoD：造 >10 次爬取批次，sweep 后只剩最近 10 次 + 被 pin 的；pin 的批次即使超期也留存。
- **I-9.3 pin / 取消 pin action（配置层，成员限定）** ↑I-9
  - 做什么：配置 ActionSet 加 `:pin_batch` / `:unpin_batch` action，写 `:pinned_batches` slice。**配置层动作**——caps 来自配置成员 recipe 的 `requested_caps`（全局约束 3），匿名/房外人无此 cap。
  - DoD：成员 pin 一次爬取后该批次进 pin 列表、不被 sweep；匿名调用被 CapBAC 拒。

**标注**：今天能做（全在 dealscout plugin 自己文件，照现成 sweeper/slice 先例，零改已有代码）；**依赖 I-1**（爬取先出数据 + 批次 id）才有东西可扫。

---

# 撮合腿（亮点·涌现）—— 撮合 = hello 公开面聊天

**换轨说明（2026-07-05，证据版）**：上一版把撮合做成"申请加入私有 session（`#1178` admission gate）→ pending 私密 → owner `approve_admission` → 聊聊看"——**过度设计、DealScout 用不上，整条删**。新玩法：撮合 = **hello 公开面聊天**——DealScout **组合 hello 拿公开面 + concierge 客服 agent**（hello 的 orchestrator off 到 `EzagentPluginHello.Router`，`hello_orchestrator.ex` handle_receive hand off、`router.ex:13-14` 策略：**非 owner member 永远路由 concierge，访客到不了 builder**，concierge 应答 `hello_concierge.ex:43`）；**登录用户**在公开面**自助 join + 发消息**（web `session_feed_channel.ex:197-228`，post 带 `mentions:[orchestrator_uri]` @orchestrator → 非 owner 转 concierge）；**匿名只读不能写**（两处硬禁 `session_feed_channel.ex:325-330` + `membership.ex:1200-1208`）；**founder 全量白板互见**（`external_feed.ex:85-98`）+ **看发言者身份**（`session_feed_channel.ex:353`）→ **owner 主动 invite 深聊者进私有 session**（`conversation_actions.ex:683` `invite_member`）。全链机制都在 main，DealScout 直接 riding hello 组合面 + session_feed_channel + concierge + invite_member，**不再走"申请加入"基建**。

## I-10 · 组合 hello+concierge 的 Definition seed + 发布公开面 ↑F-8

**目标**：DealScout 的公开面**组合 hello**——Definition 声明 `uses: [:ezagent_plugin_hello]`（依赖 hello plugin 已装）+ `roles` 含 concierge 客服 agent 角色槽（per-agent flavor），发布出一个带公开面 + 客服 agent 的 socialware。公开面聊天路由复用 hello：orchestrator off 到 `EzagentPluginHello.Router`（`hello_orchestrator.ex` handle_receive hand off、`router.ex:13-14` 策略），**非 owner member 永远 concierge、访客到不了 builder**（identity-first 结构门），concierge `handle_receive`（`hello_concierge.ex:43`）应答。发布走**独立 config registry**（今天仿 hello code-seed 经真 governance publish）。这是撮合腿的**入口**（别人先看到你的公开面，才会来聊）。

**Definition = 17 字段纯数据（`apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex:12-28` struct）**：`name / version / title / description / uses / bases / shape / views / roles / assets / routing_rules / prompt_templates / legends / orchestrator_template_uri / adapters / visibility_policy / owner_policy`——**顶层无 flavor**；flavor 在 `roles` 里每个 agent 角色槽条目（`role_slot/1` `definition.ex:275-303` 读取并要求 agent 槽 flavor 非空 `:282-286`，`@type` `:34-36`，materialize 缺省 `"cc"`）。**#1180 起 `agents` 改名 `roles`、`members` 退休**（两字段并成一个 `roles`），`owner_policy` 只准 `%{type: :installer}`。

**`uses` ≠ 组合轴**：`uses` = 声明依赖哪些 plugin（必须已装，`manifest_resolver.ex:41` `ensure_plugins_installed` 缺失即 `{:error, {:missing_socialware_plugins, ...}}`）。真组合 = 多 Definition 的 `installs` merge（`definition_editor.ex:63` `config_for_template` 逐 install `merge_definition`）+ 单 Definition 的 `bases/shape/views` union（`definition.ex:124` `behaviors/1`）。所以"拿 hello 公开面 + concierge"**不是靠 `uses` 拉 view**，而是 DealScout Definition 自己声明 concierge agent + 复用 hello 的 orchestrator/router 路由 + hello 的 public_view 面。

**Files（dealscout plugin Definition + seed）**：
- 修改/新建 `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/definition_seed.ex`（组合 Definition：`uses` hello + `roles` 含 concierge/discover 的 agent 角色槽 + `visibility_policy`）

**开发点**：

- **I-10.1 组合 Definition（uses hello + roles 含 concierge 角色槽）** ↑I-10
  - 做什么：seed 一个 Definition，`uses: [:ezagent_plugin_hello]`（依赖 hello 已装，`manifest_resolver.ex:41` 会验缺失即拒）；`roles` 列 concierge 客服 + 发现腿的 agent 角色槽，每条 `%{role_name, fill: :agent, recipe, flavor}`（flavor per-agent，`role_slot/1` `definition.ex:282-286` 要求非空、materialize 缺省 `"cc"`）。公开面路由复用 hello：`hello_orchestrator.ex` handle_receive 把 USER 消息 hand off 到 `EzagentPluginHello.Router`（`router.ex:13-14` 策略），**非 owner member 永远 concierge**，`hello_concierge.ex:43` 应答。
  - DoD：Definition 进 registry；`uses` 的 hello 未装则 seed 显式失败（`manifest_resolver.ex:41`，非静默）。
- **I-10.2 发布公开面（仿 hello code-seed 经 governance publish）** ↑I-10
  - 做什么：发布走**独立 config registry（Allen 决策 #1147/#1152，有意架构选择，非缺口、非"我们 propose 待补"）**——socialware 是纯数据 Definition，**有意不打进 plugin 包**（plugin 包只管代码 + recipe，`PluginPackage.Manifest` 的 seed_ref kind 必须 `:recipe`、拒 `:socialware`，`apps/ezagent_core/lib/ezagent/plugin_package/manifest.ex:54-56` 在 parse 时 REJECT 而非静默丢弃）。今天像 hello 那样**仿 code-seed**：boot 时写 config map（照 hello `app.ex:238` `seed_definition_if_absent`）+ 经真 governance publish（`ConfigGovernance.Socialware.publish_or_upgrade` `apps/ezagent_domain_session/lib/ezagent/socialware/config_governance/socialware.ex:116`，内部跑 `open_cr → stage_definition → publish_cr` 全流程 `:109`/`:80`）。未来 registry P3 从外部 config 源发布（不写 Elixir）。
  - DoD：boot 后 DealScout socialware 进 config registry，公开面可被 discover/install。
- **I-10.3 开 `visibility_policy.web_anon_access`（发布者自助，非 admin）** ↑I-10
  - 做什么：Definition `visibility_policy: %{web_anon_access: true, publish_policy: :auto}`（照 hello `app.ex:254`）——**web_anon_access 是发布者自助**，决定"能不能铸只读 anon"，**不需 admin**。**admin 只管全域**：只有 `scope: :public`（跨 workspace 发现）才走 admin 门（`config_governance/socialware.ex:197` `authorize_public_scope` → 有 public definition 才 `authorize_admin` `:228`，否则直接 `:ok`）。真正上公网靠**域名分配（infra 层）**，合规是外部审批，平台不背。
  - DoD：发布后匿名请求能被铸只读 anon（非 403）；不声明 public scope 时发布无需 admin。

**标注**：今天能做（组合 Definition + 仿 hello code-seed，机制全在 main）；**依赖 hello plugin 已装** + I-5（views 匿名链先通）+ I-6（发现腿 Definition seed 复用同一 seed 逻辑）。

---

## I-11 · 公开面登录写接线（复用 session_feed_channel 自助 join+post）↑F-9

**目标**：撮合腿核心之一——**登录用户**在 DealScout 公开面**自助 join + 发消息**。这条**完全复用 web 现成 `session_feed_channel.ex` 的 participatory join/post**，DealScout 侧零新机制。登录用户 post 的消息带 `mentions:[orchestrator_uri]` @orchestrator → 由非 owner 路由规则永远转 concierge（访客到不了 builder）。这换掉旧版"申请加入 pending + owner 审核"整条——不再有 `:pending_members` / `approve_admission`，登录用户直接自助进公开面聊。

**Files（复用 web channel，DealScout 侧极薄）**：
- 复用 `apps/ezagent_web/lib/ezagent_web/socialware/session_feed_channel.ex:197-228`（`handle_participatory_join` / `handle_participatory_post`）
- 复用 `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex:1200-1208`（成员 cap 授予：`confirmed?` 才给 chat actions）
- 无需改 DealScout 代码（公开面即 hello 组合出的 public_view 面）

**开发点**：

- **I-11.1 登录自助 join（复用 handle_participatory_join）** ↑I-11
  - 做什么：登录用户在公开面点"加入" → web `session_feed_channel.ex:197` `handle_participatory_join`：`signed_in_principal` 拿到登录 principal（匿名返回 nil，`:325-330`）→ `provision_invited_join_authority` + `dispatch_join` + `mount_participation_caps`。成员写 cap 由 `membership.ex:1200-1208` 授（`confirmed?` 才给 `@member_chat_actions`，否则只给 publisher/只读 actions）。DealScout 侧不需自造准入。
  - DoD：登录用户自助 join 成公开面成员，`member: true`，公开面显示"发送"composer（非只读）。
- **I-11.2 登录发言 @orchestrator → concierge（复用 handle_participatory_post）** ↑I-11
  - 做什么：登录成员发消息 → `session_feed_channel.ex:229` `handle_participatory_post` → `dispatch_post`（`:353`）构造 `Message` 带 `mentions: [orchestrator_uri(session_uri)]` → dispatch 进 session。orchestrator off 到 hello Router，**非 owner member 永远路由 concierge**（`router.ex:13-14`），登录访客到不了 builder。
  - DoD：登录非 owner 成员发消息 → concierge 应答（`hello_concierge.ex:43`），验证消息未走 builder。
- **I-11.3 端到端：登录用户逛公开面 → 自助 join → @concierge 聊** ↑I-11
  - 做什么：串起 I-11.1/I-11.2——登录用户经 `/socialware/*` 看到 DealScout 公开面 → 自助 join → 发消息被 concierge 接待。全程无 pending、无 owner 审核。
  - DoD：e2e——登录用户自助 join 公开面并与 concierge 往返，历史留痕。

**标注**：**今天能做（复用 web 现成 `session_feed_channel`）**——登录自助 join + post + @orchestrator 路由 concierge 的机制全在 main，DealScout 是把它用成公开面聊天的 socialware；**依赖 I-10**（公开面先发布，别人才逛得到）。

---

## I-12 · founder 身份看板 + 匿名只读验证 ↑F-10

**目标**：撮合腿核心之二——**founder（owner）全量白板互见** + **看发言者身份** + **匿名只读硬禁写**。owner 看得到公开面上所有发言者是谁、说了什么（全量白板），据此挑深聊对象（接 I-13 invite）。匿名只能看不能写，两处 gate 硬禁——**没有"访客登记"这层**，匿名就是纯只读。

**Files（复用现成 gate + 全量白板 + 身份显示）**：
- 复用 `apps/ezagent_domain_socialware/lib/ezagent/socialware/external_feed.ex:85-98`（`chat_messages` 全量白板）
- 复用 `apps/ezagent_web/lib/ezagent_web/socialware/session_feed_channel.ex:353`（发言者身份）+ 两处只读 gate（`:325-330` / `membership.ex:1200-1208`）

**开发点**：

- **I-12.1 匿名只读硬禁写（两处 gate 验证）** ↑I-12
  - 做什么：验证匿名不能写——**gate ①** web 层 `session_feed_channel.ex:325-330` `signed_in_principal`：匿名 caller（`AnonUser.anon_uri?`）返回 `nil`，post/join 直接 `{:error, %{reason: "not_logged_in"}}` 拒；**gate ②** 成员 cap 层 `membership.ex:1200-1208`：`confirmed?` 才授 `@member_chat_actions`，未确认/匿名只有 publisher/只读 cap。两处硬禁，DealScout 侧不需新机制。
  - DoD：匿名经公开面能看发现流/机会页，但 post/join 被两处 gate 之一显式拒（`not_logged_in` / 无 chat cap）。
- **I-12.2 founder 全量白板 + 看发言者身份** ↑I-12
  - 做什么：owner 看到公开面**全量白板**——`external_feed.ex:85-98` `chat_messages` 返回 FULL collaborative chat（全部 chat-visible 消息，不是 delivered projection `snapshot/2`），同 live membership 读门；发言者**身份可见**——`session_feed_channel.ex:353` `dispatch_post` 携带 principal 身份，founder 据此识别谁在发言。
  - DoD：owner 在看板看到所有发言者身份 + 全量消息，能挑出深聊对象。

**标注**：今天能做（两处只读 gate + 全量白板 + 身份显示全在 main）；**依赖 I-11**（先有登录用户发言可看）；看板若要在 world 出独立 tab 依赖 I-8（world tab 接线，需协调）。

---

## I-13 · founder invite 深聊 wiring ↑F-11

**目标**：撮合腿核心之三——owner 从公开面（I-12 身份看板）挑出深聊者，**主动 invite 进私有 session** 深聊、选择性披露、AI 辅助撮合、撮合成功记账。**这是 owner 主动拉，不是访客申请**——复用 world `conversation_actions.ex:683` `invite_member`。撮合北极星口径：撮合成功 = **公开面真实互动 / 被邀深聊**，不是"申请通过数"。

**Files（riding 现成 invite + slice）**：
- 复用 `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex:683`（`invite_member`）
- 改自己那份配置走 `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex:82`（`session.fork_config`）
- 修改 `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/recipes.ex`（`dealscout-support` 撮合辅助 recipe）+ `matchmaking.ex`（撮合记账 slice）

**开发点**：

- **I-13.1 founder invite 深聊者进私有 session** ↑I-13
  - 做什么：owner 在身份看板（I-12）挑中发言者 → 主动 invite 进一个私有 session 深聊——复用 world `conversation_actions.ex:683` `invite_member`（parse member URI → `demand_spawn_member` 先从 snapshot spawn 冷成员 → `:join`）。这是 **owner 主动拉**（不是访客申请、无 pending 审核环节），私有 session 里深聊、选择性披露（应用层约定，哪些材料在信任建立后才发）。
  - DoD：owner invite 一个公开面发言者 → 对方成私有 session 成员、双方能私密往返。
- **I-13.2 `dealscout-support` 撮合辅助 recipe** ↑I-13
  - 做什么：`roles/0` 声明一个客服型 recipe `dealscout-support`——辅助撮合（引导披露、AI 撮合建议）。三要素照 `orchestrator_recipe.ex:65-79`：`prompt` 限定"只在本 session 范围内辅助撮合"、`requested_caps` 给读会话 + 回消息（不给配置层 cap）。作为一个 agent 角色槽放进 Definition `roles:` 列表（`%{role_name, fill: :agent, recipe: "dealscout-support", flavor}`）。
  - DoD：`dealscout-support` recipe 进 `RecipeRegistry` + 进 Definition.roles（一个 agent 角色槽）；建会话时物化成 live 客服成员（跑 cc）。
- **I-13.3 撮合成功记账（真实互动 / 被邀深聊 → 撮合北极星）** ↑I-13
  - 做什么：撮合北极星口径 = **公开面真实互动 + 被邀深聊**（不是申请通过数）。达成时往 session 连接 slice 写一条记录（`{:set, :connections, [...]}` effect、读用 `ctx.read`，同 I-4.1 slice 先例 `apps/ezagent_plugin_kb/lib/ezagent_plugin_kb/kb.ex:80-83`），质量加权双向连接计数 = **撮合北极星 P-3.2** 数据源。记账失败要 telemetry。
  - DoD：一次被邀深聊达成 → c↔对端连接记进 slice、连接计数 +1（可查）。
- **I-13.4 改自己配置走 per-install 独立 fork_config** ↑I-13
  - 做什么：每个安装是**独立 config**（`socialware_install.ex:109-124` `persist_install_template` 每 install 落独立 SessionTemplate `installs: [install_entry]`）；用户改自己那份配置走 `conversation_actions.ex:82` `session.fork_config`（fork 自己的配置，不动别人的公开面）。
  - DoD：用户改配置只影响自己的 install；他人公开面不受影响。

**标注**：今天能做（`invite_member` + `fork_config` + slice 全在 main，`dealscout-support` 是纯 recipe）；**依赖 I-12**（先看到发言者身份才能挑着 invite）。

---

## I-14 · 平台跨用户推荐（关系网层）↑F-12

**目标**：发现层**第③腿**——跨用户实例发现 + 匹配推荐 + 朋友圈图（关系网层）。当前 DEF 级跨 workspace 发现已通（`definition_registry.ex:255` list + content-hash 寻址），但**跨用户"发现别人已发布的实例/产物"缺**——这是**平台方向**，riding registry track（#1169/#1173），dealscout 是首个真实需求方、**不阻塞**（①主动找 I-1..I-3、②别人逛公开面登录进来聊 I-11 今天能做）。

**开发点**：

- **I-14.1 缺口说明 + riding registry track（discuss-first）** ↑I-14
  - 做什么：产出一份"跨用户实例发现 + 匹配推荐 + 朋友圈图"的设计缺口说明交 Allen——现状 DEF 级发现在 `apps/ezagent_domain_session/lib/ezagent/socialware/definition_registry.ex:255`（`list/1` 跨 ws）+ content-hash 寻址 `:87`，**实例级跨用户发现缺**。这是关系网层平台方向，riding registry track（#1169/#1173，`../README.md` §4 discuss #3）。dealscout 只记需求、不自造关系网机制。
  - DoD：缺口说明交 Allen（discuss-first）；dealscout 主线不依赖此腿推进。

**标注**：**discuss-first / 缺口**（平台方向，riding registry track；dealscout 首个需求方，不阻塞主干）。

---

## I-15 · email reach out（后续）↑F-13

**目标**：把撮合/深挖结果经 email 自动 reach out。**语义错配**：现 ExternalMirror `:push` 是"session → 绑定期固定且已验证的收件人"，dealscout 要对**任意新 leads 动态群发**（每个新地址一次 bind+握手）——不直接匹配，后续另设计。

**Files（email plugin，后续）**：
- 复用 `apps/ezagent_plugin_email/lib/ezagent/email/email.ex:26`（`send/4`）+ `external_mirror.ex:142`（:push binding 三 gate + 验证握手）

**开发点**：

- **I-15.1 固定对端 threaded 对话先做** ↑I-15
  - 做什么：对**已知固定收件人**（如撮合已连接对端）用现成 `:push` binding + RFC 5322 threading（`Email.send/4`，`external_mirror.ex:142` 三 gate + inbound 验证握手）——这条完全契合现机制。
  - DoD：dealscout agent 能对一个已绑定验证过的固定对端发 threaded 邮件并收回复。
- **I-15.2 动态群发另设计（defer）** ↑I-15
  - 做什么：对任意新 leads 的动态群发（每地址一次 bind+握手）**不在本轮**——现 push 语义不匹配，要平台另设计"动态收件人 mint+握手"（`../README.md` §4 discuss，email 动态群发 defer）。本 issue 只占位，不实现。
  - DoD：/（defer 项，产出一份"动态群发 vs push 语义"的设计缺口说明交 Allen，不写代码）。

**标注**：需平台补（语义错配，后续另设计）；独立后续，不阻塞主线。

---

## §依赖与顺序

```
I-1（plugin 骨架 + 轮询 + dispatch 注入）  ← 地基，必须先做
  ├─ I-2（AI 主动发现 recipe + push）        依赖 I-1（复用爬取基建）+ I-4（profile slice）
  ├─ I-3（主动搜索 recipe）                  依赖 I-1（复用 fetch client）
  ├─ I-4（profile+关键词+token 配置）        并行：挂 I-1 的 poller/fetch 上
  ├─ I-9（数据保留 sweeper）                 并行：依赖 I-1 先出数据+批次 id
  └─ I-5（DealScoutRender + SessionView + 发现流）依赖 I-1（要有会话+数据）
        ├─ I-6（追问 recipe + Definition seed）依赖 I-5（引用 DealScoutRender）+ I-1；聚合 I-2/I-3 recipe
        │     ├─ I-7（artifact upload seam）   依赖 I-6（agent 先能跑）· 需协调
        │     └─ I-8（world tab 接线）          依赖 I-5（视图先注册）· 需协调
        └─ I-10（组合 hello+concierge Definition + 发布公开面）依赖 hello 已装 + I-5（views 链）+ I-6（Definition seed）
              └─ I-11（公开面登录写接线 复用 session_feed_channel）依赖 I-10（公开面先发布别人才逛得到）
                    ├─ I-12（founder 身份看板 + 匿名只读验证）依赖 I-11（先有登录发言可看）· 出独立 tab 依赖 I-8
                    └─ I-13（founder invite 深聊 wiring）依赖 I-12（先看到身份才挑着 invite）
I-14（平台跨用户推荐 第③腿）                  discuss-first · 缺口 · 不阻塞主干
I-15（email）                                后续，独立，不阻塞主线
```

**串行主干**：I-1 → I-5 → I-6 → I-10 → I-11（发现腿地基铺到公开面，撮合腿从公开面登录聊天长出来）。
**可并行**：I-2、I-3、I-4、I-9 都挂 I-1 的 poller/fetch/slice，互不阻塞（I-2 还需 I-4 的 profile slice、I-9 需 I-1 先出批次）。
**撮合腿次序**：I-10（组合 hello+concierge 发公开面）→ I-11（登录自助 join+发言）→ I-12（身份看板+匿名只读）→ I-13（founder invite 深聊+记账），逐级依赖。
**需协调的两个**（I-7 碰 core upload seam、I-8 碰 world Phase 3）单独排期，不卡主干 I-1→I-5→I-6→I-10→I-11 的 dev/热装推进。
**riding 现成机制（撮合换轨后）**：撮合腿 I-10/I-11/I-12/I-13 全 riding main 现成机制——组合 hello 公开面 + concierge（`router.ex:13-14` 非 owner 永远 concierge）、web 登录自助 join+post（`session_feed_channel.ex:197-228`）、匿名只读两处 gate（`:325-330` + `membership.ex:1200-1208`）、全量白板 + 身份（`external_feed.ex:85-98` / `session_feed_channel.ex:353`）、owner invite 深聊（`conversation_actions.ex:683`），**不再依赖"申请加入 / pending / admission gate"任何一环**。
**discuss-first / 缺口**：I-14 平台跨用户推荐（发现层第③腿，平台方向，riding registry track，dealscout 首个需求方不阻塞）。
**独立后续**：I-15 email 与主线无依赖。

**"今天能做"的最小可发布切片**（照 handoff Part 2）：
**I-1 爬取骨架 → I-2 AI 主动发现 / I-3 主动搜索 → I-4 配置 → I-5 视图 → I-6 recipe+Definition → I-10 组合 hello+concierge 发公开面 → I-11 登录自助 join+发言（concierge 接待）**——跑通"千人千面发现（找）+ 别人逛公开面登录进来聊（撮合）+ founder 看身份 invite 深聊"的真闭环小网络（+ I-9 数据保留并行，全在 dealscout plugin 自己文件、dev/热装零改已有代码）。I-7（agent→upload seam）、I-8（world tab）需协调；I-14（第③腿）discuss-first；I-15 后续——都不卡主干。

---

## §追溯自检

**I-n.x → F-x 映射（每个开发点唯一上游 = 所属 issue 锚点，issue 锚点 ↑ F）**：

| 开发点 | ↑ issue 锚点 | issue ↑ F | 腿 |
|---|---|---|---|
| I-1.1 / I-1.2 / I-1.3 / I-1.4 | I-1 | ↑F-1 | 发现腿 |
| I-2.1 / I-2.2 | I-2 | ↑F-2 | 发现腿 |
| I-3.1 / I-3.2 | I-3 | ↑F-3 | 发现腿 |
| I-4.1 / I-4.2 / I-4.3 | I-4 | ↑F-4 | 发现腿 |
| I-5.1 / I-5.2 / I-5.3 | I-5 | ↑F-5 | 发现腿 |
| I-6.1 / I-6.2 / I-6.3 | I-6 | ↑F-6 | 发现腿 |
| I-7.1 / I-7.2 | I-7 | ↑F-7 | 发现腿 |
| I-8.1 / I-8.2 | I-8 | ↑F-5 | 发现腿 |
| I-9.1 / I-9.2 / I-9.3 | I-9 | ↑F-1（F-1.5 数据保留） | 发现腿 |
| I-10.1 / I-10.2 / I-10.3 | I-10 | ↑F-8 | 撮合腿 |
| I-11.1 / I-11.2 / I-11.3 | I-11 | ↑F-9 | 撮合腿 |
| I-12.1 / I-12.2 | I-12 | ↑F-10 | 撮合腿 |
| I-13.1 / I-13.2 / I-13.3 / I-13.4 | I-13 | ↑F-11 | 撮合腿 |
| I-14.1 | I-14 | ↑F-12 | 撮合腿（第③腿） |
| I-15.1 / I-15.2 | I-15 | ↑F-13 | 撮合腿 |

**覆盖 F 全集确认**（F 骨架见 `../README.md` §3.5，13 项两条腿）：

| F-x | 功能 | 被哪个 I 覆盖 |
|---|---|---|
| F-1 定时+手动爬取 | ✅ I-1（爬取）+ I-9（F-1.5 数据保留 sweeper） |
| F-2 AI 主动发现 | ✅ I-2（副驾 recipe + profile 匹配 push） |
| F-3 主动搜索 | ✅ I-3（搜索 recipe + query 参数化抓取） |
| F-4 配置 profile+关键词+源+token | ✅ I-4 |
| F-5 发现流渲染 | ✅ I-5（渲染逻辑）+ I-8（world tab 冒出） |
| F-6 多轮追问 agent | ✅ I-6（追问/整理 recipe + Definition seed；追问投递链复用现成 cc） |
| F-7 artifact 生成+下载 | ✅ I-7 |
| F-8 组合 hello+concierge（公开面+客服 agent） | ✅ I-10（组合 Definition uses hello + concierge agent + 仿 hello code-seed 经 governance publish） |
| F-9 登录自助 join+发言（@orchestrator 路由 concierge） | ✅ I-11（复用 `session_feed_channel.ex:197-228` 自助 join+post，非 owner @orchestrator 路由 concierge） |
| F-10 匿名只读硬禁 + 看发言者身份 + 全量白板 | ✅ I-12（两处 gate `:325-330`/`membership.ex:1200-1208` + 身份 `:353` + 全量白板 `external_feed.ex:85-98`） |
| F-11 founder invite 深聊 | ✅ I-13（`conversation_actions.ex:683` invite_member + dealscout-support recipe + 撮合记账 slice + fork_config） |
| F-12 平台跨用户推荐（第③腿） | ✅ I-14（缺口说明 + riding registry track，discuss-first） |
| F-13 email reach out（后续） | ✅ I-15 |

- **无断链**：每个 I-n.m `↑` 所属 I-n，I-n `↑` 唯一 F-x，F-x 逐级 `↑` V→J→P（严格单亲，两条腿组织）。例：I-11 ↑ F-9 ↑ V-7 ↑ J-7 ↑ P-3.2 ↑ P-2.2 ↑ P-1.1（帮找机会的人对接根），闭合。
- **F 全集 13 项全覆盖**（发现腿 F-1..F-7、撮合腿 F-8..F-13），无遗漏；I 全集 **15 issue** 全部指向 F（无悬空 issue）——单亲追溯：I-10↑F-8 / I-11↑F-9 / I-12↑F-10 / I-13↑F-11 / I-14↑F-12 / I-15↑F-13，一致。
- **一 F 多 I 说明**：F-1 由 I-1（爬取）+ I-9（F-1.5 数据保留）两 issue 分担；F-5 由 I-5（渲染逻辑）+ I-8（world tab 接线）两 issue 分担——均为"一个 F 拆到多个可独立测试单元"的正常切分，非断链。其余 F 单 issue 覆盖。
- **两条腿标注**：发现腿（地基·找为主）I-1..I-9 ↑ F-1..F-7；撮合腿（亮点·涌现）I-10..I-15 ↑ F-8..F-13。需求方 founder / 供给方 investor 两类用户**对称走同一节点**（颜色属性，不参与父子结构）。
- **撮合换轨标注（2026-07-05 证据版）**：撮合腿 I-10/I-11/I-12/I-13 从旧版"申请加入 `#1178` admission gate（pending 私密 → owner approve_admission → 聊聊看）"**整条换成 hello 公开面聊天**——组合 hello + concierge（`router.ex:13-14` 非 owner 永远 concierge、访客到不了 builder，concierge `hello_concierge.ex:43`）、登录用户自助 join+post（`session_feed_channel.ex:197-228`）、匿名只读两处硬禁（`:325-330` + `membership.ex:1200-1208`）、founder 全量白板 + 身份（`external_feed.ex:85-98` / `session_feed_channel.ex:353`）→ owner invite 深聊（`conversation_actions.ex:683`）。旧"申请加入 / pending / admission gate"全删，撮合成功北极星口径 = **公开面真实互动 / 被邀深聊**（非申请通过数）。
- **发现层三条腿标注**：①主动找 = I-1/I-2/I-3（今天能做）· ②别人逛公开面登录进来聊 = I-11（复用 `session_feed_channel`，今天能做）· ③平台跨用户推荐 = I-14（discuss-first/缺口，riding registry track，不阻塞）。
