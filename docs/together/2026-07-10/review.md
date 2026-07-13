# dev-together 回顾 · 2026-07-10 工作窗（含 07-11/07-12 周末）

> **窗口口径**：本回顾覆盖 **2026-07-10 → 07-12** 三个自然日（GMT+9）——07-10 是唯一有 `plan.md` 的计划日，07-11/07-12 周末无 plan，被一次 **lead 主导的 cbac Phase-3 冲刺**接管。两份周末 return（日期戳 07-13）在窗口末尾定稿、仍在 impl 分支上，本回顾作为**周末增量**收录。
>
> **对账并核两源**：本窗口 `returns/` 只有 1 份（kanban），台账极稀——绝大多数贡献走**直接 PR → review → merge**，靠 GitHub 合并记录反推（`gh pr list --state merged --author …`）。**本窗口无 `stack.md`**（`docs/together/2026-07-10/` 只有 plan.md / plan.html / notes / returns），故"几份进 stack"这一问**无答案 = 流程缺口**，非遗漏，见 §方法增量。

数据源：`gh pr list -R ezagent42/ezagent --state merged`，`mergedAt ≥ 2026-07-10T00:00Z`。

---

## 0. 大局（诚实版）

07-10 的 `plan.md` 头号目标是 **在 canary 实测 #1294 create_session 根因修复——让"@orchestrator 真回话"这条困扰一周的链在真实部署上验证为真绿**，并把两条结构线（AgentRuntime 控制面边界 SPEC + cc-headless 改造）移交 gaga。

**但计划被周末接管**：07-11/07-12 无 plan，窗口的主量是 allen 独力推的 **cbac-done-right Phase-3 自存储范式**（ISSUE/STORE/VERIFY + I12 paradigm-lock，10 个 stacked 子 PR + 主线合入 + 2 篇文档），外加一批 **deploy/seed/orchestrator/cc-deepseek/PTY 加固**。头号 canary 目标**未按 plan 达成**（详见 §3 事故 A），但 plan 的红线"②达成前不发'修好'通报"被遵守——没有出现虚假的"修好"通报。

**本窗口最有价值的三件事：**
1. **cbac Phase-3 自存储范式落地**——授权从"发行方→接收方 dispatch"翻转为 **grantee 自吸收（self-store absorption）+ I12 paradigm-lock**，冷目标能力交接（cold-target handoff）打通，8 段（S1–S8）+ e2e + N1 bypass 回归，全走 stacked-PR-into-task-branch 模型（handoff-standard 的 merge model 一次完整跑通）。
2. **@orchestrator 真回话链在周末被真正推进——但不是被 #1294 推进的**：#1294 修的是 create_session 结构解耦；"@mention 收得到"这一面是被 **#1333 tengu_harbor 自动物化**（cc agent 能 RECEIVE @mentions）+ **#1332 orchestrator MCP wiring + cc-deepseek flavor** 解开的，**根因与 #1294 正交**。一次真正的 #1294 canary 实测本会暴露"orchestrator 仍哑"（因为堵点在 tengu_harbor，不在 create_session）——这本身是一条 finding（见 §3 事故 A）。
3. **两条 off-plan agent spec 车道进入 impl 并诚实 return**：socialware composition-cap（组合关系→成员级窄 cap）与 orchestrator Session-Config API——两者都 codex 多轮对抗评审、都在 impl 分支上、都**未达机器返回闸**（无 PR/无远端 CI URL），return 都**没有自宣"READY TO MERGE"**，把裁定交回 lead。这两份 return 的**证据-出处标注纪律**（"prior-run evidence, Dev: Codex, NOT re-executed"、"recorded as LOCAL, NOT remote PR CI"）是本窗口最重要的方法产出（见 §方法增量）。

---

## 1. What landed（合入 main，按主题分组，带 SHA/PR）

