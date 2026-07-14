# dev-together 计划 · 2026-07-15

## 元数据
- `planned_at`: 2026-07-14（晚，为次日）
- `lead`: allenwoods
- `coordinator`: allenwoods + Claude(CC)（agent 永不占 track 行；codex = lead 轨道，记于本节，不出现在 §2）
- `day_deadline`: 2026-07-15 EOD（GMT+8）
- `timezone`: GMT+8
- `lead_confirmed`: **true**（2026-07-14 晚 · demo 分工 gaga 测→allen 验→ruihua 完善、jjkysy 明天可能没时间、codex=lead 轨道，均经 lead 逐点确认）
- `week_ref`: `docs/together/2026-W29/weekly-goals.md`

## §0 本周大局（STANDING · W29 统一 demo 验收）

**本周验收（week acceptance — 逐日不变，直到跑通）:** 在部署站点上跑通**一条端到端链** ——
登录官网（magic-link）→ 进 hello（入口/concierge）→ hello 连到 kanban socialware（开发任务板）
→ 在 kanban 上把一个真实 ezagent 开发任务派给一个**平台托管的开发 agent**（cc/codex）
→ agent 产出真实 PR → 过 CI + review + 合并 + 部署 → kanban 上看到任务流转 → 三面绿
（含 socialware install/use/uninstall 生命周期）。= **dev-loop** + **产品 dogfood** + **两者结合**。
本周至少完整跑通一次（不要求稳定），再谈去脆。

**今日进度（progress toward the acceptance）:**
- **融合这一段已落地:** 07-14 zhaomato **#1383**——Hello↔Kanban **松耦合融合**（公共/匿名入口 + 一次性登录续接 + Hello Dispatcher + 派活链路）合入 main。demo 关键路径的「hello 连 kanban」段先松耦合跑通。
- **入口已 canary 实证（07-13 #1367）** + **融合段已 landed（07-14 #1383）** → **剩下的缺口收窄为最后一段:** kanban 上**派活 → 平台 agent 出真实 PR → 过 CI/review/合 → 看板流转**——把已通的两段接成完整端到端链，本周至少跑通一次。
- **安全线本日收口:** cbac Phase-4 ed25519 签名 landed（dual-read，#1399）；entity-caps scoped patch（A/B/D）与 cap-signing 无尾巴升级已交 codex，返工待 lead 验收。

**修正/变化（deltas vs 上一 plan/state）:**
- **demo 分工明确（lead 07-14 定）:** 端到端最后一段 = **gaga 测试 demo 路径 → allen 验收 → ruihua 从产品角度完善**；**jjkysy 明天可能没时间**（不派主建，检查补位若有时间再做）。
- **gaga 已从安全线转回结构线:** AgentRuntime 边界 gate **#1402 已合**（07-14，只减不增门禁 + 绕过对抗测试）；同 PR 一并热修一个 canary 发现的 **LiveAuth 权限可见性 bug**（改读 Ed25519 校验的 live Identity caps 而非旧 caps_json，dual-read 安全）。**#1402 明确未含** ARB-2~5 存量迁移 + 一批 LiveAuth/caps 审计项（HomeLive fail-closed、EntityCaps 持久化统一、cold/restart 权限矩阵、member-cap reader、UI cap count、email boundary、no-tail enforcement）——按优先级另排。**⚠ 协调点:** gaga 列的「EntityCaps 持久化统一」与 codex entity-caps **D（EntityCaps facade）重叠**、「no-tail enforcement」= lead 轨道——须由 lead 分派，避免 gaga 与 codex 同改 caps 持久化面碰撞。
- **bridge-join 静默超时——不在 demo 关键路径（被绕过、非遗忘）:** 当初的两条焊接链（A 新建 5s 超时 · B @orchestrator 变哑）**急症那半已修 + canary 实证**（#1294 合 main `2d47475b2`、07-10 canary 不超时；#1367 07-13 canary 两次 @orchestrator 真回话）。剩下的 **cc-PTY bridge-join 慢激活**被 **cc-headless**（`:in_process_sync`，无 bridge-join 风险）绕过——demo 跑 cc-headless 即可。故 bridge-join = **cc-PTY 专项的残留 latent 项，延后登记**（仅当要用真 PTY agent 上生产时才修），**不是 demo 阻塞项**。
- **CapBAC 从「主线急症」转为「lead 轨道收口」:** 不再牵动全员；codex 两返验收 + 无尾巴升级 & enforce 时机 = lead 轨道（§4）。

