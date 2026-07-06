# dealscout（DealScout）socialware —— 入口文档 + 权威编号源

> **⚠️ 返工修订（2026-07-06 用户拍板，覆盖本文中一切相抵触的旧文；完整 banner 见同目录 spec.md / plan.md 顶部）**
>
> 层级 **plugin → socialware → ezagent**。DealScout 是 **socialware（纯配置组合）**，唯一真 plugin = 爬取后台。职责重划：**dealscout = 后台数据 + 更新信号**（爬取 plugin + 它的 agent 爬完注入新线索后 emit `__dealscout_update__`，`Ezagent.ActionSet.DealScoutCrawl.update_signal/0`，像 kanban 的 `__done__`）；**hello = 显示 + concierge**（hello 的 agent 收信号更新 json-render 页）。**dealscout 不声明任何 view / render**——下文凡出现 `DealScoutRender` / `DealScoutView` / "dealscout 自己的发现流 SessionView / world tab" 的设计**已删除、作废**（原 I-5 显示件归 hello；I-8 / F-4 world-tab 议题随之消失）。DealScout Definition（Stage D 已落地 `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/definition_seed.ex`）：`uses: ["hello","dealscout"]`、`views: [Ezagent.ActionSet.HelloRender]`（hello `PageView` 以此认领渲染，零改 hello）、`routing_rules` 用 `text_contains("__dealscout_update__")` → 已声明角色 `"page"`（内容协议 routing 像 kanban relay，零实例 URI）。下文与此抵触处一律按本 banner 为准。


> **一句话**：DealScout = **一个商业 / 投融资线索的搜索与撮合平台**（名字 = **deal 侦察兵**，主动发现投融资 + 商业机会）。核心 = **AI 千人千面发现 deal（找为主）+ 公开面聊天撮合（亮点）**；**两侧都是"找机会的人"**——需求方 founder（找钱、找路演、找商机）和供给方 investor（找项目、找标的、找情报出口）对称，**不是**单向"帮谁找 funder"、也**不是**"创业者撮合"。两类用户都用同**两条腿**：**发现腿**（地基·AI 千人千面**主动发现** + **主动搜索**机会，今天就能做）和**撮合腿**（涌现的亮点·**组合 hello 拿公开面 + concierge 客服**，登录用户在公开面**自助 join + 发言供线索**、founder 看到发言者身份后 **invite 他进私有 session 深聊**）。产品取向是 **找为主、撮合为亮点、北极星分期**。技术上 = **1 个爬取/搜索 plugin（自定义 token 绕登录，自建入站源 adapter）+ 几个自定义 recipe（含 AI 主动发现/搜索/追问）+ 组合 hello 的公开面 + concierge 客服 + 1 个自定义视图，拼成一个 Definition 发布**。
>
> **Date:** 2026-07-03（2026-07-04 撮合根重构 → 2026-07-05 找为主重构 → **2026-07-05 撮合腿证据版校正**）· **Base:** upstream/main `90e8ee29`（file:line 实读核实，HEAD `8814547d` 现读复核）
> **改进模型权威源**：`../../2026-07-05/handoffs/dealscout-code-review-and-dev-plan.md` Part 2/3（yujun 交易模型审 + 用户 2026-07-05 定稿）。找为主重构把 DealScout 从"双边撮合网络（撮合当地基）"改成"**发现副驾为地基 + 撮合为涌现亮点**"。**本次（证据版校正）**：撮合腿机制**从"#1178 申请加入私有 session"改成"hello 公开面聊天"**——现读代码确认 `#1178` admission gate 是 agent 门（防偷用别人 agent 刷凭证），DealScout 用不上；真实玩法是 DealScout 组合 hello 拿公开面 + concierge 客服，登录用户自助 join+发言、匿名只读、founder 主动 invite 深聊（`session_feed_channel.ex:197-228,325-330` / `router.ex:13-14` / `conversation_actions.ex:683`）。
> **文档地图**：本文=入口 + 编号骨架 · `model.md`=支撑概念模型（session/权限/保留/撮合机制）· `product/1-4`=P/J/V/F 编号树 · `tech/issues-plan.md`=I 层开发 issue · `spec-vs-code-gaps.md`=给 Allen 的规范 vs 代码 handoff · `../dev/independent-dev-feasibility.md`=独立开发者三条路。

---

## 0. 产品目标（用户描述）

