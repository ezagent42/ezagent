# FP5 — world 操作员控制台 UI 巡检清单(zyli, 2026-06-26)

> **方法**:本人(非 subagent)用 agent-browser 逐面登录巡检,每面截图存
> `docs/together/2026-06-26/evidence/fp5-ui-audit/`,逐步核对。**列表优先,先盘点再逐条修**(FP5 约定)。
> **环境**:`admin@ezagent.chat / worlddev` 登录 `http://world.localhost:10042`,PG dev 库
> `ezagent_pg_compat_dev`(22229 invocations / 56 kind_snapshots 的真实历史数据)。

## 总览 · 优先级排序(先盘点,逐条修待 lead 对齐后)

巡检 11 面 / 23 张证据(`evidence/fp5-ui-audit/01..23`)。按修复优先级:

| # | 级别 | 问题 | 归属 | 可否 FP5 自修 |
|---|---|---|---|---|
| **S5** | 🟥 | Agent 详情子面(config/caps/...)对真实 agent 大面积失效:cc `:activate_timeout`、py `{:unknown_action, :read_cascade}`,裸 tuple 泄漏 | core/behavior + UI | 仅 UI 层(友好文案/重试);根因待 lead |
| S5-a/b | 🟧 | 裸 error tuple 泄漏 + 无激活态/重试 | UI | ✅ |
| S9-a/b | 🟧 | Kanban 面 H1="Sessions" + 导航高亮 "Overview" 错位 | UI | ✅ |
| S1-a | 🟧 | "Rendered by React from LiveView state." 调试文案泄漏 | UI | ✅ |
| S2-a | 🟧 | Overview(`/`)无独立内容,与 Sessions 雷同 | UI/产品 | ✅(需设计) |
| S7-a | 🟧 | F9 External Mirror Bound 列泄漏裸 `~N[...]` 时间 | UI | ✅ |
| ~~S6-a~~ | ℹ️ | ~~session 掉线~~ → 已查清为 agent-browser cookie 抖动,**非 app bug** | 工具 | 无需修 |
| S6-b/S10-a | 🟨 | #990 路由缺口:per-session 无路由规则(全局 system_default 兜底) | core 路由 | ❌ 待 lead |
| S1-b/c, S3-a, S4-a, S6-c/d, S7-b/c, S9 余 | 🟨 | H1/H2 冗余、种子 typo、stale echo 绑定、Adapter 下拉等打磨项 | UI/数据 | ✅ |

**FP5 建议先修(纯 UI、无需 lead):** S5-a/b(错误文案/重试,影响最广)→ S9(kanban 导航)→
S1-a(调试文案)→ S7-a(时间格式化)→ 一批 H1/H2 冗余统一。**待 lead 对齐后再碰:** S5 根因
(cc 激活预算 / py read_cascade)、#990 路由(S6-b/S10-a)、S6-a session TTL。

## 待 lead 对齐(核心侧,不在 FP5 自修 — 对应 contributing P0)

1. **cc 冷激活 >5s ReadyGate 预算**(`invocation.ex:181`)→ 所有需 live-agent dispatch 的详情面
   超时。与 `world-e2e-seed.md` §3 已知阻塞同族。
2. **py agent 未实现 `:read_cascade`** → config 面 `:unknown_action`。behavior/action 覆盖缺口。
3. **#990 路由缺口**:新建 session 无 per-session 路由规则;全局 `system_default`(`$session_users,
   $mentions`)兜底是否足够?是否需新 session 自动套用 + per-session 规则可视化?

---

## 巡检前必修的环境阻塞(已处理)

- **B0 · world React 岛构建失败,全部面被 vite error overlay 盖死** — `@xyflow/react`
  本地 node_modules 损坏(`package.json` 等多文件 0 字节,`File is empty` JSONError)。
  **不是 UI 设计问题,是本地依赖损坏**(npm cache `TAR_BAD_ARCHIVE`)。已 `npm install
  @xyflow/react@^12.11.1 --legacy-peer-deps`(带 7890 代理)修复;world 恢复渲染。
  ⚠️ 副作用:tracked 的 `package-lock.json` 被 churn(removed 20/changed 292),
  巡检后需还原干净,不随 FP5 提交。证据:`01-sessions.png`(修前 overlay 截图见 git 历史快照前一版)。

---

## ⚠️ 方法论 caveat(避免误报)

- **agent-browser headless chromium 缺 CJK 字体**:所有中文在**截图**里渲染成豆腐块 □
  (均匀方块 = 字体缺字形,非编码 mojibake)。已用无障碍树(a11y tree,读 DOM 真实文本、
  不受字体影响)核对:如 "默认: default"、"请求 kind.behavior（action 默认 any）→ 系统按
  CapBAC 授予（详情页显示 granted）" 底层字符串**完全正常**,源码 `Identities.tsx:560` 亦正确。
  **真实浏览器里中文正常**。→ 本清单**不据截图判断中文渲染**;凡涉及文案,以 a11y 树/源码为准。

## UI 问题清单(分级:🟥 阻断 / 🟧 明显瑕疵 / 🟨 打磨项)

### S1 · Sessions 面(`/sessions`) — 证据 `01-sessions.png`

- 🟧 **S1-a 调试文案泄漏**:Session activity 卡片副标题显示 **"Rendered by React from
  LiveView state."** —— 开发期调试说明,不该展示给操作员。
- 🟨 **S1-b Layout 脚手架压在普通页顶部**:Sessions 页顶部有 "Layout"(layout_editor /
  sessions_table + 全 disabled 的上下移按钮 + "Layout changes require manage access")。
  布局编辑脚手架出现在常规 Sessions 视图,信息层级突兀。需确认是否有意。
- 🟨 **S1-c 种子数据拼写**:`session://system/default/feishu-bing`(应为 `feishu-bind`)。
  与 FP4 已知 s10 文件名 typo 同源,此处是 session 名/种子数据层面。

