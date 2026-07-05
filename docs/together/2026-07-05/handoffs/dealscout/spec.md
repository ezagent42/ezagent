# dealscout (DealScout) socialware — Dev Spec

> **写作纪律**：本 spec 用 superpowers writing-plans 的上游 spec 纪律写——每条能力断言带 `file:line` 证据（基线 `upstream/main @ fe34b76d`，本 worktree 代码字节与该基线一致——citations 已现读核实）。产品输入 = `docs/together/2026-07-03/yao/dealscout/`（README 编号骨架 + product/1-4 = P/J/V/F + tech/issues-plan = I + model + spec-vs-code-gaps）+ `docs/together/2026-07-05/infra-reference/`（dev-readiness 评估）。
>
> **一句话**：DealScout = **商业 / 投融资线索的搜索与撮合平台**（deal 侦察兵：AI 千人千面发现 deal + 公开面聊天撮合），两侧都是"找机会的人"（founder 找钱 / investor 找项目，两类用户对称，非单向找 funder、非创业者撮合），两条腿——**发现腿（地基·找）**：AI 千人千面主动发现 + 主动搜索 + 爬取 + 深挖追问；**撮合腿（亮点·涌现）**：组合 hello 拿公开面 + concierge 客服，登录用户自助 join + 发言供线索，founder 看身份后 invite 深聊。技术形态 = **1 个爬取/搜索 plugin（Elixir 代码）+ 几个 recipe + 1 个组合 hello 的 Definition（纯配置数据）**。
>
> **Date:** 2026-07-05 · **Base:** `upstream/main` (`fe34b76d`)

---

## §0. 术语一句话（首现解释）

- **socialware**：一个 app 声明单元，纯数据 `Definition`（17 字段 struct，`apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex:12-28`），列出用哪些 views / roles（角色槽）/ routing_rules，经 `DefinitionRegistry` 持久化。dealscout 整体 = 一个 Definition。
- **ActionSet**（前身 Behavior，已全局改名）：能收消息干活的处理者模块，`use Ezagent.Lifecycle` 写。
- **recipe**（前身 role）：agent 的配方——一份 `%{name, prompt, requested_caps, behaviors, skills}` 数据，装到某个 flavor（cc / native / cc-headless）上长成活 agent（`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/orchestrator_recipe.ex:64-79`）。
- **flavor**：agent 的运行引擎，是 DATA 非 code。Definition 顶层**无** flavor 字段；flavor 落在 `roles` 里每个 agent 角色槽条目里（`definition.ex:34-36` type，`role_slot/1` 读取并要求 agent 槽 flavor 非空 `:282-286`，materialize 侧缺省 `"cc"`）。
- **Lifecycle state slice**：ActionSet 的运行期可变状态，`{:set, key, value}` effect 写、`ctx.read` 读，框架自动 snapshot，plugin 作者看不到底层存储。
- **CapBAC / cap**：能力位。谁能看某 view、调某 action，由持有的 cap 决定；cap **只来自 recipe 的 `requested_caps`**（Definition struct 无 `requested_caps` 字段）。
- **public_view / 公开面**：把 session 投影成匿名 + 登录非成员可读的公开页（hello 的 json-render 页）。登录用户可自助 join + 发消息，匿名只读。
- **concierge**（hello 客服 agent）：公开面接待 agent。非 owner member 的消息 @orchestrator 后**永远被路由到 concierge**（`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/router.ex:13-14`），concierge `handle_receive` 回帖（`apps/ezagent_plugin_hello/lib/ezagent/behavior/hello_concierge.ex:43`）。
- **P14 — dispatch 是 Kind 间唯一通路**：inbound 永远走 `Ezagent.Router.dispatch/1`（`apps/ezagent_core/lib/ezagent/router.ex:79`）/ legacy `Ezagent.Invocation.dispatch/1`，禁 `PubSub.broadcast` 到 inbound topic。

---

## §1. 目标（P/J 层锚点）

DealScout 交付一个**今天在 dev / 热装下能跑通的最小撮合小网络**，覆盖 README §3 的编号树 P-1.1（帮找机会的人对接根）→ 两条价值腿：

- **P-2.1 发现腿（地基·找为主，今天能做）**：
  - **J-1** 建 profile + 配置关键词 / 源 / token，自动 + 手动爬取机会流入。
  - **J-2** 浏览千人千面发现流（AI 副驾按 profile 主动推匹配机会）。
  - **J-3** 主动搜索（手动 query 全网 / 指定源）。
  - **J-4** 单条机会多轮深挖追问。
  - **J-5** 追问产出 artifact 下载。
- **P-2.2 撮合腿（亮点·涌现，riding 已在 main 的机制）**：
  - **J-6** 组合 hello 公开自己的机会页（公开面 + concierge）。
  - **J-7** 登录用户在公开面自助 join + 发言供线索（@orchestrator → concierge 回帖；匿名只读）。
  - **J-8** founder 全量白板互见 + 看发言者身份。
  - **J-9** founder invite 深聊者进私有 session。