## §1 头号目标

**把 W29 demo 端到端串通一次（本周首次全链）** —— 已通两段（入口 canary 证 + hello↔kanban 松耦合融合 #1383），
今日补最后一段：kanban **派活 → 平台 agent 出真实 PR → 过 CI/review/合 → 看板流转**。
**分工:** gaga 测试 demo 路径（走通派活→PR→合→看板流转）→ allen 验收（canary 实测，agent-browser 截图 + 真实 PR 链接 + 看板流转）→ ruihua 从产品角度完善。**诚实标注**「松耦合，非最终挂载（#1360 Layer B 待补）」，不把松耦合冒充真挂载。

**并行 lead 轨道（§4）:** 验收 codex 两份返工（entity-caps A/B/D 实现 + cap-signing 无尾巴调查 findings）→ 定无尾巴 re-provision 升级实现 & enforce 时机（当前 dual-read；**enforce 不翻直到 audit=0 未签名**）。

**并行结构线:** gaga AgentRuntime 边界 **#1402 已合、续 ARB-2~5 存量迁移**（session 面不再伸手进 agent 生命周期），走 codex 对抗评审后交 lead。

## §2 按开发者规划（human-dev only）

> roster 来自 `team.md`（filter `role: human-dev`）；**agent 永不出现在 plan**（无 track 行、无 off-plan 节）。
> coordinator = allenwoods + CC（含 codex = lead 轨道）仅记于元数据/§4，不占 track 行。每条 track 由该 dev 的 `latest_return` 续接，并归入 §0 W29 demo 某一环。

| 开发者 | 本日 track | 闭环/依赖 | 分支 | week-goal 环 |
|---|---|---|---|---|
| **gagameow**（黄佳佳） | ① **测试 W29 demo 路径**（kanban 派活 → 平台 agent 出真实 PR → 过 CI/review/合 → 看板流转），跑通后交 **allen 验收**（头号）② **AgentRuntime 存量迁移 ARB-2~5 + LiveAuth/caps 审计跟进**（#1402 已合；⚠ 与 codex entity-caps D「EntityCaps 持久化统一」重叠，须 lead 分派避免同改碰撞）③ **确认 demo 在 cc-headless 上跑通即可**（bridge-join 是 cc-PTY 专项残留、延后登记，非 demo 阻塞——见 §0） | ① 依赖 #1383 融合（已 landed）+ demo agent 凭证；② 待 lead 分派边界；③ demo 走 cc-headless 绕 bridge-join。续 `#1375+#1379+#1381+#1402 (2026-07-14)` | `feat/demo-e2e-dispatch` + `feat/agent-runtime-arb-migration` | demo 最后一段（派活→PR→合→流转）+ 地基 |
| **zhaomaota97**（张宁） | **hello live E2E 补齐 + hello↔kanban 融合深化**（#1383 续）—— 把融合从「松耦合跑通」推向更稳的连接契约，配合 gaga 的 demo 路径测试提供 hello 侧派活入口 | 依赖 agent 可回话（已证）；与 gaga demo 路径**互检** hello 侧派活契约。续 `#1383 (2026-07-14)` | `feat/hello-kanban-fusion-deepen` | demo 产品面 + 融合(hello 侧) |
| **zyli-developer**（李震宇） | **前端 CI 覆盖续**——`tsc --noEmit` 进 CI（三个 assets 目录各跑 + 一个 CI step；#1371 分期第一步落 CI）；后续 ESLint→Vitest→Playwright 分期 | 补 #1369 xterm 类隐患的系统性闸。续 `#1389 (2026-07-14)` / `#1371` | `ci/frontend-tsc-noemit` | demo 地基/质量闸 |
| **jjkysy**（姚升悦） | **（明天可能没时间——不派主建，以下按有余力）** 检查补位（hello↔kanban 融合的 kanban 侧可核实验收）+ 把 #1360 分析形式化为 PR + 推 #1301 dealscout 到 mergeable | 若有时间；#1360 形式化 = 补挂载 infra 前置。续 `#1376 (2026-07-14, 挂起)` | `docs/socialware-data-mount-model` + kanban 检查 | demo 融合(kanban 侧检查)/监控 |

