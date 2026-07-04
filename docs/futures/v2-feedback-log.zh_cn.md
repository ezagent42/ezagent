# V2 反馈日志

> **状态**: 进行中 — V1 验收阶段从 2026-05-21 开始。Allen 手动测试
> ezagent V1（Phase 9 已关闭）；Claude 把每条反馈原话记录在这里 +
> 抽象其本质原因。
>
> V2 规划开始时，这份文档是输入源。记录期间**不实施**。

## 记录协议

每条反馈一个条目，**4 个字段**:

1. **原始反馈 (Raw quote)** — Allen 从 Feishu 发的原话（中文保留，
   不释义，不"Allen 的意思是"）。包括时间戳 + Feishu message_id 当
   可得。
2. **本质原因 (Abstracted root cause)** — 这暴露了系统或交互的什么
   一般属性？要比具体 bug 高一层抽象。"哪类设计错了？"而不是
   "哪行代码错了？"
3. **V2 影响 (V2 implication)** — 需要 SPEC 改动、架构调整、新抽象、
   删抽象，还是仅 per-feature fix？标 scope: structural / tactical /
   ergonomic。
4. **候选方案 (Candidate solutions)** — 1-3 个方向，带 trade-off。
   **不**是决定；那是 V2 规划期的事。

按**主题**分组（顶级 `##` 区段）。主题从反馈内容派生，不预设。
新模式涌现时加新主题。

## 可能出现的主题（初步猜测，可调整）

- **URI ergonomics**（3 段 URI 啰嗦；用户感受到成本吗？）
- **Workspace 切换 UX**（Keycloak 模型有原则但够直观吗？）
- **Auth flow surface**（workspace 参数繁琐；bare-handle vs 完整 URI 的 ergonomics）
- **Admin 工具 gap**（手动 mix task vs LV CRUD；缺什么）
- **Session 生命周期**（session 何时持久化；rehydration 语义）
- **Plugin authoring 摩擦**（参考 `feedback_north_star_plugin_isolation`）
- **Multi-agent orchestration UX**（Phase 7 orchestrator 在 V1 怎么呈现）
- **Demo / first-run 体验**（新 dev 跑 `mix phx.server` —— 撞见什么）
- **可观测性 gap**（出问题时，能不能看出原因？）

---

## V2 规划触发

当 Allen 说"开始 V2 规划"（或等价）时，本文档变成
`superpowers:brainstorming` 会话的输入，产出:

1. `docs/superpowers/specs/<YYYY-MM-DD>-ezagent-v2-charter.md` ——
   按主题综合 + V2 目标 + 非目标
2. 每主题的 SPEC draft（按 Phase 9 模式）
3. 修订的 PR 序列（可能是 V2 的多个 phase）

在此之前：**记录，不实施**。

---

## 条目

## Workflow gap — UI "create agent" 动词隐藏了 instantiate step

### 原始反馈

> [Feishu 2026-05-21 15:59 (GMT+9), msg `om_x100b6fde9bf484a8c4afee8c48a8120`]
> 我刚创建了 Agent: entity://agent/default/cc_demo，但看起来还是显示not running, 请检查是否已经启动？如果没有，为什么？如果启动了，为什么显示not running?

### 本质原因

V1 的 user-facing 动词 **"create agent"** **不等于** **"agent 准备好接收消息"**。UI 流程把 "create" 拆成 3 个内部步骤（spawn Kind 进 supervisor + 把 cc.agent template 加进 workspace.session_templates JSON + 通过 `cc.agent.instantiate/3` 启 PtyServer），但 `AgentNewLive.handle_event("create_agent")` 只做了 1+2 步。第 3 步（启 PtyServer）只在 `Workspace.Loader.load_all/0` 在 phx boot 时跑 — 所以新建的 cc agent 要等到 phx 重启才会真正 running。

这跟 **Phase 8c bare-handle bounce** bug 是同一类抽象漏出（auth 动词的表面效果跟实际存进 session 的内容不一致）。共同模式：user-facing 动词的 dispatch 路径在结构上**不完整**, 比动词的表面意思**少做了事**。

### V2 影响