**北极星（P-3）**：地基北极星（近期主指标·天天动 = 发现相关机会数 / 搜索满意度 / 关键词→材料转化）+ 撮合北极星（远期愿景·质量加权 = 公开面真实互动 / 被邀深聊，**不看"申请通过数"**）。

**边界（收进根）**：只做**发现 + 连接建立**，**不做**交易结算 / 尽调 / 资金托管 / 代签。

**非目标（本轮不做）**：
- I-14 平台跨用户推荐（发现层第③腿，关系网层）—— discuss-first / 缺口，riding registry track（#1169/#1173），dealscout 首个需求方但**不阻塞**。
- I-15 email 动态群发 —— push 语义错配（`:push` 是"绑定期固定且已验证收件人"，dealscout 要任意新 leads 动态群发），另设计。固定对端 threaded 可先做。

---

## §2. 组件（要建什么 / 复用什么）

### §2.1 新建（都在 `apps/ezagent_plugin_dealscout/` 自己的文件，dev / 热装零改已有代码）

| # | 组件 | 文件 | 参照先例（file:line） |
|---|---|---|---|
| C1 | 新 OTP app `:ezagent_plugin_dealscout` + plugin 契约宿主 | `mix.exs` / `lib/ezagent_plugin_dealscout/application.ex` | hello `mix.exs`；契约 `apps/ezagent_core/lib/ezagent/plugin.ex:200-257` |
| C2 | 轮询 GenServer（定时爬取） | `lib/ezagent_plugin_dealscout/poller.ex` | email `apps/ezagent_plugin_email/lib/ezagent/email/inbound.ex:57-73`（`schedule_poll` + `handle_info(:poll,_)`） |
| C3 | `:httpc` 抓取 client（治中文乱码） | `lib/ezagent_plugin_dealscout/fetch.ex` | kanban `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/miro.ex:141`（必带 `{:body_format, :binary}`） |
| C4 | 配置 slice（profile + keywords）+ token 写入 | `lib/ezagent_plugin_dealscout/config.ex` | kb slice `apps/ezagent_plugin_kb/lib/ezagent_plugin_kb/kb.ex:80-83`；token `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/github.ex:32-54`（`write_creds/1`） |
| C5 | recipe 集（发现 / 搜索 / 整理 / 追问 / 深聊辅助） | `lib/ezagent_plugin_dealscout/recipes.ex` | `orchestrator_recipe.ex:64-79`（三要素 `prompt` + `requested_caps` + `behaviors`） |
| C6 | `Ezagent.ActionSet.DealScoutRender`（cap-only render） | `lib/ezagent/behavior/dealscout_render.ex` | hello `apps/ezagent_plugin_hello/lib/ezagent/behavior/hello_render.ex:29-49` |
| C7 | SessionView module（发现流列表视图） | `lib/ezagent_plugin_dealscout/dealscout_view.ex` | hello `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/page_view.ex` |
| C8 | Definition seed（**纯数据配置**，仿 hello code-seed） | `lib/ezagent_plugin_dealscout/definition_seed.ex` | hello `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex:238`（`seed_definition_if_absent`） |
| C9 | 数据保留 sweeper（周期 GenServer） | `lib/ezagent_plugin_dealscout/retention_sweeper.ex` | `apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user/gc.ex` + `apps/ezagent_core/lib/ezagent/idempotency/sweeper.ex` |

### §2.2 复用（不新建，riding main 现成机制）

- dispatch 模型 `Ezagent.Router.dispatch/1`（`router.ex:79`）/ message_store 对话历史 / cc + cc-headless 追问 flavor（`apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/application.ex:100-112`）。
- Uploads + DownloadToken 下载链（`apps/ezagent_core/lib/ezagent/uploads.ex:99` `store!/3`；`apps/ezagent_core/lib/ezagent/uploads/download_token.ex` `mint!/2`；渲染缝 `apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex:311-343`）。
- **撮合腿全量复用 hello + web channel**（§4 详述，**正确组合 hello 即自包含可建，不需改 hello/web/core**）：join / post 表单、匿名只读两处硬禁（`session_feed_channel.ex:325-330` + `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex:1200-1208`）、全量白板 + 身份（`apps/ezagent_domain_socialware/lib/ezagent/socialware/external_feed.ex:85-98` / `session_feed_channel.ex:353`）、owner invite 深聊（`apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex:683` `invite_member`）**零改可用**；**concierge 回帖**（`router.ex:13-14` / `hello_concierge.ex:43`）也零改可用——web 层收件人 `orch_<name>`（`session_feed_channel.ex:373-375`）**不是** Definition materialize 出来的随机 UUID，而是 hello 命令式**按名重挂**的（`ensure_session_orchestrator` → `create_role_agent(ws, "orch_#{name}", ...)`，hello `app.ex:136,143`），对**任何经 world 路径建的 page session** 都补一个 `orch_<session名>` 成员（world `conversation_actions.ex:326`），跟收件人算法逐字对齐、必命中。**前提见 §4**（复制 hello 公开面配置 + 走 world 路径）。
- 发布 / 发现 / 安装链（#1164 已闭合）：`ConfigGovernance.Socialware.publish_or_upgrade/2`（`apps/ezagent_domain_session/lib/ezagent/socialware/config_governance/socialware.ex:116`）、`DefinitionRegistry.list/1`、`Installation.install_template_installs/4`。