**设计输入（非 track 行）:** **ruihuachen-designer**（陈瑞华，designer）—— ① **从产品角度完善 W29 demo**（gaga 测→allen 验后接手打磨全链产品体验，设计输入走 **Feishu**）② **#1378 rebase+解冲突** 后交 lead 合 + #1388 DealScout 撮合原型续。不占 track 行、不改代码。续 `#1378/#1388 (2026-07-14, pending)`。

## §3 冲突图（cross-task conflict map）

| 任务 | 拥有面/文件 | 冲突 | 串行/并行 |
|---|---|---|---|
| gaga demo 路径测试 + #1402 | demo 派活链（kanban↔agent↔PR）+ `docs/`（AgentRuntime SPEC）+ agent 生命周期面 | 与 zhaomato hello 侧派活是**互检**关系（非同写） | 可并行（互检对齐派活接口契约） |
| zhaomato hello↔kanban 深化 | `world`（hello 入口/渲染/派活连接） | 与 zyli 前端 CI 若同触 `world/assets` 构建/`styles.css` | world-coordination 串行共享文件 |
| zyli 前端 CI（tsc） | `ci.yml` + 三个 `assets/tsconfig.json` + CI step | 与 zhaomato 仅在 `world/assets` 构建面可能相邻；tsc 是配置面，改动小 | 大体并行；触 `world/assets` 时按 world-coordination 打招呼 |
| jjkysy kanban 侧检查 + #1360 形式化（若有时间） | kanban socialware 插件面 + `docs/socialware-data-mount-model` | 与 world 面不重叠；与 zhaomato/gaga 是**互检**关系 | 可并行 |
| **lead 轨道:** codex 两返验收 + 无尾巴升级 | `apps/ezagent_core` cap 签名面 + `caps_json` + `docs/notes|handoffs` | 与产品/kanban 面不重叠（隔离 canary-data 环境验收） | 与全员并行 |

- **world 序列化（zhaomato + zyli）:** 两条 track 都可能触 `world` → 适用 `docs/guide/world-coordination.md`（声明 surface 归属、串行化 `styles.css`、遵守 layout gate）。hello 入口/渲染/派活连接归 zhaomato；前端 CI 配置归 zyli，不改 `world` 运行时 UI。
- **demo 派活 = gaga(测路径) × zhaomato(hello 侧派活入口)** —— 两侧对齐派活/挂载接口契约（互 mock 先对齐，再各自并行）。
- **lead 轨道（codex 验收 + 无尾巴升级）在隔离 canary-data 环境**，与所有产品面并行不冲突。

## §4 依赖与 handoff 顺序 / 并行

1. **gaga demo 路径测试（头号）** —— 基于 #1383 融合，跑通 kanban 派活→平台 agent 出 PR→合→看板流转；跑通后交 **allen canary 验收**。与下游并行。
2. **zhaomato hello↔kanban 深化** —— 提供 hello 侧派活入口契约给 gaga demo 路径互检；hello live E2E 补齐。
3. **gaga AgentRuntime ARB-2~5 迁移（#1402 已合后续）** —— 走 codex 对抗评审后交 lead；与产品面并行，不阻塞。⚠ EntityCaps 持久化统一须 lead 先分派边界（与 codex D 重叠）。
4. **zyli 前端 CI（tsc 先行）** —— 全程并行；#1371 分期第一步。
5. **jjkysy（若有时间）** —— kanban 侧检查互检 + #1360 形式化 + #1301。
6. **ruihua** demo 产品完善（Feishu 设计输入）+ #1378 rebase。

**Coordinator（allenwoods + CC，含 codex = lead 轨道）职责:**
- **验收 codex 两份返工:** entity-caps scoped A/B/D 实现（`feat/entity-caps-scoped`）+ cap-signing 无尾巴调查 findings（`feat/cap-signing-notail-upgrade`）→ 定无尾巴 re-provision 升级实现 & **enforce 时机**（enforce 不翻直到 audit=0 未签名 authorizer cap）。
- **demo 端到端集成粘合 + 验收:** 把 hello live E2E + hello↔kanban 松耦合 + 派活→PR→合→看板流转拼成端到端链，canary 实测验收（gaga 测 → lead 验）。
- **分支合并**（lead 是进 main 唯一路径）· **canary 部署** · #1378 rebase 后合 · #1386 grantee-binding 收口。