**口径**：窗口内 **42 个 PR 合并**，其中 **10 个合入 `feat/cbac-done-right` 任务分支**（cbac S1–S8 的 stacked 子 PR），**32 个落 main**。cbac Phase-3 是**一个任务**，经 10 个子 PR 汇入任务分支后由 **#1356 一次落 main**——按 handoff-standard 的 merge model，不按 10 个独立特性计。

### A. cbac Phase-3 自存储范式（allen · 周末主量 · 一个任务）
> merge model：S1–S8 子 PR → `feat/cbac-done-right` 分支 → **#1356 落 main**。

| PR | 落点 | 标题 |
|---|---|---|
| #1335 | 分支 | chore(cbac): align OTP index + restore baseline CI |
| #1336 | 分支 | feat(cap) **S1**: issue and provenance seam |
| #1337 | 分支 | feat(cap) **S2**: authorize at issue time |
| #1341 | 分支 | **S3**: verified self-store absorption |
| #1342 | 分支 | **S4**: verify capability load boundaries |
| #1345 | 分支 | **S5**: persist issued recipe bindings |
| #1348 | 分支 | **S6**: self-store recipe capability artifacts |
| #1351 | 分支 | **S7**: complete cold-target capability handoffs |
| #1353 | 分支 | **S7 follow-up**: restore role-model orchestrator MCP context |
| #1354 | 分支 | **S8**: validate Phase 3 cap self-store end to end |
| **#1356** | **main** | **cbac-done-right: Phase-3 cap self-store（ISSUE/STORE/VERIFY + I12 paradigm-lock）** |
| #1358 | main | docs(cbac): sync ISSUE/STORE/VERIFY + I12 model；N1 bypass 回归；team handoff |
| #1359 | main | docs(cbac): cbac-grant-prompt — paste-before-you-code checklist |

支撑 flake/CI 卫生（main）：#1339（drain fire-and-forget Tasks，#108-class）· #1340（missing-cred spawn skips，去脆 WorldConversationTest）· #1346（transient identity-read **fail-loud**，绝不静默 deny）· #1344（keyless full-suite 绿：dummy `DEEPSEEK_API_KEY` + cc-deepseek 漂移修复）。〔#1347/#1338/#1349 为 integrate/dup/superseded，见 §2〕

### B. 头号链 — create_session / orchestrator 真回话（gaga + allen）
| PR | 开发者 | 标题 / 作用 |
|---|---|---|
| #1294 | gaga | docs(session)：新建 session 超时 + orchestrator 哑掉根因/契约破坏点（代码修复 `2d47475b2` 07-09 已落；本条是 forensics 文档） |
| #1310 | gaga | fix(session)：keep default sessions plain（**防御性 hotfix** — 默认新 session 只装 `chat` 不装 orchestrator；因 orchestrator 启动仍 block/flake；**明确不替代 #1294 canary 实测**） |
| #1317 | gaga | fix(session,workspace)：stop silent socialware install success（不可读声明不算成功；`orchestrator_status: :ready` 不撒谎） |
| #1318 | gaga | test(session)：stabilize presence read receipts e2e |
| #1326 | gaga | fix(agent,session,world)：**链 C** — 凭证缺失时跳过角色槽，不建无声僵尸（PR-1 + PR-2） |
| #1329 | allen | fix(session,agent)：decouple agent authz from session-create/install lane（R2–R5：eager orchestrator binding / register-before-grant / drain-on-failed / install-lane gate；R1 grant-seam 待 Allen A/B） |
| #1332 | allen | feat(orchestrator)：wire orchestrator MCP-channel server → `.mcp.json` + 切 orchestrator 到 cc-deepseek flavor |
| #1333 | allen | feat(cc)：**auto-materialize `tengu_harbor`** 使 cc agent 能 RECEIVE @mentions（← 真正解开"@orchestrator 收不到"的那一面，根因与 #1294 正交） |
| #1331 | allen | fix(pty)：harden cc PTY（bounded supervisor 不全节点擦除、respawn `--resume`、未知 claude 对话框 loud-fail） |