### §2.3 边界拆分（哪些自包含、哪一处仍需协调）

- **agent→upload seam**（I-7）：**自包含，回主干**。core 有现成公开 API `Ezagent.Uploads.store!/3`（`apps/ezagent_core/lib/ezagent/uploads.ex:98`）+ 现成通用 effect `:effect_returning`（`apps/ezagent_core/lib/ezagent/behavior/effects.ex:23,236`，apply 任意 MFA、无 allowlist），dealscout 自己的 ActionSet handler 直接 CALL 存爬取产物 + emit `body.attachments`——**零改 core/world/web**（详见 Task 14）。
- **公开面 concierge 回帖**（I-11）：**自包含，无平台改动**。web 收件人 `orch_<name>`（`session_feed_channel.ex:373-375`）是 hello 命令式按名重挂的成员（`ensure_session_orchestrator`，hello `app.ex:136,143`），对任何经 world 路径建的 page session 都补上、跟收件人算法逐字对齐——不需改 hello/web/core，正确组合 hello 即通（详见 §4 前提）。
- **world tab surfacing**（I-8）：**拆两半**——(a) 注册 `DealScoutView`（`@behaviour Ezagent.UI.SessionView` + registry register）+ `dealscout_render` cap = **DECLARE，自包含**，跟 hello `PageView` 同款，留 DealScout；(b) 让它在 world 会话面板**冒成可切 tab** = 要改 world owner `switch_view` 白名单（`apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex:477`，注释明写 "registered SessionViews is Phase 3"）或建 world Phase 3 = **真越界，留 ezagent-scout**（详见 Task 15）。

---

## §3. 爬取行为（用户 2026-07-05 定，务必照此实现）

> DealScout 的"爬线索 / 搜索"**要自建入站源 adapter**（dealscout plugin 自己的活）。**注意**：现有 socialware 的 `:pull` adapter 是把 ezagent session 投影成公开面的**出站** adapter（`external_feed.ex:85-98`，"外部来读 ezagent session"），语义跟"ezagent 去抓外网"正好相反——**别误用 `:pull`**。自建入站源照 email `inbound.ex` 轮询 idiom + kanban miro `:httpc` idiom。

### §3.1 两种触发口径（source / token 有无决定爬什么）

| 场景 | 触发条件 | 爬取行为 | 线索来源类型标注 |
|---|---|---|---|
| **A. 未指定 source / token** | 用户没配任何定向源 / 凭证 | **自己爬公开网页**找线索（先固定公开源 RSS / HN，扩展到通用公开抓取） | 每条线索标 `source_type: :public` |
| **B. 指定了 source / token** | 用户在配置面填了源 URL + access token（登录源） | **公开网页 + 定向找**（用 token 注入 header 抓登录源） | 公开抓的标 `:public`，定向抓的标 `:directed` |

### §3.2 硬要求

1. **每条线索必带 `source_type` 字段**（`:public` | `:directed`），在爬取注入时写入条目 map（`fetch.ex` 出口构造条目时打标）。
2. **hello / 发现流 UI 按 `source_type` 分类展示**（`DealScoutRender` 视图渲染时按 `:public` / `:directed` 分组或加来源标签，`dealscout_view.ex` `render/1`）。
3. **token 缺失时 fail-closed**：B 场景配了定向源但无 token → 该源被**显式跳过 + telemetry**，不 silent 抓空（`fetch.ex` 读凭证失败分支）。
4. **注入走 P14**：抓回条目构造 `%Cmd{}` 经 `Ezagent.Router.dispatch/1`（`router.ex:79`）投 `session.send`；dispatch 失败要 telemetry / DLQ 兜底，不 silent drop（Ezagent "这里失败了谁会知道" 认知负担）。action URI 用 sanctioned `Ezagent.URI.with_action`（照 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/miro_sync.ex:172`），不裸拼 `?action=`。

### §3.3 三条腿（发现层）

| 腿 | 机制 | 状态 |
|---|---|---|
| ① 主动找 = AI 主动发现（按 profile 千人千面推匹配）+ 主动搜索（手动 query） | dealscout 副驾 recipe（可 cc-headless）复用爬取 / 搜索基建 | **今天能做**（本 spec 覆盖 I-1/I-2/I-3） |
| ② 公开面聊天（登录进来供线索） | hello 公开面聊天（§4） | **今天能做**（riding，本 spec 覆盖 I-10/I-11） |
| ③ 平台跨用户推荐（关系网层） | ezagent 关系网层：跨用户实例发现 + 匹配推荐 + 朋友圈图 | **缺口 / discuss-first**（本 spec 非目标） |

---

## §4. 公开面聊天（撮合腿机制 = hello 公开面聊天，非"申请加入"）

> **证据版校正**：撮合机制**不是** `#1178` admission gate——现读代码 `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex:138` `not type?(:user)` 证实 `#1178` 只 pend agent、不 pend 人类（防偷用别人 agent 刷凭证 threat X），DealScout 用不上。真实玩法 = **hello 公开面聊天**，三档读写：