**地基（发现·找为主）**：每日自动 + 手动命令，探查全网/指定源的关键词相关新闻/投融资/路演/商机 →（新增）**AI 副驾按用户 profile 千人千面主动发现、主动推匹配机会** +（新增）**主动搜索**（手动 query 全网/指定源）→ 视图展示（session tab 嵌入，可发布成公开面）→ 单条信息源可多轮深入追问 → 追问后生成 artifact（材料/模板/素材）供下载 → 支持自定义 access token 探查需登录源 → 后续融合 email 自动 reach out → **一切在 chat 完成**。**注意**：现有 socialware 的 `:pull` adapter 是"把 session 投影成公开面"的**出站** adapter（ezagent_domain_socialware），**不是入站爬虫**——DealScout 的"爬线索/搜索"要**自建入站源 adapter**（dealscout plugin 自己的活，照 email `inbound.ex` / kanban miro httpc idiom）。

**亮点（撮合·涌现）**：撮合**不当地基、当发现之上涌现的亮点**。机制 = **hello 公开面聊天**（不是 `#1178` 申请加入私有 session——那是 agent 门、防偷用别人 agent 刷凭证，DealScout 用不上）：DealScout **组合 hello** 拿到公开面 + **concierge 客服 agent**（`router.ex:13-14`：非 owner member 永远路由 concierge、访客到不了 builder、不为访客发 LLM 调用；`hello_concierge.ex:43` 回帖）→ **登录用户**在公开面**自助 join + 发消息**（`session_feed_channel.ex:197-228`；post @orchestrator → 非 owner 永远路由 concierge 客服回帖），**能聊、能供线索**；**匿名只读不能写**（`session_feed_channel.ex:325-330` + `membership.ex:1200-1208` 两处硬禁）→ **founder 本人**也在同一 session，**全量白板互见**（`external_feed.ex:85-98`），想跟真人聊也行 → founder **看到发言者身份**（登录=真实 URI 带用户名，`session_feed_channel.ex:353`），**想深聊就 invite 他进私有 session**（`conversation_actions.ex:683`，owner 主动拉，不是申请人申请）→ 私密深聊 → 撮合成功记账。

**发现层三条腿**（解 yujun"没有发现层"红线）：① **主动找**（AI 搜索/发现，今天能做，发现腿核心）② **公开面聊天**（登录用户在公开面自助 join+发言、founder invite 深聊，今天能做，撮合腿；riding hello 组合面 + `session_feed_channel` 自助 join/post + concierge + `invite_member`）③ **平台跨用户推荐**（关系网层：跨用户实例发现 + 匹配推荐 + 朋友圈图；缺口/discuss-first，riding registry track，dealscout 首个需求方不阻塞）。

**两类用户对称**：需求方 founder / 供给方 investor **都是"找机会的人"**，都用发现腿 + 撮合腿。所以"需求 / 供给"是**贯穿属性（颜色标签）**，不是树的分层——同一个 J/V/F 节点两类用户对称地走。

> **功能 × 现状（能拼/要新建，file:line）** 见 `product/4-features.md`（拼装权威，已 file:line 核实）+ `model.md`（撮合机制 = **hello 公开面聊天**，非 `#1178` 申请加入）。

---

## 1. 最小组件清单（要建什么）

**新建（都在 `apps/ezagent_plugin_dealscout/` 自己的文件里，dev/热装零改已有代码）**：
1. **plugin `ezagent_plugin_dealscout`**：`children/0` 挂轮询 GenServer（`:httpc`+`body_format: :binary`，照 `email/inbound.ex:58` / `miro.ex:141`）；手动触发 action；token 存储用 kanban `write_creds` idiom（`github.ex:32-54`）；`roles/0` 声明 recipe；`config_surface/0` 给 world nav 入口。
2. **recipe 集**（发现腿 + 撮合腿）：
   - 发现腿：**AI 主动发现**（按 profile 千人千面匹配推送，新增，可用 cc-headless）/ **主动搜索**（手动 query 全网/指定源，新增，cc-headless）/ **信息整理**（native）/ **多轮追问**（cc）。
   - 撮合腿：**组合 hello 的 concierge 客服**（复用 hello 的 concierge，不新写——`router.ex:13-14` 保证访客只跟 concierge 聊、到不了 builder；`hello_concierge.ex:43` 回帖）。DealScout 只需在 Definition 里把 hello 的 concierge 组合进来，不另起客服 recipe。
   - 各自 `prompt`+`requested_caps`+`behaviors`；flavor 是每个 agent 角色槽的必填字段（#1180 role-slot，flavor 在 `Definition.roles` 每个 `fill: :agent` 条目里、**Definition 顶层无 flavor 字段**，`definition.ex:282-286`、type `:34-36`、materialize 侧缺省回填 "cc" `definition_agents.ex:321-326`）；非 cc 是否 runnable 待验，起步可统一 cc。
