# dealscout · 产品文档 4：具体功能点（F 层）

> **一句话**：dealscout 是"帮找机会的人对接"的 AI 网络，两条价值腿——**发现腿（地基·找）**和**撮合腿（亮点·涌现）**。本文把这两条腿拆成 **13 个功能锚点**：发现腿 7 个（F-1..F-7），撮合腿 6 个（F-8..F-13）。每个功能锚点 `↑` 上游一个 V（视图与操作），再拆成 2-4 个**具体功能点**，每点都标清"复用现有能力 `file:line`"还是"要新建"、以及它属于 dealscout plugin 的哪一块。
>
> **两条腿**（对齐 `../README.md §3.5`）：
> - **发现腿**（↑P-2.1 地基·今天能做）：F-1 定时+手动爬取 · **F-2 AI 主动发现（新增）** · **F-3 主动搜索（新增）** · F-4 配置（profile+关键词+源+token） · F-5 发现流渲染 · F-6 多轮追问 agent · F-7 artifact 生成下载。
> - **撮合腿**（↑P-2.2 亮点·涌现）：F-8 组合 hello+concierge 拿公开面 · F-9 登录用户公开面自助 join+发消息 · F-10 匿名只读硬禁+发言者身份显示 · F-11 founder invite 深聊 · **F-12 平台跨用户推荐（第③腿，discuss-first/缺口）** · F-13 email reach out（后续）。
>
> **颜色属性（非分层）**：🔵需求（founder 找钱/找机会）/ 🟢供给（investor 找项目/找情报出口）是标在每个节点上的**贯穿颜色**——两类用户**对称地走同一个 F 节点**，不参与父子结构（`../README.md §3.1`）。
>
> **撮合机制换轨（重构记录）**：
> - **2026-07-05a（`#1178` 版，已退役）**：撮合 = "别人**申请加入**私有 session → `#1178` admission gate 落 `:pending_members`（私密、无 cap、不 mount）→ owner 审核 `approve_admission` → 私密聊聊看"。
> - **2026-07-05b（证据版，本版）**：`#1178` 那套是**过度设计**——`#1178` 本是 agent 门（防偷用别人 agent 刷凭证），DealScout 用不上。**换成 hello 公开面聊天**：DealScout **组合 hello** 拿公开面 + **concierge 客服 agent**（`router.ex:13-14` 非 owner member 永远路由 concierge、访客到不了 builder、不为访客发 LLM 调用）；**登录用户**公开面**自助 join+发消息**（`session_feed_channel.ex:197-228`，@orchestrator → concierge 回帖）、**匿名只读硬禁**（`session_feed_channel.ex:325-330` + `membership.ex:1200-1208` 两处）、founder **全量白板互见**（`external_feed.ex:85-98`）+ **看到发言者身份**（`session_feed_channel.ex:353`）→ **owner 主动 invite** 深聊者进私有 session（`conversation_actions.ex:683`，**owner 主动拉、不是申请人申请**）。旧 F-9 申请加入 / F-10 owner 审核 / F-11 聊聊看+撮合记账（连同 `#1178` / `:pending_members` / `approve_admission` / owner 审核箱 / 访客登记 那套）**已退役**，换成 F-8 组合面 / F-9 登录自助 / F-10 匿名只读+身份 / F-11 founder invite 四节点重排。
>
> **追溯**：本文是 **F 层**，每个功能锚点 `↑` 上游 V-x（`product/3-views-operations.md`，尚未落地时按 `../README.md §3.4` 骨架 V-1..V-9 引用）；下游是 **I 层**开发 issue（`tech/issues-plan.md`），每个 issue `↑` 一个 F。底稿是 `../README.md §3`（编号骨架权威）+ `../../../2026-07-05/handoffs/dealscout-code-review-and-dev-plan.md` Part 1（socialware 全流程代码审阅，已 file:line 核实）。
>
> **对齐官方 socialware 规范（#1153）**：socialware = **零代码的纯 Definition 数据**，只引用 plugin 的 behaviors/views/recipes；**所有代码（DealScoutRender / SessionView / recipe / 爬取/搜索逻辑）都住在 dealscout plugin 里**，dealscout Definition 本身不含一行代码；**caps 只来自 recipe**——Definition 从不声明 `requested_caps`（struct 里没这个字段）。Definition struct 是 **17 个字段**（`apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex:12-28`：name / version / title / description / uses / bases / shape / views / roles / assets / routing_rules / prompt_templates / legends / orchestrator_template_uri / adapters / visibility_policy / owner_policy），**顶层没有 flavor 字段**——flavor 落在 `roles` 里每个 agent 角色槽条目里（`definition.ex:282-286`，type `:34-36`，materialize 侧缺省 `"cc"` `definition_agents.ex:321-326`）。**#1180 把旧 `agents` 字段改名 `roles`、退休了 `members` 字段**（原来 agents+members 两个字段并成一个 `roles`）——`roles` 每条要么是 agent 槽 `%{role_name, fill: :agent, recipe, flavor}`、要么是 human 槽 `%{role_name, fill: :human}`；`owner_policy` 只准 `%{type: :installer}`（`:fixed` 已被拒）。**纯数据 Definition 打不进 plugin 包不是"待补的缺口"，是 Allen 有意的架构选择（决策 #1147/#1152）**：socialware 走**独立 config registry**（ConfigStore + governance + discover + install），plugin 包只管代码 + recipe（`PluginPackage.Manifest` 明确拒 `:socialware` seed，seed_ref kind 必须是 `:recipe`）。

---

## 名词一句话（首现解释）