| 档 | 能干啥 | 代码依据（file:line） |
|---|---|---|
| **匿名（未登录）** | **只读** public 页快照 + 下载 approved artifact；**发不了言** | web gate `session_feed_channel.ex:325-330`（anon → `nil` → `not_logged_in`，join 与 post 两处硬禁）+ domain gate `membership.ex:1200-1208`（confirmed 才授 chat cap） |
| **登录非 owner** | 自助 join + 发消息 → @orchestrator 永远路由 concierge 回帖（到不了 builder） | `session_feed_channel.ex:197-228`（`handle_participatory_join` / `handle_participatory_post`）+ `router.ex:13-14`（非 owner 结构性路由 concierge）+ `hello_concierge.ex:43` |
| **founder / owner** | 读 + 写 + 全量白板互见 + 看发言者真实身份 + invite 深聊 | 全量白板 `external_feed.ex:85-98`（`chat_messages` FULL collaborative chat）+ 身份 `session_feed_channel.ex:353`（author = 真实 principal URI）+ `conversation_actions.ex:683` `invite_member` |

**撮合流（J-6..J-9）**：founder 组合 hello 公开机会页 → 别人匿名只读发现 → 登录后自助 join + 实名发言供线索（跟 concierge 先聊清来意）→ founder 全量白板看到发言 + 身份 → founder **主动 invite** 对上的人进**另一个私有 session** 深聊 → 私密深聊 + 选择性披露 + 撮合记账。**公开发现与私密深聊是两个 session**，都 riding main。

**dealscout 侧工作量**：join / invite / 匿名只读 / 全量白板 / 身份看板都是 web + world 现成链（零改）。**concierge 回帖同样自包含可达**——上一轮判"独立 DealScout Definition 的公开面 @ 不到 hello orchestrator、concierge 永不回"是**太悲观、已推翻**。真相如下：

> **✅ 正确组合 hello 指引（撮合腿自包含可建，不需改 hello/web/core）**
>
> **关键真相**：web 收件人 `orch_<name>` **不是 Definition materialize 产物**。上一轮以为通用 materialize 落随机 UUID（`definition_agents.ex:284-288`）够不到 `orch_<session名>`——但那个 orchestrator 根本不走 materialize，它是 hello **命令式按名重挂**的：`ensure_session_orchestrator` 对**任何经 world 路径建的 page session** 都补一个 `orch_<session名>` 成员（`create_role_agent(ws, "orch_#{name}", @orch_role, @hello_flavor)`，hello `app.ex:136,143`），由 world 建 session 后调（`ensure_hello_orchestrator` → `EzagentPluginHello.App.ensure_session_orchestrator`，world `conversation_actions.ex:326,342`）。它跟 web 发帖收件人算法 `orch_<session名>`（`session_feed_channel.ex:373-375` `orchestrator_uri` → `hello_agent_uri(_, "orch_")`）**逐字对齐、必命中**。**这个 orchestrator 不被 Definition 声明、也不被 snapshot 当 worker 捕获**（它按名重挂，re-install 后照样补出来）。
>
> **两个硬前提（满足即通）**：
> 1. **DealScout Definition 复制 hello 公开面配置**——`shape` 含 `Surface` + `Turn`、`adapters` 含 `external_feed`、`visibility_policy.web_anon_access: true`、`views` 引 `hello_render` view、`uses: [:ezagent_plugin_hello]`、**带 seed 页** → 让建出来的 session 成为一个 **page session**（`page_session?/1` 认 Surface，hello `app.ex:136`），`ensure_session_orchestrator` 才不 no-op。
> 2. **建 / 装会话走 world 路径**（socialware install → `create_session`）——这样 world 的 `ensure_hello_orchestrator`（`conversation_actions.ex:326`）才会跑、才会补 `orch_<name>`。
>
> 满足这两条：**交互式建造 or snapshot re-install 都行**（orchestrator 按名重挂、不被 snapshot 当 worker 捕获）。
>
> **残余风险（诚实标）**：**不走 world 路径**（CLI / 直接建 session）**或 Definition 无 Surface / 无 seed 页** → `ensure_session_orchestrator` no-op（`:ignore`，hello `app.ex` `page_session?` 假分支）→ 不建 orchestrator → concierge 不回。**这是"前提没满足"、不是"死锁"**——满足前提即通，无需任何平台改动。
>
> **不需改 hello/web/core，纯配置组合即可**：撮合腿全部在 dealscout 自己的 Definition 配置 + 复用 hello 公开面里完成，Task 11-13 不碰 hello router / `session_feed_channel.ex` / core。