3. **`Ezagent.ActionSet.DealScoutRender`**（cap-only，唯一 `:dealscout_render` action，照 `hello_render.ex:29`）+ **1 个 SessionView module**（发现流列表视图，照 `page_view.ex`）——**两者都住 dealscout plugin，Definition 只引用模块名**（规范：render/view 必须住 plugin，`definition.ex:148-154`）。
4. **1 个 Definition**（代码 seed，**零代码纯数据、只引用 dealscout plugin + hello 的模块**）：`views:[Ezagent.ActionSet.DealScoutRender]`、`roles:[发现腿 recipe + hello concierge，每个是 %{role_name, fill: :agent, recipe, flavor}]`（**agent 角色槽——只声明角色，绝不塞实例 URI**，flavor 真被读、真路由，#1180 `definition.ex:34-36,282-286` + materialize `definition_agents.ex:61,241-246`）、`bases/shape/views` union 拿到 hello 的公开面能力（**组合靠 `installs` merge `definition_editor.ex:63` + 单 def bases/shape/views union `definition.ex:124`**，**`uses` 只声明"依赖 hello 这个 plugin 已装"、不是组合轴**，`manifest_resolver.ex:41`）、`visibility_policy:%{web_anon_access: true, scope: :private}`、`owner_policy:%{type: :installer}`（**只准 `:installer`——`:fixed` owner 已被 #1180 拒**，owner 在 install 时由 caller 派生 `definition.ex:176`）。Definition 是 **17 字段** struct（`definition.ex:12-28`，无顶层 flavor）。**caps 不在这里——全来自 recipe**（Definition struct 里根本没 `requested_caps` 字段）。**撮合腿两个硬前提（concierge 回帖靠这两条）**：(1) 这份 Definition **复制 hello 公开面配置**——`shape` 含 `Surface`+`Turn`、`adapters` 含 `external_feed`、`web_anon_access:true`、引 `hello_render` view、**带 seed 页** → 让建出来的 session 成 **page session**；(2) **建/装会话走 world 路径**（socialware install→`create_session`）。满足这两条，hello 的 `ensure_session_orchestrator`（`app.ex:136,143`）就对该 page session 按名重挂 `orch_<name>` 客服前台、跟 web 收件人算法逐字对齐（`session_feed_channel.ex:373-375`）。**不走 world 路径或无 Surface/seed 页 → orchestrator 不建 → concierge 不回**（前提不是死锁）。
5. **agent 产出→upload seam**（**自包含、回主干**）：dealscout 自己的 handler 返 `:effect_returning` CALL core 现成公开 API `Ezagent.Uploads.store!/3`（`uploads.ex:98`）存产物 + emit 带 `body.attachments`（`message.ex:60`），零改 core/world/web。
6. **world tab 接线**（**拆两半**）：(a) 注册 `DealScoutView`（`@behaviour Ezagent.UI.SessionView`）+ render = 自包含留主干；(b) 让它在 world 冒成可切 tab = 改 world owner `switch_view` 白名单（`conversation_actions.ex:477`，world zero-consume SessionView registry）或 world Phase 3 = 越界、留 ezagent-scout。

**复用（不新建）**：dispatch 模型、message_store 对话历史、cc/cc-headless 追问、Uploads+DownloadToken 下载链、Surface+json-render catalog 页面生成、anon_view_caps+authorize_view 匿名门、RecipeRegistry/DefinitionRegistry/conformance gate、credential 各档存储、email push（固定对端）、**撮合腿 = 组合 hello 的公开面 + concierge**（`router.ex:13-14` 访客只跟 concierge 聊 + `hello_concierge.ex:43` 回帖）、**公开面自助 join/发言**（web `session_feed_channel.ex:197-228`：登录用户 `handle_participatory_join`/`handle_participatory_post`；匿名 `:325-330` 两处硬禁）、**owner invite 深聊**（world `conversation_actions.ex:683` `invite_member`）——撮合腿直接 riding 这些机制，**不再是缺口**。

> **对齐官方规范**（`docs/guide/socialware-authoring-interim.md`，#1153）：socialware = **零代码的纯 `Definition` 数据**，只**引用** plugin 的 behaviors/views/recipes 并配置组合。所有代码（DealScoutRender/SessionView/recipe/爬取/搜索逻辑）都住在 **dealscout plugin** 里；撮合面复用 **hello plugin** 的公开面 + concierge；dealscout Definition 本身不含一行代码。三条纪律：① 代码全进 plugin ② Definition 是 DATA ③ 经 `DefinitionRegistry` 持久化、agent config 经 CR-governance。**caps 只来自 recipe——Definition 从不声明 `requested_caps`**（17 字段 struct 里根本没这个字段，`definition.ex:12-28`）。

