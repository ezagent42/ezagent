# dev-together 计划 · 2026-07-14

## 元数据
- `planned_at`: 2026-07-14
- `lead`: allenwoods
- `coordinator`: allenwoods + Claude(CC)（agent 永不占 track 行）
- `day_deadline`: 2026-07-14 EOD（GMT+8）
- `timezone`: GMT+8
- `lead_confirmed`: **true**（2026-07-14，per-dev 任务清单已经 lead 逐人确认后再定稿本 plan）
- `week_ref`: `docs/together/2026-W29/weekly-goals.md`

## §0 本周大局（STANDING · W29 统一 demo 验收）

**本周验收（week acceptance — 逐日不变，直到跑通）:** 在部署站点上跑通**一条端到端链** ——
登录官网（magic-link）→ 进 hello（入口/concierge）→ hello 连到 kanban socialware（开发任务板）
→ 在 kanban 上把一个真实 ezagent 开发任务派给一个**平台托管的开发 agent**（cc/codex）
→ agent 产出真实 PR → 过 CI + review + 合并 + 部署 → kanban 上看到任务流转 → 三面绿
（含 socialware install/use/uninstall 生命周期）。= **dev-loop** + **产品 dogfood** + **两者结合**。
本周至少完整跑通一次（不要求稳定），再谈去脆。

**今日进度（progress toward the acceptance）:**
- **第一张多米诺已 canary 实证:** 07-13 gaga #1367（验收 commit `200f91b5`）在 canary 上证明了平台托管的
  `cc-deepseek` agent 经**正式入口**被唤醒、两次 `@orchestrator` 真回复、一个最小开发任务被 ACCEPTED。
  **全链入口打通**——下游 hello→kanban 派活、agent 产 PR、看板流转从此**可链测**。
- **自举地基已 landed:** #1361（orchestrator Session-Config MCP）+ #1362（socialware composition-cap 车道）已合 main。
- **下一步 = 沿链往下推第二段:** hello **live E2E** 真回复 + 从 hello 侧起造 hello↔kanban 融合（本周先**松耦合**跑通一次）；
  并行补回被 07-13 急症挤占的 **AgentRuntime 结构线**（demo 地基，不能再滑）。

**修正/变化（deltas vs 上一 plan/state）:**
- **新浮现的 demo 关键路径缺口——hello↔kanban 融合的底层挂载 infra 尚未建**（见 `2026-07-13/review.md` §0/§3）。
  #1362 只落「**同 session 内操作自己数据的 agent**」半；demo 要求的「hello 连 kanban」= **跨 session 共享 + 公开挂载**
  （把 kanban socialware 挂进官网/hello 派活入口）= jjkysy **#1360 Layer B**，目前 **spec-only、未实现**。
  **本周策略:** 先用**松耦合**方式把全链跑通一次（满足 W29「至少跑通一次、不要求稳定」），**紧接**造这层挂载 infra——
  先跑通、后补挂载，两步都在本周视野内。
- **jjkysy 07-13 有 2 个 #1360 分析 commit（`docs/socialware-data-mount-model`）但未走 PR/return**——今日先**形式化**为 PR/return。
- **入口已从「待证」转为「已证」**——头号从「证明入口（gaga canary）」切换到「沿链推进 + 补结构线地基」。

## §1 头号目标

**沿自举链往下推第二段 —— hello live E2E 真回复 + 从 hello 侧起造 hello↔kanban 融合（本周先松耦合跑通一次）。**
第一张多米诺（agent 可被调用/真回话）已在 canary 证明，今日把它接续成更长的链：hello 真生成/渲染要成立，
且 hello 能把开发任务递到 kanban 派活面。**红线（见 §7）:** hello↔kanban 融合的底层挂载 infra（跨 session 共享 + 公开挂载 = #1360 Layer B）
**本周先不强求真挂载**——先**松耦合**跑通一次，**紧接**再补挂载 infra；不得为「看起来通了」而绕过 #1360 Layer B 的真实缺口（诚实标注「松耦合，非最终挂载」）。