**不另起 `dealscout-support` 客服 recipe**（公开面客服 = hello concierge，复用 `hello.concierge` recipe，flavor `native`——非 `cc`）；私有深聊里的 AI 撮合辅助是另一回事，可选，由 dealscout 自己的深聊辅助 recipe 承担（I-13）。

---

## §5. 发布（今天仿 hello code-seed 经真 governance publish）

- **发布走独立 config registry（Allen 决策 #1147/#1152，有意架构选择，非缺口）**：socialware 是纯数据 Definition，**有意不打进 plugin 包**——`PluginPackage.Manifest` 的 seed_ref kind 必须 `:recipe`、**拒 `:socialware`**（`apps/ezagent_core/lib/ezagent/plugin_package/manifest.ex:174-179`，parse 时 REJECT 非静默丢弃）。plugin 包只管代码 + recipe。
- **今天的发布 = 仿 hello**：boot 时写 config map（`DefinitionRegistry.seed_definition_if_absent`，照 hello `app.ex:238`）+ 经真 governance publish（`ConfigGovernance.Socialware.publish_or_upgrade/2` `config_governance/socialware.ex:116`，内部跑 `open_cr → stage_definition → publish_cr` 全流程）。broken governance 路径会 boot 时 fail-LOUD。
- **匿名门自助、不需 admin，且不再要求 `:fixed` owner**：`visibility_policy.web_anon_access: true` 决定能不能铸只读 anon——**发布者自助**。**#1180 起 owner 与 web_anon_access 解耦**：`validate_anon_owner/2` 现是纯 `:ok` no-op（`definition.ex:432`），旧规矩"web_anon_access 必须配 `:fixed` owner（D-5）"**已作废**；owner 一律走 `owner_policy: %{type: :installer}`、由 install 时的 caller 派生（`definition.ex:176`），`:fixed` 已被拒（`:412-425`）。DealScout 的公开面就写 `web_anon_access: true` + `owner_policy: %{type: :installer}` 即可，不再声明任何 owner URI。**admin 只守全域**：只有 `scope: :public`（跨 workspace 发现）才走 admin 门（`config_governance/socialware.ex:197` `authorize_public_scope` → `:228` `authorize_admin`）。真正上公网靠**域名分配（infra 层）**，不是这 flag。
- **过 conformance gate**：`mise exec -- mix ezagent.socialware.check`（12 条有序断言，CI 接入红即非零退出）。重点过 `routing_receivers_resolve`（routing_rules 的 receiver 只能解析到已声明的**角色名**——`{:role, name}` 或裸角色名，#1180 起 URI receiver 不再放行）。
- **未来（迁移）**：registry P3（#1169/#1173）从外部 config 源发布（不写 Elixir）——见 §9 迁移标注表。

---

## §6. 安装配置（per-install 独立 + fork_config）

- **install**：`Installation.install_template_installs/4`（`apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex:72`）写 per-session install 记录；world 侧 `SocialwareInstall.prepare_create_template/4`（`apps/ezagent_plugin_world/lib/ezagent/world/socialware_install.ex:20-46`）写本地 install SessionTemplate `%{installs:[ref]}`。**per-install 独立**——别人装 DealScout 各写一份本地 install SessionTemplate + 独立 write cap（`socialware_install.ex:109-124`）。
- **配置层动作**（改关键词 / 源 / token / profile / pin）= **成员限定**（持 config cap），改自己那份配置走 `session.fork_config`（`conversation_actions.ex:82`）；改公共发布物要 manage 权限（governance）。caps 来自 recipe 的 `requested_caps`，匿名 / 房外人无此 cap。
- **今天的配置 UI 现状（务必写清）**：world 的 agent / socialware 表单（`apps/ezagent_plugin_world/lib/ezagent/world/workspace_plugin_actions.ex`）**只能填名字 + 描述**，Definition 的 config map / routing_rules / roles（角色槽）声明**无 UI 路径、只能 code-seed**；发布也无 UI（只能 code-seed 经 governance publish）。运行期配置（profile / keyword / token 经 chat action）**半通**——靠 dealscout 自己建的配置 ActionSet + chat 命令，不是 world 表单。见 §8 分类表 "今天有无 UI" 列。

---

## §7. 测试策略

### §7.1 三层测试