> **架构拼装判定**：用户设想（1 爬取/搜索 plugin + 几个 recipe + 组合 hello 拿公开面拼接发布）**成立**——爬取/搜索 plugin（自建入站源 adapter）✅、自定义 recipe ✅、组合 hello 公开面 + concierge + 发布 ✅（#1164 已闭合发布/发现/安装链）、**撮合 = hello 公开面聊天 ✅**（登录自助 join+发言 `session_feed_channel.ex:197-228`、匿名只读 `:325-330`、非 owner 路由 concierge `router.ex:13-14`、founder invite 深聊 `conversation_actions.ex:683`）——**concierge 回帖也自包含可达**（web 收件人 `orch_<name>` 是 hello 命令式按名重挂、非 materialize 随机 UUID，`app.ex:136,143` / world `conversation_actions.ex:326`，见 §"撮合腿两个硬前提"）。剩接线：upload seam（**自包含 CALL 回主干**）、world 冒 tab（**越界那半留 ezagent-scout**）、定时轮询 GenServer（dealscout 自己代码）。**详见 `spec-vs-code-gaps.md`**。

---

## 2. 分步 Plan（PR-sized，标"今天能做"vs"等收口"）

| 步 | 做什么 | 腿 | 层 | 依赖 |
|---|---|---|---|---|
| **F1** 爬取/搜索 plugin 骨架 | 新 plugin + 轮询 GenServer（先固定公开源如 RSS/HN）+ 手动触发 action + token 存储 | 发现腿 | 新 plugin | **今天能做**（dev/热装） |
| **F1b** AI 主动发现 + 主动搜索 | 千人千面 profile 匹配推送（发现）+ 手动 query（搜索），复用爬取基建 + recipe | 发现腿 | 新 plugin | **今天能做**（发现层第①腿） |
| **F2** recipe + Definition seed | `roles/0` 声明发现腿 recipe（flavor per-agent，flavor 在 `roles` 的 agent 槽条目 `definition.ex:282-286`）+ 组合 hello concierge + `after_boot` 仿 hello code-seed（config map + governance publish）含 `roles` 角色槽的 Definition | 两腿 | 新 plugin | 今天能做；非 cc runnable 待验 |
| **F3** DealScoutRender + SessionView + 视图 | cap-only render ActionSet + SessionView + json-render 发现流页（走 Surface）| 发现腿 | 新 plugin | 今天能做 |
| **F4** world tab 接线（**拆两半**） | (a) 注册 `DealScoutView` + render；(b) 让它在 world 冒可切 tab | 发现腿 | (a) 新 plugin / (b) 碰 world | **(a) 今天能做（自包含）；(b) 越界留 ezagent-scout**（`switch_view` 白名单 `conversation_actions.ex:477` / world Phase 3） |
| **F5** artifact 下载 seam | dealscout handler `:effect_returning` CALL `Uploads.store!/3`（`uploads.ex:98`）→ emit `body.attachments`（`message.ex:60`）→ world 通用渲染缝 mint 下载链（`conversation_data.ex:331-336`）→ 匿名下载（`external_feed_controller.ex:61`） | 发现腿 | 新 plugin（**零改 core/world/web**） | **今天能做（自包含 CALL）** |
| **F6** 组合 hello 发布公开面 + 匿名只读 | `uses:[:ezagent_plugin_hello]`（声明依赖）+ bases/shape/views union 拿公开面 + concierge；`visibility_policy.web_anon_access: true` + anon view cap → 匿名只读可看（发布者自助、不需 admin，只有 scope:public 跨 ws 发现才要 admin `socialware.ex:197,228`）| 撮合腿入口 | 新 plugin Definition | F3 后 |
| **F7** 公开面登录写 + concierge + invite 深聊 | 复用 `session_feed_channel.ex:197-228` 登录自助 join/post（非 owner @orchestrator→concierge 回帖 `router.ex:13-14`）；匿名只读硬禁 `:325-330`；founder 看身份 `:353` → `invite_member` 拉进私有 session `conversation_actions.ex:683`。**concierge 回帖两个硬前提**：Definition 复制 hello 公开面配置成 page session（带 Surface+seed 页）+ 走 world 路径建会话（world 补 `orch_<name>`，`app.ex:136,143`） | 撮合腿 | riding hello + session_feed_channel | **今天能做**（自包含、不需改 hello/web/core；换掉旧"#1178 申请加入"） |
| **F8** email reach out（后续） | 固定对端 threaded 先做；动态群发另设计 | 撮合腿 | email plugin | 后续 |
| **F9** 平台跨用户推荐（第③腿） | 关系网层：跨用户实例发现 + 匹配推荐 + 朋友圈 | 撮合腿 | 平台方向 | **缺口/discuss-first**（riding registry track） |