## §5 开工 prompt（每个 dev 一段 paste-ready）

> 每段可直接粘贴给该 dev / 其 agent 起步。深任务走完整 `handoff` 出 spec；本节是快路 kickoff。通用规约见 §7。

### gaga — 测试 W29 demo 路径（派活→PR→合→看板流转）+ AgentRuntime ARB-2~5 迁移 + demo-on-cc-headless 确认
- **分支:** `feat/demo-e2e-dispatch`（demo 测试）+ `feat/agent-runtime-arb-migration`（ARB-2~5，#1402 已合后续）——先 `git fetch origin main` 再从 `origin/main` 切。
- **范围:** ① **测 demo 最后一段**——基于 #1383 融合，在 kanban 上派一个真实 ezagent 开发任务给平台托管 agent（cc/codex，**走 cc-headless**）→ agent 出真实 PR → 过 CI/review/合 → kanban 看到流转，跑通后交 allen canary 验收；② **AgentRuntime 存量迁移 ARB-2~5 + LiveAuth/caps 审计跟进**（#1402 已合；**⚠「EntityCaps 持久化统一」与 codex entity-caps D 重叠，须 lead 先分派边界再动**）；③ **确认 demo 在 cc-headless 上跑通即可**（bridge-join 是 cc-PTY 专项残留、延后登记，非 demo 阻塞——见 §0）。**范围外:** demo 去脆（先跑通一次）；未经 lead 分派前不动 EntityCaps 持久化面。
- **必读:** `ezagent-socialware` + `ezagent-developer` 技能 · #1383 融合 PR（派活链/Hello Dispatcher）· `docs/together/2026-W29/weekly-goals.md` · `2026-07-14/review.md` §5 · `#1375+#1379+#1381 (2026-07-14)` 续接点 · dev-together 技能。
- **DoD:** demo 最后一段的**canary 实证**（agent-browser 截图 + 真实 PR 链接 + 看板流转截图，走 cc-headless，交 allen 验收）+ ARB 迁移的**失败样例 gate**（若本日推进）。
- **闸:** 全套静态 gate（`arch.scan + doc.scan + uri_query.scan + check_invariants` 或 `mix ci.local`）+ 回归测试 + PR-head CI 绿 + rebase main。**SPEC 约:** #1402 先 codex 对抗评审，SOUND 后交 lead。

### zhaomato — hello live E2E 补齐 + hello↔kanban 融合深化（#1383 续）
- **分支:** `feat/hello-kanban-fusion-deepen`（先 `git fetch origin main` 再从 `origin/main` 切）
- **范围:** ① hello **live E2E** 补齐（6-point：真 deepseek 生成 json-render → validate → 渲染 → PATCH → concierge 只读 → 匿名可见 → 36-组件约束 live）；② **hello↔kanban 融合深化**——把 #1383 的松耦合连接推向更稳的派活接口契约，给 gaga demo 路径提供 hello 侧派活入口。**范围外:** #1360 Layer B 真挂载（本周先松耦合）。
- **必读:** `ezagent-socialware` + `ezagent-developer` 技能 · #1383 融合 PR · `docs/guide/world-coordination.md`（触 `world`，与 zyli 串行 `styles.css`）· `#1383 (2026-07-14)` 续接点 · dev-together 技能。
- **DoD:** hello live E2E 的 **agent-browser 截图 + transcript**（真 deepseek，非 stub）+ hello 侧派活入口契约（与 gaga 对齐）。
- **闸:** 全套静态 gate + 回归测试 + PR-head CI 绿 + rebase main。**world 规约:** 声明 surface 归属、串行 `styles.css`、遵守 layout gate。

### zyli — 前端 CI 覆盖续（`tsc --noEmit` 进 CI）
- **分支:** `ci/frontend-tsc-noemit`（从 `origin/main` 切）
- **范围:** #1371 前端 CI 覆盖**第一步**：`tsc --noEmit` 接进 CI——三个 assets 目录（`ezagent_web/assets`、`ezagent_plugin_world/assets`、`ezagent_plugin_hello/assets`）各跑 + 一个 CI step。**范围外:** 一次做全（ESLint/Vitest/Playwright 后续分期）；不改 `world` 运行时 UI。
- **必读:** `docs/futures/todo.md` 前端 CI 节 · `ci.yml` · 三个 `assets/tsconfig.json` · `[[reference_ezagent_static_gate_topology]]` · `#1389 (2026-07-14)` 续接点 · dev-together 技能。
- **DoD:** `tsc --noEmit` 在 CI 中对三个 assets 目录**真实运行并会 fail**（构造类型错误证明 gate 有效，再修复）+ CI 绿。
- **闸:** 全套静态 gate + PR-head CI 绿 + rebase main。