- **ActionSet**：action 的处理者模块，用 `use Ezagent.Lifecycle` 写，是 ezagent 里"能收消息干活"的单元（历史名 Behavior，已全局改名 ActionSet）。
- **recipe**：agent 的"配方"——一份声明 `prompt + requested_caps + behaviors + skills` 的数据，装到某个 flavor（cc / native…）上就长成一个活 agent（历史名 role）。
- **Definition**：socialware app 的"清单"——纯数据，列出这个 app 用哪些 views / roles（角色槽）/ routing_rules，经 DefinitionRegistry 持久化。dealscout 整体就是一个 Definition。
- **Lifecycle state slice**：ActionSet 的运行期可变状态，用 `{:set, key, value}` effect 写、`ctx.read` 读，框架自动 snapshot，plugin 作者看不到底层存储。
- **CapBAC / cap**：能力位。谁能看某个 view、谁能调某个 action，都由持有的 cap 决定。
- **public_view / 公开面**：把一个 session 投影成匿名 + 登录非成员可读的公开页（hello 的 json-render 页）。登录用户可自助 join + 发消息，匿名只读。撮合就发生在这个公开面上（不在私有 session）。
- **concierge（hello 客服 agent）**：公开面的接待 agent。非 owner member 的消息 @orchestrator 后**永远被路由到 concierge**（`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/router.ex:13-14`：访客到不了 builder、也不为访客发 LLM 调用），concierge `handle_receive` 回帖（`apps/ezagent_plugin_hello/lib/ezagent/behavior/hello_concierge.ex:43`）。这是撮合腿"公开面聊天"的接待底座（换掉旧 `#1178` admission gate）。
- **invite_member（owner 主动 invite）**：founder 在公开面看到值得深聊的发言者后，**主动把对方拉进一个私有 session** 深谈（`apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex:683`）。是 owner 主动拉，不是申请人申请。

---

## 发现腿

## F-1 · 定时 + 手动爬取 ↑ V-3（配置面板触发爬取）🔵🟢

把"每天定时抓 + 用户在 chat 里手动喊一嗓子就抓"落地。**全套先例，新建但零改已有代码。** 两类用户对称（🔵爬找钱线索 / 🟢爬找项目线索）。

- **F-1.1 定时轮询 GenServer**：起一个周期性 tick 的 GenServer，到点就跑一次爬取。**复用**现有轮询 idiom `apps/ezagent_plugin_email/lib/ezagent/email/inbound.ex:63,72`（`handle_info(:poll, …)` → `Process.send_after(self(), :poll, poll_interval_ms())`，仓里没有 cron 框架，这是标准写法）。**属**：dealscout plugin 的 `children/0` 里挂这个 GenServer。
- **F-1.2 `:httpc` 抓外网 + 中文治乱码**：直连公开源（先固定一个如 RSS/HN）拉数据。**复用** kanban 的 `:httpc` 写法 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/miro.ex:141,143`——**必带 `{:body_format, :binary}`**，否则 `:httpc` 把 body 返成 charlist 会让中文乱码。**属**：dealscout plugin 的爬取模块。
- **F-1.3 手动触发 action（chat 命令）**：用户在对话里发一条命令就立刻爬一次。**复用** dispatch 唯一通路 `apps/ezagent_core/lib/ezagent/router.ex:79`（`Router.dispatch(%Cmd{})`）。**属**：dealscout plugin 自己的 ActionSet 里加一个 `:crawl_now` 之类的 action。
- **F-1.4 抓回数据注入发现流**：爬到的条目通过 dispatch 灌进 session（当成一条 `session.send`）。**复用** `Ezagent.Invocation.dispatch/1`。**要新建的注意点（拼装现状澄清）**：现有 socialware 的 `:pull` adapter 是**把 ezagent session 投影成公开面的出站 adapter**（`apps/ezagent_domain_socialware/lib/ezagent/socialware/external_feed.ex:85-98` `chat_messages` 一带，"外部来读 ezagent session 状态"），**不是入站爬虫**——语义跟"ezagent 去抓外网线索"正好相反。所以 DealScout 的"爬线索/搜索"要**自建入站源 adapter**（dealscout plugin 自己的活，照 email `apps/ezagent_plugin_email/lib/ezagent/email/inbound.ex` 轮询 idiom / kanban miro `:httpc` idiom），**别误用 `:pull`**。**属**：dealscout plugin 爬取模块的出口（自建入站源）。
- **F-1.5 数据保留（爬取数据不无限膨胀）**：一次配置→定时+手动爬取，数据持续流入 KB slice，要有保留策略防膨胀。**策略**：默认保留**最近 10 次爬取**（或最近 1 个月，取先到者，保信息新鲜）+ **可选 pin 某几次长期保存**（pin 是配置层动作、成员限定，见 F-4）。**dealscout 自建 sweeper**（非平台缺口）：一个周期 GenServer（`Process.send_after` 照 F-1.1 idiom）扫 KB slice、丢弃超期且未 pin 的爬取批次——**照** `apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user/gc.ex` + `apps/ezagent_core/lib/ezagent/idempotency/sweeper.ex` 的周期清扫先例。每次爬取批次在 slice 里有批次 id + pin 标记。**属**：dealscout plugin 保留 sweeper 模块（新建，零改已有代码）。

---

## F-2 · AI 主动发现（千人千面 profile 匹配推送，**新增**）↑ V-1（发现流视图）🔵🟢

**发现腿核心（发现层第①腿的"发现"半）**：不是等用户搜，而是 AI 副驾**按用户 profile 千人千面主动匹配**，把最相关的机会推到发现流顶部。两类用户对称（🔵按 founder profile 推匹配的钱/机会 / 🟢按 investor profile 推匹配的项目/标的）。**新增功能锚点**——复用爬取基建 + recipe，把"抓回的原始流"过一遍 AI 匹配再排序推送。

- **F-2.1 AI 主动发现 recipe（可用 cc-headless）**：一个按 profile 打分/匹配的配方——读用户 profile（F-4.1）+ 爬回的原始流，产出"这条为什么匹配你"的千人千面推送。**复用** recipe 三要素声明 `apps/ezagent_plugin_cc/lib/ezagent/orchestrator/orchestrator_recipe.ex:65,69,71`（`prompt: persona()` + `requested_caps` + `behaviors`）；搜索/匹配算力用 cc-headless flavor（Python SDK sidecar 版）。**属**：dealscout plugin 的 `roles/0` 声明这个"发现 recipe"。
- **F-2.2 复用爬取基建当输入**：主动发现不另起数据源——直接吃 F-1 爬回、落 KB slice 的原始机会流。**复用** F-1.4 的注入出口 + slice 读（`ctx.read`）。**属**：dealscout plugin 发现 recipe 的输入侧。
- **F-2.3 匹配结果推进发现流**：把 AI 匹配打过分的条目经 dispatch 推进发现流（当成一条带 `match_score`/`why` 元数据的 `session.send`）。**复用** F-1.4 的 `Ezagent.Invocation.dispatch/1` 注入出口 + slice 写 `{:set, :discoveries, …}`（照 `apps/ezagent_plugin_kb/lib/ezagent/behavior/kb.ex:119,135` snapshot-metadata slice 先例）。**属**：dealscout plugin 发现 recipe 的输出侧。
- **F-2.4 profile 是匹配依据**：主动发现读的 profile 就是 F-4.1 配置面里存的（关注方向/阶段/地域…）。**复用** F-4 的 profile slice。**属**：跨接 F-4 配置。

---

## F-3 · 主动搜索（全网/指定源手动 query，**新增**）↑ V-4（搜索面板）🔵🟢

**发现腿核心（发现层第①腿的"搜"半）**：用户在搜索面板打一句 query（"最近关注具身智能的早期基金"），副驾**主动搜全网/指定源**，即时返回一批候选。跟 F-2 的差别：F-2 是**副驾主动推**（被动接收），F-3 是**用户主动搜**（主动 query）。两类用户对称（🔵搜钱/机会 / 🟢搜项目/标的）。**新增功能锚点**——复用爬取基建 + recipe（搜索用 cc-headless）。

- **F-3.1 搜索 action（收 query）**：一个 action 收用户输入的 query，触发一次即时搜索。**复用** dispatch 通路 `apps/ezagent_core/lib/ezagent/router.ex:79` + 爬取模块的 `:httpc` 通道（F-1.2，带 `{:body_format, :binary}`）。**属**：dealscout plugin 的搜索 ActionSet。
- **F-3.2 主动搜索 recipe（cc-headless）**：把 query 拆成搜索策略、跑全网/指定源、整理候选。**复用** recipe 三要素声明 `apps/ezagent_plugin_cc/lib/ezagent/orchestrator/orchestrator_recipe.ex:65-71`；用 cc-headless flavor 跑搜索算力。**属**：dealscout plugin 的 `roles/0` 声明这个"搜索 recipe"。
- **F-3.3 搜索结果回发现流/搜索面**：搜到的候选经 dispatch 回投到搜索面（或临时并入发现流）。**复用** F-1.4 注入出口。**属**：dealscout plugin 搜索模块出口。
- **F-3.4 指定源 + token 复用配置**：搜索需登录源时用 F-4 存的 token。**复用** F-4.4 的凭证读取通道。**属**：跨接 F-4 配置。

---

## F-4 · 配置：profile + 关键词 + 源 + token ↑ V-3（配置面板）🔵🟢

让用户能设"我是谁（profile）/ 我关心哪些关键词 / 哪些源 / 探查需登录源用哪个 token"，且**运行期可改**。**用 state slice + 凭证存储，无需新机制。** 这些都是**配置层 cap、成员限定、群聊提交**——只有持配置 cap 的房间成员能改，动作以会话消息落进 session（认证=session 成员身份，见 `../model.md`）。**token 是配置层的一个字段**——与关键词同逻辑：只有配置成员能填/改，匿名/房外人不可见、不可改。profile 是 F-2 主动发现的匹配依据。

- **F-4.1 profile + 静态默认关键词进 recipe config**：出厂默认的一组关键词/源 + profile schema，作为配方的 layer-2 数据。**复用** kanban 把结构化数据塞进 recipe config 的写法 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex:99-103`（`config: %{…}`）。**属**：dealscout plugin 的 recipe 声明。
- **F-4.2 运行期可变 profile/关键词 → Lifecycle state slice**：用户改 profile/关键词，写进 agent 的可变状态、自动 snapshot、重启不丢。**复用** `{:set, :profile, …}` / `{:set, :keywords, …}` effect + `ctx.read` 读回的先例 `apps/ezagent_plugin_kb/lib/ezagent/behavior/kb.ex:119,135`（kb 存元数据同款）。**属**：dealscout plugin 的配置 ActionSet。
- **F-4.3 配置读写 action**：一个 action 收"设 profile/设关键词/设源"、一个读回当前配置给视图展示（+ 给 F-2 主动发现读 profile）。**复用**上面同一套 slice 读写。**属**：dealscout plugin 配置 ActionSet 的 action 面。
- **F-4.4 token 写入凭证存储**：把用户填的 token 落到 `system://credentials/<x>.yaml`。**复用**最简先例 kanban `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/github.ex:35,54`（`write_creds/1`，admin-gated，照 token_store idiom）。**属**：dealscout plugin 的 token 存储模块。
- **F-4.5 保存 token UI action**：配置面板里"保存 token"按钮触发一个 action 写凭证。**复用**同上 `write_creds` 通道。**属**：dealscout plugin 配置 ActionSet。
- **F-4.6 爬取/搜索时读取凭证注入请求**：爬取/搜索模块从凭证存储读 token，塞进 `:httpc` 请求头（绕过登录墙探查需登录源）。**复用** F-1.2 的 `:httpc` 通道 + 凭证读取。**属**：dealscout plugin 爬取/搜索模块。