### C. deploy / seed / boot 加固（allen）
- **#1334** feat(seed)：no-clobber reseed for stale app definitions（boot 暴露分叉，operator `--force` 迁移）
- **#1330** test(boot)：gate — boot+seed 须在**空凭证库**下成功且不启任何带凭证 agent
- **#1343** static arch gate：禁止裸 `__DIR__` 运行时资产解析（#1325 的另一半）
- **#1350** ci：re-tier — full-suite 移出 every-PR、block deploy dispatch on it、rename dispatch job（supersedes #1349）

### D. cc backend / bridge（allen）
- **#1324** feat(cc)：DeepSeek backend for cc flavor（pty + headless，API-key 认证，无 OAuth login）
- **#1325** fix(cc)：ship esr-bridge sidecar in release + 运行时解析 `bridge_script_path`（cc agent 从未 bound——MCP sidecar 缺席 release）
- **#1311** fix(cc)：cc-headless 继承宿主 Claude login — 补缺失的 `host_login_dir/0` delegate（#1309）

### E. auth / identity / membership（allen）
- **#1306** fix(auth)：magic-link/confirm/reset 用**请求 host**（allowlisted），不用静态 `Endpoint.url()`
- **#1307** fix(identity,workspace)：user-creation 路径补 workspace membership（operator 任务 + `create_user` facade）〔即 go-live `member_uris` 空导致 6 用户看不到 workspace 的根因修复〕

### F. 产品面（zhaomato / jjkysy）
- **#1312** zhaomato feat(hello)：visible control + sharer/publisher agents + v2 seed page + rebuild guide（← zhaomato 本窗口唯一合入）
- **#1298** jjkysy refactor(world)：**kanban 改版** — 插件页面注册表化 + socialware 纯化 + e2e 四段（← kanban-rework-final return 映射此 PR）
- **#1293** jjkysy chore(arch)：#1255 三命名裁定
- **#1292** jjkysy chore：全量 re-bootstrap 项目讨论 skill
- **#1304** jjkysy chore(dev-together)：W28 方法增量润色 + 收齐 #1302 seed 漂移 + owner-guard 名单制

### G. 流程 / 文档（不计产品量）
- **#1302** allen docs(together)：0709 close/review + 0710 plan + skill method-deltas
- **#1305** allen docs(together)：review attribution by PR-creator + track handoff（allen→gaga）+ CI-green/PR-title rules
- （#1294 forensics、#1358/#1359 cbac 文档、#1304/#1292 skill 亦属流程/文档面）

### H. 周末 off-plan agent spec 车道（**未合入 main**，impl 分支，诚实 return）
| 车道 | spec 分支 @SHA | impl 分支 @SHA | return 状态 |
|---|---|---|---|
| **socialware composition-cap v5**（组合关系→成员级窄 operate cap，走既有 owner gate，不新造授权原语） | `spec/socialware-composition-cap-revision-v5` @ `9243ff1f4` | `feat/socialware-composition-cap` @ `d7ebcd39b`（6 commits，0 behind / 6 ahead main） | **out_of_scope**（off-plan agent；机器闸未达：无 PR/无 CI URL；`ci.local` exit 2 = 既有并发 seed flake，隔离重跑绿）；**未自宣 READY TO MERGE** |
| **orchestrator Session-Config API v4**（单域边界 `execute/…` + 薄投影 MCP/HTTP/CLI/World + 版本化 HMAC PAT） | `spec/orchestrator-mcp-revision-v4` @ `eec2f82af` | `feat/orchestrator-session-config` @ `9820a3044`（8 commits，8 ahead / 0 behind） | **deferred**（机器闸开：无 PR-head CI、须 post-merge canary、须 rebase 核 main freshness）；**未自宣 READY TO MERGE** |

两车道均 codex 多轮对抗评审、方向 SOUND，进 codex 实现；均把**审查/CI 拓扑裁定交回 lead**。

---

## 2. 效率 / 台账对账（Required accounting）