并行的 demo **地基**头号：**gaga 补回 AgentRuntime 边界 SPEC / `agent_runtime_boundary` gate**（W28③ 结构线，session 面不再伸手进 agent 生命周期）——07-13 被 PTY 急症正当挤占，今日不能再滑。

## §2 按开发者规划（human-dev only）

> roster 来自 `team.md`（filter `role: human-dev`）；**agent 永不出现在 plan**（无 track 行、无 off-plan 节）。
> coordinator = allenwoods + CC 仅记于元数据，不占 track 行。每条 track 由该 dev 的 `latest_return` 续接，并归入 §0 W29 demo 某一环。

| 开发者 | 本日 track | 闭环/依赖 | 分支 | week-goal 环 |
|---|---|---|---|---|
| **zhaomaota97**（张宁） | ① hello **live E2E**（6-point：greeter 入口 → 真 prompt → curl-llm(deepseek) 真生成 json-render spec → `Spec.validate` → live 渲染 → 第二 prompt 变形/PATCH → concierge 只读问答不改页 → 匿名 `public_view` 可见 → catalog 36-组件约束 live 成立；交付 agent-browser 截图 + transcript）② **从 hello 侧起造 hello↔kanban 融合**（把 kanban socialware 接进官网/hello 派活入口，hello 侧连接） | 依赖 agent 可回话（已 07-13 证）；hello↔kanban 融合本周先**松耦合**。续 `#1312` | `feat/hello-live-e2e-kanban-fusion` | demo 产品面 + 融合(hello 侧) |
| **gagameow**（黄佳佳） | ① **AgentRuntime 边界 SPEC / `agent_runtime_boundary` gate**（W28③ 结构线，session 面不再伸手进 agent 生命周期；补回，**头号**）② **demo agent 凭证下发**（`test-zyli-cc-1` 等缺凭证） | demo 地基；SPEC 走 codex 对抗评审（见 §4）。续 `#1367` | `spec/agent-runtime-boundary` | demo 地基（agent 控制面收敛） |
| **jjkysy**（姚升悦） | **以检查补位为主，不做主建** —— ① hello↔kanban 融合的 **kanban 侧检查** ② 整体进度监控 + 测试（kanban 看板上 demo 各环节任务卡 + **至少一条可核实的跨环节验收用例**，真数据）③ 把昨日 #1360 分析**形式化为 PR/return**；#1301 dealscout 次要 | 依赖 zhaomato hello 侧连接（互检）；#1360 形式化 = 补挂载 infra 前置。续 `kanban-rework-final (2026-07-10)` | `docs/socialware-data-mount-model`（#1360 形式化）+ kanban 检查 | demo 融合(kanban 侧检查)/监控 |
| **zyli-developer**（李震宇） | **前端 CI 覆盖**，**先 `tsc --noEmit` 进 CI**（每 assets 目录 + 一个 CI step；后续 ESLint → Vitest → Playwright smoke 分期） | 补 #1369 xterm 类隐患的系统性闸。续 `#1365` / `#1371` | `ci/frontend-tsc-noemit` | demo 地基/质量闸 |

**设计输入（非 track 行）:** **ruihuachen-designer**（陈瑞华，designer）—— **官网体验**：把飞轮原型 #1372 的 IA/视觉方向
接入真实 world/hello LiveView 面（设计输入走 **Feishu**，不占 track 行、不改代码）。续 `#1372`。

## §3 冲突图（cross-task conflict map）

| 任务 | 拥有面/文件 | 冲突 | 串行/并行 |
|---|---|---|---|
| zhaomato hello live E2E + hello↔kanban(hello 侧) | `world`（hello 入口/渲染、官网首程、hello→kanban 连接入口） | 与 zyli 前端 CI 若同触 `world/assets` 构建/`styles.css` | world-coordination 串行共享文件 |
| zyli 前端 CI（tsc） | `ci.yml` + 三个 `assets/tsconfig.json`（web/world/hello）+ CI step | 与 zhaomato 仅在 `world/assets` 构建面可能相邻；tsc 是配置面，改动小 | 大体并行；触 `world/assets` 时按 world-coordination 打招呼 |
| jjkysy kanban 侧检查 + #1360 形式化 | kanban socialware 插件面 + `docs/socialware-data-mount-model` | 与 world 面不重叠；与 zhaomato hello↔kanban 是**互检**关系（非同写） | 可并行（互检对齐接口契约） |
| gaga AgentRuntime SPEC + 凭证下发 | `docs/`（SPEC）+ agent 生命周期/配置面（canary） | 与产品面、kanban 面不重叠 | 可并行 |