---

## F-5 · 发现流视图渲染 ↑ V-1（发现流视图 / session tab）🔵🟢

把发现流（爬回 + AI 匹配的机会）在 session tab 里渲染成一个列表页。**视图机制已就位，但渲染器/视图 module 要自己建（规范要求 render/view 必须住 plugin）。**

- **F-5.1 `DealScoutRender` ActionSet（cap-only）**：一个只管"看的权限门"的 ActionSet（唯一 action `:dealscout_render`），不是真渲染器。**照** `apps/ezagent_plugin_hello/lib/ezagent/behavior/hello_render.ex:32,46`（`def actions, do: [:dealscout_render]` + cap-only；`:dealscout_render` 名唯一，避开 `{Session, :hello_render}` / `:kanban_render` 冲突，`CapabilityRegistry.check_conflict!` 会对撞名 RAISE）**新建**。**属**：dealscout plugin，Definition 只写模块名引用它。
- **F-5.2 SessionView module（发现流列表）**：真正决定列表页长什么样的视图 module。**照** `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/page_view.ex`（PageView）**新建**——不能直接复用，因为 PageView 的 action 名唯一、且只匹配 `:hello` 类型 session。**属**：dealscout plugin，Definition.views 只引用模块名。
- **F-5.3 授权门 authorize_view**：谁能看这个视图由 cap 决定。**复用** 统一 cap 门 `apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view.ex:121`（`authorize_view/3`）；Definition 把 DealScoutRender 放进 `views:` 字段后，`behaviors/1`（`apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex:124-130`）会把它拼进 spawn 的 behavior 集并注册 render cap。**属**：dealscout Definition 的 `views:` 数据 + 复用平台门。
- **F-5.4 world tab 接线**：让注册好的 SessionView 在 world UI 里自动冒出一个 tab。**要新建/需协调**：world tab 现在把 chat/pty/page 硬编码，注册的 SessionView 不会自动冒 tab——`apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex:475` 注释明写"surfacing of registered SessionViews is Phase 3"。**属**：碰 world 已有代码（非 dealscout 自己文件），需协调 world owner / Allen。