**"dealscout 是首个真实用户"的两条**：① Definition.views→anon_view_caps→authorize_view 这条链 hello 没走（hello Definition 没写 views 键），**dealscout 会是首用者**（F3/F6 跑通、顺带验证 T2 views 设计）；② dealscout 是**第一个把 hello 公开面聊天（组合 hello + concierge + 登录自助 join/发言 + founder invite 深聊）用成真撮合流**的 socialware（F7）。

---

## 3. 编号骨架（traceability index）—— 权威编号源

> 全套产品↔技术文档的**权威编号源**。**类 mindmap：每个节点恰有一个上游父节点（`↑`），从根逐层派生**——不是阶段并列，是思考推导。
> **重构说明（2026-07-05，找为主）**：上一版（2026-07-04）把 DealScout 的根定成"撮合"，硬拆需求侧/供给侧两条链、在多父 M 弥合点交汇。本版按改进模型重构——
> - **根从"撮合"改成"帮找机会的人对接"**：地基是**发现副驾（找）**，撮合是**涌现的亮点**（不吞掉、但不当地基）。
> - **层 2 从"撮合谁"改成"两条价值腿"**：发现腿（地基）/ 撮合腿（亮点）。
> - **北极星分期**：地基北极星（近期主指标，天天动）/ 撮合北极星（远期愿景，质量加权）。
> - **需求 / 供给降级为贯穿属性（颜色标签）**，不再是树的分层——两类用户对称走同一节点。**因此 tree 恢复严格单亲**，不再需要多父 M 节点（弥合概念保留，见 §3.8，机制 = **hello 公开面聊天**）。
> - **撮合腿证据版校正（2026-07-05）**：撮合机制**从"#1178 申请加入私有 session"改成"hello 公开面聊天"**——现读代码确认 `#1178` admission gate 是 agent 门、DealScout 用不上；真实玩法 = 组合 hello 公开面 + concierge + 登录自助 join/发言 + founder invite 深聊。J/V/F/I 撮合腿节点相应换轨（见 §3.9）。
> 底层模型：`model.md`（session 角色 / 权限两层 / 保留 / 撮合机制 = hello 公开面聊天）。

### 3.1 编号规则

- **前缀**：P=定位→北极星 · J=用户旅程 · V=视图与操作 · F=功能点 · I=开发 issue。
- **格式**：`前缀-层.序`（例 `P-1.1`；`I-1.2`=第1个issue的第2个开发点）。
- **唯一上游 `↑`**：每节点恰一个父。同前缀跨层向上；跨文档在衔接处向上（J↑P-3、V↑J、F↑V、I↑F）。构成一棵从"帮找机会的人对接"到"issue"的推导树。
- **颜色属性（非层）**：🔵需求（founder 找钱）/ 🟢供给（investor 找项目）是标在节点上的**贯穿颜色**，标注"这个节点两类用户怎么对称地走"，**不参与父子结构**。

### 3.2 P · 定位→北极星（product/1）—— 从"帮找机会的人对接"根逐层推导

**层 1 · 根（无上游）**
- **P-1.1** 帮"找机会的人"对接：投融资/找机会场景里，找钱的 founder 和找项目的 investor 都在"找机会"，中间隔着信息不对称 + 连接成本高。DealScout 用 **AI 千人千面发现副驾（地基·找）** 帮每个人把机会搜齐挖透，并让**撮合作为涌现的亮点**（组合 hello 公开面 + concierge、登录进来发言供线索、founder invite 深聊）自然长出来。**边界**（收进根）：只做**发现 + 连接建立**，**不做**交易结算/尽调/资金托管/代签。

**层 2 · 两条价值腿（↑ P-1.1）**
- **P-2.1** ↑P-1.1 **发现腿（地基）**：AI 千人千面**主动发现**（按 profile 推匹配机会）+ **主动搜索**（全网/指定源 query）+ 爬取 + 深挖追问 + 产出材料。两类用户对称（🔵找钱线索 / 🟢找项目线索），**今天就能做**（发现层第①腿）。
- **P-2.2** ↑P-1.1 **撮合腿（亮点·涌现）**：**组合 hello 拿公开面 + concierge 客服** → 登录用户在公开面**自助 join + 发言供线索**（非 owner @orchestrator 永远路由 concierge 回帖，`router.ex:13-14`）→ 匿名只读（`session_feed_channel.ex:325-330`）→ founder 在同一 session 全量白板互见、看发言者身份 → founder **invite 对上的人进私有 session 深聊**（`conversation_actions.ex:683`，owner 主动拉）→ 撮合记账。双向对称（founder↔访客角色可互换），riding hello 公开面聊天（发现层第②腿）。

