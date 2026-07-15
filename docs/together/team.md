# Dev Together Team

_Last checked: 2026-07-13_

The durable roster for `dev-together`. **Row identity = `github_username`** (the
canonical key; it joins to PR authorship). `dev-together plan` reads this file,
filters to `role: human-dev`, and derives each dev's next increment from
`current_track` + `latest_return`. `current_track` / `latest_return` have a
**single writer: `dev-together review`** (end of day). A mid-stream pivot may be
reflected by the lead.

`short_name` is the alias the daily `plan.md`/handoffs use (`zyli`, `zhaomato`);
it exists so the long GitHub key joins to the short name plans cite.

| github_username | short_name | role | feishu_name | current_track | latest_return | timezone | github_lookup |
|---|---|---|---|---|---|---|---|
| `zyli-developer` | zyli | human-dev | 李震宇 | 前端 CI 覆盖任务（分期，先 `tsc --noEmit` 进 CI；#1371 登记，结转） | `#1389 (2026-07-14)`（Session Bindings/Routing 标签点击修复；纯前端隔离低风险） | GMT+8 | verified org member |
| `gagameow` | gaga | human-dev | 黄佳佳 | 测试 W29 demo 路径（派活→平台 agent 出 PR→合→看板流转）交 allen 验收 + AgentRuntime 存量迁移 ARB-2~5 + LiveAuth/caps 审计（#1402 已合；⚠「EntityCaps 持久化统一」与 codex entity-caps D 重叠、待 lead 分派）；demo 走 cc-headless（bridge-join 归 #1405 设计线、impl 待 lead 决策） | `#1375+#1379+#1381+#1402+#1403+#1405 (2026-07-14)` — 3 已合安全 PR（PTY 归属 + create_user 提权洞 + cap-gate 加固）+ #1402 AgentRuntime 边界门禁 + LiveAuth 热修 + #1403 HomeLive fail-closed（删 admin 兜底提权洞，已 main·未发 canary）+ #1405 bridge-join/agent-fault 设计（证伪缺凭证归因、Option B 锁、连到 #1394 同一静默丢弃病、impl 卡 2 个 lead 决策）；**07-15：#1412 auth Task 3-6 readers（LiveAuth/MemberCap/world→verified EntityCaps、fail-closed）+ email-inbound authority seam（移除未签名 inline mint）+ #1416 W29 demo 真机分段验证（CapBAC 确认在拦 kanban 未授权写、抓 2 个 project_cwd→sidecar bug、定位 4 个 provisioning 缺口，无造假）** | GMT+8 | verified |
| `zhaomaota97` | zhaomato | human-dev | 张宁 | hello live E2E（6-point transcript，orchestrator 真回话已由 #1367 证明、现可链测）+ hello↔kanban 融合深化 / 配合 #1360 Layer B 挂载 | `#1383 (2026-07-14)` — Hello↔Kanban 松耦合融合（公共/匿名入口 + 登录续接 + Hello Dispatcher + 派活链路），W29 demo 关键路径 | GMT+8 | verified org member |
| `allenwoods` | allen | lead | 林懿伦 | **CapBAC 线收口**（entity-caps A/B/D 验收+部署 #1409 · grantee-signing 证明 #1386/#1410 · no-tail spec v3 两轮对抗评审 SOUND + handoff #1413/#1414）→ 待 codex no-tail build 交回验收 → canary drain → audit=0 → **手动翻 enforce（终局）**；W29 demo provisioning 4 缺口架构约束已给 gaga（#1417）；enforce 不翻直到 audit=0 未签名 | `07-15: #1409/#1386/#1410/#1413/#1414/#1408（CapBAC 全线落 main）` | GMT+9 | verified |
| `jjkysy` | jjkysy | human-dev | 姚升悦 | （明天可能没时间）检查补位（hello↔kanban 融合的 kanban 侧可核实验收）+ 把 #1360 分析形式化为 PR + 推 #1301 dealscout 到 mergeable（他的 #1376 挂载 infra 已被 entity-caps north-star 接管、由 allen 主导 · codex 开发） | `#1376 (2026-07-14, 挂起)` — 把挂载扩成完整通用 infra（表+Mount API+reconcile），但被 entity-caps 去中心化模型取代、转 draft；API/测试/kanban 契约留用 | GMT+8 | verified |
| `ruihuachen-designer` | ruihua | designer | 陈瑞华 | 从产品角度完善 W29 demo（gaga 测→allen 验后接手打磨）+ #1378 rebase+解冲突→lead 合 + #1388 DealScout 撮合原型续（设计输入，不占 track 行） | `#1378 (2026-07-15, merged) + #1421 daily`（website-demo 目录重整 + flywheel design-brief + recruit-publish-flow 落 main；#1388 DealScout（加 dating 式双向匹配）+ #1419 Profile 名片 socialware 续、明天改） | GMT+8 | verified |
| `claude` | claude | agent | — | off-plan support (orchestration / fixes on request) | n/a | — | n/a |
| `codex` | codex | agent | — | off-plan support (bounded verifiable sub-tasks) | n/a | — | n/a |