---

## F-6 · 多轮追问 agent ↑ V-2（单条机会详情 + 追问视图）🔵🟢

对某一条机会源反复深挖、多轮追问。**现成，无需新机制**——对同一个 agent URI 连发 `session.send` 就是追问。两类用户对称（🔵追问某笔投融资的细节 / 🟢追问某个项目的背景）。

- **F-6.1 cc / cc-headless flavor 现成**：真 Claude brain，两种 flavor（PTY TUI 版 cc、Python SDK sidecar 版 cc-headless）。**复用** `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/application.ex:100,103,112`（`agent_flavors/0`，`"cc"` / `"cc-headless"`）。**属**：dealscout recipe 装到 cc flavor 上（今天统一 cc，见 F-6.4）。
- **F-6.2 投递链 session.send → agent :receive**：追问消息经 dispatch 投到 agent 的接收缝。**复用** `apps/ezagent_domain_agent/lib/ezagent/behavior/agent/receive.ex:198`（`handle_receive/2` 投递接缝）+ AgentBridge 门面。**属**：全复用平台投递链，dealscout 不碰。
- **F-6.3 多轮上下文**：让 agent 记得前几轮聊了啥。**复用**两条现成：cc-headless 的 SDK resume（`apps/ezagent_plugin_cc/.../sdk_sidecar.ex:97`）+ session DB 历史（`message_store.ex:142` 的 `recent_in_session`）。**属**：全复用。
- **F-6.4 追问回应 recipe 声明**：一个"追问回应"配方。**复用** recipe 三要素声明 `apps/ezagent_plugin_cc/lib/ezagent/orchestrator/orchestrator_recipe.ex:65,69,71`（`prompt: persona()` + `requested_caps` + `behaviors`）。**属**：dealscout plugin 的 `roles/0` 回调声明这个 recipe。✅ **per-agent flavor 现在能声明（#1180 role-slot 已落地，2026-07-05 核实）**——agent 角色槽 type 含 `flavor`（`definition.ex:34-36`），`role_slot/1`（`definition.ex:275-303`）**读取并要求** agent 槽 flavor 非空（`:282-286`），materialize 一路透传（`definition_agents.ex:321-326` `flavor_of` 缺省回填 `"cc"`）。所以发现腿几个 recipe 想跑不同 flavor（native 整理 / cc-headless 搜索发现 / cc 追问）**声明层今天成立**；**唯一运行时口子**是非 cc flavor 是否真 runnable（cc 是今天唯一双 hook 齐的），起步可统一 `"cc"` 无碍。

---

## F-7 · artifact 生成 + 下载 ↑ V-5（artifact / 下载区）🔵🟢

追问深挖后，agent 产出一份材料/模板/素材，用户能下载。**下载链已全就位，缺一个"agent 产出→登记 upload"的缝。**

- **F-7.1 uploads 存储**：把文件存进平台 uploads。**复用** `apps/ezagent_core/lib/ezagent/uploads.ex:99`（`store!/3`）。**属**：复用 core，dealscout 通过 seam 调它（见 F-7.4）。
- **F-7.2 DownloadToken 铸下载链接**：给 upload 铸一个限时下载 token，附在回复消息上。**复用** `apps/ezagent_core/lib/ezagent/uploads/download_token.ex:92`（`mint!/2`，TTL≤24h、type-lock）+ 渲染缝 `apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex:311-343`（自动给 upload 附件 mint 一个签名 `href`）。**属**：全复用渲染缝。
- **F-7.3 匿名下载路由**：发布后匿名访客也能下载（只放 approved）。**复用** 公开路由 `apps/ezagent_web/lib/ezagent_web/router.ex:166`（`GET /socialware/external/download`）。**属**：复用通用 web 路由。
- **F-7.4 agent 产出 → upload 的 seam（缺口）**：把 agent cwd 里生成的文件搬进 uploads。**要新建**：一个 agent-facing 入口（MCP tool 或新 effect）调 `Uploads.store!`——现在 `store!` 只有 web 上传控制器在调，没有 agent 侧入口。**属**：碰 core seam，**需 discuss**（这是"agent 产出变可下载 artifact"的通用平台缺口，建议做成平台 effect/MCP tool 而非 dealscout 私有）。

---

## 撮合腿

## F-8 · 组合 hello + concierge 拿公开面 ↑ V-6（公开机会页视图）🔵🟢

DealScout **不自己造公开面**——**组合 hello 插件**拿到 hello 的 json-render 公开页 + **concierge 客服 agent** 当接待。**关键澄清：组合不靠 `uses`**——`uses` 只声明"依赖 hello plugin 已装"，真正的组合靠 **installs merge**（多 Definition）+ **bases·shape·views union**（单 Definition）。发布 = 今天仿 hello 的 code-seed（写 config map + boot 经真 governance publish）；匿名门是**发布者自助、不需 admin**。

