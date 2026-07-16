# dev-together 回顾 · 2026-07-15（lead close · v2 终稿）

**一句话：** 今天是 **CapBAC 签名线整条塌进 `main`** 的一天——entity-caps 底座、grantee-signing（经对抗性证明）、no-tail 自愈**设计**（两轮 codex 审 → SOUND）全部落地，W29 demo 在真 canary 上完成分段验证（并当场确认 CapBAC **正在生产执行拦截**）。但 EOD 有两件大事改写了下半场：一是 **canary 因缺 `EZAGENT_SIGNING_SEED_V1` 冻结了 1.3 天、7 连败**，当晚定位并**救回**；二是 no-tail 自愈的**实现**（codex build）经两轮对抗复审挖出真 bug → **NEEDS-REVISION 搁置**，Allen 重新锚定问题后**转向严格签名 re-architecture**（spec 已 v11、11 轮审 SOUND）。本周需要的安全地基已就位；剩下的是严格签名实现排期、demo 的 dev-loop provisioning、以及（刻意推迟的）enforce 翻转。

## §1 今日工作统计（按领域 / PR / 负责人）

| 领域 | PR / 产出 | 负责人 |
|---|---|---|
| **entity-caps A/B/D 底座** | #1409 durable delivery outbox + `OutboundGrant` ledger + `EntityCaps` facade + 写侧架构门禁（前一日落地、今日 canary 部署验证） | **allen**（lead 轨道；codex 构建） |
| **grantee-signing（C）** | #1386 spec 修订；#1410 finalize + **对抗性证明**（retargeting 在 Cap seam 与 `EntityCaps.load` 封闭；8 个 verify chokepoint 均 receiver-aware，0 gap） | **allen**（lead 轨道） |
| **cap-signing no-tail（设计）** | #1413 自愈 spec **v3**（两轮 codex 对抗审 → SOUND）；#1414 handoff-convention 修订 —— **注意：实现返工，见 §3** | **allen**（lead 轨道） |
| **capability-auth follow-ups** | #1412 **Task 3-6 readers**（LiveAuth / MemberCap / world-count → 改读已验证 `EntityCaps`，fail-closed）+ email-inbound authority seam（移除未签名 inline mint） | **gaga** |
| **W29 demo（分段验证）** | #1416 真 canary partial-E2E 证据 + blockers（CapBAC 确认**拒绝**未授权 kanban 写入；发现 2 个真 bug）；#1417 dev-loop provisioning 架构约束 | **gaga**（验证）；**allen**（约束） |
| **AgentRuntime 领域边界** | #1411 AgentRuntime 领域边界 + **可恢复 retirement**（main full-suite 绿 + canary 部署验证） | **gaga** |
| **前端 CI 进 gate** | #1415 前端 `tsc` + `vitest` 纳入 gate（dev-loop CI 地基） | **zyli** |
| **cc-headless skill 加载取证** | #1418 cc-headless `setting_sources=[]` → agent 加载不了 skill/CLAUDE.md 的**取证 + 修复方案**（D1 已裁走显式 plugin-bundle 路径） | **gaga** |
| **Hello→kanban 委派 + 回流** | #1425 Hello→kanban 委派 + 只读分享 + 数据回流（补了回流回归测试）；发现 Hello 回执是**委派快照**非活面 → #1426 记 followup | **zhaomaota**；**allen**（回归测试） |
| **工程效率 + 自助 workspace** | #1427 工程效率分析（session 工时下界）+ 企业自助开 workspace 缺口清单 | **allen** |
| **cap-signing 严格化（转向）** | `feat/cap-strict-capstore` 严格签名 re-arch spec（v11，11 轮对抗评审 SOUND）；#1424 no-tail 实现**搁置（draft）** | **allen**（lead 轨道） |
| **协调 / 收尾** | #1420 gaga↔codex cap-gate 重叠说明；#1422 close v1 | **allen** |