**层 3 · 北极星（分期，↑ 对应腿）**
- **P-3.1** ↑P-2.1 **地基北极星（近期·主指标，天天动）**：发现的相关机会数 / 搜索满意度 / 关键词→可用材料的转化率 & 时间。地基有没有兑现，天天能量。
- **P-3.2** ↑P-2.2 **撮合北极星（远期·愿景，质量加权）**：**撮合成功数 = 公开面真实互动 / 被邀深聊**——用可观测硬代理衡量（公开面登录用户持续发言互动 / founder 发出 invite 深聊 / 进私有 session 后双向确认 / 下游 email thread 动起来），**不看"申请通过数"这类漏斗前段指标**（旧 `#1178` admission 通过数作废），**不用 owner 自报"标记成功"**（可刷）。撮合作为涌现亮点的长期愿景指标。

### 3.3 J · 用户旅程（product/2；两条腿组织，🔵需求/🟢供给作颜色）

**发现腿旅程（↑P-3.1，两类用户对称）**
- **J-1** 建 profile + 配置关键词/源/token、**自动 + 手动爬取机会流入** ↑P-3.1
- **J-2** 浏览**千人千面发现流**（副驾按 profile 主动推匹配机会）↑P-3.1
- **J-3** **主动搜索**机会（手动 query 全网/指定源）↑P-3.1
- **J-4** 单条机会深挖追问 ↑P-3.1
- **J-5** 追问产出 artifact 下载 ↑P-3.1

**撮合腿旅程（↑P-3.2，双向对称 = 交汇点）**
- **J-6** **组合 hello 公开自己的机会页**（公开面 + concierge 客服，让别人能发现、访客改不了页只跟 concierge 聊）↑P-3.2
- **J-7** 登录用户在公开面**自助 join + 发言供线索**（发消息 @orchestrator → 非 owner 路由 concierge 回帖；匿名只读不能写）↑P-3.2
- **J-8** founder 本人在同一 session **全量白板互见 + 看发言者身份**（想跟真人聊也行）↑P-3.2
- **J-9** founder **invite 深聊者进私有 session**（owner 主动拉对上的人，私密深聊 → 撮合记账）↑P-3.2
- **J-10** email reach out（后续，对已连接对端外联）↑P-3.2

### 3.4 V · 视图与操作（product/3；V-x ↑ 对应 J）
**发现腿视图**
- **V-1** 发现流视图（千人千面机会列表）↑J-2 · **V-2** 单条机会详情 + 追问 ↑J-4 · **V-3** 配置面板（profile+关键词+源+token+**爬取触发**）↑J-1 · **V-4** 搜索面板 ↑J-3 · **V-5** artifact/下载区 ↑J-5

**撮合腿视图**
- **V-6** 公开机会页视图（hello 页 + concierge 聊天框）↑J-6 · **V-7** 公开面聊天视图（登录写 composer / 匿名只读）↑J-7 · **V-8** founder 身份看板（谁在发言 + 身份 + 全量白板）↑J-8 · **V-9** invite 深聊面（owner 拉人进私有 session）↑J-9

### 3.5 F · 功能点（product/4；F-x ↑ 对应 V）
**发现腿功能**
- **F-1** 定时 + 手动爬取 ↑V-3 · **F-2** **AI 主动发现**（千人千面 profile 匹配推送，新增）↑V-1 · **F-3** **主动搜索**（全网/指定源 query，新增）↑V-4 · **F-4** 配置：profile+关键词+源+token ↑V-3 · **F-5** 发现流渲染 ↑V-1 · **F-6** 多轮追问 agent ↑V-2 · **F-7** artifact 生成下载 ↑V-5

**撮合腿功能**
- **F-8** 组合 hello + concierge 拿公开面 ↑V-6 · **F-9** 登录用户公开面**自助 join + 发消息**（非 owner @orchestrator 永远路由 concierge）↑V-7（换掉旧"#1178 申请加入"）· **F-10** 匿名只读硬禁（web+domain 两处 gate）+ 发言者身份显示 ↑V-8 · **F-11** founder **invite 深聊**（`invite_member` 拉进私有 session）↑V-9 · **F-12** 平台跨用户推荐（关系网层，discuss-first/缺口，发现层第③腿）↑V-6 · **F-13** email reach out（后续）↑V-6