- **F-8.1 `uses` 只声明依赖 hello plugin（不是组合轴）** ↑F-8：Definition 的 `uses: [:hello]` 只声明"hello plugin 必须已装"，装载时 `ensure_plugins_installed`/`plugin_installed?` 校验（`apps/ezagent_domain_session/lib/ezagent/socialware/manifest_resolver.ex:41`）。**它不拿 view、不做组合。** **属**：dealscout Definition 的 `uses` 数据。
- **F-8.2 真组合 = installs merge + bases·shape·views union** ↑F-8：拿到 hello 公开面靠两条组合轴——多 Definition 的 `installs` 合并（`apps/ezagent_domain_session/lib/ezagent/socialware/definition_editor.ex:63` `config_for_template`）+ 单 Definition 的 `bases`/`shape`/`views` union 进 spawn 的 behavior 集（`apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex:124` `behaviors/1`，views 是 render ActionSet、会带 `<sw>_render` cap 进 spawn 集）。dealscout 走它拿 hello 的 json-render 页。**属**：dealscout Definition 的 `bases`/`shape`/`views` 数据（引用 hello 的 render/page view）。
- **F-8.3 concierge 客服 recipe（公开面接待）** ↑F-8：公开面接待 agent = concierge。`hello_orchestrator.ex` off 到 `EzagentPluginHello.Router`，**非 owner member 永远被路由 concierge**（`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/router.ex:13-14`：访客到不了 builder、不为访客发 LLM 调用），concierge `handle_receive` 回帖（`apps/ezagent_plugin_hello/lib/ezagent/behavior/hello_concierge.ex:43`）。**属**：dealscout Definition 的 `roles` 里一个 agent 角色槽引用 concierge recipe（复用 hello，dealscout 零改）。
- **F-8.4 发布 = 仿 hello code-seed 经真 governance publish** ↑F-8：今天的发布 = 写一份 config map + boot 时经**真 governance 发布** `ConfigGovernance.Socialware.publish_cr`（`apps/ezagent_domain_session/lib/ezagent/socialware/config_governance/socialware.ex:81`）；未来 registry P3 才从外部 config 源发布（**不写 Elixir**）。**属**：dealscout 的 code-seed + 复用平台 governance publish。
- **F-8.5 匿名门自助、不需 admin** ↑F-8：公开面开匿名靠 `visibility_policy.web_anon_access`（`definition.ex:28` 默认 `false`），**发布者自助改**——**admin 只管全域**，只有 `scope: :public`（跨 workspace 发现）才要 admin（`socialware.ex:197` `authorize_public_scope`→`:228` `authorize_admin`→`:public_socialware_requires_admin`）。真正上不上公网靠**域名分配（infra 层）**，合规是外部审批、平台不背。**属**：dealscout Definition 的 `visibility_policy` 数据。
- **F-8.6 匿名下载已批准 artifact** ↑F-8：匿名下载走公开路由 `apps/ezagent_web/lib/ezagent_web/router.ex:166`（`GET /socialware/external/download`，只放 approved surface）。**属**：复用通用 web 路由。

---

## F-9 · 登录用户公开面自助 join + 发消息 ↑ V-7（公开面聊天视图）🔵🟢

**撮合腿入口 = 发现层第②腿**：登录用户（🟢 investor 看到你的机会页 / 🔵 founder 看到别人的机会页）在公开面**自助 join、直接发消息供线索**——**不用申请、不用等审核**。发的消息 @orchestrator，非 owner 永远被路由 concierge 回帖。**能聊、能供线索。全链已在 main，dealscout 零改机制。**

- **F-9.1 登录用户自助 join**：登录用户在公开面点"加入"→ web `handle_participatory_join` 拿 `signed_in_principal` → provision join authority + `dispatch_join` + mount participation caps（`apps/ezagent_web/lib/ezagent_web/socialware/session_feed_channel.ex:197-228`）。成员 cap 授予见 `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex:1200-1208`（confirmed 用户拿 member chat + publisher actions）。**复用**全链，dealscout 零改。**属**：复用 web + domain 自助 join。
- **F-9.2 发消息 @orchestrator → 路由 concierge 回帖**：登录成员发消息走 `dispatch_post`，消息带 `mentions: [orchestrator_uri]` @orchestrator（`session_feed_channel.ex:351` 一带）→ 非 owner member 永远路由 concierge（`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/router.ex:13-14`）→ concierge `handle_receive` 回帖（`hello_concierge.ex:43`）。**复用**全链。**属**：复用 hello 路由 + concierge。
- **F-9.3 全量白板互见**：公开面是 **FULL collaborative chat / shared whiteboard**——每个 viewer 看到所有参与者的消息、live（`apps/ezagent_domain_socialware/lib/ezagent/socialware/external_feed.ex:85-98` `chat_messages`）。founder 与来访者在这个白板上互见，撮合就在这里发生。**复用** external_feed 投影。**属**：复用平台公开面投影。

---

## F-10 · 匿名只读硬禁 + 发言者身份显示 ↑ V-8（founder 身份看板）🔵🟢

匿名访客**只读、不能写**（web + domain 两处硬禁 gate）；登录用户发言时 founder 看到**真实身份**（URI 带用户名），这是 founder 判断"值不值得深聊"的依据。**全在 main，dealscout 零改机制。**

- **F-10.1 匿名只读硬禁（web gate）**：匿名 join/post 都被挡——`signed_in_principal` 对 anon URI 返回 `nil`（`apps/ezagent_web/lib/ezagent_web/socialware/session_feed_channel.ex:325-330`），join/post 都落到 `{:error, not_logged_in}` 分支。**复用** web gate。**属**：复用平台 web 只读门。
- **F-10.2 匿名只读硬禁（domain gate）**：domain 层第二道硬禁——member cap 授予按 confirmed 用户身份分档（`apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex:1200-1208`），匿名/未登录拿不到 chat action cap。**复用** domain gate（web+domain 两处硬禁）。**属**：复用平台 domain 只读门。
- **F-10.3 发言者身份显示**：登录用户发言时消息 author = 真实 principal URI（带用户名，`session_feed_channel.ex:353` `dispatch_post` 用 `Ezagent.Message.new(principal, …)`）→ founder 在公开面看到"谁在说话"。**复用** 消息 author 透传。**属**：复用平台身份透传 → dealscout 身份看板视图（V-8）。

---

## F-11 · founder invite 深聊（owner 主动拉进私有 session）↑ V-9（invite 深聊面）🔵🟢

founder 在公开面看到值得深聊的发言者 → **主动 invite 对方进一个私有 session** 深谈。**关键换轨：owner 主动拉，不是申请人申请**（旧 `#1178` 申请-审核那套已退役）。这是撮合腿"交汇发生的地方"（`../README.md §3.8`：一方 invite、一方被邀，角色可互换，两类用户对称交汇）。**riding world `invite_member`，dealscout 零改机制。**