> 说明：CapBAC 栈里以 `allenwoods` 署名的 PR 实为经 codex + coordinator 工具驱动的 lead 轨道产出。

**KPI：**今日合入 PR **6**（#1411 / #1412 / #1415 / #1416 / #1418 / #1425；#1409 为前一日）；CapBAC 线**塌进 main**；canary **救回**（1.3 天中断解除）；cap-signing **转向严格签名设计**；enforce **仍 OFF（dual-read）**。

## §2 计划 vs 实际（accounting）

- **计划（0715 plan §1/§2）：** 头号目标 = W29 demo 首次端到端完整跑通（gaga 测 → allen 验收 → ruihua 完善）；并行 lead 轨道 = 接住 codex 两次返工 → no-tail 升级 + enforce 时机。
- **实际：** **CapBAC 线主导并基本完成底座与设计**——entity-caps A/B/D 验收+合入+部署，grantee-signing 已证明，auth-followup readers 已交付；同时 gaga 的 AgentRuntime 边界（#1411）、zyli 的前端 CI（#1415）、cc-headless skill 取证（#1418）、Hello 回流（#1425）都塌进 main。**demo 推进到一次严谨的分段验证**（#1416），精确钉出剩余缺口而非硬凑一次完整 E2E。但 no-tail 这条「设计→实现→enforce」路径在 EOD **发生了转向**（§3）：实现返工、路径改锚。所以「lead 轨道」在底座上超额交付，但 no-tail 的终局被**推倒重设计**；「头号目标」（完整 demo E2E）**尚未跑通**，卡在 4 个 provisioning 缺口（#1417）。
- **今日 returns：** `capability-auth-followups.md`（gaga）、`demo-e2e-dispatch.md` + 证据（gaga）、`ruihua-daily.md`、`notes/cap-gate-overlap-gaga-codex.md`（allen）。

## §3 事故与转向（EOD 头条）

### ① canary 部署事故 → 救回

- cap-signing #1399 落地后，**部署环境缺 `EZAGENT_SIGNING_SEED_V1`** → world 插件 boot 抛 `:missing_seed` 崩溃 → **canary 冻结 1.3 天、7 连败**。这段时间的「dispatch success」只是**触发成功**、并非**部署成功**——是一次真实的可观测性陷阱（把 CI 触发误当部署健康）。
- **修复：** 三 channel 写入共用同一 signing seed → canary **重部署 success**，1.3 天中断解除、**main HEAD 全量上 canary**（含 #1409/#1411 等当日底座）。

### ② cap-signing 大转向：no-tail 实现搁置 → 严格签名 re-architecture

- no-tail 自愈**实现**（codex build）经**两轮对抗复审**挖出真 bug：**revoke 复活**（撤销的 cap 被自愈流程复活）、**caps_json 数据擦除**、**`verify_for` 当分类器回归**（dual-read 下接受未签名 cap，把审计退化成 false-zero no-op——正是 v1 spec 阶段抓到、如今在实现里复现的那处）、**snapshot 版本损坏** → 判定 **NEEDS-REVISION**，**#1424 搁置（draft）**。
- **Allen 重新锚定问题 X**（能力伪造 = 提权 / 凭证盗用，这是威胁模型的核心）→ 决定不在自愈补丁上继续，而是**转向严格签名 re-architecture**：spec 落在 `feat/cap-strict-capstore`，**v11、经 11 轮对抗评审 SOUND**——两个认证 chokepoint（`authorize/3` + `Cap.issue`）、**principal-agnostic**、**隔离 signer 域 + 钉根公钥环**、**wipe+reseed cutover**。这是把「自愈残尾」的战术补丁升级为「签名不可伪造」的结构性设计。

## §4 质量与风险