### 3.6 I · 开发 issue（tech/issues-plan；每 issue ↑ 一个 F）
**发现腿**
- **I-1** 爬取 plugin 骨架 ↑F-1 · **I-2** AI 主动发现 recipe + push ↑F-2 · **I-3** 主动搜索 recipe ↑F-3 · **I-4** 配置（profile+关键词+token 存储）↑F-4 · **I-5** DealScoutRender+SessionView+发现流 ↑F-5 · **I-6** 多轮追问 agent + Definition seed ↑F-6 · **I-7** artifact→upload seam ↑F-5（自包含 CALL，回主干）· **I-8** world tab 接线 ↑F-4（(a) 注册 view 自包含 / (b) world 冒 tab 留 scout）· **I-9** 数据保留 sweeper ↑F-1

**撮合腿**
- **I-10** 组合 hello + concierge 的 Definition seed + 发布公开面（仿 hello code-seed 经 governance publish）↑F-8 · **I-11** 公开面登录写接线（复用 `session_feed_channel` 自助 join/post）↑F-9（换掉旧"#1178 申请加入" I-11）· **I-12** 身份看板 + 匿名只读验证（两处 gate）↑F-10 · **I-13** invite 深聊 wiring（owner 拉进私有 session）↑F-11 · **I-14** 平台跨用户推荐 ↑F-12（discuss-first/缺口）· **I-15** email（后续）↑F-13

### 3.7 追溯自检（每份文档末尾必附）
- **严格单亲树**：每节点恰一个 `↑`、只指上一层、非 issue 必有子。**需求/供给是颜色属性、不参与父子结构**，所以不再有多父节点（上一版的多父 M 弥合点已随"撮合当根"一起退役）。
- 每个 issue 逐级 ↑ 回到 **P-1.1（帮找机会的人对接根）**，无断链。例：I-11（公开面登录写接线）↑ F-9（登录自助 join+发消息）↑ V-7（公开面聊天视图）↑ J-7（登录公开面自助 join+发言供线索）↑ P-3.2 ↑ P-2.2 ↑ P-1.1。
- 节点数：P 5 · J 10 · V 9 · F 13 · I 15。

### 3.8 撮合腿 = 交汇点（弥合概念保留，机制 = hello 公开面聊天）
上一版把"撮合发生的地方"画成多父 M 弥合点（需求侧链 + 供给侧链在公开面登记处交汇）。本版**弥合概念保留、机制和结构都换**：

- **交汇发生在撮合腿（P-2.2 及其下游 J-6..J-9 / V-6..V-9 / F-8..F-11）**，不再是独立多父节点。因为需求/供给降级成颜色属性，**同一个撮合腿节点两类用户对称地走**——founder 发布公开面（J-6）、访客登录后自助 join+发言（J-7）、founder 看身份并 invite 深聊（J-8/J-9），角色可互换。这就是"双方在撮合腿交汇"。
- **机制 = hello 公开面聊天**（不是 `#1178` 申请加入——现读代码确认 `#1178` admission gate 是 agent 门、防偷用别人 agent 刷凭证，DealScout 用不上）：DealScout 组合 hello 拿公开面 + concierge 客服（`router.ex:13-14`：非 owner member 永远路由 concierge、访客到不了 builder；`hello_concierge.ex:43` 回帖）；登录用户在公开面自助 join + 发消息（`session_feed_channel.ex:197-228`），发的消息 @orchestrator → 非 owner 路由 concierge → 客服回帖；匿名只读不能写（`session_feed_channel.ex:325-330` + `membership.ex:1200-1208` 两处硬禁）；founder 全量白板互见（`external_feed.ex:85-98`）、看发言者身份（`session_feed_channel.ex:353`）→ invite 对上的人进私有 session 深聊（`conversation_actions.ex:683`，owner 主动拉）。
- **数据落地**：撮合腿 = 一个组合了 hello 的公开面 session（public_view）+ founder 想深聊时另拉的私有 session。访客在公开面登录后自助成员、发言供线索；founder 主动 invite 才把对上的人拉进私有 session 深聊。见 `model.md`（撮合机制 = hello 公开面聊天）。