| 问题 | 答案 |
|---|---|
| plan.md 里有几条 track？ | **6 条人类 track**（allen lead 线 · gaga 头号+2 结构线 · zhaomato ①②· zyli · jjkysy · ruihua）+ coordinator off-plan support（不占 track 行） |
| 到了几份 return，几份迟到？ | **on-plan：1 份**（`2026-07-10/returns/kanban-rework-final.md`，jjkysy 席位/agent 代笔，on_time，取代 07-09 pending kanban-rework）。**周末 off-plan：2 份**（`2026-07-13/returns/socialware-composition-cap.md` out_of_scope · `2026-07-13/returns/orchestrator-session-config.md` deferred）——日期戳 07-13、窗口末定稿、仍在 impl 分支未入 main。**迟到：0**（三份均 on_time/按约束标注） |
| 几份进了 stack.md？ | **无 stack.md** —— `2026-07-10/` 目录只有 plan.md/plan.html/notes/returns。此问**无答案 = 流程缺口**（见 §方法增量 D1） |
| 几个合入 main？ | **42 PR 合并；32 落 main，10 入 `feat/cbac-done-right` 任务分支**。按开发者（含分支）：allen 32 · gaga 5 · jjkysy 4 · zhaomato 1。落 main 计：allen 22 · gaga 5 · jjkysy 4 · zhaomato 1 |
| superseded / out-of-scope / blocked / deferred？ | **superseded**：#1349（dispatch rename）→ #1350 · #1338（drain dup）→ #1339 · #1347（integrate 批）已收编入各 S PR。**out_of_scope**：socialware composition-cap return（off-plan agent，非 07-10 track）。**deferred**：orchestrator-session-config return（机器闸/canary 未达）。**blocked→已解**：kanban 大脑层曾被 #1309 挡（本窗口 #1311 已修）。**deferral（登记）**：AgentRuntime 边界 SPEC + cc-headless 改造（07-10 移交 gaga，窗口内未落地为合入 SPEC，见 §3 事故 B） |
| 相关 GitHub PR 状态？ | **合 main 32**（cbac 10 子 PR 汇任务分支）；**有意 open**（未合/subsumed 分列）：#1360（socialware 跨 session 数据共享 = mount agent 分析，→Allen 拍板）· #1357（allen socialware composition-cap lane spec，← jjkysy #1355 gap）· #1355（jjkysy core-gap handoff）· #1327（zyli #1245 卸载浏览器证据）· #1320（zyli fix class session listings）· #1301（jjkysy dealscout 完整改版，五段）· #1148（jjkysy 可寻址单位审计）· #1134（zhaomato concierge + public read）· #1296/#1297/#1299（allen CapBAC/agent-layer/admin-gate 设计&gate，待 Allen 拍板）· #1256（gaga agent×flavor v2.5 决策记录）· #1287/#1149（ruihua canary playtesting/UI 问题）· #1316/#1267（allen cc-headless 量化/活页面调研）· #1322/#1323（allen canary-rename/cc-headless MCP，部分被 #1350/#1332 收编，待清理） |

**头号目标 vs 实际（诚实记账）**：plan 头号 = #1294 canary 实测"@orchestrator 真回话"。**未按 plan 达成**——无 canary transcript 归档；该能力在周末被 #1332/#1333 从**另一条根因**（tengu_harbor + orchestrator MCP flavor）推进。07-10 计划的 per-dev track 与实际：gaga 交付 #1310/#1317/#1318/#1326（头号链的加固/去脆），但**未产出 AgentRuntime 边界 SPEC**（结构线未落地）；zhaomato 的 hello live E2E 以 #1312（可见性控制 + v2 seed + rebuild guide）推进，**live E2E "greeter + curl-llm 真回复" transcript 未归档**；zyli canary 走查**无 return 亦无窗口内合入 PR**（#1320/#1327 仍 open）；ruihua 无 PR（计划内）。**窗口主量（cbac Phase-3 ~13 PR）是 07-10 plan 之外的 lead 冲刺**——plan 被周末接管，本回顾明记，不用合并数掩盖头号目标滑动。

