# dev-together 计划 · 2026-07-13

## 元数据

- `planned_at`: 2026-07-13
- `lead`: allenwoods
- `coordinator`: allenwoods + Claude(CC)（agent 永不占 track 行）
- `day_deadline`: 2026-07-13 EOD（GMT+8）
- `timezone`: GMT+8
- `lead_confirmed`: **true**（2026-07-13，per-dev 任务清单已在 Feishu 逐人确认后再定稿本 plan）
- `week_ref`: `docs/together/2026-W29/weekly-goals.md`

## §0 本周大局（STANDING · W29 统一 demo 验收）

**本周验收（week acceptance — 逐日不变，直到跑通）:** 在部署站点上跑通**一条端到端链** ——
登录官网（magic-link）→ 进 hello（入口/concierge）→ hello 连到 kanban socialware（开发任务板）
→ 在 kanban 上把一个真实 ezagent 开发任务派给一个**平台托管的开发 agent**（cc/codex）
→ agent 产出真实 PR → 过 CI + review + 合并 + 部署 → kanban 上看到任务流转 → 三面绿
（含 socialware install/use/uninstall 生命周期）。= **dev-loop** + **产品 dogfood** + **两者结合**。
本周至少完整跑通一次（不要求稳定），再谈去脆。

**今日进度（progress toward the acceptance）:**
- **自举地基已 landed:** #1361（orchestrator session-config MCP）+ #1362（socialware
  composition-cap 车道）**均已合入 main**（HEAD `a915343de`）——demo 所需的 agent 控制面/组合能力地基就位。
- **canary 侧:** PAT pepper 已设 canary。
- **下一步 = 本日头号:** 在 canary 上实证自举第一段（agent 可被调用/真回话，见 §1）；通了下游才可链测。
- **待/风险:** seed-flake 可能挡 canary 部署——部署前需排查，否则 canary 实测被阻。

**修正/变化（deltas vs 上一 plan/state）:**
- **`FatNine`（戴明，后端）2026-07-13 退出 ezagent 开发**，已从 roster 与今日 track 移除（team.md 已记）。
- **coordinator = allenwoods + CC**（分支合并 / canary 部署 / demo 集成粘合）；agent 不占 track 行。
- **#1362 已从「合并中」转为「已合 main」**——地基不再是在途项。

## §1 头号目标

**在 canary 上跑通自举 demo 的第一段 —— 平台 agent（cc/codex）可被正常调用/真回话（gaga）。**
这是全链入口：agent 若不能被 kanban 派活、不能回话，下游整条 demo（hello 连 kanban、派任务、
产 PR、看板流转）都无从开始。W28 头号 canary 目标"@orchestrator 真回话"未按 plan 归档
（见 `2026-07-10/review.md` §3 事故 A），能力已由 #1332/#1333 就位——本日先在 canary 实证这一段。

**红线（见 §7）:** canary 前不宣布修好。

## §2 按开发者规划（human-dev only）

> 依 dev-together plan 技能：**roster 来自 `team.md`（filter `role: human-dev`）**，
> **agent 永不出现在 plan 中**（无 track 行、无 off-plan 节）。coordinator = allenwoods + CC
> 仅记于元数据，不占 track 行。每条 track 由该 dev 的 `latest_return` 续接，并归入 §0 W29 demo 某一环。

| 开发者 | 本日 track | 闭环/依赖 | 分支 | week-goal 环 |
|---|---|---|---|---|
| **gagameow**（黄佳佳） | **agent 方向配置 + 验证自举第一步**：配置平台托管的开发 agent（能被 kanban 派活、能产 PR），**canary 上 #1294 @orchestrator 真回话验证**（GitHub 确认周末未做/未归档；#1310 是防御性 hotfix，不替代 canary 实测）。这是自举全链入口。 | 前置于整条 demo；agent-browser 截图 + PTY join 日志取证。续接 `#1326 链C credential-skip (2026-07-10)` | `fix/agent-callable-canary`（示例） | 自举 dev-loop 入口 |
| **jjkysy**（姚升悦） | **整体进度监控 + 测试，以 kanban socialware 为抓手**：把 demo 各环节任务放进 kanban socialware（dogfood 看板），跟踪进度 + 跨环节测试验收把关。 | 依赖各环节产出；kanban 作为团队看板。续接 `kanban-rework-final (2026-07-10)` | `feat/kanban-progress-board` | 自举 × socialware |
| **zhaomaota97**（张宁） | **官网 + hello**：官网首程（登录 → 进站）+ hello 入口 + **hello 连接 kanban**；#1134 concierge/public-read 顺带。 | hello 连 kanban 是 demo 的产品面；依赖 agent 可回话。续接 `#1312 (2026-07-11)` | socialware/官网 |
| **zyli-developer**（李震宇） | **UI 优化 + bug 修复**：修 demo journey 的 UI bug + 优化（#1320 class listings、#1327 卸载 UI，+ 走查发现的）。 | 修各环节 UI 缺陷。续接 `#1276 (2026-07-09)`（#1320/#1327 仍 open） | `fix/demo-ui-polish` | socialware/官网 |