- **world 序列化（zhaomato + zyli）:** 两条 track 都可能触 `world`（zhaomato hello 渲染/入口面、zyli `world/assets` tsc）→ 适用
  `docs/guide/world-coordination.md`——**声明 surface 归属、串行化 `styles.css`、遵守 layout gate**。hello 入口/渲染归 zhaomato；
  前端 CI 配置（tsconfig/ci.yml）归 zyli，不改 `world` 运行时 UI。
- **hello↔kanban = zhaomato(hello 侧建) × jjkysy(kanban 侧检查)** —— 非同写同一文件，而是**两侧对齐挂载/派活接口契约**（互 mock 先对齐，再各自并行，见派发原则 §2）。
- **jjkysy #1360 形式化、gaga AgentRuntime SPEC、zyli 前端 CI** 三者互不重叠，可全程并行。

## §4 依赖与 handoff 顺序 / 并行

1. **gaga 补回 AgentRuntime 边界 SPEC（头号地基）** —— 走 **codex 对抗评审**后交 lead（SPEC → 评审 → 落地线）；与下游并行，不阻塞产品面。
2. **zhaomato hello live E2E（6-point）** —— 入口已证，今日直接跑真回复链；先交 E2E transcript，再起 hello↔kanban 融合(hello 侧)。
3. **hello↔kanban 融合互检:** zhaomato 出 hello 侧连接契约 → jjkysy 从 kanban 侧检查 + 对齐；两侧先 **mock 对方接口**对齐契约，再并行（派发原则 §2）。本周先**松耦合**，#1360 Layer B 挂载 infra 形式化后再补真挂载。
4. **jjkysy #1360 形式化为 PR/return** —— 把 07-13 的 2 commit（`docs/socialware-data-mount-model`）落成 PR/return（补挂载 infra 的前置 spec），并给可核实的 kanban 看板交付。
5. **zyli 前端 CI（tsc 先行）** —— 全程并行；#1371 登记的分期任务第一步。
6. **ruihua** 官网体验 UX 设计输入（Feishu），作为 hello/官网面参照。

**Coordinator（allenwoods + CC）职责:** 分支合并（lead 是进 main 唯一路径）· canary 部署 · demo 集成粘合（把 hello live E2E + hello↔kanban 松耦合 + 看板流转拼成端到端链，整体验收编排）· 裁定 #1360 Layer B 挂载 infra 的排期（松耦合先跑通、紧接补挂载）。

## §5 开工 prompt（每个 dev 一段 paste-ready）

> 每段可直接粘贴给该 dev / 其 agent 起步。深任务（带真实未知）走完整 `handoff` 命令出 spec；本节是快路 kickoff。通用规约见 §7。

### zhaomato — hello live E2E（6-point）+ 从 hello 侧起造 hello↔kanban 融合
- **分支:** `feat/hello-live-e2e-kanban-fusion`（先 `git fetch origin main` 再从 `origin/main` 切）
- **范围:** ① hello **live E2E** 6-point 链：greeter 入口 → 真 prompt → **curl-llm(deepseek) 真生成** json-render spec → `Spec.validate` → live 渲染 → 第二 prompt **变形/PATCH** → concierge **只读问答不改页** → 匿名 `public_view` 可见 → catalog **36-组件约束 live 成立**；② **从 hello 侧起造 hello↔kanban 融合**——把 kanban socialware 接进官网/hello 的派活入口（hello 侧连接）。**范围外:** 强求 #1360 Layer B 真挂载——本周先**松耦合**，诚实标注「松耦合，非最终挂载」。
- **必读:** `ezagent-socialware` + `ezagent-developer` 技能 · hello 渲染底座/入口源 · **`docs/guide/world-coordination.md`**（触 `world`，与 zyli 串行 `styles.css`）· `2026-07-13/review.md` §0/§3（hello↔kanban 挂载 infra 缺口）· `#1312 (2026-07-11)` 续接点 · dev-together 技能。
- **DoD:** hello live E2E 的 **agent-browser 截图 + transcript**（6-point 全成立，真 deepseek 生成，非 stub）+ hello↔kanban 松耦合连接的**真实产品面证明**（LiveViewTest 过路由 / agent-browser 驱动）+ 与 jjkysy 对齐的挂载/派活接口契约。
- **闸:** `arch.scan + doc.scan + uri_query.scan + check_invariants`（或 `mix ci.local`）+ 回归测试 + PR-head CI 绿 + rebase main。**world 规约:** 声明 surface 归属、串行 `styles.css`、遵守 layout gate。