### jjkysy — （明天可能没时间；有余力再做）检查补位 + #1360 形式化 + #1301
- **分支:** `docs/socialware-data-mount-model`（#1360 形式化）+ kanban 检查（从 `origin/main` 切）
- **范围:** **不派主建**——若有时间：① hello↔kanban 的 **kanban 侧检查**（与 zhaomato/gaga 互检派活接口契约）；② 把 **#1360 分析形式化为 PR**（Layer B spec）；③ 推 #1301 dealscout 到 mergeable。
- **必读:** `ezagent-socialware` + `ezagent-developer` 技能 · #1360/#1355/#1357 core-gap 线 · `docs/socialware-data-mount-model` · `#1376 (2026-07-14, 挂起)` 续接点 · dev-together 技能。
- **DoD（若做）:** #1360 形式化的 PR + kanban 侧检查可核实结论。
- **闸:** 全套静态 gate + PR-head CI 绿 + rebase main。

### ruihua（设计输入，非 track 行）
- designer 不占 track 行、不改代码。① **从产品角度完善 W29 demo**（gaga 测→allen 验后接手打磨全链产品体验，设计输入走 **Feishu**）；② **#1378 rebase+解冲突**后交 lead 合 + #1388 DealScout 续。

## §6 out-of-scope / backlog（登记 + 归因）

- **enforce 翻转（`require_signature:true`）** —— 待 codex 无尾巴升级完成 + audit=0 未签名 authorizer cap 后才翻（归「auth 不变量 flip，按 §7 新 gate 先过真数据 E2E」）。
- **entity-caps C（grantee-signing #1386）+ scoped A/B/D 落地** —— codex 在开，返工待 lead 验收（归「lead 轨道 CapBAC 收口」）。
- **#1360 Layer B 挂载 infra 真实实现** —— 本周先松耦合跑通，真挂载紧接排期（归「demo 关键路径地基，先形式化」）。
- **前端 CI 分期后续（ESLint/Vitest/Playwright smoke）** —— 本轮只 tsc，后续分期（归「MVP 质量闸分期，按 #1371」）。
- **demo 去脆 / 稳定化** —— 本周先跑通一次即达标，稳定化结转下周（归「MVP 线之外」）。

## §7 协作约束

- **【新 gate · 07-14 沉淀】auth 不变量 / 数据迁移改动，enforce/flip 前必须过一次真 canary 数据 E2E** —— 干净 fixture 的绿单测是必要非充分（cap-signing 6/196 缺口只在真数据上现形）。enforce 不翻直到 audit=0 未签名。
- **CI 闸:** return 前本地跑**全套**静态 gate（不跑子集）；**机器闸 CI 绿 ≠ 产品验证**。
- **canary 红线:** **canary 前不宣布修好。** 任何「demo 跑通 / 链测通过」的通报须有 canary 实测证据（agent-browser 截图 + transcript / 真实 PR 链接 + kanban 流转截图）后才发。
- **PR 标题诚实:** 未 canary 实证的修复不标「修好」；**hello↔kanban 本周是「松耦合先跑通」，须诚实标注「松耦合，非最终挂载（#1360 Layer B 待补）」**——不把松耦合冒充真挂载。
- **评审基准:** `origin/main`（rebase 到 current main 后再 return）；每任务一分支，PR 只并入本任务分支，lead 走 `close` 合入 main。
- **SPEC 约:** gaga AgentRuntime #1402 先走 **codex 对抗评审**（架构方向/分层/边界），SOUND 后再交 lead。
- **skill 改动:** dev-together **无唯一 owner**——全员讨论，特殊情况由 lead admin-merge。
- **开工前必读:** `docs/together/contributing/` + dev-together 技能 + `docs/guide/world-coordination.md`（触 `world` 的 zhaomato/zyli 必读）+ `2026-07-14/review.md` §3/§5 + 各自 §5 开工 prompt / handoff。