> 注：zhaomato 分支 `feat/hello-kanban-entry`（表格宽度所限并入 §5 开工 prompt）。

**设计输入（非 track 行）:** **ruihuachen-designer**（陈瑞华，designer）—— **UX 设计（官网体验为主）**。
按 skill 与 team.md，designer 不占 track 行、不改代码；设计输入走 Feishu，作为 demo journey 的
官网体验参照。续接 `#1204 (2026-07-09)`。

## §3 冲突图（cross-task conflict map）

| 任务 | 拥有面/文件 | 冲突 | 串行/并行 |
|---|---|---|---|
| zhaomato hello/官网 | `world`（hello 入口、官网首程、hello→kanban 连接） | 与 zyli 同触 `world` | 见下方序列化 |
| zyli demo UI polish | `world`（各环节 UI、#1320/#1327 卸载 UI） | 与 zhaomato 同触 `world` | 见下方序列化 |
| jjkysy kanban 看板 | kanban socialware 插件面（独立命名空间） | 与 world 面不重叠 | 可并行 |
| gaga agent/orchestrator config | agent/orchestrator 配置面（canary） | 与产品面不重叠 | 可并行（且为前置） |

- **world 序列化（zhaomato + zyli）:** 两条 track 都触 `world` → 适用
  `docs/guide/world-coordination.md`——**声明 surface 归属、串行化 `styles.css`、遵守 layout gate**。
  hello 入口/官网首程归 zhaomato；各环节 UI 缺陷/卸载 UI 归 zyli；共享文件按 world-coordination 串行。
- **jjkysy = kanban 插件、gaga = agent/orchestrator 配置**——两者与 world 面及彼此互不重叠，可全程并行。

## §4 依赖与 handoff 顺序 / 并行

1. **gaga 先跑通「agent 可被调用/真回话」（canary 实测）** —— 全链入口，未通前下游 demo 无法链测。
2. gaga 宣布 agent 可回话后 → zhaomato 的 hello→kanban 连接与 jjkysy 的 kanban 派活面变为**可链测**。
3. zhaomato 官网首程 + hello 连 kanban（产品面）→ jjkysy 在 kanban 上派一个真实开发任务给平台 agent。
4. agent 产 PR → coordinator 走 CI/review/合并/部署 → jjkysy 在 kanban 看到任务流转 → 三面绿。
5. zyli 全程修各环节 UI 缺陷（并行）；ruihua 提供官网体验 UX 设计输入（Feishu）。

**Coordinator（allenwoods + CC）职责:** 分支合并（#1361 + #1362 已合 main；lead 是进 main 唯一路径）
· canary 部署（含 PAT pepper）· demo 集成粘合（把各环节拼成端到端链，跨环节接线 + 整体验收编排）。

## §5 开工 prompt（每个 dev 一段 paste-ready）

> 每段可直接粘贴给该 dev / 其 agent 起步。深任务（带真实未知）走完整 `handoff` 命令出 spec；
> 本节是快路 kickoff。通用规约见 §7。

### gaga — agent 方向配置 + 验证自举第一步（canary）
- **分支:** `fix/agent-callable-canary`（示例；先 `git fetch origin main` 再从 `origin/main` 切）
- **范围:** 配置平台托管的开发 agent（能被 kanban 派活、能产 PR）；**在 canary 上实证 #1294
  @orchestrator 真回话**（GitHub 确认周末未做/未归档）。范围内：canary 实测取证；范围外：把 #1310
  防御性 hotfix 当成"已修好"——它不替代 canary 实测。
- **必读:** `ezagent-developer` 技能 · #1294（create_session 两链解耦根因）/#1310（默认 session plain
  防御性 hotfix）上下文 · `2026-07-10/review.md` §3 事故 A · dev-together 技能。
- **取证 = DoD:** **canary 上 agent 真回话**的 transcript + **agent-browser 截图** + **PTY join 日志**
  （机器闸 CI 绿 ≠ 产品验证；此段只有 canary 能证）。
- **闸:** `arch.scan + doc.scan + uri_query.scan + check_invariants`（或 `mix ci.local`）+ 回归测试 + PR-head CI 绿 + rebase main。
- **红线:** **canary 前不宣布修好**（须有实测证据再通报）。

### jjkysy — kanban socialware 作为团队进度看板
- **分支:** `feat/kanban-progress-board`（从 `origin/main` 切）
- **范围:** 把本周 demo 各环节任务放进 kanban socialware（**dogfood** 看板），跟踪进度 +
  做跨环节测试验收把关。范围内：看板作为团队真实进度面 + 验收关口；用到组合能力时对齐 #1362
  composition-cap 车道（已 main）。