### gaga — AgentRuntime 边界 SPEC / `agent_runtime_boundary` gate（补回）+ demo agent 凭证下发
- **分支:** `spec/agent-runtime-boundary`（从 `origin/main` 切）
- **范围:** ① **AgentRuntime 边界 SPEC**——把「session 面不再伸手进 agent 生命周期」写成结构线 SPEC + 一道 `agent_runtime_boundary` 静态 gate（W28③）；② **demo agent 凭证下发**——`test-zyli-cc-1` 等缺凭证的平台 agent，按 per-agent config 下发（诚实旗标于 07-13 review §3）。**范围外:** 大改运行时实现——本轮先 SPEC + gate 契约，实现分期。
- **必读:** `ezagent-developer` 技能 · `docs/together/2026-W29/weekly-goals.md` §使能结构③ · agent 生命周期/控制面源 · `#1367 (2026-07-13)` 续接点 · `references/handoff-standard.md` · dev-together 技能。
- **DoD:** AgentRuntime 边界 SPEC（四属性齐全，走 **codex 对抗评审**后交 lead）+ `agent_runtime_boundary` gate 的**失败样例**（gate 能抓到 session 越界）+ demo agent 凭证下发的**可核实结果**（agent 从缺凭证 → 可被调用，脱敏证据）。
- **闸:** 全套静态 gate + 回归测试 + PR-head CI 绿 + rebase main。**SPEC 约:** 先 codex 对抗评审（架构方向/分层/边界），SOUND 后再交 lead。

### jjkysy — 检查补位（kanban 侧检查）+ 监控/测试 + #1360 形式化
- **分支:** `docs/socialware-data-mount-model`（#1360 形式化，续 07-13 的 2 commit）+ kanban 检查（同分支或 `feat/kanban-fusion-check`，从 `origin/main` 切）
- **范围:** **以检查补位为主，不做主建** —— ① hello↔kanban 融合的 **kanban 侧检查**（与 zhaomato hello 侧互检挂载/派活接口契约）；② 整体进度监控 + 测试（kanban 看板上 demo 各环节任务卡 + **至少一条可核实的跨环节验收用例**，真数据非 stub）；③ 把昨日 **#1360 分析形式化为 PR/return**（跨 session 共享 + 公开挂载 = Layer B，补挂载 infra 前置 spec）。**范围外:** #1301 dealscout 次要（有余力再推 mergeable）。
- **必读:** `ezagent-socialware` + `ezagent-developer` 技能 · #1360 / #1355 / #1357 core-gap 线 · #1362 composition-cap lane（已 main）· `docs/socialware-data-mount-model`（07-13 2 commit）· `kanban-rework-final (2026-07-10)` 续接点 · dev-together 技能。
- **DoD:** #1360 形式化的 **PR/return**（Layer B spec 落成，不再「有 commit 无 PR」）+ kanban 侧检查的**可核实结论**（跨环节验收用例过，真数据）+ 与 zhaomato 对齐的接口契约。
- **闸:** 全套静态 gate + 回归测试 + PR-head CI 绿 + rebase main。