- **Scope**: structural — V1 的 `AgentNewLive` "create" 动词有误导性，不是一行能修的
- **Affects**: `EzagentPluginLiveview.AgentNewLive`, `Ezagent.Workspace.Loader`, `Ezagent.PluginCc.PtyServer` 生命周期，可能还有 "agent kind 生命周期阶段" 抽象本身
- **Blocks**: Allen 的 V1 cc agent 测试（workaround: phx 重启）—— 不硬阻塞其它测试
- **相关 Phase 9 PR/SPEC**: 无直接关联；这是 Phase 8c 的表面 bug 被 V1 测试 surface 出来
- **相关 memory**: 形态类似 Phase 8c bare-handle bounce 触发 `SessionPrincipal.put/2` invariant 的 bug

### 候选方案

- **A — AgentNewLive 战术修复**: `add_template` 之后加一个 `Workspace.invoke_template(workspace_uri, tmpl_name)` step。一个额外 dispatch 调用。Trade-off: 保留了 "spawn Kind + register template + instantiate template" 三步分裂；只有 LV 这条路径知道要串起来。其它 create 路径（CLI, API）要重复这个串接。
- **B — agent 生命周期重构为显式阶段**: UI 显示 `registered → instantiated → running` 带显式转换。"Not running" 变成 "Registered but not instantiated"。Trade-off: UI 更复杂但没隐藏 gap；user 看得到当前在哪个阶段。
- **C — 把 "create + instantiate" 合成单个 dispatch action**（推荐 V2）: 在 Behavior 层统一 workflow。`Ezagent.ActionSet.AgentLifecycle.create_and_start` 是一个 cap-gated dispatch；AgentNewLive / CLI / API 都 invoke 同一个 action。Trade-off: 需要新 Behavior；最干净的抽象；符合 Phase 9 "dispatch 是唯一路径" invariant（Decision #3，invariant 1）。

### 链接

- **V1 战术 fix 已发布**: PR #175 (commit `c60cd32`) — Workspace.add_template chains to invoke_template + AgentNewLive spawn 反序修正 + Domain.Agent.lifecycle_status facade + cc.agent mode/remote-channel dead code 删除
- Phase 8c 同类模式: bare-handle bounce → `SessionPrincipal.put/2` invariant
- Allen 2026-05-21 16:22 Q2 澄清: cc plugin 原设计是 channel 为本体 + 可选 PTY；remote-channel 是延期 placeholder；**当前方向**（Allen 决定）: 只保留 local-pty mode，将来 remote 是另一个 plugin。PR #175 按这个做。
- Allen 2026-05-21 Q3 澄清: Agent UI fix **是** V1 work（不是 V2 延期）；V2 会引用 V1 的 Domain.Agent facade 作为架构样板。
- 测试 gap **已关闭** in PR #175: "AgentNewLive create_agent → 同时 Agent Kind + PtyServer alive" e2e 回归测试

## V2 宏 charter — Phoenix-Plug 风格 spawn pipeline（Allen 草图 + Claude refinement）

### Allen 的 V2 宏草图（Feishu 2026-05-21 16:36, msg `om_x100b6fdf11dbe8a8c333bbaa75d77c7`）

> [原话引用]
> defmodule Ezagent.Plugin.Cc.Template.CcAgent do
>   use Ezagent.Kind.Template,
>   use Ezagent.Entity.Agent
>     agent_types: cc,
>     spawns_with: [Ezagent.Domain.Pty.PtyServer]
>     spawns_pipeline: Agent.spawn |> Caps.grant |> Pty.Start |> Channel.connect |>  Session.join

### Refined V2 syntax（Claude — Elixir 现实约束）

```elixir
defmodule Ezagent.PluginCc.Template.CcAgent do
  use Ezagent.Kind.Template,
    creates: Ezagent.Entity.Agent,
    flavor: "cc",
    spawns_with: [Ezagent.Domain.Pty.PtyServer]

  spawn_pipeline do
    step Ezagent.Lifecycle.AgentSpawn
    step Ezagent.Lifecycle.CapsGrant
    step Ezagent.Lifecycle.PtyStart
    step Ezagent.Lifecycle.ChannelConnect
    step Ezagent.Lifecycle.SessionJoin
  end

  def required_params, do: [:agent_uri, :cwd]
end
```

### 为什么改 Allen 的草图