- **F-11.1 owner 主动 invite 深聊者**：founder 在 world UI 点 invite、把发言者 URI 拉进私有 session → `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex:683` `invite_member`（校验 caller caps + parse member URI → dispatch session `:join`）。**owner 主动拉，不是申请人申请。** **复用** world invite_member 全链，dealscout 零改。**属**：复用 world invite。
- **F-11.2 私密深聊对话**：被邀者进私有 session 后跟 founder（及 AI 客服）对话。**复用** F-6 的追问投递链 `apps/ezagent_domain_agent/lib/ezagent/behavior/agent/receive.ex:198`（`session.send → agent :receive`，全复用平台）。**属**：全复用投递链，dealscout 不碰。
- **F-11.3 改配置：per-install 独立 + fork_config**：别人装 DealScout = **per-install 独立**——每装写一份本地 install SessionTemplate + 独立 write cap（`apps/ezagent_plugin_world/lib/ezagent/world/socialware_install.ex:109-124` `persist_install_template`）；改**自己那份**配置走 `session.fork_config`（`apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex:82`）；改**公共发布物**要 manage 权限（governance）。**复用** world install + fork_config。**属**：复用平台 per-install 隔离 + fork_config。
- **F-11.4 撮合北极星 = 真实互动 / 被邀深聊**：撮合成功**不看"申请通过数"**，看**公开面真实互动 + 被邀深聊**——喂**撮合北极星 P-3.2**。可选在 session 落一条轻量互动/邀请记录供回溯（`{:set, key, value}` slice，照 `apps/ezagent_plugin_kb/lib/ezagent/behavior/kb.ex:119,135`）。**属**：复用 slice 记账（口径 = 互动/深聊，非申请通过）。

---

## F-12 · 平台跨用户推荐（关系网层，**discuss-first / 缺口**）↑ V-6（公开机会页视图）🔵🟢

**发现层第③腿**：ezagent 关系网层——跨用户实例发现（发现别人已发布的机会实例，不只是 Definition）+ 匹配推荐 + 朋友圈图。**这是平台方向、当前缺口，标 discuss-first，不阻塞 dealscout**（①主动找 F-2/F-3、②登录自助 join+供线索 F-9 今天能做）。

- **F-12.1 跨用户实例发现（缺口）**：现在 `DefinitionRegistry.list/1`（`apps/ezagent_domain_session/lib/ezagent/socialware/definition_registry.ex:255`）是**"发现 DEF 去装"**（DEF 级跨 workspace 闭合），**"发现别人已发布的实例/产物"缺**（handoff Part 1 明标）。**要平台新建**：跨用户实例索引。**属**：平台方向，**discuss-first**，riding registry track（#1169/#1173）。
- **F-12.2 匹配推荐 + 朋友圈图（缺口）**：跨用户按 profile 推荐可连接的人、画关系网图。**要平台新建**。**属**：平台方向，**discuss-first**，dealscout 是首个真实需求方、不阻塞。

---

## F-13 · email reach out（后续）↑ V-6（对公开机会页 leads 外联）🔵🟢

爬到/深挖到/撮合到 leads 后，自动发 email 触达。**固定对端 threaded 对话契合；动态群发语义错配，需另设计。**

- **F-13.1 出站发信**：给一个地址发邮件。**复用** `apps/ezagent_plugin_email/lib/ezagent/email/email.ex:26`（`Email.send/4`）。**属**：email plugin（不在 dealscout plugin）。
- **F-13.2 固定对端 threaded（契合）**：跟一个已绑定、已验证握手的收件人做多轮 threaded 对话——**完全契合现有机制**。**复用** ExternalMirror `:push` binding `apps/ezagent_domain_external_mirror/lib/ezagent_domain_external_mirror/external_mirror.ex:142`（三 gate + inbound 验证握手）+ RFC 5322 threading。**属**：复用 email `:push` adapter。
- **F-13.3 动态群发（语义错配，需另设计）**：dealscout 想对**任意新 leads 动态群发**，每个新地址都要一次 bind + 握手——现 push 语义是"session → 绑定期就固定且已验证的收件人"，**不直接匹配**。**要新设计**：这是 F-13 归入"后续"的根因，不在本轮范围。**属**：后续与 email/ExternalMirror owner 另议。

---

## §末 · 追溯自检

### F-n.x → 上游映射表