> **role legend:** `human-dev` gets a daily track in `plan`. `lead` runs the
> cadence. `agent` is off-plan support — never gets a track row in the plan.
> `designer` / others are listed for the username↔Feishu map but get no track.
>
> **dev-together 无唯一 owner。** 所有 skill 改动全员讨论；特殊情况由 lead
> （`allenwoods`）admin-merge（「Protect dev-together skill」CI gate = lead-gated，
> 不属于任何个人）。`dev-together review` 作为 `current_track`/`latest_return` 的
> **single writer** 指的是一处机械去重的写入职责，不是对 skill 的所有权。

## Platform accounts — go-live (2026-07-06)

The seeded login accounts for the deployed platform (world). Login = email
magic-link delivered to these `@ezagent.chat` mailboxes (mail service
`email.ezagent.chat`). Admin = 林懿伦. These are the "available usernames" the
go-live reseed provisions.

| feishu_name | email | role | github_username |
|---|---|---|---|
| 林懿伦 | `lin.yilun@ezagent.chat` | **admin** | `allenwoods` |
| 姚升悦 | `yao.shengyue@ezagent.chat` | user | `jjkysy` |
| 陈瑞华 | `chen.ruihua@ezagent.chat` | user | `ruihuachen-designer` |
| 李震宇 | `li.zhenyu@ezagent.chat` | user | `zyli-developer` |
| 张宁 | `zhang.ning@ezagent.chat` | user | `zhaomaota97` |
| 黄佳佳 | `huang.jiajia@ezagent.chat` | user | `gagameow` |

> Login flow: user enters their `@ezagent.chat` email on world → app mints a
> single-use magic-link (`/auth/magic/:token`, task #87, login-only for existing
> accounts) → delivered via `email.ezagent.chat` → user opens it from their
> mailbox → logged in. Old pre-2026-07-06 accounts/data are cleared on the
> go-live reseed (agent-identity + role-on-edge data-structure change).

## Profile — background（固定）+ 强项/适合任务（review 更新）

> agent 加持下所有工程师都具备**全栈/部署**能力；差异在**开发习惯、产品 sense、
> 架构熟悉程度**——这决定开发效能与**最佳派发点**。`background` 固定；`强项/适合任务`
> 由每次 close review 的 §2 更新（见末节流程）。