| Allen 草图 | 调整 | 原因 |
|---|---|---|
| `use Foo, use Bar` | 单个 `use` 带 options | Elixir 不允许 statement 里两个 `use`；常见 idiom 是单 `use` + keyword options |
| `agent_types: cc` (atom) | `flavor: "cc"` (string) | 匹配 Phase 9 SPEC §5.14 `entity://agent/<flavor>_<name>` URI shape（flavor 是 string prefix） |
| `Foo \|> Bar \|> Baz` 在 attribute level | `spawn_pipeline do step Foo; step Bar; ... end` block macro | `\|>` 是 runtime operator，无法在 module-definition time 求值。Phoenix 的 `pipeline :browser do plug X end` 是 Elixir DSL 的标准 pattern |
| `Ezagent.Domain.Pty.PtyServer`（Domain layer）| 保留 — Allen 好建议 | PTY 是 generic capability（cc 之外 future flavor 也可能用）；domain layer 是正确位置（当前在 plugin_cc — V2 promote） |

### 宏 expansion（macro 生成什么）

`use Ezagent.Kind.Template` + `spawn_pipeline` block 生成:

1. **`instantiate/3` callback**: 串接 pipeline 各 step 带 context（类似 Plug.Conn — 每 step 接 `%Ezagent.Lifecycle.Context{}` struct 返 `{:ok, context}` 或 `{:error, reason, context}`）
2. **`flavor_match?/1` helper**: 按声明的 flavor prefix match URI
3. **`Ezagent.Domain.Agent.lifecycle_status/1` 集成**: 自动从 pipeline 最远完成的 step 派生 phase
4. **Pipeline trace / debugging**: 每个 step record 进 telemetry；debugger UI 显示 "stuck at PtyStart" 而不是神秘的 "Not running"
5. **terminate/3 反向 pipeline**: graceful shutdown 反序跑 (SessionLeave → ChannelDisconnect → PtyStop → CapsRevoke → AgentDespawn)
6. **Cap-gated**: 每个 step 声明所需 cap（如 `PtyStart` 需要 `pty.start` cap）；首次 denial 即 halt

### V2 为什么重要

- **Plugin authoring 摩擦减少**: cc plugin 作者写 ~5 行 + 5 个 lifecycle 模块（每 step 一个）；orchestration 由 macro 生成
- **跨 plugin 可组合**: feishu plugin 可加 `Ezagent.PluginFeishu.Lifecycle.WebhookRegister` step 不动 cc plugin
- **可调试性**: pipeline trace 胜过 "Not running" 谜题 —— operator 看到 exactly 哪个 step 失败
- **再也没 reverse-spawn-order bug**: pipeline 顺序声明式 + 编译期检查
- **terminate 对称**: 今天没 graceful agent shutdown；V2 macro 免费给

### Trade-off

- `Ezagent.Kind.Template` 本身 macro 复杂度增（~200 LOC macro）
- Plugin 作者学新 DSL（用 Phoenix Plug 熟悉度缓解）
- Edge case: 动态 pipeline（template 根据 params 选 step）—— 需设计

### 推荐 V2 PR 序列

1. 定义 `Ezagent.Lifecycle.Step` Behaviour (`call/2` + `terminate/2`)
2. 实现 `spawn_pipeline` macro 在 `Ezagent.Kind.Template`
3. cc.agent template 重构用 macro（迁移测试：行为保留）
4. echo/curl/future plugin 重构用 macro
5. `Ezagent.Domain.Pty` 从 plugin_cc 推上 Domain layer（PTY = generic capability）
6. CI gate: 每个 plugin Template 必须用 macro (grep gate)

### 链接

- Allen 关于 bug 历史 + 预防策略问题 Feishu 2026-05-21 16:37 (msg `om_x100b6fdf2f46b094c3ada79847ecc1c`) — 答案在下面条目

---

## 架构预防 — 反序 spawn bug 是怎么钻过去的，如何根本预防

### 原始反馈

> [Feishu 2026-05-21 16:37 (GMT+9), msg `om_x100b6fdf2f46b094c3ada79847ecc1c`]
> agent spawn 反序问题是怎么出现的，如何预防？

### 本质原因

bug ship 因为**测试集分辨不出 "Kind 由直接 spawn + Template 作为 config" 和 "Kind 由 Template 作为 creator"**。两种状态都满足 `KindRegistry.lookup → {:ok, _}`；只有当 template instantiate 是**唯一** creator 时 layering invariant 才成立。

