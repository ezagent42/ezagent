# E2E 手测阻塞根因分析（步骤 2–8）+ 缺口路由

> **任务** `world-deploy-e2e-pg` · **分支** `world-deploy-e2e-pg` · **2026-06-23**
> 手动 E2E：**只有步骤 1（注册/登录）可完成**；2–8 各自阻塞。下面逐步给出**实测/代码级根因**与**owner 路由**。
> 验证手段：live server（`world.localhost:10042`，PG）+ in-node `:erpc`（`ezagent_runtime@127.0.0.1`）+ `data-last-dispatch` 读取 + `invocations`/`messages`/`kind_snapshots` DB 查询。
> 置信度标注：✅实测复现 · 📖代码结构确认 · ⚠️工具限制（agent-browser 无法可靠驱动 React 受控输入，相关 UI 症状以代码/erpc 为准）。

## TL;DR — 根因与 owner

| 步 | 现象 | 根因（一句话） | 置信 | Owner |
|---|---|---|---|---|
| 1 注册/登录 | ✅ 可用 | — | ✅ | — |
| 2 建 cc agent + credential | create 可、用不起来 | create 本身可（spawn 真实 claude 进程），但 **cc credential/登录完成未接线** + 2 个 UX bug | ✅/📖 | **gagameow**（credential）+ **FatNine**（UX 面） |
| 3 开 session 对话 | send 静默无效 | **`create_session` 5s dispatch 超时 + snapshot-on-create 竞态** → session 无可重生快照 → `:session :send` 返回 `:no_such_actor`，被 `:cast` 吞 | ✅ | **lead / core+domain session 生命周期** |
| 4 routing rule | Add 静默无效 | **与步 3 同一根因**（无快照 session 不可 dispatch）；builder 本身存在 | ✅ | **lead**（同一修复解锁） |
| 5 建 hello page/app | 无入口/无效 | **world UI 无 hello-app 创建路径**（`ensure_app`/HelloSession instantiate 未接到任何 world 按钮） | 📖 | **zhaomaota97 `world-hello-convergence`** |
| 6 外部 customer 链接 | 无法演示 | route/匿名 infra OK，但**缺一个 live `public_view` session**（被步 5 卡住） | 📖 | **zhaomaota97**（infra 在 ezagent_web，已可用） |
| 7 world 里看 hello 状态 | 只有临时 iframe | 仅 `HelloPagePreview` 临时 iframe，非原生 `HelloPageView`；且需 hello session（步 5） | 📖 | **zhaomaota97** |
| 8 双向状态同步 | 无法演示 | 依赖步 5 的 hello session + 步 3 的 world 侧 send crux；双向同步未验证 | 📖 | **zhaomaota97** + **lead** |

---

## 逐步根因

### 步骤 2 — 创建 cc agent + 完成 credential/登录 🟡→⛔
- **create 本身可用**（✅，原 walkthrough 已验证）：后端 `workspace.create_agent`（`workspace.ex:760`）成功创建 `entity://system/agent/claude-bot` 并 **spawn 一个真实 `claude` OS 进程**（`os_pid` live、`running: true`）。
- **Blocker A — 空 CWD 静默失败（UX）📖**：cc flavor 要求已存在的 CWD（`agent_create.ex:144` → `{:error, :cwd_required_for_cc}`）。CWD 留空时 `last_dispatch_status` 被设为 error，但**表单什么都不显示**——用户看到一个"死"表单。→ **FatNine**。
- **Blocker B — agent 详情页状态不解析（UX）📖**：详情页显示 `Phase: unknown / Flavor: unknown / Bridge: not connected`，而真实 status 是 `%{phase: :alive, flavor: "cc", running: true}`。源头 `Identities.tsx:283` `String(status.phase || "unknown")`、`:211` `agent.flavor || "unknown"` —— 详情页没解析 live status。→ **FatNine**。
- **Blocker C — cc credential/登录完成未接线（真正卡点）📖**：agent 进程能 spawn，但**没有 operator 流程把 Claude 凭据喂给它**，所以它无法认证、无法真正回复。因此即便建好 agent 也无法对话。→ **gagameow `agent-flavor-headless-protocol-api`**。

