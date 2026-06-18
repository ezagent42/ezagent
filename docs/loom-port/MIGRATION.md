# Loom → main 迁移说明

> 配套文档:`STORAGE.md`(loom 产物怎么存)。本文讲**怎么做的**、**怎么跟基座结合**、**怎么保证 main 和 loom 功能都不丢**。
>
> 源分支:`loom-stitch`(下称 stitch)。目标:`main`。工作隔离在 worktree `/home/ning/ezagent-port`,profile=`port`(独立端口 + sidecar + SQLite 库),不影响线上 stitch 服务/数据。

---

## 1. 一句话

把 loom 这个**功能完整的产品**(AI 建站 + 多智能体编排 + 发布/接线员/消费会话)从 stitch 整体搬到 main,**不改 main 一行核心逻辑**(只动 12 个声明式钩子点),靠 ezagent 的 **plugin 契约**接入基座,再把 stitch 与 main 之间的**约定差异**在 plugin 边界逐条桥接,最终 main 原有能力和 loom 全量能力都不丢。

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

### 跟 socialware 基座的关系

`ezagent_domain_socialware` 是**面向消费者/匿名访客**的领域 app:`customer_feed` / `anon_user` / `customer_auth` / `public_view` / `chat_feed` / `page_view`。它定义了「一个发布出去的页面被陌生人打开、临时身份、customer-visible 的消息流」这套模型。

loom 的**消费侧**(发布链接、访客临时用户、接线员控制台、`:customer_visible` 消息、弹幕/导购预览 AI)正是**建立在 socialware 这套基座之上**:loom 不重新发明匿名访客/消费会话,而是复用 socialware 的 customer/anon 模型 + UI 的 `SessionViewRegistry` 视图注册,自己只负责「建站 + 多智能体编排」这部分增量。所以 loom 与基座是 **「消费 + 叠加」** 而不是 **「替换」** 的关系。

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