3 个促成因素:

1. **Idempotent instantiate 掩盖了 bug**: `cc.agent.instantiate/3` 见到 `KindRegistry.lookup → {:ok, _}` 就 short-circuit。pre-spawn flow 工作是因为 instantiate "宽容" —— 但宽容吃掉了架构 invariant。
2. **没有 "每个 Agent Kind 都来自 Template" invariant test**: 现有 invariant 断言 workspace binding、URI shape、cap workspace —— 没有断言 provenance。
3. **心智模型漏出**: AgentNewLive 作者（Phase 8c PR-N）想 "Kind = 东西; Template = 配置"。正确模型: "Template = 创建者; Kind = 产物"。没有 macro 强制，每个 author 都重新决定一次。

### V2 影响

- **Scope**: structural (macro 强制) + tactical (invariant test) + skill update
- **Affects**: SpawnRegistry, Kind/Template authoring story, ezagent-developer SKILL.md anti-pattern
- **Blocks**: V2 macro 设计是结构性答案；invariant test + skill update 中间过渡

### 候选方案 — 5 层防御

| Layer | 策略 | 时机 |
|---|---|---|
| 1. 结构性 | macro 生成的 `spawn_pipeline` 让 "spawn 在 template 外" 编译期不可能 | V2 |
| 2. Invariant test | Runtime: 每个 alive `entity://agent/<flavor>_*` Kind 在某 workspace.session_templates 都有 matching template | V1（建议跟进 PR）|
| 3. Domain API | `Ezagent.Domain.Agent.create(flavor, name, params)` 作为**唯一** user-facing 创建 API; UI/CLI/API 都走它 | V1 fix #175 部分（facade 已加；未强制为唯一入口）|
| 4. SKILL.md anti-pattern | "Never call SpawnRegistry.spawn(entity://agent/...) directly outside Template.instantiate/3" 加进 ezagent-developer skill | V1（建议跟进 PR）|
| 5. CI gate | 静态 grep: lib/ code 在 template 模块外调 `SpawnRegistry.spawn(entity://agent/...)` 即 fail CI | V1（建议跟进 PR）|

**V2 的 macro (Layer 1) 是结构性 fix**。Layer 2 + 4 + 5 是 V1 follow-up，Allen 可授权（Feishu 16:50 问）。Layer 3 部分由 Fix 2 (Domain.Agent facade) 完成；让它成为**唯一**入口是 V2 scope。

### 链接

- Bug 起源: Phase 8c PR-N (AgentNewLive 创建, 2026-05-20)
- V1 fix: PR #175 (commit `c60cd32`)
- V2 macro: 本文档上一条目



### 条目模板

```markdown
## <主题> — <一句话摘要>

### 原始反馈

> [Feishu 2026-MM-DD HH:MM, msg `om_xxx`]
> <Allen 原话，中文保留>

### 本质原因

<1-3 句。不是"按钮坏了"而是"反馈 X 暴露缺失抽象：系统没有
Y 概念，所以用户得手动做 Z"。抽高一层。>

### V2 影响

- **Scope**: structural | tactical | ergonomic
- **Affects**: <影响的子系统 / SPEC 章节 / invariant>
- **Blocks**: <依赖的其它反馈，如有>

### 候选方案

- **A**: <方向>；trade-off: <代价>
- **B**: <方向>；trade-off: <代价>
- **C**（如适用）: <方向>；trade-off: <代价>

### 链接

- 相关 Phase 9 PR/SPEC: <ref 如有>
- 相关 memory: <feedback_xxx 如有>
- 相关 Decision Log 条目: #<number> 如有
```

---

## 约定

- **按 memory `feedback_bilingual_docs_convention`**: 本文档有
  `.md` 平行英文版，两个文件同步更新。
- **按 memory `feedback_subagent_review_plans`**: V2 规划开始时，
  SPEC subagent 要读**两份**: 本文档 + Phase 9 SPEC + amendments +
  demo doc。
- **按 memory `feedback_completion_requires_invariant_test`**: V2
  feature 需要 invariant test；本文档识别**应该**是 invariant 的
  东西。
- **不提前实施**: 即使 fix 是一行，先记录在这里。Allen + Claude
  review 抽象 pass 然后再 implementation pass。重点是发现跨反馈的
  模式，不是追个别症状。