### S2 · Overview 面(`/` 根/落地页) — 证据 `02-overview.png`

- 🟧 **S2-a Overview 无独立内容,与 Sessions 完全雷同**:访问 `/` 渲染出的页面与
  `/sessions` 逐像素相同(同 "Sessions" H1、同 Layout 面板、同 Session activity 表)。
  左导航高亮 "Overview",但页面 H1 仍是 "Sessions" —— **名实不符,落地页缺独立
  dashboard/概览**(操作员进系统第一眼看到的是裸 Sessions 表,无总览/快捷入口/状态概要)。

### S3 · Identities 列表(`/identities`) — 证据 `03-identities.png`

- ✅ 整体良好:卡片网格(claude-bot/e2e-test=Agent cc,py_default=Agent py,Admin=User),
  过滤 All/Users/Agents/agent:cc/agent:py 正常,仅显示 system workspace 身份(合理)。
- 🟨 **S3-a H1/H2 标题重复**:页面 H1 "Identities" + 卡片区 H2 "Identities"(带 "DIRECTORY"
  eyebrow),同词重复。多个面共有此模式(见 S4),建议统一(H2 用更具体的小标题或省略)。

### S4 · New Agent 表单(`/identities/agents/new`) — 证据 `04-agent-new.png`

- ✅ 结构良好:Flavor 下拉(cc/cc-headless/codex/codex-remote/curl/hello_builder/native/np/py)、
  Name、project_cwd、CC 配置(Model/Effort/Permission mode/Tools)、Requested caps、With PTY。
  中文文案经 a11y 树核对正常(截图豆腐块为字体假象,见 caveat)。
- 🟨 **S4-a H1/H2 重复**:同 S3-a("New Agent" / "New agent"),且大小写不一致。

### S5 · 🟥 Agent 详情子面对真实 agent 大面积失效(头号发现)

证据:`05-agent-config.png`(cc)、`06-agent-config-py.png`(py)、`07-agent-caps.png`(cc caps)。

**现象**:点进 agent 详情的 config / caps(及大概率 api-keys/extensions/terminal)子面,
页面先转圈,随后红色错误框抛出**裸 error tuple**,内容为空:

| 子面 | agent | 抛出的错误 |
|---|---|---|
| `/config` | claude-bot(cc) | `:activate_timeout` |
| `/config` | py_default(py) | `{:unknown_action, :read_cascade}` |
| `/caps` | claude-bot(cc) | `:activate_timeout`(下方 caps 表空) |

**根因(两类,均属 core/behavior,P0 须与 lead 对齐,不擅动)**:
1. **cc 冷激活超预算**:这些子面 dispatch `:call` 到 live agent 读配置/caps,触发 cc agent
   PTY 激活;`ReadyGate.await(uri, 5_000)`(`invocation.ex:181`)5s 超时 → `:activate_timeout`。
   与 `docs/guide/world-e2e-seed.md` §3 已知阻塞(orchestrator/template 实例化慢)同族。
2. **py 缺 action**:py agent 的 Kind 未实现 config 面所调的 `:read_cascade` → `:unknown_action`。
   是 behavior/action 覆盖缺口。

**UI 可修部分(本 FP5 范围)**:
- 🟧 **S5-a 裸 error tuple 泄漏**:`:activate_timeout` / `{:unknown_action, :read_cascade}`
  这类 Elixir 内部 tuple 直接展示给操作员。应转友好文案(如"agent 正在启动，稍候重试"/
  "该 flavor 暂不支持读取此配置")。
- 🟧 **S5-b 无激活态/重试**:cc 冷激活本就需时间,UI 应 lazy-activate + spinner + 超时后
  "重试"按钮,而非一次性 5s 失败终态。
- 🟨 **S5-c H1/H2 重复 + 大小写**:"Agent Config/Agent config"、"Entity Caps/Entity caps"。

> **核心侧根因登记(待 lead 对齐,不在 FP5 自行修)**:cc 激活 >5s ReadyGate 预算;
> py 未实现 `:read_cascade`。与 #990 路由缺口一并提交对齐。