> ⚠️ 注：我用 agent-browser 驱动该表单时点 Create 得到 `error:name_required`——这是 **agent-browser 没能把值写进 React 受控 state** 的工具假象（真实手输不会出现）。关键信号是该表单的 Create **确实会 dispatch + 校验**（`data-last-dispatch` 从 `idle`→`error:name_required`），所以步 2 的卡点是 credential/UX，不是 create 路径本身。**若你手测时是"填了 name+CWD 后 create 仍失败"，请贴出当时的 `data-last-dispatch` 值，可能另有 create-超时（见步 3）。**

### 步骤 3 — 开 session 并与 agent 对话 ⛔（已 root-cause，✅）
1. **`create_session` 自动同步 spawn 一个 orchestrator agent**（`workspace.ex:776-798`，返回 `orchestrator_status`）→ 这一步慢，**稳定超过 5s 框架 dispatch `:call` 超时**（erpc 实测 ×5：`{:timeout,{GenServer,:call,[…workspace.create_session…],5000}}`，超时常量 `invocation.ex:259-260`）。world "New session" 因此 racy/超时。
2. **snapshot-on-create 与这个 5s 预算竞态**：实测两次相同的超时 create，**一个写了快照、一个没写**（`kind_snapshots` 的 `session://` 行）。所以 session 可能在**没有可重生快照**的情况下被交给 UI（如 `e2e-chat`/`main`，`snapshot_exists?`=false）。
3. 无快照的 session **不可 dispatch**：`:session :send` 走 lazy-spawn → `snapshot_exists?`=false → `{:error, :no_such_actor}`（`invocation.ex:190-194`）。
4. **错误被吞**：`send_message` 用 `mode: :cast` + `reply: :ignore`（`conversation_actions.ex:144-149`），`:no_such_actor` 只出现在隐藏的 `data-last-dispatch` 属性——composer 清空、transcript 停 "No turns"、零报错。
5. **正向对照（✅）**：对**有快照**的 session 发送 → `{:ok, %{stored: true}}`，lazy-respawn `:unknown→:ready`，消息持久化（`messages` 0→1）。**所以 send/cap/lazy-spawn 机制本身是好的**——卡点是 create 超时 + 快照竞态。
6. 注：**不是 cap 问题**——admin 持 wildcard cap `{:any,:any,:any,:any,:any}` 且 `confirmed:true`。
→ **owner：lead / core+domain workspace+Session-Kind 生命周期。** 详见 `returns/world-deploy-e2e-pg.md` §7。

### 步骤 4 — 创建 routing table / session routing rule ⛔（与步 3 同根因，✅）
- in-session routing builder **存在**（`session.routing.add` → `add_routing_rule`，`conversation_actions.ex:331-357`）。它是 `:call`，错误会进 `last_dispatch_status`。
- 在无快照 session 上 Add → 同样 `:no_such_actor`。**不是独立 bug，是步 3 crux 的另一个 surface。** → **lead**（同一修复解锁）。

### 步骤 5 — 创建 hello page/app ⛔（📖）
- **world UI 没有创建 hello app 的路径。** `EzagentPluginHello.App.ensure_app/2`（构建 `public_view` hello session + HelloBuilder orchestrator，`app.ex:24`）只在以下处被调用：boot（`application.ex:123`）、demo mix task（`ezagent.demo.seed_hello`）、HelloSession 模板 instantiate（`hello_session.ex:44`）——**没有任何一个接到 world 按钮**（`grep ensure_app|HelloSession apps/ezagent_plugin_world/lib` = 空）。
- world UI 的 "Session templates" 表单（`workspace.template.save` + `public_view` 勾选，`WorkspacePlugin.tsx:196`）建的是**通用 public_view SessionTemplate**，不是 hello app（无 HelloBuilder、无 live session）；world 也**没有把模板 instantiate 成 live session 的入口**（grep 同样为空）。
→ **owner：zhaomaota97 `world-hello-convergence`**（其 handoff Phase 1 owns 暴露此流程）。

