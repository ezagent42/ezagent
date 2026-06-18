# Loom → main 迁移说明

> ⚠️ **状态(2026-06-18 修正,重要)**:本文记录的是 **stitch 时代独立 loom plugin 的移植**——它**跑在 socialware 基座旁边、并没有走 socialware**(自带 `LoomOrchestrator`/`LoomWorker` 等独立 Kind + 自己的 `temp_user`/`consumer_session`/`/loom/p` 匿名消费侧;mix 依赖里没有 `ezagent_domain_socialware`)。
>
> 但 main 的架构(**socialware substrate**,task #46,`docs/superpowers/specs/2026-06-09-socialware-substrate-design.md`)明确要求 **「AI 建站 / customer app」(就是 loom)必须做成 socialware 的一个 vertical** —— 即在**一个** `SocialwareSession` Kind 上组合 `Chat / Turn / Surface / ConfigUpdate / Publisher` 行为 + 声明外部 SPA view 的一个 **Template**(`#810 "socialware loom vertical"` 就是这件事)。
>
> **所以这版移植不满足 main 的要求,不作为最终目标合入。** 本文保留为**功能基线 / 参考**(证明各功能在 main 上能跑通、URI/flavor 等基座差异怎么填);真正的目标是 **「loom 作为 socialware vertical」**,需另行设计实施(见本文档目录下后续的评估/设计文档)。

---

> 配套文档:`STORAGE.md`(loom 产物怎么存)。本文讲(在上述「独立 plugin 移植」语境下)**怎么做的**、**基座差异怎么填**。
>
> 源分支:`loom-stitch`(下称 stitch)。目标:`main`。工作隔离在 worktree `/home/ning/ezagent-port`,profile=`port`(独立端口 + sidecar + SQLite 库),不影响线上 stitch 服务/数据。

---

## 1. Loom 是什么(前端 / 后端各做什么)

Loom 是一个跑在 ezagent 上的 **AI 建站 + 多智能体编排**产品。它由**两半**组成:一个前端 SPA 和一个 Elixir 后端 plugin。

### 前端(Next.js SPA)

> **源码在另一个独立仓库,不在本仓库。本仓库只保存它的编译产物**(Next.js 静态导出),vendored 在 `apps/ezagent_plugin_loom/priv/static/loom_ui`(basePath `/loom`)。所以**不要直接改 `loom_ui` 下的文件**——会被下次构建覆盖。

负责全部界面与交互:

- **建站工作台**:用户对话驱动生成 / 编辑一个实时 React 页面(由 builder 完成,**v0 式**),Sandpack 沙箱里实时预览;
- **发布与版本**:把当前页发布成可分享链接;多版本 + 编辑回退;
- **发布页消费体验**:访客打开链接看到成品页 + 预览侧 AI 导购(Stitch)聊天 + 动态「✨」卡片(AiSpot)+ 弹幕 + 按登录身份解锁的隐藏入口(角色门控);
- **运营页**(如接线员控制台):本身也是 builder 生成的页面,用 loom SDK 跨会话看 / 接待访客;
- session 切换、历史、素材上传;
- 通过 **SDK bridge**(`platform` 模块)调后端 `/loom/api/*`,自己不直接碰数据库。

### 后端(Elixir plugin `ezagent_plugin_loom`)

负责编排、LLM、持久化、给前端的 SDK API:

- **`WebPlug`** —— 唯一 web 入口(`forward "/loom"`):既发上面那份静态产物,又提供 `/api/*` 的 SDK 桥;
- **每个 session 一支 agent team**:orchestrator(拆解 → fan-out → 聚合 → 合成)、workers(按主题分工)、**builder**(团队里唯一能改页面源码的)、meta-agent(收 @ 自然语言指令加 / 删团队成员)、salesperson(预览侧导购 orchestrator + 一组固定 sub-worker);
- **LLM dispatcher**:team 的推理走可切换后端(`claude_code` 本地 headless / `deepseek` HTTP);预览侧 AI(Stitch / AiSpot)**固定直连 DeepSeek**,不走这个 dispatcher;
- **持久化**:页面源码 + 运行态进 SQLite,边角 config 进旁路 JSON,大素材进文件系统(详见 `STORAGE.md`);
- **业务逻辑**:发布 / fork / 衍生谱系 / 角色门控 / 接线员同伴集 / 匿名临时用户等。

### 这次做了什么(一句话)

把上面整套(前端编译产物 + 后端 plugin)从 stitch 整体搬到 main,**不改 main 一行核心逻辑**(只加少数声明式钩子点),靠 ezagent 的 **plugin 契约**接入基座,再把 stitch 与 main 之间的**约定差异**在 plugin 边界逐条桥接,最终 main 原有能力和 loom 全量能力都不丢。

---

## 2. 基座(umbrella)长什么样

ezagent 是一个 Elixir umbrella,分三层 + 插件:

| 层 | apps | 职责 |
|---|---|---|
| **core 内核** | `ezagent_core` | Kind 引擎、Dispatch/Router、CapBAC、URI、EventLog/Snapshot、ReadyGate/Idempotency/DLQ 等可靠性原语 |
| **domain 领域** | `ezagent_domain_identity` / `_workspace` / `_session` / `_agent` / `_agent_bridge` / `_socialware` / `_ui` / `_pty` / `_python` / `_external_mirror` | 身份/工作区/会话/智能体/**社交化(消费侧)**/UI 视图注册/PTY/外部镜像 |
| **transport / admin** | `ezagent_web`(Phoenix,纯传输)、`ezagent_plugin_liveview`(admin LiveView 控制台) | HTTP/WS 入口、后台界面 |
| **plugins** | `ezagent_plugin_cc` / `_codex` / `_echo` / `_np` / `_feishu` / `_advisor` / `_curl_agent` / **`_loom`** | 以 OTP app 形式挂在内核上的扩展 |

**loom 就是其中一个 plugin**(`ezagent_plugin_loom`),跟 cc/echo/np 平级。

### loom 与 socialware / autoservice 的关系(平行 vertical,loom 都不依赖)

**结论先行**:loom **不依赖 `ezagent_domain_socialware`**,也**完全不碰 autoservice**。三者是同一个 ezagent 基座上的**平行 vertical**,不是上下游 —— 别把 loom 理解成「建在 socialware/autoservice 之上」。

**和 socialware**

`ezagent_domain_socialware` 是面向消费者/匿名访客的领域 app(`customer_feed` / `anon_user` / `public_view` / `chat_feed` / `config_projection`(soul)…)。但:

- loom 的 mix 依赖只有 `ezagent_core` / `ezagent_domain_session` / `_external_mirror` / `_ui` —— **列表里没有 `ezagent_domain_socialware`**。
- 「发布页被陌生人打开 / 临时身份 / 弹幕 / 导购预览 AI」这套消费侧,loom 是**自己实现**的(`temp_user.ex` / `consumer_session.ex` / `snapshots.ex` / `owned_sessions.ex` / `salesperson*.ex` / `role_config.ex`),**不**调 socialware 的 `customer_feed` / `anon_user` / `public_view`。
- 真正共享的只是更底层的 **core 概念**:`:customer_visible` 消息可见性(定义在 `ezagent_core/message.ex`,不是 socialware 专属)+ Session / dispatch / CapBAC。所以 loom 和 socialware 是**同站在 core 上、各做各的消费侧**(sibling),不是 loom 建在 socialware 之上。
- (路线图上 #810「socialware loom vertical」是另一个「把 loom 做成 socialware 原生 vertical」的方向;**本 PR 移植的是 stitch 自带消费侧、与 socialware app 解耦的那版 loom plugin**。)

**和 autoservice**

- autoservice 是**另一条独立产品线 vertical**(客服方向:cinnox「soul」= 一篇 markdown → 经 `socialware/config_projection` 投影成 cc bot 的 `CLAUDE.md`),在自己的 `autoservice-dev` 分支上演进,**建在 socialware 之上**。
- **loom 源码对 autoservice 零引用**(在 loom `.ex` 里 grep `autoservice` / `customer_chat` / `cinnox` 全空),autoservice 也不用 loom。两者唯一交集是**共同的 ezagent 基座**。
- 一句话:**socialware 上挂着 autoservice 这条客服 vertical;loom 是另一条、连 socialware app 都没用上。本 PR 既没用到 autoservice,也不依赖 socialware app —— 只复用最底层的 core。**

---

## 3. loom 怎么接进基座(plugin 契约)

loom 不 patch 内核,而是实现 `use Ezagent.Plugin` 契约,把自己要的东西**声明**出来,基座在 boot 时收集:

```
EzagentPluginLoom.Application  (use Ezagent.Plugin)
├── behaviors/0        → 7 个 Behavior + 7 个 Entity Kind
│                        (Loom / LoomOrchestrator / LoomWorker / LoomBuilderWorker /
│                         LoomMetaAgent / LoomSalespersonWorker / LoomSalespersonSubWorker)
├── agent_flavors/0    → loom / loomorch / loomworker / loombuilder / loommeta /
│                        loomsalesperson / loomsalespersonsub  → 各自的 Entity 模块
├── after_boot/0       → seed 默认 loom agent + 恢复 agent flavor(见 §4.2)
├── register_session_views → 往 Ezagent.UI.SessionViewRegistry 注册
│                            LoomSessionView(LOOM tab,iframe)+ LoomDashboardView(Dashboard tab)
└── (ezagent_web 里)  forward "/loom" → EzagentPluginLoom.WebPlug  +  post "/loom-signup"
```

loom 通过这些声明拿到基座的服务,**调用关系**(实测频次):`Ezagent.Kind`×101、`Ezagent.URI`×100、`SystemPrincipal`×30、`Invocation/Router`×22、`SpawnRegistry`×15、`Capability`×8、`MessageStore`×7、`KindRegistry`×5、`AgentFlavorAttributes`×3 ——**全是单向消费基座 API**,没有反向 patch。

### 唯一的 Web 入口

整个 loom(Next.js 静态产物 + SDK 桥 + 发布页 + 接线员 API)都在 `EzagentPluginLoom.WebPlug` 里,经 `forward "/loom"` 挂到 ezagent_web。Phoenix 在这里只是**传输**(P13:Phoenix is transport, not fullstack),loom 的业务一律走 `Ezagent.Router.dispatch` / `Invocation.dispatch` 进会话(P14:dispatch 是 Kind 之间唯一通路)。

---

## 4. 难点:stitch 与 main 的约定差异,逐条桥接

plugin 契约保证了「能挂上」,但 stitch 和 main 在底层约定上有差异,代码搬过来能编译却**运行期出错**。迁移的真正工作量在这里。每一条都在 **plugin 边界**桥接,不改基座。

### 4.1 URI 顺序:类型/类优先 → 工作区优先(系统性三层)

| | stitch | main(规范) |
|---|---|---|
| entity | `entity://<type>/<ws>/<name>` | `entity://<ws>/<type>/<name>` |
| session | `session://<class>/<ws>/<sid>` | `session://<ws>/<class>/<sid>` |

loom 代码里凡是**构造**或**解析** entity/session URI 的地方(team.ex / worker_config.ex / 各 Behavior 的 `*_ws_sid` / web_plug / 各旁路存储 / lineage / 模板)全部从「类优先」改成「工作区优先」。其中 `Ezagent.Capability.workspace_of` 用 host 当 ws,host 错了整条 dispatch + 鉴权 + 消息路由都错,所以这是迁移里改动面最大的一层。

### 4.2 Agent 的 Kind 解析:从「名字推导」改成「flavor 存储」+ 重启存活

main 解析一个 agent 该用哪个 Kind 模块,靠的是**存在 ETS 里的 flavor**(`AgentFlavorAttributes`),而不是 stitch 那样从名字推。这带来两个迁移问题:

- **spawn 时**:bare spawn 前必须先 `put` flavor(team.ex `spawn_step/put_loom_flavor`),否则 `{:no_kind_module_for_agent}`。
- **重启后**:ETS 丢了。有快照的 agent(orchestrator)靠 `after_boot/restore_agent_flavors` 从 `kind_snapshots` 扫回 flavor 复活;**无快照的成员**(builder/worker/meta/salesperson —— 它们是无状态的、永不落快照)靠 `WebPlug.heal_team/2`(挂在 `/history`、`/stream` 上,meta 活性做廉价 gate)按需幂等重建。两者合起来保证 team 跨重启自愈。

### 4.3 发布物:合成模板模块 → 数据驱动实例化(Plan B)

stitch 每次发布会合成一个 Template Class 模块。main 走 **Plan B**:发布/保存物是纯 JSON 数据(`loom_saved_classes.json`),`SavedClasses.instantiate_from_data/3` 直接按数据实例化 `session.loom`,不再经 TemplateRegistry 查合成模块。

### 4.4 前端边界:stitch 布局 ⇄ 规范布局的适配器

vendored 的 loom 前端是 **stitch 时代的静态产物**(`priv/static/loom_ui`,源码在独立仓库,这里改不了)。它解析 session URI 字符串时按 stitch 顺序 `session://<class>/<ws>/<sid>`。于是 WebPlug 必须当**适配器**:

- 出站(交给前端的 session URI,如接线员同伴列表):`fe_session_uri/2` → `session://loom/<ws>/<sid>`(前端看得懂);
- 入站(前端回传的 URI,如 operator-send):`parse_fe_session_uri/1` → 归一回规范 `%URI{}` 给 message store / cohort / dispatch 用。

**内部一律规范,边界一律翻译**。同理 `/loom-signup` 接受 stitch 顺序的身份 URI(`normalize_signup_order` 翻成规范),让 vendored 注册弹窗的提示也能用。

### 4.5 其它基座对齐

- **A3**:admin 冷启动建 main 会话改成 config 可控的异步挂载(`async_main_session`,test=同步、dev/prod=异步)。
- **Tailwind**:loom 的服务端渲染视图(Dashboard 等内联 `~H`)要被 Tailwind 扫到,在 `app.css` 加 `@source ".../ezagent_plugin_loom/lib"`,否则工具类被 purge、样式丢失。
- **系统主体**:loom 的 3 个 system principal 经 plugin 声明登记进 main Catalog 并归类(不编辑 `catalog.ex`)。

---

## 5. 怎么保证 main 功能不丢

**靠 plugin 隔离 + 把对共享文件的改动收敛成一份显式清单。**

- loom 是独立 OTP app,main 的 core/domain 代码**不被 loom 改**;loom 只**消费**基座 API。
- 对 main 共享文件的改动只有**少数几个钩子点**,且都是「加一条声明 / 加一个 forward / 注册一个视图」式的加法,不改原有分支语义。典型如:`router.ex` 加 `forward "/loom"` + `/loom-signup`;`app.css` 加一行 `@source`;admin_live 加 A3 异步分支。
- 遵守 main 的 grep-gate 不变式(dispatch-only、`Ezagent.URI`、2 段 URI、chat→session slice 等),CI 门控不破。
- 通用改进(非 loom 的 UX/infra)单独成提交,跟 loom PR 分开,避免「顺手改基座」。

→ 结论:把 loom plugin 整个摘掉,main 回到原状,行为不变。

## 6. 怎么保证 loom 功能不丢

**靠功能清单 + e2e 验收 + 运行期逐个补齐。**

- 验收依据是功能清单(建站对话生成、发布、fork、接线员、弹幕、导购 AI、多智能体 @ 加/删成员、素材库……),逐项对照 stitch 不缺。
- 运行期实测把 §4 的差异一个个打绿:team 能起、@builder 有回应且跨重启自愈(4.2)、发布页能开/能 fork(4.3)、接线员同伴列表能看能点能发消息(4.4)、Dashboard 样式回归(4.5)、注册按提示也能成(4.4)。
- 已知**非 loom**、属环境的项(main 会话的 Claude Code 编排器在无 `claude` 的 port 测试环境 90s 超时)明确标注为环境问题,不计入 loom 回归。

---

## 7. 验证基线

- `mix compile` 干净(仅 main 既有的历史 warning,无 loom 新增)。
- port profile 隔离启动(`EZAGENT_PROFILE=port PORT=10088 LOOM_LLM_BACKEND=deepseek`),loom LLM 走 DeepSeek,不依赖 `claude`/MCP。
- 关键路径以服务端日志 + 直连 endpoint 实证(如 `/history` 返回完整帧、cohort 解析出正确 ws、flavor restore `QUERY OK`)。