---

## 3. 事故 / Gap / 结转（诚实复盘）

### 事故 A — 头号 canary 目标未达成，且"orchestrator 真回话"是被另一条根因解开的
**经过**：plan 头号 = canary 实测 #1294 让 @orchestrator 真回话（红线："达成前不发修好通报"）。窗口内**无 canary transcript 归档**（`docs/e2e/2026-07-1[012]` 只有 phase3-cbac 证据，无 orchestrator-replies 截图/PTY join 日志）。gaga 反而插入**防御性 hotfix #1310**（默认 session 只装 chat、不装 orchestrator），note 明写"因 orchestrator 启动仍 block/flake、不替代 #1294 canary 实测"。周末真正解开"@mention 收得到"的是 **#1333 tengu_harbor 自动物化**（cc agent 能 RECEIVE @mentions）+ **#1332 orchestrator MCP wiring/cc-deepseek flavor**——**根因与 #1294（create_session 解耦）正交**。
**教训/记账**：① 头号目标滑动，明记不掩盖；② 红线"不发修好通报"**被遵守**（无虚假通报）——这是成熟信号；③ **一次真正的 #1294 canary 实测本会暴露 orchestrator 仍哑**（堵点在 tengu_harbor，非 create_session），这条 finding 说明"急症根因"与"能力可用"是两个根因、须各自 canary 证；④ 头号 canary 结转，**待 gaga 补一次真回话 canary transcript**（现能力已由 #1332/#1333 就位，实测应可过）。规则映射见 §方法增量。

### 事故 B — 移交 gaga 的两条结构线（AgentRuntime 边界 SPEC + cc-headless 改造）未在窗口落地
**经过**：07-10 plan 把两条结构线移交 gaga（W28 目标③"收敛 agent 控制面边界"）。窗口内 gaga 合入的是头号链加固（#1310/#1317/#1318/#1326），**AgentRuntime 边界 SPEC 未产出合入版**（#1256 agent×flavor v2.5 决策记录仍 open；#1297 agent-layer 边界评估仍 open），cc-headless 改造由 allen 侧以 #1311/#1324/#1332 分片推进而非 gaga 的枚举式全量改造。
**结转**：AgentRuntime 边界 SPEC 结转为 gaga 次日 current_track（见 team.md）。W28 目标③ 本窗口以"急症加固"推进、结构线待补。

### 事故 C — 两份周末 return 均未达机器返回闸（机器闸 ≠ 产品验证，被诚实标注）
**经过**：composition-cap（`ci.local` exit 2 = 既有 default-SessionTemplate 并发 seed flake，隔离重跑 14/0 绿；无 PR/无 CI URL）与 orchestrator-session-config（无 PR-head CI、须 post-merge canary、local base `720913ad` 未 re-fetch）**均未达机器闸**，两份 return **都没有自宣 READY TO MERGE**，把裁定交回 lead。
**这是正向信号不是事故**：两份 return 把"证据出处"标注到位（"prior-run evidence, Dev: Codex, NOT re-executed"、"recorded as LOCAL, NOT remote PR CI"），正是对"注入报告/凭空自证"风险的正确响应（见 §方法增量 D5）。**待 lead 裁定**：审查/CI 拓扑（直接审 target 分支 vs 建非-main review PR 出绿 CI head）、并发 seed flake 是否单列 CI-稳定债。

### 已解 / 结转登记
- **kanban 大脑层**（07-09 被 #1309 挡）：#1311 已修 cc-headless host-login，**待补一次真脑闭环 e2e**（kanban-rework-final return §结论）。
- **socialware 全生命周期验证**（C1，07-08→持续结转）：本窗口未系统跑；composition-cap 车道推进了"组合关系授权"这一支。
- **admin?/1 业务态清理**（#1299 SOUND-WITH-NOTES）：仍待 Allen 合入定夺。
- **CapBAC vs RBAC（#1296）/ agent-layer 边界（#1297）**：设计 PR 仍 open，待 Allen 拍板是否成重构线。