- **必读:** `ezagent-socialware` + `ezagent-developer` 技能 · #1362 composition-cap lane（已在 main）·
  `kanban-rework-final (2026-07-10)` 续接点 · dev-together 技能。
- **DoD:** demo 各环节在 kanban 上有任务卡 + 可见流转；至少一条跨环节验收用例通过（真实数据，非 stub）。
- **闸:** 同上全套静态 gate + 回归测试 + PR-head CI 绿 + rebase main。

### zhaomato — 官网首程 + hello 入口 + hello 连 kanban
- **分支:** `feat/hello-kanban-entry`（从 `origin/main` 切）
- **范围:** 官网首程（登录 → 进站）+ hello 入口 + **hello 连接 kanban**；#1134 concierge/public-read 顺带。
  这是 demo 的**产品面**。**依赖:** agent 可回话（gaga 段通了才可链测 hello→kanban 派活）。
- **必读:** `ezagent-socialware` 技能 · hello 相关源（hello 渲染底座/入口）· **`docs/guide/world-coordination.md`**
  （触 `world`，与 zyli 串行 `styles.css`）· dev-together 技能 · `#1312 (2026-07-11)` 续接点。
- **DoD:** 官网首程 + hello 入口 + hello→kanban 连接的**真实产品面证明**（LiveViewTest 过路由 /
  agent-browser 驱动）+ 截图companion；非仅后端 seam。
- **闸:** 同上全套静态 gate + 回归测试 + PR-head CI 绿 + rebase main。**world 规约:** 声明 surface 归属、串行 `styles.css`、遵守 layout gate。

### zyli — demo journey UI 优化 + bug 修复
- **分支:** `fix/demo-ui-polish`（从 `origin/main` 切）
- **范围:** 修 demo journey 的 UI bug + 优化：#1320 class listings、#1327 卸载 UI，+ 走查发现的。
  触 `world`，与 zhaomato 串行共享文件。
- **必读:** **`docs/guide/world-coordination.md`**（触 `world` 必读）· `ezagent-developer` 技能 ·
  #1320 / #1327（仍 open）· `#1276 (2026-07-09)` 续接点（大 PR/动行锚文件本地跑全套 gate）· dev-together 技能。
- **DoD:** 每个修复项的**用户面证明**（过真实 surface 的自动化测试）+ 截图；#1320/#1327 各自闭环或明确结转。
- **闸:** 同上全套静态 gate（大 PR/行锚文件**本地必跑全套**，见 #1276 教训）+ 回归测试 + PR-head CI 绿 + rebase main。**world 规约:** 各环节 UI/卸载 UI 归 zyli，串行 `styles.css`。

### ruihua（设计输入，非 track 行）
- designer 不占 track 行、不改代码。**官网体验 UX 设计**输入走 **Feishu**，作为 demo journey 的官网体验参照。

## §6 out-of-scope / backlog（登记 + 归因）

- **cbac Phase-4（crypto 签名 / scoring）** —— lead 侧登记项，非本日 demo 关键路径（归「近期目标外的地基项，登记待排」）。
- **demo 去脆 / 稳定化** —— 本周先跑通一次即达标；稳定化明确结转下周（归「MVP 线之外，按 weekly-goals 结转」）。
- 走查中若冒出大量 world UI 缺陷超出 #1320/#1327 —— 按 team.md 派发原则 §3 判定「偏离方向」或「底层疏漏」并登记，不隐性扩范围。

## §7 协作约束

- **CI 闸:** return 前本地跑**全套**静态 gate（`arch.scan + doc.scan + uri_query.scan + check_invariants`
  或整套 `mix ci.local`）——不跑子集（大 PR/动行锚文件尤其，见 #1276）；**机器闸 CI 绿 ≠ 产品验证**。
- **PR 标题诚实:** 未 canary 实证的修复不标「修好」。
- **canary 红线:** **canary 前不宣布修好。** 任何"agent 真回话 / demo 跑通"的通报，须有 **canary 实测证据**
  （agent-browser 截图 + PTY join 日志 / 真实 PR 链接 + kanban 流转截图）后才发（对齐
  `2026-07-10/review.md` §3 事故 A 红线，未虚报是成熟信号）。
- **评审基准:** `origin/main`（rebase 到 current main 后再 return）；每任务一分支，PR 只并入本任务分支，lead 走 `close` 合 main。
- **skill 改动:** dev-together **无唯一 owner** —— 全员讨论，特殊情况由 lead（allenwoods）admin-merge
  （「Protect dev-together skill」CI gate = lead-gated）。
- **开工前必读:** `docs/together/contributing/` + dev-together 技能（含 `references/handoff-standard.md`）
  + `docs/guide/world-coordination.md`（触 `world` 的 zhaomato/zyli 必读）+ 各自 §5 开工 prompt / handoff。