### zyli — 前端 CI 覆盖（先 `tsc --noEmit` 进 CI）
- **分支:** `ci/frontend-tsc-noemit`（从 `origin/main` 切）
- **范围:** #1371 登记的前端 CI 覆盖任务**第一步**：把 **`tsc --noEmit` 类型检查接进 CI**——三个 assets 目录（`ezagent_web/assets`、`ezagent_plugin_world/assets`、`ezagent_plugin_hello/assets`）各跑 + 一个 CI step。**范围外:** 一次做全（ESLint/Vitest/Playwright 后续分期，本轮只 tsc）；不改 `world` 运行时 UI（只加 CI 配置）。
- **必读:** `docs/futures/todo.md` 2026-07-13 节（前端 CI 覆盖任务 + 分期计划）· `ci.yml`（前端 CI 落 full-suite 或新 job，见 todo 备注）· 三个 `assets/tsconfig.json` · `[[reference_ezagent_static_gate_topology]]`（#1370 lockstep guard）· `#1365 (2026-07-13)` 续接点 · dev-together 技能。
- **DoD:** `tsc --noEmit` 在 CI 中对三个 assets 目录**真实运行并会 fail**（构造一个类型错误证明 gate 有效，再修复）+ CI 绿。
- **闸:** 全套静态 gate + PR-head CI 绿 + rebase main。

### ruihua（设计输入，非 track 行）
- designer 不占 track 行、不改代码。**官网体验**：把飞轮原型 #1372 的 IA/视觉方向接入真实 world/hello LiveView 面的**设计输入**走 **Feishu**，作为 hello/官网面参照。

## §6 out-of-scope / backlog（登记 + 归因）

- **#1360 Layer B 挂载 infra 的真实实现（跨 session 共享 + 公开挂载）** —— 本周先松耦合跑通，真挂载**紧接**排期；今日只做 jjkysy 的**形式化 spec**（归「demo 关键路径地基，本周内紧接补，先形式化」）。
- **cbac Phase-4（crypto 签名 / scoring）** —— lead 侧登记项，非本日 demo 关键路径（归「近期目标外的地基项，登记待排」）。
- **前端 CI 分期后续（ESLint / Vitest / Playwright smoke）** —— 本轮只 tsc；后续分期结转（归「MVP 质量闸分期，按 #1371 计划推进」）。
- **demo 去脆 / 稳定化** —— 本周先跑通一次即达标；稳定化明确结转下周（归「MVP 线之外，按 weekly-goals 结转」）。
- 走查中若冒出超范围的 world UI 缺陷 —— 按 team.md 派发原则 §3 判定「偏离方向」或「底层疏漏」并登记，不隐性扩范围。

## §7 协作约束

- **CI 闸:** return 前本地跑**全套**静态 gate（`arch.scan + doc.scan + uri_query.scan + check_invariants` 或整套 `mix ci.local`）——不跑子集（大 PR/动行锚文件尤其，见 #1276）；**机器闸 CI 绿 ≠ 产品验证**。
- **PR 标题诚实:** 未 canary 实证的修复不标「修好」；**hello↔kanban 融合本周是「松耦合先跑通」，须诚实标注「松耦合，非最终挂载（#1360 Layer B 待补）」**——不得把松耦合冒充真挂载。
- **canary 红线:** **canary 前不宣布修好。** 任何「demo 跑通 / 链测通过」的通报须有 canary 实测证据（agent-browser 截图 + transcript / 真实 PR 链接 + kanban 流转截图）后才发（对齐 `2026-07-10/review.md` §3 事故 A 红线，未虚报是成熟信号）。
- **评审基准:** `origin/main`（rebase 到 current main 后再 return）；每任务一分支，PR 只并入本任务分支，lead 走 `close` 合入 main。
- **SPEC 约:** gaga AgentRuntime SPEC 先走 **codex 对抗评审**（架构方向/分层/边界），SOUND 后再交 lead。
- **skill 改动:** dev-together **无唯一 owner** —— 全员讨论，特殊情况由 lead（allenwoods）admin-merge（「Protect dev-together skill」CI gate = lead-gated）。
- **开工前必读:** `docs/together/contributing/` + dev-together 技能（含 `references/handoff-standard.md`）+ `docs/guide/world-coordination.md`（触 `world` 的 zhaomato/zyli 必读）+ `2026-07-13/review.md` §0/§3（hello↔kanban 挂载 infra 缺口）+ 各自 §5 开工 prompt / handoff。