---

## 4. 方法增量（MANDATORY — 促进，不只收集）

> 三源：两份周末 return 的 Method-friction 节 + kanban-rework-final + 窗口协作实况。每条给出**规则映射**（既有/新增）+ 处置（**dev-together skill 改动** vs **tracked process-debt**）。

### D1. 无 stack.md → 台账对账靠 PR 反推（process-debt，owner: lead）
`2026-07-10/` 无 `stack.md`，"几份进 stack"无答案。**规则（既有）**：review.md 的 Required accounting 假定 stack.md 存在。**处置**：process-debt——本窗口以直接-PR 为主、returns 稀，stack.md 事实停用。**建议 skill 改动**：若团队常态走直接-PR，review.md 的 accounting 应把"stack.md 计数"降级为"可选"，并把**双源对账（returns/ ∪ GitHub 合并）**升为**必跑**（对账并核两源已在 skill，本窗口再次实证其必要）。

### D2. spec 源须绑**完整 commit SHA**，不绑"v5"/名字（**skill 改动**，owner: lead）
composition-cap return #1：spec 中途 v4→v5，且 v5 HEAD 从中间 commit `5d216a7be` 更正到 `9243ff1f4`。**规则（新增）**：**handoff 的 source-of-truth spec 必须绑完整 40 位 commit SHA**（"读 spec 从分支 X @ `<full-sha>`，blob `<hash>` 核实"），永不绑版本名/分支名。**处置**：写进 `handoff-standard.md`「Required-reading」节——"spec/研究文档引用 = 分支@完整SHA，返回时核 tree 携带该文件"。若无此规则，多轮 spec 修订下极易读到过期版本。

### D3. "no core global flip" = **LOCKED decision**，须在 handoff 显式钉死（**skill 改动**，owner: lead）
composition-cap return #2：0a(b) 蓝图 core `authorize_cap_shape` fail-closed 全局翻转被**提出后又明确 descope**；若 handoff 未把"不动 core 全局 gate"钉为 **LOCKED decision**，极易在 core 上过度伸手做大范围安全改动。**规则（新增）**：**touches CapBAC/core 的 handoff 必须列一节 "Locked decisions / must-not-do"**，把"不翻转的 core 语义"显式钉死（对齐 discuss-first triggers 里 CapBAC/core 触发 clarify 前置）。**处置**：写进 `handoff-standard.md` 的 Defer rules 邻节——"load-bearing 的**不改**决定与**改**决定同样 load-bearing，须显式 LOCKED"。

### D4. phased-handoff **target-branch** 一次性审查 ≠ 默认机器闸（**skill 改动**，owner: lead）
orchestrator return §10 #1：任务约束"保留 target 分支给 lead 一次性完整审查"，与 dev-together 默认机器闸（PR-head CI 绿 + rebased on current main）不同；这是**合法的 pre-merge local 阶段**，只是 DoD 14/15/16（PR-CI/rebase-freshness/canary）变为 **lead-owned** 而非 dev 在 return 时可满足。**规则（新增）**：**skill 应认可一种"target-branch pre-merge review"返回态**——off-plan/agent 车道无 PR 时，return 声明"机器闸 lead-owned"，不视为违规、也不得自宣 READY。**处置**：写进 `commands/return.md` 的机器闸节——"无 PR 的 target-branch 返回：三项机器闸标 `deferred(lead-owned)`，close 时由 lead 补齐"。对齐既有 memory「codex handoff = self-merge to target branch」「codex sub-steps not whole PRs」。

