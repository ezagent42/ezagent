# dev-together 复盘 · 2026-07-09

**reviewed_at**: 2026-07-10 晨（GMT+9）· lead: allenwoods（coordinator: Claude 执行）
**本日头号目标**：跑通自举开发流程（Track C 修通）。**达成度：根因修复已落 main（#1294 → `2d47475b2`，CI 全绿），唯余 canary 实测** —— gaga 完整诊断 create_session 两链根因并产出修复，本晨 rebase+绿+合入；orchestrator 真回话的 canary 实测转结 07-10 头号。

## §1 本日进入 main / 晋级

| # | 内容 | 说明 |
|---|---|---|
| #1266 (`364ccf6ba`) | skill 分发 P1-P3（SkillRegistry + seed 车道 + 物化 fold） | 二次验收修复后合入；**stable 已晋级至此**（含 #1243/#1252/#1257/#1259/#1261/#1263） |
| #1295 | seed-loader 去重（ShippedManifest 共享 loader） | hello/kanban Demo 收敛；duplicate-fn cap 46→42（考据：46 是虚高记账） |
| #1276 (`2df027f58`) | world 模板 UX + cc dev-channel 探针 + PTY 会话面 | 今晨 coordinator 补 4 道行锚 gate 后 squash 合入（见 §3 method-delta 1） |
| #1277 | hello v2 seed page + rebuild guide + domain fixes（web_anon_access / manifest nil requires） | zhaomato；官网 hello 重建工具/指南 |
| #1294 (`2d47475b2`) | create_session 根因（rev6 契约恢复 + cc PTY 早产修复 + A2 静态 gate） | gaga；本晨 rebase+绿+合入，**canary 实测 orchestrator 回话 = 唯余项** |
| #1293 | #1255 三命名裁定（arch.scan allowlist 转正 + 理由 + return 文档） | jjkysy；纯注释无逻辑，07-10 02:08 合入 |
| #1292 | 项目讨论 skill `project-discussion-esr-ng` 全量 re-bootstrap | jjkysy；skill markdown |

## §2 开发效能（profile 更新据此）

- **gagameow（黄佳佳）** — 本周最强信号。create_session 卡死困扰一周（#1202→#1259→#1223 一路只按到一个 sync point），gaga **reproduce-first**、逐链取证，识破 #1223 把守护断言在一个名叫 `..._decouple_test.exs` 的文件里**反转**（`== [owner]` → orchestrator 必须已是成员），所以 CI 从未变红。诊断出"5秒超时"与"@orchestrator 不回话"是**两条被焊接的独立链**。→ 强化标签 **根因诊断 / 架构级排查**。其自证的"架构对了补丁就消失"（agent 事务移出创建路径后，handoff 那条 grant `:call`→`:cast` 补丁**不再需要**）是本周最好的架构论据——直接印证 Allen 的边界收敛方向。
- **create_session 的正确路由（团队判断）** — 值得单独记：#1276 的复盘 return 明确写着 caller-caps + longer-deadline 那条 handoff **被主动从分支移除**，因为 ownership 归 gaga #1247。团队**没有**用"加长 deadline + loading 态"去盖症状，而是把结构性修复路由给根因持有者——这个判断本身是对的，也是 Allen 边界框架的正面验证。
- **#1276（zyli）** — world 模板 UX 体量大、端到端。**返工点**：作为一个大 PR 合入时连环触发 4 道**行锚静态 gate**（arch dedup / doc-coverage / uri_query 实为 home_path 行锚 / locality allowlist），被红 arch gate 逐层掩盖。根因非代码错误，而是**本地 DoD 只跑了单个 gate**（见 §3）。→ 派发注记：大 PR + 动行锚文件时，本地跑全套 gate 是硬要求。（收尾的 gate 修复 + 合并由 coordinator 支持完成。）
- **jjkysy（#1295 + #1293 + #1292，三件全落）** — 本日产出最扎实的一位：① **#1295 seed-loader 去重**顺带**考据出 arch baseline 记账漂移**（duplicate-fn cap 46 从 #1248 起一路虚高，实测一直是 42，count≤cap 的绿掩盖了虚高）；② **#1293 #1255 三命名裁定**——AgentPassiveAttributes / RuntimeIdentity / EntityPresenter 逐条给出转正理由（passive↔flavor 对称、Runtime.* 是 OS-子进程流水线无关簇、X-of-Y 角色后缀惯例），**附 return 文档**，把"sanctioned-pending-review"清成"已评审转正"；③ **#1292 项目讨论 skill 全量 re-bootstrap**。→ 强化标签 **原则/记账把关 + 命名/边界裁定**。教训写回：bump/ratchet baseline 必须以**带数字的实测输出**为准，不能只看测试绿。

## §3 method-deltas（学习回路 → jjkysy dev-together PR）