### 步骤 6 — 打开外部 hello/customer 链接（免登录）⛔ 上游阻塞（📖）
- **infra 可用**：`GET /socialware/customer`（`ezagent_web/router.ex:99` → `Socialware.CustomerController`），无参 400，对 `public_view` session 有 tokenless 匿名路径（`customer_controller.ex:76+`）。
- 但需要一个 **live `public_view` session** 来指向——而步 5 的 UI 产不出。所以 6 无法端到端演示。
→ **owner：zhaomaota97**（infra 本身在 ezagent_web，已就绪；缺的是步 5 的创建流程）。

### 步骤 7 — 在 world session 页看到 hello conversation/page state 🟡（📖）
- 仅通过**临时 iframe** 工作：`Conversation.tsx:121-124,396` 的 `HelloPagePreview`，靠 `sessionUri.includes("/hello/")` 触发，**非原生 `HelloPageView`/SessionView 渲染**（代码注释明确标 `TEMPORARY` / `Phase 3`）。且需要一个 hello session（被步 5 卡住）。
→ **owner：zhaomaota97**（其 handoff Decision #2 owns 替换/接受 iframe）。

### 步骤 8 — session ↔ 外部 hello 双向同步 ⛔（📖）
- 依赖一个可用的 hello session（步 5）+ world 侧 send 路径（步 3 crux）。customer/chat feed infra 存在（`CustomerFeed`/`ChatFeed`/`ChatFeedAuth`），但**完整双向同步未验证**，且 world→session 方向被步 3 crux 阻塞。
→ **owner：zhaomaota97**（hello 双向）+ **lead**（world 侧 send crux）。

---

## 按 owner 汇总缺口

### → lead / core+domain session 生命周期（**最高优先**，解锁步 3/4/8 world 侧）
**一个根因，两个 surface：** `create_session` 同步 spawn orchestrator → 超过 5s dispatch 预算 → snapshot-on-create 与之竞态 → session 可能无可重生快照 → 之后所有 dispatch 静默 `:no_such_actor`。修复方向：
1. 让 `create_session` 适配 dispatch 预算（orchestrator spawn 异步化 + ack，或抬高该 action 超时）；
2. 交 UI 前**保证**可重生快照已落（同步 snapshot-on-create，或显式 "session not ready" 态）；
3. **别再吞 `:cast` send 错误**——把它 surface 出来，而不是藏进 `data-last-dispatch`。

### → FatNine `socialware-creator-agent-config`（步 2 配置面）
- 空 CWD 静默失败：surface `:cwd_required_for_cc`，cc flavor 时把 CWD 标必填。
- agent 详情页解析 live status（别再无脑 `|| "unknown"`）。

### → gagameow `agent-flavor-headless-protocol-api`（步 2/3 真正能对话）
- cc flavor 的 **credential/登录完成**：让 spawn 出来的 agent 真正认证 Claude 凭据并能回复。这是"建了 agent 也无法对话"的根本。

### → zhaomaota97 `world-hello-convergence`（步 5/6/7/8）
- 暴露 world UI 的 **hello app 创建流程**（`ensure_app`/HelloSession instantiate → live public_view session → customer 链接）。
- 用原生 `HelloPageView` 替换临时 iframe（步 7）。
- 验证 session ↔ customer **双向同步**（步 8）。

---

## 证据/复现指针
- 步 3/4 完整证据 + 正向对照 + 复现：`docs/together/2026-06-23/returns/world-deploy-e2e-pg.md` §7。
- runbook ⛔ 提示：`docs/guide/world-e2e-seed.md` §3。
- 步 3 失败态截图：`docs/together/2026-06-23/evidence/03d-send-no-such-actor.png`。
- 诊断技巧：① 浏览器 console `document.querySelector('[data-last-dispatch]').getAttribute('data-last-dispatch')` 读被吞的 dispatch 错误；② `:erpc.call(:"ezagent_runtime@127.0.0.1", Code, :eval_string, [code])` 在运行节点内忠实跑 dispatch（cookie 在 `~/.ezagent/default/runtime/cookie`，避开第二节点 workspace 单例 deadlock）。