1. **单元 / 集成（ExUnit）**：每个 dealscout 模块（poller / fetch / config / recipe 注册 / DealScoutRender cap 注册 / Definition seed）配 ExUnit 测试。跑法从 umbrella 根：
   ```bash
   docker start ezagent-pg-compat-audit-postgres      # 先起 disposable PG
   mise exec -- mix ecto.create && mise exec -- mix ecto.migrate
   mise exec -- mix test apps/ezagent_plugin_dealscout/test              # 全 app
   mise exec -- mix test apps/ezagent_plugin_dealscout/test/path/file_test.exs:42  # 单行
   ```
   参照现有 e2e scenario 写法（substrate-level ExUnit，无 LLM）：`apps/ezagent_plugin_hello/test/integration/hello_page_e2e_test.exs`（mint anon-User + join public_view + `ExternalFeed.snapshot` 读）。
2. **conformance gate**：`mise exec -- mix ezagent.socialware.check`——Definition seed 后必须全绿（含 `routing_receivers_resolve`）。
3. **真浏览器 e2e + 截图（最高纪律，§7.2）**。

### §7.2 真浏览器 e2e（每个用户面 task 必做，禁 stub 当 e2e）

- **harness**：仓内现成 `agent-browser` CLI 无人值守 e2e（`docs/e2e/auto/run.sh` + `docs/e2e/auto/lib.sh`）。helper：`ab_login`（登录 admin@ezagent.chat / worlddev）、`ab_open <url>`、`ab_wait <selector|ms>`、`ab_click`、`ab_fill_react <sel> <val>`、`ab_submit`、`ab_eval`、`ab_shot <path>`（截图）、`assert_visible` / `assert_url` / `assert_text` / `assert_agent_reply`。`BASE_URL` 默认 `http://world.localhost:10042`。另有 Playwright chromium 录制器先例 `scripts/demo/agent-create-record.js`（chromium + 编号 PNG + webm）。
- **纪律**：起 dev server（端口 10042）→ 真登录 → 真点击 → **每个有意义步骤 `ab_shot` 截图**（配置 → chat → 操作 → 结果，非只最终帧）→ 断言真实 DOM / dispatch / agent 回帖。**禁止硬编码 / stub 当 e2e——过不了测试**。
- **产物**：每个用户面 task 的 e2e 脚本放 `docs/e2e/auto/`（或 dealscout 专属 `apps/ezagent_plugin_dealscout/test/e2e/`），截图放 e2e 输出目录，命名带 task 号 + 步骤号。

### §7.3 每个 task 的测试方法（见 §8 分类表末列 + plan 每 task 的测试步骤）

---

## §8. 代码 vs 配置 分类表（硬要求 1）

> **① 写代码** = dealscout plugin 里的 Elixir（爬取 GenServer / adapter / render ActionSet / recipe / seed 逻辑 / sweeper），或碰 core / world 的 Elixir。
> **② 提交配置** = socialware Definition 的 config map（`uses` / `roles`（角色槽）/ `routing_rules` / `visibility_policy` / `bases` / `shape` / `views` 声明式数据）。
> **③ 复用验证** = 零新代码 / 零新配置，riding main 现成机制，只做接线 + e2e 验证。

