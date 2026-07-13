# dev-together 计划 · 2026-07-13

## 元数据

- `planned_at`: 2026-07-13
- `lead`: allenwoods
- `coordinator`: allenwoods + Claude(CC)
- `day_deadline`: 2026-07-13 EOD（GMT+8）
- `timezone`: GMT+8
- `lead_confirmed`: **true**（2026-07-13，per-dev 任务清单已在 Feishu 逐人确认后再定稿本 plan）
- `week_goal`: **W29 统一 demo**（见 `docs/together/2026-W29/weekly-goals.md`）——
  登录官网 → hello → hello 连 kanban → 在 kanban 派开发任务给平台 agent → agent 产 PR
  → CI/review/合并/部署 → kanban 看到流转 → 三面绿（含 socialware install/use/uninstall）。

## 头号目标

**在 canary 上跑通自举 demo 的第一段 —— 平台 agent（cc/codex）可被正常调用/真回话（gaga）。**
这是全链入口：agent 若不能被 kanban 派活、不能回话，下游整条 demo（hello 连 kanban、派任务、
产 PR、看板流转）都无从开始。W28 头号 canary 目标"@orchestrator 真回话"未按 plan 归档
（见 `2026-07-10/review.md` §3 事故 A），能力已由 #1332/#1333 就位——本日先在 canary 实证这一段。

## 按开发者规划（human-dev only）

> 依 dev-together plan 技能：**roster 来自 `team.md`（filter `role: human-dev`）**，
> **agent 永不出现在 plan 中**（无 track 行、无 off-plan 节）。coordinator = allenwoods + CC
> 仅记于元数据，不占 track 行。每条 track 由该 dev 的 `latest_return` 续接，并归入 W29 demo 某一环。

| 开发者 | 本日 track | 闭环/依赖 | 分支 | week-goal |
|---|---|---|---|---|
| **gagameow**（黄佳佳） | **agent 方向配置 + 验证自举第一步**：配置平台托管的开发 agent（能被 kanban 派活、能产 PR），**canary 上 #1294 @orchestrator 真回话验证**（GitHub 确认周末未做/未归档；#1310 是防御性 hotfix，不替代 canary 实测）。这是自举全链入口。 | 前置于整条 demo；agent-browser 截图 + PTY join 日志取证。续接 `#1326 链C credential-skip (2026-07-10)` | `fix/agent-callable-canary`（示例） | 自举 dev-loop |
| **jjkysy**（姚升悦） | **整体进度监控 + 测试，以 kanban socialware 为抓手**：把 demo 各环节任务放进 kanban socialware（dogfood 看板），跟踪进度 + 跨环节测试验收把关。 | 依赖各环节产出；kanban 作为团队看板。续接 `kanban-rework-final (2026-07-10)` | `feat/kanban-progress-board` | 自举 × socialware |
| **zhaomaota97**（张宁） | **官网 + hello**：官网首程（登录 → 进站）+ hello 入口 + **hello 连接 kanban**；#1134 concierge/public-read 顺带。 | hello 连 kanban 是 demo 的产品面；依赖 agent 可回话。续接 `#1312 (2026-07-11)` | `feat/hello-kanban-entry` | socialware/官网 |
| **zyli-developer**（李震宇） | **UI 优化 + bug 修复**：修 demo journey 的 UI bug + 优化（#1320 class listings、#1327 卸载 UI，+ 走查发现的）。 | 修各环节 UI 缺陷。续接 `#1276 (2026-07-09)`（#1320/#1327 仍 open） | `fix/demo-ui-polish` | socialware/官网 |

**设计输入（非 track 行）:** **ruihuachen-designer**（陈瑞华，designer）—— **UX 设计（官网体验为主）**。
按 skill 与 team.md，designer 不占 track 行、不改代码；设计输入走 Feishu，作为 demo journey 的
官网体验参照。续接 `#1204 (2026-07-09)`。

## 冲突图（cross-task conflict map）

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

## Coordinator（allenwoods + CC）职责

- **分支合并**：#1361（orchestrator session-config MCP）**已合入 main**；socialware composition-cap
  车道（`d7ebcd39b`）合并中。lead 是进 main 的唯一路径。
- **canary 部署**（含 PAT pepper 配置）。
- **demo 集成粘合**：把各 dev 的环节拼成一条端到端链，负责跨环节的接线与整体验收编排。

## 意向 handoff 顺序

1. **gaga 先跑通「agent 可被调用/真回话」（canary 实测）** —— 全链入口，未通前下游 demo 无法链测。
2. gaga 宣布 agent 可回话后 → zhaomato 的 hello→kanban 连接与 jjkysy 的 kanban 派活面变为**可链测**。
3. zhaomato 官网首程 + hello 连 kanban（产品面）→ jjkysy 在 kanban 上派一个真实开发任务给平台 agent。
4. agent 产 PR → coordinator 走 CI/review/合并/部署 → jjkysy 在 kanban 看到任务流转 → 三面绿。
5. zyli 全程修各环节 UI 缺陷（并行）；ruihua 提供官网体验 UX 设计输入（Feishu）。

## 红线

- **canary 前不宣布修好。** 任何"agent 真回话 / demo 跑通"的通报，须有 **canary 实测证据**
  （agent-browser 截图 + PTY join 日志 / 真实 PR 链接 + kanban 流转截图）后才发——
  机器闸 CI 绿 ≠ 产品验证（对齐 `2026-07-10/review.md` §3 事故 A 红线，未虚报是成熟信号）。

## 开工前必读

`docs/together/contributing/` + dev-together 技能（含 `references/handoff-standard.md`）+
`docs/guide/world-coordination.md`（触 `world` 的 zhaomato/zyli 必读）+ 各自 handoff。
返还前 rebase 到 current main + 自测绿（arch.scan + doc.scan + uri_query.scan + check_invariants，
或整套 `mix ci.local`）+ PR-head CI 绿。