### D5. 证据须带**出处**，"没重跑" ≠ 绿，agent 自述 gate-绿**永不**替代 PR-CI（**skill 改动**，owner: lead）
两份周末 return 都用大量防御性出处标注（"heavy-suite = **prior-run evidence, Dev: Codex, NOT re-executed**"、"recorded as **LOCAL** results, **NOT remote PR CI**"、"§8a file:line 锚在 pre-work main @720913、已 re-map"）。这是对**注入报告/凭空自证（injection-report-confabulation）**风险的正确响应——但目前靠 return 作者自觉，未成规则。**规则（新增/强化）**：既有"return 前必须看到 PR CI 全绿（看每个 check 的最终结论）"应扩为——**① 每条证据标注出处与时点（re-run vs prior-run vs read-only）；② "gates green" 的散文陈述永不作为 PR-CI 替代；③ 无 PR 时静态/本地绿只作 local 证据、显式标 `NOT remote CI`**。**处置**：写进 `commands/return.md` 的机器闸节，作为"证据出处三条"。这是本窗口最重要的方法产出。

### D6. codex-rescue relay-break：codex 会 orphan 长任务，须切 bounded sub-steps（process-debt，owner: lead/coordinator）
窗口协作实况 + 既有 memory（「codex sub-steps not whole PRs」「codex handoff = self-merge to target branch」「codex/curl live-spawn gotchas」）：codex 长跑会断/孤儿化；两条周末车道正是被切成 bounded 子步（composition-cap 6 commits、session-config P1/P2 8 commits，各自可独立审）才走通。**规则（既有，重申并制度化）**：**交 codex 的 = 有界可验证子步，不是整个 PR/长任务**；relay 断即以 target-branch 现状对账（return 已含完整 SHA 台账）。**处置**：process-debt——把"codex 子步切分 + target-branch 对账"写进 `contributing/` 的 codex 协作节（非本回顾硬改 skill）。

### 卫生类（return-sourced，登记）
- **`mix ci.local` 会改写 `apps/ezagent_web/assets/pnpm-lock.yaml`**（dependency-sync 噪声）——**return 前必须还原**（两份 return 均已确认 clean）。→ 写进 return checklist。
- **default-SessionTemplate 并发 seed flake**（`persist failed: :failed`，3 setups/2 files，隔离重跑 14/0 绿）——**单列独立 CI-稳定债**（owner: lead 指派），**不归因** composition-cap；#108-class。

---

## 5. 次日计划建议

1. **补头号 canary transcript**（gaga）：#1332/#1333 已就位，跑一次 canary "新建 session 不超时 + @orchestrator 真回话"（agent-browser 截图 + PTY join 日志），把 07-10 头号目标正式收口——**这次实测会同时验证 tengu_harbor 那条根因**。
2. **裁定两条周末车道**（lead）：先审 target 分支（composition-cap `d7ebcd39b` / session-config `9820a3044`），定审查/CI 拓扑（直接审 vs 建非-main review PR），并把 default-SessionTemplate 并发 seed flake 单列 CI-稳定债。
3. **AgentRuntime 边界 SPEC 重启**（gaga）：W28 目标③ 结构线本窗口未落地，次日以 SPEC + `agent_runtime_boundary` arch gate 收口（把 #1329 的 install-lane gate 泛化为数值度量），coordinator 备 codex 对抗评审。
4. **恢复 stack.md 或正式承认直接-PR 模型**（lead）：若常态走直接-PR，把 review.md accounting 的双源对账升为必跑、stack.md 计数降为可选（D1）。
5. **把 D2–D5 四条 skill 改动落一个 dev-together PR**（lead，单写者）：spec-SHA 绑定 / core-LOCKED-decision 节 / target-branch pre-merge 返回态 / 证据出处三条——本窗口方法增量的核心。
6. **推进 open 产品线**：jjkysy dealscout #1301（五段，推到可合）+ socialware core-gap 决策（#1355/#1357/#1360，Allen 拍板）；zyli #1320/#1327 收口 + canary 走查补 return；zhaomato hello live E2E transcript 补齐（#1312 已合，能力依赖 orchestrator 真回话，见建议 1）。

---

*本回顾面向全体开发者，团队向 HTML 版见 `review.html`。Required accounting 双源已核（returns/ ∪ GitHub 合并）。*