1. **静态 gate 拓扑 —— return 前跑完整 `ci.local`，不跑子集。** #1276 四道 gate 连环暴露的根因：这些 gate 分散在**不同 CI job**——`gate (deterministic)` 只跑 arch.scan + doc.scan；`full-suite` 跑 `ci.local`，`uri_query.scan`（含 `home_path_in_runtime_code` 行锚）+ 全部 ExUnit 不变量**只在这里**；`check_invariants` **不含** uri_query.scan。且 HomePathExceptions / locality allowlist / arch anchors 是**按行锚定**的——上方插/删行就漂移，把合法永久豁免变成"违规"。**写入 return DoD**：改动含行锚豁免文件或新增/提升公共 def 时，本地必跑 `arch.scan + doc.scan + uri_query.scan + check_invariants`（或整套 `ci.local`）；行锚漂移**重锚**、不新增 allowlist。
2. **机器返还闸（CI 绿）≠ 产品验证。** #1294（create_session）+ 历史教训（coordinator 曾在 #1259 后过早宣布"create_session 修好"，实测仍超时）：凡动 orchestrator / session-create / PTY 就绪的改动，test 环境跳过 `require_transport_join`、短路 `:exec.run`，**只有 canary 能证 bridge 真 join、orchestrator 真回话**。**写入 handoff 标准**：这类 PR 合并后加一个显式的 **canary 实测步骤**，实测过再宣布。
3. **（基建）** mac runner 从 GitHub releases 下 `tailwindcss` 二进制反复吃 504（#1276 收尾撞到），asset build 挂但测试全绿 = infra flake。→ follow-up：runner 预缓存二进制。

## §4 台账对账（4 份 return + 无归档 track）

> 归属 = **开 PR 的开发者**（非 return/commit 的执行 agent）。

| PR / track | 归属（PR 创建者） | 状态 | 去向 |
|---|---|---|---|
| #1276 world 模板 UX（含 create-failfast + PTY 面 stacked） | **zyli** | **merged** `2df027f58` | 补 4 gate 后合入；world 模板 UX + cc 探针 + PTY 面。其中 `deadline_ms` 加长 stopgap **未进 main**（已核实：workspace.ex 仅通用 pass-through helper，无 60000 硬值）——正确地让位给 #1294 结构修 |
| #1295 seed-loader 去重 | **jjkysy** | **merged** | ShippedManifest 共享 loader；duplicate-fn cap 46→42 |
| #1294 create_session 根因（Track C） | **gaga** | **本晨落地 `2d47475b2`（CI 全绿）→ carry canary 实测到 07-10** | rebase + 4 gate 修 + A2 破坏性验证 + 一处 full-suite 真回归修复后合入；**唯余 canary 实测 orchestrator 真回话**（已核实 canary 部署带此 commit） |
| 官网 hello 重建 | zhaomaota97 | **merged #1277**（走直接 PR，非 returns/ 台账） | v2 seed page + rebuild guide + domain fixes（web_anon_access / manifest nil requires）。**注**：重建工具/指南已交付；**部署渠道上的 live E2E（greeter+curl-llm 真回复）能力上依赖 #1294 落 canary**——07-10 复走确认 |
| 官网飞轮 handoff | ruihuachen-designer | **merged #1204**（走直接 PR） | 价值链梳理 + 可点击 demo + handoffs + scenarios（07-09/handoffs/ 即其产出） |
| canary 走查 | zyli-developer | **无 return 归档 → 确认/结转** | 07-10 结转（zyli 主体在 #1276；走查 return 未归档） |
| #1293 #1255 三命名裁定 | **jjkysy** | **merged**（07-10 02:08 coordinator admin-merge） | arch.scan.ex 三条 allowlist 从"sanctioned-pending-review"清成"已评审转正"+ 逐条理由 + **return 文档 `1255-naming-adjudication.md`**；纯注释无逻辑改动 |
| #1292 项目讨论 skill re-bootstrap | **jjkysy** | **merged**（07-10 02:08） | `project-discussion-esr-ng` skill 全量重建到 main（2 文件 skill markdown） |

> **台账 vs 实际合并的缺口**：zhaomato #1277 / ruihua #1204 走**直接 PR review→merge**，没进 returns/ 台账；jjkysy #1293 有 return 文档但在**未合并的 PR 分支上**（当时未落 main，故初版 review 漏记）——都已据 GitHub 更正。教训：review 对账必须**同时**扫 returns/ **与当日/隔夜 GitHub 合并 + open PR 的 returns/**，三源并核。仅剩 **zyli canary 走查**无归档无对应 PR → 真结转，07-10 确认。

## §5 次日建议

见 `docs/together/2026-07-10/plan.md`。头号 = **#1294 落地 + canary 实测**（困扰一周的 create_session 链）；lead 新增结构线 = **AgentRuntime 控制面 in-repo 边界**（把 #1294 的 A2 gate 泛化为可量化的边界度量）；jjkysy 把本篇两条 method-delta 写进 skill。

---

团队向 HTML 版见 `review.html`。