| 功能点 | ↑ 上游 | 复用 / 新建 | 归属（dealscout plugin 哪块 / 或缺口） |
|---|---|---|---|
| **F-1 定时+手动爬取** | ↑ V-3 | — | dealscout plugin 爬取子系统 |
| F-1.1 轮询 GenServer | ↑ F-1 | 复用 `inbound.ex:63,72` | plugin `children/0` |
| F-1.2 :httpc + binary | ↑ F-1 | 复用 `miro.ex:141,143` | 爬取模块 |
| F-1.3 手动触发 action | ↑ F-1 | 复用 `router.ex:79` | ActionSet action |
| F-1.4 数据注入发现流 | ↑ F-1 | 复用 `Invocation.dispatch`；**自建入站源**（socialware `:pull`=出站投影 `external_feed.ex:85-98`、非入站爬虫，别误用）| 爬取出口（自建入站源）|
| F-1.5 数据保留 sweeper | ↑ F-1 | **新建**（照 `anon_user/gc.ex`+`idempotency/sweeper.ex`） | dealscout 保留 sweeper 模块 |
| **F-2 AI 主动发现（新增）** | ↑ V-1 | **新增**（复用爬取基建+recipe） | dealscout 发现 recipe |
| F-2.1 发现 recipe(cc-headless) | ↑ F-2 | 复用 `orchestrator_recipe.ex:65,69,71` | plugin `roles/0` |
| F-2.2 吃爬取基建当输入 | ↑ F-2 | 复用 F-1.4 出口 + slice 读 | 发现 recipe 输入 |
| F-2.3 匹配结果推发现流 | ↑ F-2 | 复用 `Invocation.dispatch` + slice `kb.ex:119,135` | 发现 recipe 输出 |
| F-2.4 profile 是匹配依据 | ↑ F-2 | 复用 F-4 profile slice | 跨接 F-4 |
| **F-3 主动搜索（新增）** | ↑ V-4 | **新增**（复用爬取基建+recipe） | dealscout 搜索 recipe |
| F-3.1 搜索 action | ↑ F-3 | 复用 `router.ex:79` + `:httpc`(F-1.2) | 搜索 ActionSet |
| F-3.2 搜索 recipe(cc-headless) | ↑ F-3 | 复用 `orchestrator_recipe.ex:65-71` | plugin `roles/0` |
| F-3.3 结果回发现流/搜索面 | ↑ F-3 | 复用 F-1.4 出口 | 搜索模块出口 |
| F-3.4 指定源+token 复用 | ↑ F-3 | 复用 F-4.4 凭证读取 | 跨接 F-4 |
| **F-4 配置(profile+关键词+源+token)** | ↑ V-3 | — | dealscout 配置面 |
| F-4.1 profile+默认进 recipe config | ↑ F-4 | 复用 `kanban application.ex:99-103` | recipe 声明 |
| F-4.2 可变→state slice | ↑ F-4 | 复用 `kb.ex:119,135` | 配置 ActionSet |
| F-4.3 读写 action | ↑ F-4 | 复用同上 slice | 配置 ActionSet |
| F-4.4 token 写入凭证 | ↑ F-4 | 复用 `github.ex:35,54` write_creds | token 存储模块 |
| F-4.5 保存 token UI action | ↑ F-4 | 复用同上 | 配置 ActionSet |
| F-4.6 读凭证注入请求 | ↑ F-4 | 复用 `:httpc` 通道 | 爬取/搜索模块 |
| **F-5 发现流视图渲染** | ↑ V-1 | — | dealscout 视图子系统 |
| F-5.1 DealScoutRender | ↑ F-5 | **新建**（照 `hello_render.ex:32,46`） | dealscout plugin ActionSet |
| F-5.2 SessionView | ↑ F-5 | **新建**（照 `page_view.ex`） | dealscout plugin view module |
| F-5.3 authorize_view | ↑ F-5 | 复用 `session_view.ex:121` + `definition.ex:124-130` | Definition `views:` + 平台门 |
| F-5.4 world tab 接线 | ↑ F-5 | **新建/需协调**（`conversation_actions.ex:475` Phase 3） | 碰 world 代码 |
| **F-6 多轮追问 agent** | ↑ V-2 | — | dealscout recipe + 复用投递链 |
| F-6.1 cc/cc-headless | ↑ F-6 | 复用 `cc application.ex:100,103,112` | recipe 装 flavor |
| F-6.2 投递链 :receive | ↑ F-6 | 复用 `receive.ex:198` | 全复用 |
| F-6.3 多轮上下文 | ↑ F-6 | 复用 `sdk_sidecar.ex:97` + `message_store.ex:142` | 全复用 |
| F-6.4 追问回应 recipe | ↑ F-6 | 复用 `orchestrator_recipe.ex:65,69,71`；**flavor 声明层已通 #1164**（`definition.ex:36,293-300` + `definition_agents.ex:101,326`），非 cc runnable 待验 | plugin `roles/0` |
| **F-7 artifact 下载** | ↑ V-5 | — | 复用下载链 + 1 缺口 |
| F-7.1 uploads 存储 | ↑ F-7 | 复用 `uploads.ex:99` | 复用 core |
| F-7.2 DownloadToken href | ↑ F-7 | 复用 `download_token.ex:92` + `conversation_data.ex:311-343` | 复用渲染缝 |
| F-7.3 匿名下载路由 | ↑ F-7 | 复用 `router.ex:166` | 复用 web 路由 |
| F-7.4 agent→upload seam | ↑ F-7 | **新建/需 discuss**（agent-facing 入口缺口） | 碰 core seam |
| **F-8 组合 hello+concierge 拿公开面** | ↑ V-6 | 复用 hello 组合面（installs merge / views union）| dealscout Definition 数据 |
| F-8.1 `uses` 只声明依赖 hello | ↑ F-8 | 复用 `manifest_resolver.ex:41`（`uses` 非组合轴）| Definition `uses` |
| F-8.2 真组合 installs merge+views union | ↑ F-8 | 复用 `definition_editor.ex:63` + `definition.ex:124` | Definition `bases`/`shape`/`views` |
| F-8.3 concierge 客服 recipe | ↑ F-8 | 复用 `router.ex:13-14` + `hello_concierge.ex:43` | Definition `roles` agent 角色槽（复用 hello）|
| F-8.4 发布=仿 hello code-seed | ↑ F-8 | 复用 `socialware.ex:81` `publish_cr`（真 governance）| dealscout code-seed + 平台 publish |
| F-8.5 匿名门自助不需 admin | ↑ F-8 | 复用 `definition.ex:28` + `socialware.ex:197,228`（只 `scope::public` 才要 admin）| Definition `visibility_policy` |
| F-8.6 匿名下载 approved | ↑ F-8 | 复用 `router.ex:166` | 复用 web 路由 |
| **F-9 登录用户公开面自助 join+发消息** | ↑ V-7 | 复用（全链已在 main）| 复用 web+domain+hello |
| F-9.1 登录自助 join | ↑ F-9 | 复用 `session_feed_channel.ex:197-228` + `membership.ex:1200-1208` | 复用 web+domain join |
| F-9.2 发消息 @orchestrator→concierge | ↑ F-9 | 复用 `session_feed_channel.ex:351` + `router.ex:13-14` + `hello_concierge.ex:43` | 复用 hello 路由 |
| F-9.3 全量白板互见 | ↑ F-9 | 复用 `external_feed.ex:85-98` `chat_messages`（FULL collaborative chat）| 复用平台公开面投影 |
| **F-10 匿名只读硬禁+发言者身份** | ↑ V-8 | 复用（web+domain 两处硬禁）| 复用平台 gate + dealscout 身份看板 |
| F-10.1 匿名只读硬禁(web) | ↑ F-10 | 复用 `session_feed_channel.ex:325-330`（anon→`nil`→`not_logged_in`）| 复用 web 只读门 |
| F-10.2 匿名只读硬禁(domain) | ↑ F-10 | 复用 `membership.ex:1200-1208`（confirmed 分档）| 复用 domain 只读门 |
| F-10.3 发言者身份显示 | ↑ F-10 | 复用 `session_feed_channel.ex:353`（author=真实 principal URI）| dealscout 身份看板视图 |
| **F-11 founder invite 深聊** | ↑ V-9 | 复用 world invite_member | 复用 world invite + dealscout recipe |
| F-11.1 owner 主动 invite | ↑ F-11 | 复用 `conversation_actions.ex:683` `invite_member`（owner 主动拉，非申请）| 复用 world invite |
| F-11.2 私密深聊对话 | ↑ F-11 | 复用 `receive.ex:198` | 全复用投递链 |
| F-11.3 改配置 per-install+fork_config | ↑ F-11 | 复用 `socialware_install.ex:109-124` + `conversation_actions.ex:82` `fork_config` | 复用平台隔离+fork |
| F-11.4 北极星=真实互动/被邀深聊 | ↑ F-11 | 复用 `{:set,...}` slice `kb.ex:119,135`；喂北极星 P-3.2（非申请通过数）| 复用 slice 记账 |
| **F-12 平台跨用户推荐** | ↑ V-6 | **缺口/discuss-first**（第③腿）| 平台方向 |
| F-12.1 跨用户实例发现 | ↑ F-12 | **缺口**（`definition_registry.ex:255` 只 DEF 级）| 平台方向 riding registry track |
| F-12.2 匹配推荐+朋友圈图 | ↑ F-12 | **缺口** | 平台方向 discuss-first |
| **F-13 email reach out（后续）** | ↑ V-6 | — | email plugin（非 dealscout） |
| F-13.1 出站发信 | ↑ F-13 | 复用 `email.ex:26` | email plugin |
| F-13.2 固定对端 threaded | ↑ F-13 | 复用 `external_mirror.ex:142` | email :push adapter |
| F-13.3 动态群发 | ↑ F-13 | **需另设计**（语义错配） | 后续另议 |