### 3.9 重构记录（2026-07-04 版 → 2026-07-05 找为主版 → 2026-07-05 撮合腿证据版校正）
| 上一版 | 问题（改进模型指出） | 本版 |
|---|---|---|
| 根 = 撮合（matchmaking） | 撮合当地基过重；真正天天用的是发现（找）| 根 = 帮找机会的人对接；**地基 = 发现副驾，撮合 = 涌现亮点** |
| 层 2 = 需求侧/供给侧两条链 | 两类用户对称、都用同两条腿，硬拆成两条链是错的分层 | 层 2 = **两条价值腿**（发现腿/撮合腿）；需求/供给降级为**颜色属性** |
| 多父 M 弥合点（M-1/M-2/M-3）| 因"撮合当根 + 供需拆链"才需要多父交汇 | 退役；交汇内化进**撮合腿**（严格单亲，见 §3.8）|
| 撮合机制 = 公开面访客登记 + agent 策展（07-04）| 公开广播有隐私/信噪问题（yujun）| 一度改 `#1178` admission gate → **证据版再校正为 hello 公开面聊天**（见下行）|
| 撮合机制 = `#1178` 申请加入私有 session（07-05 找为主版）| 现读代码：`#1178` admission gate 是 agent 门、防偷用别人 agent 刷凭证，DealScout 用不上 | **hello 公开面聊天**：组合 hello 公开面 + concierge（`router.ex:13-14`）+ 登录自助 join/发言（`session_feed_channel.ex:197-228`）+ 匿名只读（`:325-330`）+ founder invite 深聊（`conversation_actions.ex:683`）|
| 北极星 = 单条撮合北极星（双向连接数）| 撮合是远期愿景，拿来当唯一近期指标会误导 | **分期**：地基北极星（近期主指标·天天动）+ 撮合北极星（远期愿景·质量加权 = 公开面真实互动/被邀深聊，非申请通过数）|
| 旧 F-9 访客登记 / `#1178` 申请加入 / 旧 I-11 | 机制换轨（两次）| F-9 登录自助 join+发言 / F-10 匿名只读+身份 / F-11 founder invite 深聊；I-11 公开面登录写接线 |

---

## 4. Discuss-first（给 Allen）

dealscout 触及的平台侧协调项 + 缺口，**详见 `spec-vs-code-gaps.md`** 与 `tech/issues-plan.md`：

1. ~~**agent-facing upload seam**~~（F-5 / I-7）——**已不是缺口**：core 有现成公开 `Uploads.store!/3`（`uploads.ex:98`）+ 通用 effect `:effect_returning`（`effects.ex:23,236`），dealscout handler 直接 CALL、零改 core/world/web（自包含，回主干）。
2. **world 冒 tab（Phase 3，只这半是缺口）**（F-4 / I-8）——**拆两半**：注册 `DealScoutView` + render 是自包含（dealscout 自己做）；只有让它在 world 会话面板**自动冒 tab** 才碰 world owner（`switch_view` 白名单 `conversation_actions.ex:477`，world zero-consume SessionView registry / world Phase 3），这半留 ezagent-scout、排期。
3. **平台跨用户推荐（发现层第③腿）**（F-12 / I-14）——跨用户实例发现 + 匹配推荐 + 朋友圈图（关系网层），是平台方向，riding registry track（#1169/#1173）。dealscout 是首个真实需求方，标 discuss-first，**不阻塞**（①主动找、②公开面聊天 今天能做）。
4. **dealscout 当 Definition.views 匿名链首个 conformance example**——hello 没走这条链（毛边），dealscout 走它能顺带验证 T2 的 views/anon_view_caps/authorize_view 端到端。
5. **声明式打包缺口是 Allen 有意绕过、不是"待补"**：纯数据 Definition 打不进 plugin 包的 manifest（`PluginPackage.Manifest` 拒 `:socialware` seed，seed_ref kind 必须 `:recipe`）——这是 **Allen 决策 #1147/#1152** 的有意架构选择：**socialware 走独立 config registry**（ConfigStore + governance + discover + install），plugin 包只管代码 + recipe。dealscout 照此走"代码进 plugin + Definition code-seed 经 governance publish"，不等打包通道。

> **撮合不再是缺口**：撮合腿 = hello 公开面聊天（组合 hello 公开面 + concierge + 登录自助 join/发言 + 匿名只读 + founder invite 深聊），全部 riding 已在 main 的机制（`router.ex:13-14` / `session_feed_channel.ex:197-228,325-330` / `conversation_actions.ex:683`），**不再是缺口**。

---

## 5. 与主线的关系

- **不阻塞、不依赖官网上线**：发现腿 F1-F3 + 撮合腿 F6/F7 今天在 dev/热装下能做（新 plugin 自己的文件 + 组合 hello 公开面聊天，riding 已在 main 的机制）。
- **等 socialware 收口的只有"纯数据上传"**——但这是 Allen 有意让 socialware 走独立 config registry（#1147/#1152），dealscout 用代码 seed（仿 hello，config map + governance publish）绕过，不等。
- **反过来喂养收口**：dealscout 是 Definition.views 匿名链的**真实需求方**（upload seam 已用 core 现成 API 自包含解决、world 只剩"冒 tab"那半是 Phase 3），撮合腿又是 **hello 公开面聊天（组合 hello + concierge + 公开面登录写 + invite 深聊）的首个产品化组合用户**，正好给平台提供动机和验收用例。