### S6 · Admin 簇 — 证据 `08-admin.png` ~ `16-admin-routing.png`

整体健康:Dashboard(统计卡 Kinds 22/Sessions 3/Workspaces 4/Entities 9/Agents 3 + CC
orchestrator "ok" 面板)、Observability/Invocations、Entity Registry、Snapshots、Templates、
Capabilities/Grantable、Authz Audit、Settings(Save SMTP)、Routing 全部正常渲染。

- ℹ️ **S6-a(已查清,降级为非 bug)巡检中途被弹回登录**:复测 + 查 server 日志确认为
  **agent-browser 的 cookie 持久化抖动**,非 app bug。日志中对应行是
  `Phoenix.Router halted in EzagentWeb.Plugs.RequireEntity.call/2`(认证插件因请求未带 cookie 而
  拦截),**全程零 LiveView 崩溃 / 零 Elixir 异常**(61 条 `[error]` 全是 boot 期 `zyli-codex-1`
  陈旧 codex sidecar crash-loop,与导航无关)。换全新 agent-browser session 后,导航到 config 页
  **不再登出** → 排除"坏详情页踢人"假设。操作员真实浏览器不受影响。
- 🟨 **S6-b Routing 与 #990 的关系待厘清**:`/admin/routing` 有全局 mention 规则 `system_default`
  (`$session_users, $mentions`);但 handoff #990 称"新建 session 无默认 always→members 规则、
  @ 消息不投递"。→ 需厘清:全局规则存在,但**新 session 是否自动套用**?(核心路由,入待对齐清单)
- 🟨 **S6-c stale echo 绑定**:External Mirror 绑定表有 `protocol_api → l5_echo_0624`,echo 插件已
  于 #1011 删除 → 残留 stale 绑定数据(种子/历史遗留,非 UI bug,清理项)。
- 🟨 **S6-d H1/H2 冗余**:Admin 各面均 H1/H2 同词(Admin Dashboard/Dashboard 等)。

### S7 · F9 External Mirror 面(`/admin/sessions/:id/external_mirror`,zyli 自己交付) — 证据 `17-external-mirror-f9.png`

- ✅ 功能完整:Session URI + Bind 表单(Adapter/Target chat id/Bind)+ 绑定表(Adapter/Target/
  Workspace/Bound/Unbind)。zyli F9 交付物渲染正常。
- 🟧 **S7-a Bound 列泄漏裸 Elixir 时间**:显示 `~N[2026-06-25 03:13:37.475284]`(NaiveDateTime
  sigil 原样输出),应格式化为人类可读(`2026-06-25 03:13` 或相对时间)。
- 🟨 **S7-b Adapter 自由文本框**:预填 "feishu",可改为已注册 adapter 下拉(feishu/protocol_api),
  减少手误。
- 🟨 **S7-c H1/H2 冗余**(External Mirror/External mirror)。

### S8 · Workspaces / Plugins / Profile — 证据 `18`~`22`

- ✅ `/workspaces`(表:Name/URI、Members、Templates、Rules)、`/plugins`(Installed plugins)、
  `/plugins/feishu/bindings`(User bindings + Bindings 表 open_id/user_uri/bound_by)、
  `/profile`(Admin 卡 + Edit display name + Capabilities + View caps)均正常渲染、导航高亮正确。

### S9 · 🟧 Kanban 面导航/标题错位(`/plugins/kanban`) — 证据 `21-plugins-kanban.png`

- 🟧 **S9-a H1 错误**:页面 H1 显示 **"Sessions"**,应为 "Kanban/看板"(H2 才是 "看板 · 配置")。
- 🟧 **S9-b 左导航高亮错误**:进 `/plugins/kanban` 时左导航高亮 **"Overview"**,应高亮 "Plugins"
  (kanban 隶属 Plugins)。
- ✅ 内容本身正常(Miro 连接 Access Token + GitHub PAT 配置表单)。

### S10 · Conversation 对话面(`/sessions?session=<uri>`) — 证据 `23-conversation.png`

- ✅ 构建扎实:transcript(气泡区分 YOU/AGENT)、composer("@ to mention" + Attach + Send)、
  Chat/PTY 切换、Restart orchestrator、debug 面板、expand layout、MEMBERS 面板(test-curl-1
  AGENT + Admin USER + Invite)、ROUTING 面板(Always matcher + Receivers + Add)。
- 🟨 **S10-a ROUTING 面板 "0 / No session routing rules"(印证 #990)**:此 session 无 per-session
  路由规则。但本例 agent 确实回复了(全局 `system_default` 规则兜住投递)→ **#990 的"@ 不投递"
  在有全局规则时被缓解;需厘清"新建 session 是否需自动套用/可视化 per-session 规则"**。属核心路由,
  入待对齐清单(见末节)。
- ℹ️ agent 回复 "no API key for provider `deepseek`" 是 test-curl-1 自身缺 key(功能态,非 UI bug);
  其指引的修复入口 `/identities/agents/.../api-keys` 本身受 S5(activate_timeout)影响。