| Issue | 内容 | 分类 | 今天有无 UI | 测试方法 |
|---|---|---|---|---|
| **I-1** 爬取 plugin 骨架 | ①代码 | plugin app + poller + fetch + dispatch 注入 | N/A（后端） | ExUnit（`process_record` 式单测，注入 dispatch_fun seam）+ dev 起 server 看 poller tick |
| **I-2** AI 主动发现 recipe + push | ①代码 | recipe 声明（Elixir `roles/0`）+ profile 匹配 push | N/A（后端 recipe） | ExUnit（recipe 进 RecipeRegistry）+ e2e：给 profile 看发现流按 profile 排序 |
| **I-3** 主动搜索 recipe | ①代码 | recipe + query 参数化 fetch | N/A | ExUnit + e2e：chat 发 query → 结果落发现流 |
| **I-4** 配置（profile+keyword+token） | ①代码 | config slice + `write_creds` token 存储 | **半通**（chat action 可改，world 表单不支持 Definition 级配置） | ExUnit（slice 读写 + snapshot）+ e2e：chat 改 profile → 重启还在 |
| **I-5** DealScoutRender + SessionView + 发现流 | ①代码 | cap-only render ActionSet + view module + json-render 页 | N/A（视图代码） | ExUnit（cap 无冲突注册 + view 注册）+ **真浏览器 e2e**（session tab 渲染发现流 + 分类展示 + 截图） |
| **I-6** 追问 recipe + Definition seed | ①代码（recipe）+ **②配置（Definition seed）** | recipe = Elixir；Definition = 纯数据 config map | Definition **无 UI**（只能 code-seed） | ExUnit（recipe 注册 + Definition 进 registry）+ conformance gate + e2e：建 session → 发现腿 agent 自动 materialize |
| **I-7** artifact → upload seam | ①代码（**自包含 CALL，回主干**） | dealscout handler 返 `{:effect_returning, {Ezagent.Uploads, :store!, [ws,name,tmp]}, [], bind_as: :uri}` 存产物 → emit `body.attachments:[{:ref,:uri}]`（`message.ex:60`），零改 core/world/web | N/A | ExUnit（seam 登记 upload + `body.attachments` 透传不被清空 `message.ex:43-44`）+ e2e：追问产出 → 会话显示可下载附件 → 匿名经 `/socialware/external/download` 下载 + 截图 |
| **I-8** world tab 接线 | **拆两半**：(a) 注册 view = ①代码自包含；(b) world 冒 tab = 越界留 ezagent-scout | (a) `DealScoutView` register + `dealscout_render` cap（跟 hello `PageView` 同款）；(b) 改 world `switch_view` 白名单 `conversation_actions.ex:477` 或 world Phase 3 | **(a) 无 UI 但内容可渲染；(b) 才让它冒 tab** | (a) ExUnit（view 注册 + render 分类）；(b) **真浏览器 e2e**（world 切到 dealscout tab）**留 scout** |
| **I-9** 数据保留 sweeper | ①代码 | 周期 GenServer + pin slice | N/A（后端）+ pin action 半通 | ExUnit（造 >10 批次 sweep 后只剩 10 + pin 留存）+ e2e：pin 一批后不被 sweep |
| **I-10** 组合 hello Definition + 发布 | **②配置** | Definition config map（uses hello + roles 含 concierge 角色槽 + visibility_policy）；仿 hello code-seed 发布 | Definition + 发布**无 UI**（code-seed 经 governance publish） | ExUnit（Definition 进 registry + publish 成功）+ conformance gate + **真浏览器 e2e**（匿名访问公开面只读 + 截图） |
| **I-11** 公开面登录写接线 | **③复用验证** | 复用 `session_feed_channel` 自助 join / post，零新代码 | 有 UI（web 公开面 composer） | **真浏览器 e2e**（登录用户自助 join → 发消息 → concierge 回帖 + 每步截图） |
| **I-12** 身份看板 + 匿名只读验证 | **③复用验证**（+ 看板视图 code 在 I-5） | 复用两处 gate + 全量白板 + 身份 | 有 UI（world owner 看板） | **真浏览器 e2e**（匿名 post 被拒 + owner 看到发言者身份 + 截图） |
| **I-13** founder invite 深聊 | ①代码（dealscout-support recipe + 记账 slice）+ ③复用（invite） | recipe + slice = Elixir；invite = 复用 world | 有 UI（world invite 按钮） | ExUnit（recipe 注册 + slice 记账）+ **真浏览器 e2e**（owner invite 发言者 → 私有 session 深聊 + 截图） |
| **I-14** 平台跨用户推荐 | —（design doc，discuss-first） | 缺口说明交 Allen，非本轮代码 | N/A | 无（design-only，非目标） |
| **I-15** email reach out | ①代码（后续） | 固定对端 threaded 复用 `:push`；动态群发另设计 | N/A | ExUnit（固定对端 threaded）；动态群发 defer |

**统计**：
- **①写代码**：I-1、I-2、I-3、I-4、I-5、I-6（recipe 部分）、I-7、I-8、I-9、I-13（recipe+slice 部分）、I-15 = **11 个 issue 含代码**。
- **②提交配置**：I-6（Definition seed）、I-10（主 Definition config）= **2 个 issue 是配置**（I-10 纯配置，I-6 代码+配置混）。
- **③复用验证**：I-11、I-12、I-13（invite 部分）= **2-3 个 issue 纯复用验证**。
- **配置类今天有无 UI**：Definition 级配置（I-6 seed / I-10）**今天无 UI，只能 code-seed**；运行期配置（I-4 profile/keyword/token 经 chat）**半通**（dealscout 自建 chat action，world 表单不支持）；world 表单（`workspace_plugin_actions.ex`）只能填名字+描述、发布无 UI 路径。**结论：绝大多数配置今天没 UI，本轮走 code-seed / chat-action，UI 化等 registry P1 catalog。**

---

## §9. 迁移标注表（硬要求 2 — 哪些等 main 更新要迁移）

> 每个受影响 issue 标 "⚠️ main 到 X 后迁移 Y"。写代码时按前瞻兼容口径落，避免返工。

