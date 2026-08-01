# Ezagent v0.4 — IMPLEMENTATION ROADMAP

> **Status**: 定稿(架构师 SUGGESTION + Allen 4 轮 grill + dev review 三个 brainstorm section + 架构师 2 轮 roadmap review 闭环)
> **基于**: `ARCHITECTURE.md` v0.4_final(Decision Log #1-#79;本 roadmap review 衍生的 #80/#81/#82 由架构师 patch 进 ARCHITECTURE.md)
> **本文档的作用**: 把 ezagent 的实施切成 6 个 phase。**它不是详细实施规格**——每个 phase 进实施前要先 `/brainstorm` 出该 phase 的 `SPEC/VERIFICATION/PLAN/DECISIONS`,再 `/goal` 实施。这份 roadmap 是每个 per-phase brainstorm 的**种子**。

---

## 0. 这份文档怎么用

### 0.1 工作流闭环(每个 phase)

```
roadmap 里这个 phase 的 entry
   │
   ▼
per-phase /brainstorm
   │  产出 docs/phase-specs/phaseN/{SPEC, VERIFICATION, PLAN, DECISIONS}.md
   │  (VERIFICATION 先于 PLAN 写 —— 它是 sub-step 之间的契约)
   ▼
/goal 实施 (Allen AFK)
   │  ├─ sub-step Na: 写代码 → 跑 e2e flow gate + 单元/集成测试 → 全绿 → tag phaseNa
   │  ├─ sub-step Nb: ...                                      → tag phaseNb
   │  └─ 撞墙(gate 红 / 不变式违反)→ /goal 自动暂停,等 Allen 回来 grill
   ▼
phase 整体完成 → Allen review
   │  (对照 entry 的「测试员体验」+「人 review 关键点」+ GLOSSARY 新增决策)
   ▼
phaseN git tag → 下一个 phase
```

**phase 是 brainstorm 单元 + Allen review 单元;sub-step 是 /goal 内部执行单元 + e2e gate 单元 + 撞墙 revert 单元。** Allen 在 sub-step 期间 AFK,只有撞墙才被拉回(Decision #80)。

### 0.2 每个 phase entry 的模板(10 字段)

1. **目标** — 一句话,phase 完成后系统能做什么
2. **测试员体验 / demo** — 人坐在屏幕前能**具体**做什么、看到什么
3. **Deliverables** — 多 deliverable 的 phase 分 sub-step(Na/Nb/...),每个列核心模块 + 大致 LOC(core / plugin 分开标)
4. **前序依赖** — 依赖前面哪个 phase 的什么产出
5. **当前 esr 状态对照** — 涉及的功能现有 esr 怎么做、有什么可复用、有什么坑
6. **测试** — e2e flow track 在这个 phase 让哪几条 flow 可跑(走什么 transport)+ 这个 phase 自带的单元/集成测试范围
7. **相关不变式** — 8 条硬不变式里这个 phase 特别相关的几条
8. **人 review 关键点** — Allen 验收 checklist
9. **brainstorm 时要重点展开的点** — 进 per-phase brainstorm 时真正需要 grill 的开放问题
10. **typical 决策点** — 实施期大概率撞到的判断点

---

## 1. 总体结构

### 1.1 7 个 phase + sub-step 模型

(原 v0.4 roadmap 写 6 个 phase 收尾于 Phase 5;post-Phase-5 实施期 Allen 加 Phase 6,scope 见 §9 below。)

| Phase | 主题 | sub-step | status |
|---|---|---|---|
| **0** | 项目骨架 + 工具链 | 单块 | ✅ done |
| **1** | ezagent_core MVP + LiveView admin + CC bridge 原型 | 1a → 1b → 1c | ✅ done |
| **2** | Routing + Matcher + Chat + 单 session IM | 2a → 2b | ✅ done |
| **3** | Persistence + Kind 模型补全(Templates / Workspace / Agent / CapBAC) | 3a → 3b → 3c → 3d | ✅ done |
| **4** | LiveView IM 完整化 + CLI 自动派生 + View 同构 | 4a → 4b | ✅ done |
| **4.5** | Operator/Admin Tools Maturity + Snapshot Observability + Per-rule CapBAC(in-flight 中临时插入) | 4.5-1 ... 4.5-5 | ✅ done |
| **5** | Feishu + CC channel + Pty-Web | 5a → 5b → 5c | ✅ done w/ known gap(v1→v2 CC channel wire swap → moved to Phase 6) |
| **6** | Three-Layer Restructure(core / domain / plugin)+ shadcn-like UI + Python contract(详见 `docs/phase-specs/phase6/SPEC.md`) | 6-1, 6-2, 6-3, 6-5, 6-11, 6-12 done; 6-4/6-7/6-8/6-9/6-10 moved to Phase 7 | ⚠️ partial — six PRs shipped (extraction + UI domain + applies_to_users + Python contract + closeout), CC channel v2 + multi-user surface deferred to Phase 7 |

**sub-step 是 /goal 的内部 e2e gate,不是 Allen 介入点**(Decision #80):

- 每个 sub-step 完成时,/goal 自动跑该 sub-step 对应的 e2e flow(§2)+ 单元/集成测试
- 全部 gate 绿才能进下一 sub-step,并打内部 tag(`phaseNa` / `phaseNb` / ...)
- sub-step 撞墙(gate 红 / 不变式违反)→ /goal 自动暂停,等 Allen 回来 grill
- Allen 在**整 phase 完成后**才 review;sub-step 期间 AFK

把"行为正确性"(自动化的 e2e gate)和"架构设计判断"(整 phase 后人来)拆开 —— Phase 3 有 4 个 sub-step 不意味着 Allen 介入 4 次。

### 1.2 4 条贯穿 track

不属于某个 phase,每个 phase 都做:

| Track Name | 内容 | 起始 |
|---|---|---|
| **不变式 track** | §1.3 的 8 条,每 phase 完成前 grep 自查,`/goal` 提示词带这 8 条 | Phase 0 |
| **同构 track** | CLI ↔ LiveView 每个新 Behavior 必须两端等价(定义见 §1.4),不等价 = bug | Phase 2(spot-check)→ Phase 4(CI 硬门) |
| **e2e flow track** | manual-check feishu-cc 流程抽成 transport-agnostic 操作流程(§2),Phase 1+ 走 LiveView 验、Phase 5 走 Feishu 验;**作为 /goal 的 sub-step 内 gate**(§1.1) | Phase 1 |
| **词汇 track** | `GLOSSARY.md` 术语表 + 易混淆词表 + 消歧 convention;新文档/代码复用易混淆词必须用消歧写法 | Phase 0 |

### 1.3 设计原则 → 见 SKILL 权威集

历史上本节列过 "10 条硬不变式"(来自 ARCHITECTURE v0.4 Decision Log)。现已合并进 SKILL 权威集:

**权威源**:`.claude/skills/ezagent-developer/SKILL.md` §Design Principles — 26 条编号原则(P1-P26)+ `Where each old principle now lives` 对照表(含本节 10 条的逐项映射)。Phase 实施期任何 sub-step 完成前的 grep 自查也以 SKILL 为准。

### 1.4 CLI ↔ LiveView 同构等价 — 精确定义

**同构等价 = Invocation 等价 + Coverage 等价 + 同 BEAM,不含渲染。**

- **Invocation 等价**:对同一个 `(Behavior, action, args)`,两个 UI 构造出的 `%Invocation{}` 的 `target` / `mode` / `args` **完全相同**;只允许 `ctx.reply`(transport 决定)和 `ctx.caller`(principal 决定)不同。
- **Coverage 等价**:`@interface` 里声明的每个 action,两个 UI 都调得到;不存在「只在一端有」的 action。
- **同 BEAM**(post-Phase-5 strengthening,Allen 2026-05-17 + Decision #130):两端的 dispatch 必须 hit **同一个 BEAM**——CLI 用 distributed Erlang RPC 进入 runtime 节点,LV 本来就在 runtime 节点内。任何走"CLI 自己 boot 一个 VM" 的设计都违反此条。
- **不含渲染**:`Ezagent.View` 层(LiveView HTML vs CLI ANSI)故意不同,不在等价范围内。

执行机制随 phase 演化:**Phase 2-3 手动 spot-check**(CLI 还是手写的)→ **Phase 4+ 自动 CI property test**(对每个注册 action,LiveView 解析出的 Invocation 和 CLI 解析出的 Invocation 相等 modulo `ctx.reply`/`ctx.caller`)→ **post-Phase-5 同-BEAM gate**(`cli_lv_same_server_invariant_test.exs`)。

### 1.5 长期组件的 phase 增量

某些组件不是某个 phase 的产物,而是从 Phase 1 起一路增量长大,跨多个 phase。brainstorm 时把它们视作连续的 plugin,**不要在 phase 之间"重新创建"**:

| 组件 | Phase 1 | Phase 2 | Phase 3 | Phase 4 | Phase 5 |
|---|---|---|---|---|---|
| `ezagent_web_liveview` plugin | `/admin`(audit + manual dispatch) | + `/sessions/:id` | + `/workspaces` + workspace 切换 | + slash command + rules side panel + multi-view | unchanged |
| `esr_adapter_cli` plugin | — | 起步(`esr send` / `session list` 手写) | + `esr workspace` | + 从 `@interface` 自动派生 | — |
| `ezagent_core` LOC(**core-only 累计**) | ~420 | ~600 | ~775 | ~805(+`view.ex`) | unchanged |

Phase 4 的 "LiveView IM 完整化" **不是从零做 LiveView**,是给 Phase 1-3 累计的 plugin 加最后一层 UI 功能。`ezagent_core` LOC 行**只算 core**(plugin 代码不进这行;plugin 不在 ARCHITECTURE.md §14 budget 内)—— core-only 累计 ~805 < target 870 < red line 1100。

---

## 2. 测试 e2e flow track

### 2.1 transport-agnostic flow 格式

产出 `docs/phase-specs/e2e-parity/FLOWS.md`,把 `docs/notes/manual-e2e-verification.md`(老 esr 的 feishu-cc 人工验证流程)抽成 **transport-agnostic 操作流程**——每条 flow = 一串「人的动作 → 期望的系统行为」,不绑 transport。**操作流程不变,变的只是走哪个 transport**(LiveView 早期 / Feishu 最终)。

### 2.2 核心 8 条 flow

| # | Flow | 来源 | 最早可跑 |
|---|---|---|---|
| F1 | 文本往返(人发文本 → agent react → agent reply) | 单app DM step 2 | Phase 1(LiveView + Echo) |
| F2 | 触发工具(人要求工具动作 → 执行 → 结果回) | 单app DM step 3-4(send_file) | Phase 4(@command Behavior) |
| F3 | session 结束 + 清理(无 orphan actor) | 单app DM step 5 | Phase 2 |
| F4 | 多方路由(@mention 命中 receiver + `always()` rule **同时**到——验证 **additive 语义**,不是 "default fallback") | 多app happy + §5.5 + Decision #41 | Phase 2 |
| F5 | 跨上下文转发(上下文 A 的消息转到 B) | 多app cross-app | Phase 5(早期可 LiveView 模拟) |
| F6 | 鉴权拒绝(无 cap 的 principal → 操作被拒,拒绝可观测) | 多app negative path | Phase 3d |
| F7 | 零匹配(无 rule 命中 → DLQ unroutable,可观测) | v0.4 §5.5.5 不变式 | Phase 2 |
| F8 | 重启恢复(状态扛得住重启) | persistence | Phase 3 |

### 2.3 验证机制随 phase 演化

- **Phase 1-3**:LiveView 驱动(Allen 手动 or `Phoenix.LiveViewTest` 脚本化)
- **Phase 4**:加 CLI 驱动(同构性)
- **Phase 5**:Feishu 驱动 —— 就是 `manual-e2e-verification.md`,但跑 ezagent;**全部 8 条 flow 走 Feishu transport 跑通 = v0 production demo**

**e2e flow track 是 /goal 的 sub-step 内 gate**(§1.1 / Decision #80):一个 sub-step 让某条 flow 变得可跑,该 flow 必须跑通才能 tag 这个 sub-step。每个 phase entry 字段 6「测试」明确列出该 phase 涉及的 flow,跑通是 sub-step gate;Allen review 时对照字段 2「测试员体验」做 dogfood 复核。

---

## 3. Phase 0 — 项目骨架 + 工具链就位

**1. 目标**：能跑 `mix test`,`mix phx.server` 起空架构,Claude Code 能在 repo 里正常工作。

**2. 测试员体验**：浏览器打开 → 看到空 LiveView 首页「Ezagent v0.4 — phase 0 complete」;`/_health` 返回 200。基建起来了。

**3. Deliverables**（单块）：

**工作顺序**(option-A 时序:ezagent 已有 `.git` + 规划文档奠基提交。下面是 Phase 0
实施后修正过的实际顺序 —— 原 M7 假设 `mix phx.new .` 就地脚手架,**不成立**):
```
1. cd ~/Workspace                # ezagent/ 已有 .git + 规划文档奠基提交
2. cd ezagent && mix phx.new . --umbrella --app ezagent_core --no-mailer --database sqlite3 --no-install
   # ⚠️ phx 1.8 硬行为:`mix phx.new . --umbrella` 强制把项目建到 `<dir>_umbrella/`
   #    —— 实际生成在 ../ezagent_umbrella/,并在那里 git init。不是就地脚手架。
   # ⚠️ 不加 --binary-id(P0-D2:text URI 主键)
3. merge:rm 掉 ezagent_umbrella/.git(phx.new 的空 git),把 scaffold 内容 mv 进 ezagent/,
   保留 ezagent/ 原始 founding .git;rmdir ezagent_umbrella
4. 重命名 phx.new 默认的 ezagent_core_web → ezagent_web(目录+mix.exs+EzagentWeb 模块前缀+config 全同步)
5. mix deps.get && mix compile --warnings-as-errors   # 验证 scaffold + 重命名
6. 其余 deliverable(/_health + tailnet 绑定 / HomeLive / GLOSSARY / .claude/ / check_invariants / git-hook)
7. README 替换为 Ezagent-specific
8. git add -A && git commit   # 不是 git init —— 已 inited
9. tag phase0
```
> phx.new 不生成 README/.gitignore/.formatter.exs 冲突(ezagent/ 原本就没这 3 个文件),
> 原 M7「处理 3 个冲突文件」一步实际不需要 —— phx.new 干净生成它们。

Deliverable 项:
- `mix.exs` 装上 ARCHITECTURE.md §15 的 12 个 deps(SQLite-only)
- `AGENTS.md` — v0.4 核心约定 + 「贯穿条款」(8 不变式 grep / sub-step gate 强制 / 撞墙暂停);per-phase /goal reference 它
- `ARCHITECTURE.md`(v0.4_final + 架构师 Patch A/B/C)、`ARCHITECTURE_GRILL_v0.3.md`、`IMPLEMENTATION_ROADMAP.md` 已在奠基提交里
- `GLOSSARY.md` — **两个职责**:① Decision Log 抽出的可追溯决策记录;② 术语表 + 易混淆词表(channel / session / registry / behavior / template / plugin / dispatch / instance / process / bridge / reply,见 §1.2 词汇 track)+ 消歧 convention
- Phoenix endpoint + `/_health` endpoint
- SQLite migration 框架就绪
- 空 LiveView 首页(只有提示文字)

**4. 前序依赖**：无。

**5. 当前 esr 状态对照**：老 `.claude/skills/` 审计 ——
- 干净可迁:`elixir-phoenix-helper` / `erlexec-elixir` / `commit-work` / `grill-me` / `grill-with-docs`
- 审视后大概率重建:`project-discussion-esr`（建在旧 esr `.artifacts/` 上,对 ezagent 是 stale）
- 不迁:`erlexec-elixir-workspace`（skill-creator 的 eval 工作台,不是可用 skill）
- 老 `.claude/settings.json` 的 hooks(RTK 等)审视后再迁

**6. 测试**：无 e2e flow（还没 dispatch);Phoenix 自带 test 应通过。

**7. 相关不变式**：无(还没 dispatch 路径)。

**8. 人 review 关键点**：空首页可访问？`mix test` 绿？老 `.claude/` 在新 repo 正常工作？

**9. brainstorm 重点**：`--umbrella` vs single project（架构师倾向 umbrella,理由不强）；`--no-html` 加不加；老 `.claude/` 污染源审计；sub-step tag 命名规则(`phase3a` vs `phase-3-3a` vs `phase3/3a`,对 revert/branch 的影响)；`/goal` 提示词怎么强制 sub-step gate。

**10. typical 决策点**：老 skill 迁过来报错,fix 还是删？Phoenix 1.8 + LiveView 1.1 版本配对兼容性。

---

## 4. Phase 1 — ezagent_core MVP + LiveView admin + CC bridge 原型

**1. 目标**：dispatch 一个 Invocation 到 Echo Kind,audit log 实时显示在 LiveView,Allen 能在 LiveView 给远程开发机里的 Claude Code 发指令。

**2. 测试员体验**：打开 LiveView `/admin` → audit log 实时流动；点「Echo 测试」→ 完整 Echo invocation 出现在 audit；用 manual dispatch form 发给远程 CC → CC 收到 → reply 回到 LiveView。**你能通过 LiveView 跟 Claude Code 通信了。**

**3. Deliverables**（3 sub-step,顺序 1a → 1b → 1c）：
- **1a ezagent_core MVP**（~400 LOC core）— `Ezagent.Kind` 宏(register→subscribe→announce_ready 三步)/ `KindRegistry`(`put_new` + `lookup`)/ `ReadyGate` / `PendingDelivery` / `Idempotency` / `Invocation.dispatch/1`(含 ReadyGate / PendingDelivery / Idempotency 接入,`:call` to not-ready fail-fast;**step 5.5 authz gate 实现为显式 permissive stub**:`authz_check/2` 永远返回 `:ok` + emit `[:ezagent, :authz, :stub_grant]` telemetry,函数注释 `PHASE-3D-STUB: DO NOT REMOVE`,Decision #82)/ `Behavior` behaviour + `BehaviorRegistry` / `InterfaceValidator` 最小版 / `Audit.Writer` GenServer + batch flush(SQLite `invocations` 表)/ `DLQ` 最小版 / **bootstrap**: BEAM 首次启动数据库空时自动创建 `user://admin` 持 all-caps,后续启动跳过;`user://admin` 的 cap 不可 revoke(防自锁死,Decision #81)/ `Ezagent.Entity.Echo` + `Ezagent.ActionSet.Echo`（plugin 代码,spec 里要存在的示例 Kind,不是测试代码）
- **1b LiveView /admin**（~150 LOC plugin）— audit log 实时流(subscribe `[:ezagent, :invoke, :stop]` telemetry)/ manual dispatch form / Echo 测试按钮 / **默认 `ctx.caller = user://admin`**(无 auth UI,开发期 dogfood;CLI 同)。**依赖 1a 才能显示 audit。**
- **1c CC stdio bridge 原型**（~80 LOC Python）— `claude --channels plugin:esr-bridge`,bridge↔CC 走 stdio(协议要求),bridge↔Ezagent 的 wire 工程师选。**文件名带 `_v1_prototype` 后缀,Phase 5 用 v2 完全替换。依赖 1b 才能看结果。**
- 内部 tag `phase1a/1b/1c`

**4. 前序依赖**：Phase 0 的项目骨架 + Phoenix endpoint。

**5. 当前 esr 状态对照**：老 esr 的 Python channel 代码（`adapters/cc_mcp/`、openclaw channel_server 模式）可借鉴 stdio bridge 原型的实现模式；Audit / DLQ 在老 esr 无直接对应物,ezagent 新建。

**6. 测试**：F1（文本往返,走 LiveView + Echo）；1a/1b/1c 各自的单元测试。

**7. 相关不变式**：#2（`use Ezagent.Kind` 生命周期）、#3（`:call` to not-ready fail-fast）、#1（inbound via dispatch）。**authz gate 的 stub 形态**:Phase 1-3c 期间 `authz_check/2` 是显式 permissive stub —— **stub 必须保持显式 + 带 `:stub_grant` telemetry**,不能被 Phase 2/3 的 refactor 顺手删除;gate 在路径里(不变式不破),只是放行。Phase 1-3c 期间 `ctx.caller` 在 LiveView/CLI 默认填 `user://admin`(authz stub 期一致占位)。

**8. 人 review 关键点**：LiveView /admin 点 Echo,audit log 显示完整链路？manual dispatch 给 `agent://cc-builder/...`,远程 CC 收到？CC reply 回来在 LiveView 可见？重启 BEAM,LiveView 重连,audit 历史还在？

**9. brainstorm 重点**：`use Ezagent.Kind` 宏复杂度(>100 LOC 怎么办——拆 helper 还是简化机制)；**esr-bridge ↔ Ezagent 的 wire 形态**（stdio + JSON-RPC vs WS + Phoenix.Socket,后者更接近 Phase 5 形态;bridge↔CC 必须 stdio）；LiveView audit 实时流性能（高频 invocation）；`user://admin` bootstrap 实现位置（`Ezagent.Application.start/2` 的 task vs 独立 `Ezagent.Bootstrap` 模块;不可 revoke 检查**结构性放在 `Ezagent.Capability.revoke/2` 路径里**,不是散落各处特判）。

**10. typical 决策点**：宏太复杂拆 helper 还是简化；audit 流加 throttle 还是只显示最近 N 条；bridge 断连重连策略。

---

## 5. Phase 2 — Routing + Matcher + Chat Behavior + 单 session IM

**1. 目标**：一条 Message 从 inbound 路由到 N 个 receiver；Allen 在 LiveView 里跟 Echo Kind / Claude Code 在同一个 session 聊天。

**2. 测试员体验**：进 `/sessions/test-1`,打「hello @echo」→ Echo 在 session view 回「hello」；Claude Code 也加入同一 session,@ 一下能收到；发一条匹配不到任何 rule 的消息 → DLQ unroutable 表有记录。**你能在一个 session 里多方聊天(你 + Echo + CC)。**

**3. Deliverables**（2 sub-step,顺序 2a → 2b）：
- **2a Routing core**（~180 LOC core）— `RoutingRegistry`(`declare_table` / `put_new` / `put` / `lookup` / `lookup_all`,含可选 `reverse_index`)/ `Routing.Matcher`(求值器 + 组合子 `always`/`and`/`or`/`not` + Message-field matchers `mention`/`from`/`from_member`/`text_contains`/`ref_to`/`from_external`)/ `Routing.Rules`(additive rules)/ `Ezagent.Message` struct(5 字段最小集)/ 零匹配路由 → telemetry `[:ezagent, :routing, :unroutable]` + DLQ。**plugin 部分**:`Ezagent.ActionSet.Chat`(`:receive` + `:send`,`esr_behavior_chat`)/ `Ezagent.Session` Kind 雏形(具体 Kind,plugin;还没 Workspace,先做单 session 容器)
- **2b LiveView session view**（~200 LOC plugin）+ **CLI 起步**（~100 LOC plugin,`esr_adapter_cli`）— `/sessions/:id` 页:Message 列表 + Send box;实时 PubSub 订阅 `<session_uri>:events`;CLI 基础命令 `esr send` / `esr session list` / `esr session inspect`，**CLI 手写,还不从 `@interface` 自动派生**(那是 Phase 4)
- 内部 tag `phase2a/2b`

**4. 前序依赖**：Phase 1 的 `dispatch/1` + Echo Kind + CC bridge。

**5. 当前 esr 状态对照**：老 esr `session/chat_routing/registry.ex`（417 行）的 attach/detach/current 语义是**行为参考**(要在新模型里重新表达,不 verbatim 迁)；Matcher 是**全新**概念,老 esr 没有 additive-rule matcher；Message envelope 老 esr 是散的,ezagent 新建统一 struct。

**6. 测试**：F3（session 结束清理）、F4（多方路由,**验证 additive 语义**:加 `always() → [A]` 和 `mention(B) → [B]` 两条 rule,发 `@B hi`,**A 和 B 同时收到** —— 不是 "default fallback 短路"）、F7（零匹配 → DLQ）；2a/2b 单元测试；**CLI ↔ LiveView 同构 spot-check 从这里起**（手动:Allen 在 LiveView 做操作,CC 跑等价 CLI 比对）。

**7. 相关不变式**：#4（unique-key `put_new` / duplicate-key `put`）、#7（零匹配 telemetry + DLQ）。

**8. 人 review 关键点**：「hello @echo」Echo 回复？CC 加入 session @ 收到？Allen LiveView 发完,CC 跑等价 CLI,LiveView 实时显示同一条（同构 spot-check）？故意发匹配不到的消息,DLQ unroutable 有记录？

**9. brainstorm 重点**：**Matcher AST 序列化**（`:erlang.term_to_binary` 快但不可读 vs JSON 可读但 atom 麻烦）；**Message ordering**（同 session 多 receiver,跨进程顺序不保证——是否要写进 spec）；Session URI namespace（Phase 2 没 Workspace,建议 `session://test/<uuid>`,Phase 3 加 workspace 后改 `session://<workspace>/<uuid>`）。

**10. typical 决策点**：`Ezagent.Message` 序列化撞 BEAM atom limit（mention 用 string 而非 atom）；LiveView message body markdown 渲染是否推迟到 Phase 4。

---

## 6. Phase 3 — Persistence + Kind 模型补全

**1. 目标**：BEAM 重启后状态恢复；Workspace 落地;Agent Kind + CapBAC 落地 —— 三个 Kind 子类（Session / Resource / Entity）全部补全。

**2. 测试员体验**：`/workspaces` 建一个 workspace `esr-dev`,加几个 folder,bind 一个 chat,起 session 聊几句；SSH 进开发机 `kill beam`,重启 Ezagent,LiveView 重连后 workspace / session / 消息历史**全在**；能看到 agent 持有的 caps,没 cap 的操作被拒。**状态扛得住重启 + 工作能按 workspace 组织 + Kind 模型补全。**

**3. Deliverables**（4 sub-step,顺序 3a → 3b → 3c → 3d;LOC 按 core / plugin 分栏):
- **3a Persistence** — **core ~130**（`snapshot.ex` ~40:`Ezagent.Kind` snapshot 集成,`:on_change` 只在 slice 真变写 / `:on_terminate` / `:periodic`;`scheduler.ex` ~40:`Process.send_after/3` wrapper 替代 Oban;`message_store.ex` ~50:`append/2` + `query/1`）
- **3b Templates + Workspace** — **core ~15**（`template.ex`:`Ezagent.Kind.Template` behaviour 契约）**+ plugin ~150+**（`Ezagent.Resource.Workspace` 薄 Resource Kind + 4 个标准 Workspace Behavior `esr_behavior_workspace_folders` / `_metadata` / `_bindings` / `_repos`;§10.7 的 4 张参考表 ChatRouting / PrincipalMapping / SessionRules / SessionBindings）
- **3c LiveView + CLI 增量** — **plugin only**（`ezagent_web_liveview` +~100:`/sessions` 含 workspace 归属 / `/workspaces` list+create / session view workspace 切换 / 重启测试入口;`esr_adapter_cli` +~80:`esr workspace list/create/edit/rename` / `bind-chat` / `esr session list --workspace`）
- **3d Agent Kind + CapBAC** — **core ~30**（`capability.ex`:`Ezagent.Capability` struct + `matches?/2`,**用 struct 不用字符串** —— 记取老 esr `capability-name-format-mismatch.md` 教训;`revoke/2` 集中检查 `user://admin` all-caps 不可 revoke）**+ plugin ~120**（`Ezagent.Entity.Agent` Principal Kind）/ `dispatch` flow step 5.5 的 authz gate **从 permissive stub 变真实**:开工前 grep `:esr, :authz, :stub_grant` 确认 Phase 1 的 stub 仍在(没被 refactor 删),然后 in-place 替换 `authz_check/2` 为真实 cap 检查 + `[:ezagent, :authz, :granted]` / `:denied` telemetry / `user://admin` cap 真实化后仍持 all-caps 且不可 revoke
- 内部 tag `phase3a/3b/3c/3d`
- **LOC 合计**:Phase 3 ezagent_core ≈ **+175**(累计 ~775),plugin ≈ +450+

**4. 前序依赖**：Phase 2 的 Session Kind + Routing + RoutingRegistry。

**5. 当前 esr 状态对照**：
- `resource/workspace/`（880 行,struct 字段直接映射到 `Ezagent.Resource.Workspace` 的 state slice）；磁盘上有真实 workspace.json（esr-bound + repo-bound）—— **数据迁移决策点**:pre-launch 按 yaml-layout-v2 spec 是「删了重建」,但要确认
- 持久化:老 esr 用 YAML 文件 + ETS dump,ezagent 是 SQLite,**全重写**,老代码只作参考
- `entity/cap_guard.ex`（237 行,**Pull** authz）/ `resource/capability/` + `permission/`：cap **结构**当参考,Pull → Push **重写**
- `entity/agent/` + `plugin/agent_kind_registry.ex`：agent_def 概念参考

**6. 测试**：F8（重启恢复,3a 后）、F6（鉴权拒绝,3d 后）；snapshot / MessageStore / Workspace / CapBAC 单元 + 集成测试（真实 SQLite）。

**7. 相关不变式**：#5（snapshot 只在 slice 真变写）；3d 后 authz gate 变真实(#1 路径里的 step 5.5 不再是 stub)。

**8. 人 review 关键点**：建 workspace + 加 folder + bind chat + 起 session 聊几句；`kill beam` 重启后 workspace / session / 消息历史全在？远程 CC 跑 `esr workspace list` 等价信息？没 cap 的 agent 操作被拒、拒绝可观测？

**9. brainstorm 重点**：Workspace 4 个 Behavior 拆多细（架构师列了 4 个,`Metadata` 可能太薄——「Behavior 是关注点单元」,太薄反而是反例）；4 个 Workspace Behavior 是单 plugin 内 4 个模块还是各为独立 plugin；`:periodic` snapshot 间隔默认值；MessageStore 查询索引（query pattern 取舍）；Pull → Push 改造范围；**数据迁移**（导入老 workspace.json vs 重建）。

**10. typical 决策点**：Workspace `agent` 字段类型（atom vs string,影响 schema 演化）；`/session:new` 时 Workspace `validate/1` 失败的 UX 报错；SQLite WAL mode 竞争（LiveDashboard 同时跑）；`Ezagent.Capability` struct schema；Workspace 4 个 Behavior 拆 plugin 内部模块边界。

---

## 7. Phase 4 — LiveView IM 完整化 + CLI 自动派生闭环 + View 同构

**1. 目标**：LiveView 完全可用作日常 IM；CLI 从 `@interface` 自动派生,跟 LiveView 完全等价（§1.4 定义）；Allen 在 LiveView 用 slash command 完成 80% 操作。

**2. 测试员体验**：LiveView 打 `/agent:set-default arch-a<TAB>` → 自动补全；装一个新 Behavior plugin 重启 → 它的 slash 命令**自动出现**（没写 UI 代码）；远程 CC 跑等价 CLI `esr agent set-default arch-a` → 同样效果,等价性 CI test 绿；rules side panel 加一条 rule 即时生效。**LiveView 是完整可用的 IM,CLI 自动派生且可证等价。**

**3. Deliverables**（2 sub-step,顺序 4a → 4b）：
- **4a 同构派生 core**（`view.ex` ~30 LOC core + ~220 LOC plugin）— `Ezagent.View` behaviour + `Ezagent.View.Registry`(core)/ LiveView slash command parser（从 `BehaviorRegistry` 扫所有 `@interface` 自动编译 slash tree）/ CLI 用 Optimus 从同一个 `@interface` 派生 + 自动挂载 / `EzagentWebLiveview.MessageView` + `EsrAdapterCli.MessageView`（两个同构 View module）/ `ctx.reply` 路由表完整化。**← CLI ↔ LiveView 等价 CI property test 在这里成为可能,并变成硬门。**
- **4b LiveView 完整化**（~200 LOC plugin）— slash command UI / routing rules side panel（编辑 / 添加 / 删除,反向渲染 matcher DSL）/ `/agents/:id` 页（agent 详情 + caps 列表 + 持有的 sessions）/ members panel / 多 view 渲染对比页
- 内部 tag `phase4a/4b`

**4. 前序依赖**：Phase 3 的完整 Kind 模型（三个子类 + CapBAC）+ Behavior 集。

**5. 当前 esr 状态对照**：老 esr `Ezagent.Commands.Meta` DSL + `slash/`（1221 行）+ `cli/`（617 行）+ `gen_slash_routes` / `check_command_docs` mix task。`@interface` 是 `Commands.Meta` 的 v0.4 演化；slash parser 逻辑可参考老 `slash/`；mix-task 式 gen → 运行时 auto-mount。

**6. 测试**：F2（触发工具）；**CLI ↔ LiveView 等价 CI property test 在 4a 后成为硬门**（§1.4 执行机制升级）。

**7. 相关不变式**：CLI ↔ LiveView 同构等价（4a 后 CI 强制）；全部 8 条贯穿不变式持续自查。

**8. 人 review 关键点**：LiveView 输入 `/agent:set-default arch-a<TAB>` 补全？装新 Behavior plugin（**完全不写 UI 代码**)slash command 自动出现？CC 跑等价 CLI,LiveView 实时显示同样效果？rules side panel 加 `mention("B") → agent_b`,IM 里 @B 立即生效？

**9. brainstorm 重点**：slash parser 实现（NimbleParsec / Combinators vs 手撸 split）；Optimus subcommand tree（启动扫一次 vs 每次 `--help` 扫,后者支持 hot-reload 但慢）；同构性契约严格化（**每个 Behavior 在 LiveView 和 CLI 行为不等价 = bug**）。

**10. typical 决策点**：LiveView session 重连 message stream 补（`MessageStore.query` 历史 vs 等 PubSub catch up）；CLI attach mode（`esr-cli attach` 交互式）走 stdio 还是独立 socket；slash command 大小写敏感性。

---

## 8. Phase 5 — Feishu adapter + CC channel(production)+ Pty-Web

> **📌 Naming note (2026-05-17)**: PRs #27-#32 were shipped under the label "Phase 5" but their scope (operator/admin LV tools maturity + snapshot observability + per-rule routing cap-check) **is not** what this section describes. That work was reassigned to **Phase 4.5** and lives at `docs/phase-specs/phase4.5/`. The real Phase 5 below (Feishu adapter + CC channel production + Pty-Web) was then completed end-to-end the same day via PRs #36-#51. See "Status (2026-05-17)" below.

> **📊 Status (2026-05-17): complete-with-known-gap**
>
> | Deliverable | Status | PRs |
> |---|---|---|
> | 5a Feishu adapter (LV-integrated) | ✅ done — `Ezagent.Entity.FeishuChat` Receiver Kind + `WebhookPlug` + lark API client + session↔chat_id binding via Template + routing rule | #42, #45, #46, #51 |
> | 5b CC channel production | ⚠️ **partial** — `ezagent_plugin_cc` Template Class + connect-token persistence shipped (#41); Phase 1 v1_prototype HTTP/SSE wire continues to be production transport. Full WS rewrite still TODO | #41, #49 |
> | 5c Pty-Web | ✅ done — xterm.js + dispatch path invariant test | #40 |
> | (4 post-Phase-5 follow-ups Allen drove same day) | ✅ | #43 (hotfix), #45 (Receiver Kind drift correction), #48 then #50 (CLI HTTP→RPC pivot), #49 (PtyServer agent_uri via mcp.json) |
>
> Phase 5 is closed as `complete-with-known-gap`; the v1→v2 CC channel wire-swap moves into Phase 6 scope.

**1. 目标**：Feishu 群里 @ 一下 → Ezagent 路由 → CC session 收到 → 回复回 Feishu；在 LiveView 里看完整链路；Pty-Web（TUI 显示）接入。

**2. 测试员体验**：真实 Feishu 群里 @ 一个 agent → Ezagent 路由 → CC session 收到 → reply 回 Feishu；LiveView 里同时看到完整路由链；跨机器:CC 在笔记本、Ezagent 在云上、Feishu 群照样通；Pty-Web 浏览器里看到 TUI。**production feishu-cc demo;LiveView 和 Feishu 双端都能用。**

**3. Deliverables**（3 sub-step,顺序 5a → 5b → 5c;全部 plugin 代码,ezagent_core 不变）：
- **5a Feishu adapter** — `ezagent_plugin_feishu`（Elixir adapter + Python feishu bot）/ §10.7 的 4 张参考表落到 production
- **5b CC channel production** — `ezagent_plugin_cc`（Elixir adapter + Python channel server）—— **重写 Phase 1 的 `_v1_prototype` stdio bridge 为 v2,完全替换不修改 v1** / WS connect token 验证 + CapBAC 完整接入 / `RoutingRegistry.CCInstanceConnection` 表（多 CC 实例支持）
- **5c Pty-Web** — `esr_plugin_pty_web`（工程师命名可调）/ `:ex_pty` 集成 / 输出走 `<pty_session_uri>:output` PubSub topic,LiveView 用 xterm.js 渲染 / 输入反向 dispatch `Ezagent.ActionSet.Pty.input`,**走 Ezagent 标准路径不裸 PubSub（满足不变式 #1）**
- 内部 tag `phase5a/5b/5c`

**4. 前序依赖**：Phase 4 的完整 transport 层 + View 抽象 + 同构 CLI。

**5. 当前 esr 状态对照**：**最大的 port-don't-rewrite 机会** —— 老 esr 有大量可复用 Python:`adapters/feishu/`、`handlers/feishu_app/`、`handlers/feishu_thread/`（lark SDK 集成 + 签名校验,记取 `feishu-ws-ownership-python.md`:Feishu WS 留 Python）；`adapters/cc_mcp/` + CC channel Python 同理。Elixir adapter 侧新建。

**6. 测试**：F5（跨上下文转发）；**全部 8 条 flow 走 Feishu transport 跑通 = `manual-e2e-verification.md` against ezagent = v0 production demo**。

**7. 相关不变式**：#8（CC channel 用 stdio）;#1（pty I/O 也走 dispatch,不裸 PubSub）;全部 8 条最终验证。

**8. 人 review 关键点**：Feishu 群 @ agent,LiveView 里看到 routing 全链路？Feishu 收到 reply？跨机器场景（CC 笔记本 / Ezagent 云上 / Feishu 群）通？Pty-Web 显示 TUI 的工作流跑通？

**9. brainstorm 重点**：Python channel server 跟 Phase 1 stdio bridge 怎么平滑切换（两套并存逐步迁移 CC 实例 vs 一次切）；Feishu webhook 同步处理 vs 异步队列（Phase 5 流量小可同步,给 future 留余地）；Pty-Web 前端框架（xterm.js + LiveView hook vs 独立 React）。

**10. typical 决策点**：bridge v1 → v2 迁移策略；Feishu webhook rate limit / 签名校验细节；Pty-Web web 端框架；xterm.js resize handling。

---

## 9. Phase 6 — Production Hardening(post-Phase-5,实施期补加)

**1. 目标**：把 v0 demo-quality 系统抬到能跑真实小团队的 production state。补 Phase 5 留的硬 gap,把 EZAGENT_HOME 迁移落地,补长期组件成熟度。

**2. 测试员体验 / demo**：(待 brainstorm)

**3. Deliverables — 原计划 vs 实际(2026-05-18 closeout)**：

> Phase 6 实际 ship 24 PRs(#4 → #27),但 scope 跟原始 6a-6f 列表显著不同。原计划的"基础设施补完"工作压后,实际优先 ship 的是 Feishu↔Ezagent↔cc 端到端生产化 + 协议合规修复。下表是诚实账目:

| 原计划项 | 状态 | 备注 |
|---|---|---|
| **6a CC channel v1 → v2 wire swap** | ⚠️ 部分(deferred to Phase 7) | v2 `EzagentPluginCc`(Phoenix.Socket + BridgeRegistry)Phase 6 PR 4 落地,runtime 优先查 v2 binding;但实际 `agent://cc-demo` 仍走 v1_prototype HTTP/SSE 链路。完整 cutover 留到 Phase 7 |
| **6b EZAGENT_HOME DB 迁移** | ❌ 未做 | 仍在 repo root |
| **6c CLI token-based auth** | ❌ 未做 | CLI 仍 admin-all-cap |
| **6d Workspace-scoped routing** | ❌ 未做 | routing_rules 仍 global |
| **6e Federation MVP** | ❌ 未做(可选) | |
| **6f Plugin scaffolder** | ❌ 未做(intentionally) | "Allen 2026-05-17 现在不做"持续生效 |

**实际 ship 的工作(Phase 6 真实交付)**:

- **Feishu 生产硬化**:WS long-connect sidecar(PR 15)、`UserBinding` + `BindingPolicy`(PR 15)、`@-mention` 路由(PR 16)、react 异步绕过 Client mailbox(PR 17)、`SenderResolver` auto-spawn on inbound(PR 18)、image/file pass-through(PR 14)、inbound delegation + 错误回执到原 chat(PR 27,Decision #134)
- **CC bridge / PTY resilience**:per-bridge 文件日志 + verbose trace(PR 21)、eager-announce + auto-prompts(PR 19)、SSE-subscriber dedup(PR 20)、announce retry-forever + backoff(PR 22)、`claude-pty-settings.json` override `remoteControlAtStartup`(PR 23)
- **CC channel 协议合规**:drop list-valued `meta` keys,conform to channels-reference `Record<string, string>` schema(PR 26,Decision #132)
- **User identity 基线**:`Ezagent.Entity.User.default_caps/0` 结构性默认 cap,`Users.create/3` prepend,`BindingPolicy` 对 pre-PR-27 user idempotent 补齐(PR 27,Decision #133)

**3 个 architectural trade-off 在 forensic record 里记下来防 drift**:
- `User.default_caps` 用 `behavior: :any` 是循环依赖妥协,不是 idiom
- `InboundDispatcher` dispatch mode `:cast` → `:call` 是 transport-layer 覆盖,`Chat @interface` 仍声明 `:cast`
- Channel `meta` 全 string 是外部协议契约,非 Ezagent design choice

详见 [docs/notes/phase-6-architecture-closeout.md](docs/notes/phase-6-architecture-closeout.md) + ARCHITECTURE.md Decision #132/#133/#134。

**4. 前序依赖**:Phase 5 + 4 post-Phase-5 PRs 全部 done。Phase 6 brainstorm 时再细化决策点。

**5. 测试**:F1-F8 全部 e2e 真生产路径跑通(已经基本满足,Phase 5 demo 验证过);新增"CC channel WS 路径 = Phase 1 v1 HTTP 路径"等价性 property test(Phase 7 v2 cutover 时落)。

**6. 相关不变式**:#1-#10(已完整)。Phase 6 不引入新不变式,但守住一条**外部不变式**——channel meta = `Record<string, string>`(Decision #132)。

**7. Phase 7 待办**(原 6a/6b/6c/6d/6e 顺延):CC channel v1→v2 完整 cutover、EZAGENT_HOME DB 迁移、CLI token-based auth、Workspace-scoped routing、可选 Federation MVP。Phase 7 brainstorm 时再排优先级。

---

## 9b. Phase 7 — Multi-agent orchestration + Ezagent v1 release(in flight)

**1. 目标(LOCKED v3 — Allen 2026-05-18 brainstorm rounds 1-3)**:
Phase 7 是 Allen 亲手驱动的最后一个 phase + **Ezagent v1 official release**。两个互锁目标:
1. Production-grade **session-template generator**——人类创建 session → 自带 orchestrator(LLM-driven session-internal manager)→ 与 orchestrator 对话 = template 完善过程 → session 可被 fork(config only)、可 update_template(新 hash 不动老)、可 save_template_as 起新 template
2. Make Ezagent **self-sustaining** for dev team without Allen——所有 deferred Phase 6 infra debt 关掉,handoff readiness(invariant tests + skill + 4 onboarding docs)落地,Decision Log + GLOSSARY + ROADMAP 都 current 到 v1 状态

**2. SPEC/VERIFICATION/PLAN/DECISIONS** — 4 个文档已 ship:`docs/phase-specs/phase7/{SPEC,VERIFICATION,PLAN,DECISIONS}.md`(SPEC v3 LOCKED + V1-V5 measurable criteria + 24-PR 顺序 + impl 时累积的 Decision)

**3. Decisions D7-1 → D7-10 已 LOCKED**(全部在 ARCHITECTURE Decision Log Phase 7 closeout 升 #135-#144):
- D7-1: Orchestrator LLM-driven not deterministic
- D7-2: AgentTemplate + SessionTemplate 都是 `Ezagent.Kind.Template` umbrella 下的 Template Class
- D7-3: Scope-bounded cap delegation(`{:within_session, _}` + `{:spawned_by, _}` tuple shapes,Ezagent v1 marker)
- D7-4: Federation drop(Allen reopens later)
- D7-5: EZAGENT_HOME DB migration mandatory + `mix ezagent.bootstrap` one-command install
- D7-6: `esr-developer` skill 是 dev team 的 Allen 替身
- D7-7: Fork unit = configuration only(无 message history)
- D7-8: Plugin runtime hot-install via `:application.load + start`(no unload)
- D7-9: Ezagent packaging = `mix ezagent.bootstrap`(no OTP release)
- D7-10: SessionTemplate version = SHA hash(immutable)+ tag(mutable overlay)

**4. Sub-step model**(per PLAN.md):
- **7-1 Infra closeout** — 6 PRs:workspace routing enforcement / CC v1→v2 cutover / mix ezagent.bootstrap / CLI token + parity / sidecar EOF reap / mix ezagent.plugin.install
- **7-2 Agent + Session templates** — 5 PRs:AgentTemplate Kind / SessionTemplate Kind + git-hash versioning / template caps / Agent.spawn/4 + slice fields / LV+CLI 表单
- **7-3 Orchestrator** — 8 PRs:matches?/2 scope extension / dispatch ctx :session_uri / cc-orchestrator template / 7 MCP tools / Session persistence flip / fork+merge / spawn_from_template CapBAC / e2e demo
- **7-4 Handoff readiness** — 5 PRs:`esr-developer` skill / 4 onboarding docs / ≥8 invariant tests / Decision Log #135-#144 + GLOSSARY + ROADMAP final / forensic note + Ezagent v1 release declaration

**5. Live progress(此 ROADMAP 文件最近更新时)**——Phase 7 自启动以来 9+ PR 已 merged 到 main:
- Pre-7 docs(PR 30/#84): SPEC v3 + VERIFICATION + PLAN + DECISIONS LOCKED
- 7-1-a workspace enforcement(PR 31/#85): WorkspaceRegistry(第 5 个 ETS Registry)
- 7-1-c `mix ezagent.bootstrap`(PR 33/#87): V1.1 + V4.5
- 7-1-d CLI ↔ LV cap parity(PR 34/#90): V3.4
- 7-1-e sidecar EOF reap(PR 35/#88): V4.3
- 7-1-f `mix ezagent.plugin.install`(PR 36/#89): V1.4 + D7-8
- 7-2-a AgentTemplate Kind(PR 37/#92): D7-2 一半
- 7-3-a Capability.matches?/2 scope-tuple extension(PR 42/#93): D7-3 contract(spawned_by deny-by-default placeholder)
- 7-4-d Decision Log #135-#144 + GLOSSARY + ROADMAP final(this PR / PR 53)

**剩余约 14 PR**(7-1-b CC v1→v2 cutover、7-2 SessionTemplate + template caps + Agent.spawn/4 + LV 表单、7-3 orchestrator MVP 多 PRs、7-4 Ezagent skill + 4 docs + handoff note)。

**6. Non-goals(deferred to dev-team v1.x+)**:
- **Federation**(D7-4,Allen reopens)
- **Plugin unload / swap**(D7-8)
- **Production OTP release / Docker / systemd**(D7-9;`mix ezagent.bootstrap` 够 dev team 起步)
- **SessionTemplate three-way merge**(D7-7)
- **Template synthesis**(orchestrator 生成新 AgentTemplate)
- **Cross-session agent delegation**
- **Multimedia / streaming**(Phase 8 — §9c Dyte direction)

**7. Ezagent v1 release(Phase 7 闭幕同时)** — Decision Log 加 D7-3 即正式标记 v0→v1。`docs/notes/phase-7-handoff.md` 是 v1 release note(PR 54 deliverable)。

---

## 9c. Phase 8 — Media + streaming(future,record-only)

**1. 目标**:从 message-passing 扩到 multimedia(图片/文件已经有了)+ 流媒体(语音/视频)。

**2. 设计方向**(Allen 2026-05-18):**Control plane / data plane 分离**——Ezagent 仍是 control plane(signaling / 鉴权 / 会话状态 / audit log),媒体字节走外部 SFU。**不抽象通用 channel**(会把 message-passing 跟 streaming 的根本差异藏起来,诱导误用)。

**3. 候选数据面**:
- **Dyte**(Allen 倾向)— 托管 SFU,SDK 完整,接入最快;cost 跟 minutes 走
- **LiveKit**(开源 self-host)— 灵活但运维负担
- **Volcengine**(已有 voice pivot 经验)— TTS/STT bidirectional WebSocket,跟豆包配套

**4. Ezagent 侧最小新组件**(草稿):
- `Ezagent.Entity.MediaSession`(新 Kind,URI scheme `media://room-id`)
- `Ezagent.ActionSet.MediaSignaling`(actions: join / leave / offer / answer / ice)
- 一个 plugin(e.g. `esr_plugin_dyte`)实现 token 颁发 + webhook 接收 SFU 事件,把 join/leave 当 control message 灌进 dispatch
- 媒体字节**永不**进 Ezagent 进程 — peer ↔ SFU,SFU webhook 只发"who joined/left"
- CapBAC gate `media.join`,routing rule 决定谁能加入哪个 media://room

**5. 风险 / 待答**:Phase 8 brainstorm 才动;现在记录方向,不锁实现。

---

## 9d. Phase 9 — Workspace = deployment unit(2026-05-21 完成,14 PR)

**1. 目标**(`docs/notes/workspace-as-deployment-unit.md` framing):workspace 从 Phase 8c 的"配置 bundle(70% 隔离)"升级到完整 deployment unit,关闭 4 个剩余 gap(entity URI / cap / dispatch / 数据列)+ 引入 Keycloak realm-admin 风格的 system workspace。

**2. SPEC**(`docs/superpowers/specs/2026-05-21-phase-9-tenant-isolation-design.md`,双语 + 3 个 amendment):
- §3 URI SPEC v3:`<scheme>://<type>/<workspace>/<name>` 强制 3-segment(entity + session + template + resource;workspace/system 不变)
- §4 Capability 加 `workspace_uri` 维度(`@enforce_keys`,matcher 严格)
- §5 Dispatch step 5.6 cross-workspace isolation
- §6 Tenant-aware auth(`:current_workspace_uri` derived;workspace 选择器权限分支)
- §7 per-tenant 表 `workspace_uri` NOT NULL 列
- §13 Keycloak system workspace(`workspace://system` visible: false;admin 移到 system;成员身份给跨 workspace 权限)

**3. 14 PR 序列**(全部 admin-merge 到 main):
| # | PR | 内容 | LOC |
|---|----|------|-----|
| 158 | SPEC v3 设计 | 1189 doc |
| 159 | URI v3 entity + 163 文件迁移 | 1231 |
| 160 | SPEC amend 1(workspace switch correction) | 103 doc |
| 161 | Cap workspace 维度 | 1037 |
| 162 | Dispatch step 5.6 + invariant test | 593 |
| 163 | Tenant auth + switcher | 464 |
| 164 | 数据隔离列(6 表 + 3 invariant test) | 1200+ |
| 165 | Test pool 配置 fix(根因:Phase 9 dispatch concurrency) | 18 |
| 166 | SPEC amend 2(URI 统一进入 scope) | 315 doc |
| 167 | URI 统一 session/template/resource | 999 |
| 168 | SPEC amend 3(权限分支 switcher) | 109 doc |
| 169 | System workspace + Keycloak | 1131 |
| 170 | Legacy default/admin seed 修复 | 58 |
| 171 | Demo 文档(双语 + 7 截图) | 600+ doc |

**4. 7 个新 invariant test**(`feedback_completion_requires_invariant_test` 标准):
- `entities_have_workspace_test.exs` — 2-segment entity URI 拒
- `cap_has_workspace_test.exs` — Cap struct 6 字段强制
- `cross_workspace_isolation_test.exs` — step 5.6 gate(临时禁用 → 2/6 失败)
- `all_per_tenant_uris_have_workspace_test.exs` — 2-segment session/template/resource 拒
- `per_tenant_tables_have_workspace_column_test.exs` — Schema + DB column
- `no_nil_workspace_writes_test.exs` — Changeset 拒 nil + grep gate
- `system_workspace_membership_test.exs` — system workspace 存在 + cross_workspace?/2 行为

**5. 实施期反馈循环**(Allen 3 次 Feishu 纠正驱动 3 个 amendment):
- Amendment 1(SPEC #160):workspace switch 不是 "always logout",entity URI workspace-bound 决定了 switch = 换 entity
- Amendment 2(SPEC #166):URI 统一不能 defer 到 SPEC v4,Phase 9 必须做 — 否则迁移不完整(sessions 仍要 out-of-band WorkspaceRegistry lookup)
- Amendment 3(SPEC #168):workspace switch 是**权限分支**不是 "always logout" — system 成员 in-place,普通 user 拒绝 + 提示

每个 amendment 都先 SPEC update + commit + push + admin merge,再用更新后的 SPEC 写下一个 PR。

**6. Phase 9 demo**(`docs/notes/phase-9-demo-2026-05-21.md` 双语)— 7 截图(login/sessions/workspaces/identities/users/routing/admin)+ 每张配 Phase 9 证据 + 文档化"演示中发现 + 当场修复的 bug"(legacy admin seed PR #170)。Demo 用 headless Chrome via CDP cookie injection(`/tmp/phase9-demo/take_screenshots.py`)。

**7. Ezagent v1 验收阶段**(2026-05-21 begin)—— Phase 9 落地后 Allen 进入手动 V1 验收;反馈记录到 `docs/futures/v2-feedback-log.md`(原话 + 抽象本质原因 + V2 影响)。V2 规划基于累积反馈。

**8. 关键架构发现**(subagent 在实施期抓到):
- CapBAC step 5.5 实际住在 `Kind.Runtime.handle_dispatch/4`,不是 `Invocation.dispatch/1`(PR-4 subagent 找到)
- PR-3 的 `workspace_match?/2` 已经在 step 5.5 做 cap-workspace 匹配;step 5.6 的**独立**作用是 caller↔target workspace 检查(admin 在 default 持 team-alpha-scoped cap 的边角情况)
- SPEC §7.1 当时的 physical mapping 已被 2026-08-01 clean-slate capability 设计取代：held caps 现在只以 `identity_caps.caps_json` 为持久 authority；`users` 不再有 `caps_json`，`kind_snapshots` 只保留可重建的 runtime projection。
- SQLite 不支持 ALTER COLUMN → CREATE-NEW/INSERT-SELECT/DROP/RENAME 模式重建 6 张表
- "Pre-existing sandbox failures" 实际是 Phase 9 dispatch concurrency 把 pool 5 推到瓶颈以上 → bump 到 20 解决

---

## 10. 文件清单

phase 0 起 ezagent repo 里应该有：

```
ezagent/
├── ARCHITECTURE.md              ← v0.4_final + Patch A/B/C,不动
├── ARCHITECTURE_GRILL_v0.3.md   ← dev review 两轮记录(历史可追溯)
├── GLOSSARY.md                  ← Decision Log 抽出 + 术语表 + 易混淆词表,实施期持续 append
├── IMPLEMENTATION_ROADMAP.md    ← 本文档
├── AGENTS.md                    ← Claude Code / 实施期 agent 的 prompt + 「贯穿条款」
├── docs/phase-specs/
│   ├── e2e-parity/
│   │   └── FLOWS.md             ← e2e flow track 的 8 条 transport-agnostic flow
│   ├── phase0/
│   │   ├── SPEC.md              ← 详细规格(per-phase brainstorm 产出)
│   │   ├── VERIFICATION.md      ← 验收清单(先于 PLAN 写,sub-step 间契约)
│   │   ├── PLAN.md              ← 任务清单
│   │   └── DECISIONS.md         ← 实施期撞到的判断点 + 决策原则
│   ├── phase1/ ... phase5/
└── .claude/                     ← 从老 esr 迁过来(审视后)
```

每个 phase 进 `/goal` 前,先 `/brainstorm` 出那个 phase 目录下的 4 个文件(VERIFICATION 先于 PLAN)。

---

## 11. 风险点

| 风险 | Phase | 缓解 |
|---|---|---|
| Phase 1 bridge 原型 vs Phase 5 production 不一致,迁移期混乱 | 1→5 | bridge 文件名带 `_v1_prototype`;Phase 5 用 v2 完全替换,不修改 v1 |
| LiveView IM 自己作为 review 工具,但 Phase 1-3 还简陋,review 体验差 | 1-3 | 接受 trade-off — Phase 1-3 LiveView 主要是 audit log + manual dispatch,够用;Phase 4 才追求 UX |
| `/goal` 跑完 phase 报"完成",但实际有不变式违反 | 全程 | `/goal` 提示词强制「完成前自查 8 条不变式」+ git tag 前人工 spot check |
| e2e flow 覆盖不全,/goal 自报 sub-step 完成实际有漏 | 全程 | brainstorm 阶段 `VERIFICATION.md` **先于** `PLAN.md` 写;VERIFICATION 是 sub-step 之间的契约,e2e flow gate 不通过不能 tag sub-step |
| Workspace 数据迁移(老 esr → v0.4)漏数据 | 3 | Phase 3 brainstorm 先定「导入 vs 重建」;pre-launch 倾向重建 |
| Feishu webhook 在 Phase 5 撞 rate limit / 签名校验细节 | 5 | 工程师领域,前置准备;Python bot 大段复用老 esr 代码 |

---

## 12. 下一步

1. **本文档 + ARCHITECTURE.md(Patch A/B/C)双双 sign-off**
2. **写 `docs/phase-specs/e2e-parity/FLOWS.md`** —— e2e flow track 的 8 条 flow 详细化(可跟 Phase 0 并行)
3. **Phase 0 的 `/brainstorm`** —— 产出 `docs/phase-specs/phase0/{SPEC,VERIFICATION,PLAN,DECISIONS}.md` + `/goal` 提示词模板
4. **`/goal` for Phase 0** → Allen 验收 → `phase0` tag → Phase 1 brainstorm → ...

预计每个 phase 1-2 周,6 phase 共 8-12 周。

**如果某个 phase 实施期暴露架构问题:接受暂停 → 回头改 `ARCHITECTURE.md` / `GLOSSARY.md` → 继续。不为赶进度绕过架构问题(grill 文化贯穿到底)。**

---

## Appendix: 给工程师的开放问题

部分已在 dev review 闭环中收敛,剩余待 per-phase brainstorm 处理:

| # | 问题 | 状态 |
|---|---|---|
| Q1 | Phase 0 `--umbrella` vs single project | Phase 0 brainstorm 决 |
| Q2 | Phase 1 esr-bridge ↔ Ezagent 的 wire（stdio+JSON-RPC vs WS+Phoenix.Socket) | Phase 1 brainstorm 决 |
| Q3 | Matcher AST 序列化（term binary vs JSON) | Phase 2 brainstorm 决 |
| Q4 | Pty-Web 前端框架 | Phase 5 brainstorm 决 |
| Q5 | Phase 0 老 `.claude/` 审视有无污染源 | Phase 0 实施期经验性问题 |
| Q6 | LOC budget 落地哪些模块比 target 高/低 | 各 phase 实测反馈,每 phase 实测后 GLOSSARY.md 加一条「Phase N LOC 实测」Decision |
| Q7 | Workspace 老数据导入 vs 重建 | Phase 3 brainstorm 决 |
| Q8 | sub-step `git tag` 命名规则(`phase3a` vs `phase-3-3a` vs `phase3/3a`) | Phase 0 brainstorm 定,后续遵循 |
| Q9 | `/goal` 提示词怎么强制 sub-step gate | Phase 0 brainstorm 同时产出 `/goal` 提示词模板 |
| Q10 | M5 的 telemetry 防呆机制是否推广到其他「显式 stub」 | 经验性,Phase 1 实施期看 |
| Q11 | `ezagent_core` LOC 实测 vs §14 budget 的反馈机制 | Phase 0 brainstorm 定 traceability 流程 |