| github | background | 强项 / 适合任务（动态，据 review） |
|---|---|---|
| `allenwoods` (林懿伦) | 全栈工程师 · 背景 AI 博士 · 当期职责 lead programmer | 架构/地基、对抗评审驱动的大改造、跨域整合、运行时、部署。架构熟悉度最高。6-25：独力 A+B+C + RF-1..9 + kanban-as-role + py-agent + deploy。7-10 周末：独力推 cbac Phase-3 自存储范式（ISSUE/STORE/VERIFY + I12 paradigm-lock，10 stacked 子 PR + e2e）+ deploy/seed/orchestrator/cc-deepseek/PTY 加固——一次完整跑通 stacked-PR-into-task-branch merge model；强化"大改造/范式级授权重构" |
| `jjkysy` (姚升悦) | 全栈工程师 · 背景 AI 博士 · 当期职责 lead programmer | 架构/原则把关（主动发现 kanban 原则问题）、kanban 插件原作（#964 13.5k LOC）、dev-together 流程/评审贡献大。适合地基/流程/评审。7-09：#1295 揪出 duplicate-fn baseline 虚高（46 实为 42），强化"记账/原则把关"。7-10：kanban 改版 #1298 收口（重做连贯全链路证据 26 件，分层确定句结论）+ #1255 三命名裁定 #1293 + 项目讨论 skill re-bootstrap #1292；发现 socialware core-gap（#1355 组合关系→窄 cap / #1360 跨 session 数据共享）驱动 lead spec #1357——强化"产品收口 + 深层缺口发现"。7-13：#1360 core-gap（跨 session 数据共享 = mount agent 进房间）分析线有推进——`docs/socialware-data-mount-model` 2 commit（分析记录 + 收窄 Layer B），续 #1355/#1357；但**未开 PR、未写 return**，PR 层不可见。缺口是**流程（未形式化）**而非产出为零——强化"深层缺口发现"的同时须补"落到 PR/return"。kanban 进度看板 + #1301 dealscout（末触 07-12）仍待落。派发注记：明日把 #1360 分析形式化为 PR/return + 给可核实的看板交付 + 推 #1301 到 mergeable |
| `gagameow` (黄佳佳) | 运维工程师 | 部署/运维、agent console（6-25）、agent 配置验证。运维 + 产品 sense。7-09：#1294 根因诊断——create_session 两链（#1223 焊接）解耦，reproduce-first 识破 decouple_test 断言反转。强化"根因诊断/架构级排查"。7-10：链C credential-skip（#1326）+ stop-silent-install-success（#1317）+ presence e2e 去脆（#1318）+ 默认 session plain 防御性 hotfix（#1310，诚实标注"不替代 canary 实测"）；注意点：AgentRuntime 边界 SPEC（移交结构线）本窗口未落地，须补。7-13：**自举第一张多米诺 canary 实证**（#1367 commit 200f91b5：平台 cc-deepseek agent 经正式入口被唤醒 + 两次 @orchestrator 真回复 + 最小开发任务 ACCEPTED）；**根因诊断再验**——用单变量 D-vs-E 受控实验证伪 coordinator 的"认证失败"误诊（933 崩溃/0 auth 命中，真根因 `--continue`），加 respawn 断路器 + 600+ 行测试 + 双语根因文档（#1366/#1369）。强化"reproduce-first 根因诊断"。注意点：AgentRuntime 边界 SPEC 仍未落地（急症正当挤占，结转 07-14）；诚实旗标：部分 demo agent（`test-zyli-cc-1`）缺凭证，待下发 |
| `zyli-developer` (李震宇) | 全栈工程师 | 全栈、E2E 体系、Feishu 适配/产品缺口。端到端验证强。7-09：#1276 大 PR 连环触发 4 道行锚 gate（本地只跑单 gate）→ 派发注记：大 PR/动行锚文件本地跑全套 gate。7-13：#1365 一次性把 #1320（creator 自动入 class/template session → 过滤列表可见）+ #1327（卸载证据）收口到 current main，overview 可见性统一 caller-scoped，thin `defdelegate` 守住 arch 预算（precommit 全绿）。强化"产品缺陷收口 + 可见性/授权面" |
| `zhaomaota97` (张宁) | 全栈工程师 | 全栈、前端 json-render / hello 渲染底座。前端/渲染强。7-11：#1312 hello 可见性控制 + sharer/publisher agents + v2 seed + rebuild guide；注意点：hello live E2E "greeter+curl-llm 真回复" transcript 待补（能力依赖 orchestrator 真回话）。7-13：本日 track（官网首程 + hello 连 kanban）被阻——依赖的 orchestrator 真回话 mid-day 才由 gaga #1367 证明；**属 blocked-not-idle，非空转**；阻塞现已清，E2E transcript 结转 07-14（现可链测） |
| `ruihuachen-designer` (陈瑞华) | 产品经理 | 产品/设计版式、可外发文档版式输入（设计输入，不改代码）。7-13：#1372 官网飞轮 demo——可点击静态 HTML 原型（`index-gallery.html` 落地页「组织的 IDE」+ 双边飞轮 Builder/Seller 走查路径 + README），零构建可跑；coordinator 按 designer-deliverable 约定（#1373）代开 PR。强化"产品叙事/飞轮可视化 + 可外发原型" |

> **退出记录**：`FatNine`（戴明，后端）2026-07-13 退出 ezagent 开发，已从 roster 与今日 track 移除。

## 任务分配原则（lead 派发遵守）

1. **任务类闭环在一人 —— 避免当日 context 搬运。** 一类任务（含其验证）当日尽量落在
   同一人，即使历史上某子环节常由他人做。*例*：6-27 若 deploy-flow 在 `allenwoods`，
   deploy-flow **E2E 也归 `allenwoods`**（非按"zyli 常做 E2E"拆走）——当日最优点是
   context 持有者。**次日** context 进 main 后，任务可迁移。
2. **最大化并行。** 若当日任务须拆两人且 A 等 B，**在 A 插 mock-B、B 插 mock-A**，
   双方先对齐 mock 契约再各自并行，消除串行等待。
3. **围绕近期目标（最重要）。** 当日工作聚焦近期目标。**大量 out-of-scope = 信号**：
   要么开发偏离方向（避免/拉回），要么底层疏漏（系统排查）。out-of-scope 必须在 plan
   显式登记并归因到这两类之一。

## profile 更新流程（据 review）

每次 close review §2（开发效能）后，lead 据其更新本档每人"强项/适合任务"：高效低返工
→ 强化该类标签；踩坑/返工 → 记 `contributing/` 并调整派发（配 mock/评审）；主动发现深层
问题 → 记"原则把关"强项。profile 是**被数据持续修正的动态档**，非一次性背景。