| main 更新 | 是什么 | 受影响 issue | ⚠️ 迁移动作 | 前瞻兼容口径（今天怎么写就不返工） |
|---|---|---|---|---|
| **✅ role-slot 已落地（#1180）** | Definition 只准声明"角色槽"，退休 `members`、禁参与者/owner 实例 URI（`definition.ex` 三个 enforce 点：`reject_retired_declaration_fields` `:313-318`、`reject_participant_instance_uris` `:323-366`、`owner_policy` 拒 `:fixed` `:412-425`） | **I-6、I-10、I-13**（凡写 Definition roles / routing_rules 的） | **无需迁移——已落地**，直接用新 API | **直接用 `roles` 声明角色槽**：agent 槽 `%{role_name, fill: :agent, recipe, flavor}`、human 槽 `%{role_name, fill: :human}`（`definition.ex:34-36`）；routing receivers 用 `{:role, name}`（只认已声明角色名）；`owner_policy: %{type: :installer}`（`:fixed` 被拒）。**绝不塞参与者/owner 实例 URI，也别再用退休的 `agents`/`members` 字段。** |
| **registry P2 统一安装** | homesite 建 session 统一走"装 socialware"这一条路（分发 plan §6 P2） | **I-10**（install path） | ⚠️ main 到 P2 后建 session 收敛进标准安装路 | 今天走 `Installation.install_template_installs/4` + per-install SessionTemplate（`socialware_install.ex:109-124`）；P2 后把 DealScout 建 session 迁进统一安装路——工程整洁，非阻塞 |
| **registry P3 外部 config 源发布** | Definition 住独立 config-repo，deploy 时 seed / 跨环境 promote（分发 plan §5 / §6 P3；#1169/#1173 已落 P0） | **I-6、I-10**（发布 path） | ⚠️ main 到 P3 后从 dir 发布（不写 Elixir seed） | 今天仿 hello code-seed（`app.ex:238` + governance publish）；P3 后把 Definition 从"插件 imperative seed"迁到"registry 版本化分发"——更硬的分发，非前置 |
| **registry P1 catalog 发现 UI** | 把薄 dropdown 升级成真 catalog（搜索 / 详情 / 版本史 / from-catalog 安装，`world_live.ex:704`） | I-10 发现面 + §8 配置 UI 缺口 | ⚠️ main 到 P1 后 DealScout Definition 在平台目录被浏览 / 搜到 | 今天 discover 走 `DefinitionRegistry.list/1` + world `socialware_rows/1`；P1 是更好的分发面，叠加非前置 |

**统计**：**role-slot（#1180）已落地、不再是迁移项**（原标 I-6 / I-10 / I-13 直接按新 `roles` API 写）；**仍待迁移的只剩 registry P1 / P2 / P3**——I-10 标 P1 + P2 + P3、I-6 标 P3。**共 3 类未落地 main 更新（P1 / P2 / P3）。**

---

## §10. 依赖与最小可发布切片顺序

**串行主干**（发现腿地基铺到公开面，撮合腿从公开面登录聊天长出来）：

```
I-1 爬取骨架 → I-5 视图 → I-6 recipe+Definition seed → I-10 组合 hello 发公开面 → I-11 登录自助 join+发言
```

**可并行**（都挂 I-1 的 poller / fetch / slice）：I-2（AI 主动发现，需 I-4 profile slice）、I-3（主动搜索）、I-4（配置）、I-9（数据保留，需 I-1 先出批次）。

**撮合腿次序**：I-10 → I-11 → I-12（身份看板 + 匿名只读）→ I-13（invite 深聊 + 记账），逐级依赖。

**边界拆分**：I-7（upload seam）**自包含 CALL、回主干**（`Uploads.store!` + `:effect_returning`，零改 core/world/web）；I-8 **拆两半**——(a) 注册 view + render 自包含留主干、(b) world 冒 tab 越界留 ezagent-scout。

**最小可发布切片（今天能做，跑通"千人千面发现（找）+ 别人逛公开面登录进来聊（撮合）+ founder 看身份 invite 深聊"的真闭环）**：

```
I-1 → I-4 → I-2 / I-3 → I-5 → I-6 → I-10 → I-11 → I-12 → I-13   (+ I-9 数据保留并行)
```

全在 dealscout plugin 自己文件、dev / 热装零改已有代码。I-7 自包含回主干；I-8(a) 注册 view 回主干、I-8(b) world 冒 tab 留 ezagent-scout；I-14 discuss-first；I-15 后续——都不卡主干。

---

## §11. 追溯（spec ↔ 编号骨架）

本 spec 各 §锚到 README §3 的 P/J/V/F/I 编号树：§1 目标 = P/J；§3 爬取行为 = F-1/F-2/F-3 + I-1/I-2/I-3/I-4；§4 公开面聊天 = F-8..F-11 + I-10..I-13；§5 发布 = F-8.4 + I-10；§6 安装配置 = F-11.3 + I-6/I-10；§8 分类表 = I-1..I-15；§9 迁移表 = infra dev-readiness 评估的 role-slot（#1180 已落地）/ P1 / P2 / P3。plan（`2026-07-05-dealscout-plan.md`）把每个 I 拆成 TDD task，逐 task 引 P/J/V/F/I 编号。