- **两轮对抗复审在实现落 main 前拦住了坏构建。** no-tail 实现的四类真 bug（revoke 复活 / caps_json 擦除 / verify_for 分类器回归 / snapshot 损坏）若合入会直接损害 cap 数据完整性与审计可信度。**审查循环再次为自己买单**——代价是承认设计需要推倒，收益是没有把一套会擦数据的自愈流程放进生产。
- **CapBAC 已在 live demo 上证明正在执行**（#1416：kanban write-config / create-card 被精确 capability-denied）。当天建的安全在生产语境真的咬合。
- **canary 事故暴露一个可观测性真缺口**：部署健康信号不能等同于 CI 触发信号。已通过共享 seed 修复，但「触发 ≠ 部署成功」这一课要固化进部署检查。

**⚠ 风险 / deferred：**
- **Enforce（正确地）仍 OFF** —— dual-read 保持；`require_signature:true` 的翻转是刻意的手动 lead 决策，须在严格签名实现就位 + 一次真 canary 数据 E2E 之后才做。
- **cap-signing 严格签名实现待排期** —— spec 已 SOUND（`feat/cap-strict-capstore` v11），但实现投入稍后再定；no-tail 自愈路径已废（#1424 draft 搁置）。
- **kanban 回流待真实栈验证** —— #1425 已补回流回归测试，但真实部署栈上的接收方活 kanban tab 回流仍待录到；Hello 回执快照 → 活面的产品缺口记在 #1426。
- **demo 未跑通是真实缺口，如实标注** —— 4 个 dev-loop provisioning 缺口（凭证继承、worktree/cwd、GitHub 认证、kanban cap）已有架构约束（#1417）。

## §5 方法沉淀（Act）

1. **强化——SPEC → 对抗审查 → 修订，先于（并高于）构建。** no-tail 的 spec 走了两轮审查判 SOUND，但**实现**仍在复审里翻车——说明「spec SOUND」不等于「实现 SOUND」，实现同样要过对抗复审这道门。今天正是这道门拦住了会擦数据的构建。
2. **强化——问题锚定优先于战术修补。** no-tail 自愈本质是在给一个会漏未签名 cap 的模型打补丁；Allen 重新锚定「能力伪造 = 提权」后，转向严格签名 re-architecture 才是对着真问题的结构性解，而非继续给残尾打补丁。
3. **新增——部署健康 ≠ CI 触发。** canary 1.3 天 7 连败期间「dispatch success」误导为部署正常。教训固化：部署检查要验**运行时 boot + 插件加载**，不能只看 workflow 触发。
4. **强化——裸 `mix test` ≠ 本 umbrella 的验收信号。** entity-caps 复验显示大量「失败」是 harness 产物（未加载 sibling app 的 `UndefinedFunctionError` + SQL-Sandbox ownership）；CI `gate` 才是权威信号，红色复跑先对 ci.local 对账再怪代码。
5. **确认有效——诚实的分段验证胜过伪造的绿。** gaga 的 #1416 在不走任何 raw-RPC / live-DB / 提权捷径的前提下推进 demo 并钉出真实缺口。这是标准。

## §6 明日 / next

- **cap-signing 严格签名：** `feat/cap-strict-capstore`（v11 SOUND）择时排实现——两 chokepoint + 隔离 signer 域 + 钉根公钥环 + wipe/reseed cutover；实现同样过对抗复审。enforce 翻转是其后的 lead 手动终局。
- **gaga：W29 demo dev-loop provisioning**（4 缺口，按 #1417 约束——GitHub-as-plugin、凭证继承拆分、worktree/cwd-before-sidecar、kanban cap via governance）+ AgentRuntime 上层（#1411 之后）。
- **W29 demo：** provisioning 落地后串通「agent 真开 PR → CI → 合并 → kanban 流转」；gaga 测 → allen 验收 → ruihua 完善。
- **zyli：** 前端 CI 续做（#1415 之上 Playwright/E2E smoke + 独立前端 workflow）。
- **zhaomaota：** #1425 收口——Hello 回执改活刷新 / 明确跳转（#1426）、跨-workspace 拒绝测试、真实栈回流验证。
- **部署：** beta/stable 用新 seed 人工晋级；确认 canary 已载昨日全量（已完成）。