### 覆盖确认

- **F 层 13 个功能锚点**（对齐 `../README.md §3.5`）：
  - **发现腿 7 个**：F-1 定时+手动爬取↑V-3 · **F-2 AI 主动发现（新增）↑V-1** · **F-3 主动搜索（新增）↑V-4** · F-4 配置(profile+关键词+源+token)↑V-3 · F-5 发现流渲染↑V-1 · F-6 多轮追问 agent↑V-2 · F-7 artifact 生成下载↑V-5。
  - **撮合腿 6 个**：F-8 组合 hello+concierge 拿公开面↑V-6 · **F-9 登录用户公开面自助 join+发消息↑V-7** · F-10 匿名只读硬禁+发言者身份↑V-8 · F-11 founder invite 深聊↑V-9 · **F-12 平台跨用户推荐(第③腿,discuss-first)↑V-6** · F-13 email reach out(后续)↑V-6。
- **撮合机制换轨核实（证据版）**：撮合 = **hello 公开面聊天**，不再是"申请加入 `#1178` admission gate"（那套已退役）——**F-8 组合 hello** 拿公开面（`uses` 只声明依赖 `manifest_resolver.ex:41`；真组合 = installs merge `definition_editor.ex:63` + views union `definition.ex:124`）+ concierge 客服（`router.ex:13-14` 非 owner 永远路由 concierge、`hello_concierge.ex:43` 回帖）；**F-9 登录用户自助 join+发消息**（`session_feed_channel.ex:197-228`，@orchestrator → concierge）；**F-10 匿名只读硬禁**（web `session_feed_channel.ex:325-330` + domain `membership.ex:1200-1208` 两处）+ 发言者身份（`session_feed_channel.ex:353`）；**F-11 founder 主动 invite** 深聊者进私有 session（`conversation_actions.ex:683`，owner 主动拉、非申请人申请）。旧 F-9 申请加入 / F-10 owner 审核 / F-11 聊聊看+撮合记账（连同 `#1178` / `:pending_members` / `approve_admission` / 访客登记 那套）**已退役**。
- **两条新功能（新增）**：**F-2 AI 主动发现**（千人千面 profile 匹配推送，复用爬取基建+recipe，cc-headless）+ **F-3 主动搜索**（全网/指定源手动 query，复用爬取基建+recipe，cc-headless）——两者是发现腿核心、发现层第①腿的"发现"半 + "搜"半，`../README.md §3.5` 明列为新增。
- **发现腿澄清（拼装现状）**：现有 socialware 的 `:pull` adapter 是**把 session 投影成公开面的出站** adapter（`external_feed.ex:85-98`，"外部来读 ezagent session"），**不是入站爬虫**——DealScout 的"爬线索/搜索"要**自建入站源 adapter**（照 email `inbound.ex` 轮询 / kanban miro `:httpc` idiom），别误用 `:pull`。
- **F-12 平台跨用户推荐标 discuss-first/缺口**：发现层第③腿（关系网层：跨用户实例发现 + 匹配推荐 + 朋友圈图），当前缺口（`definition_registry.ex:255` 只到 DEF 级发现、实例级缺，handoff Part 1 核实），riding registry track（#1169/#1173），dealscout 是首个真实需求方、**不阻塞**（①主动找、②登录自助 join+供线索 今天能做）。
- **发现层三条腿映射（解 yujun"没有发现层"红线）**：① **主动找** = F-2 AI 主动发现 + F-3 主动搜索（发现腿核心，今天能做）· ② **登录自助进来供线索** = F-9 公开面自助 join+发消息（撮合腿，今天能做）· ③ **平台跨用户推荐** = F-12（缺口/discuss-first）。
- **颜色属性（非分层）**：13 个 F 节点全标 🔵需求/🟢供给贯穿颜色——两类用户（founder 找钱 / investor 找项目）**对称地走同一个 F 节点**，不参与父子结构（`../README.md §3.1`）。
- **每个 F-n.x 恰有一个 `↑` 上游**，指向同层功能锚点或对应 V 元素（例：F-9.x ↑ F-9 ↑ V-7 ↑ J-7 ↑ P-3.2 ↑ P-2.2 ↑ P-1.1），上游编号存在且唯一。**单亲追溯闭合**：F-8↑V-6 / F-9↑V-7 / F-10↑V-8 / F-11↑V-9 / F-12↑V-6 / F-13↑V-6，节点数 F=13 不变。
- **新建/需协调已显式标注**：F-2/F-3（新增 AI 发现/主动搜索 recipe，复用爬取基建）· F-5.1/F-5.2（新建 render/view）· F-5.4（world tab，需协调）· F-7.4（agent→upload seam，需 discuss）· F-1.5（新建数据保留 sweeper，照现成先例、零改已有）· F-1.4（自建入站源 adapter，别误用 `:pull` 出站）· F-12（平台缺口，discuss-first）——F-5.4/F-7.4/F-12 对应给 Allen 的 discuss-first 清单（`../README.md §4`）；**撮合腿 F-8/F-9/F-10/F-11 全复用 hello 公开面 + session_feed_channel 自助 join/post + concierge + `conversation_actions` invite_member，dealscout 零改机制，不再是缺口**。
- **下游 I 层**（`tech/issues-plan.md`，`../README.md §3.6`）：发现腿 I-1↑F-1 · I-2↑F-2 · I-3↑F-3 · I-4↑F-4 · I-5↑F-5 · I-6↑F-6 · I-7↑F-7 · I-8↑F-5(world tab) · I-9↑F-1(保留)；撮合腿 I-10↑F-8 · I-11↑F-9 · I-12↑F-10 · I-13↑F-11 · I-14↑F-12 · I-15↑F-13，F 全集被 I 全集覆盖。
