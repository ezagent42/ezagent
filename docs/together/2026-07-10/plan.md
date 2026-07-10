# dev-together 计划 · 2026-07-10

**planned_at**: 2026-07-10 晨（GMT+9）· lead: allenwoods（coordinator: Claude 执行）
**本周目标（W28）**：在 stable 上验证 socialware 全生命周期 + 打通官网全流程；本周新增结构线 —— **收敛 agent 控制面边界**（session 面不再伸手进 agent 生命周期）。
**本日头号目标**：**在 canary 实测 create_session 根因修复（#1294，已合入 main `2d47475b2`）** —— 让"新建 session 5 秒超时"和"@orchestrator 不回话"这条困扰一周的链，在真实部署上验证为真绿（CI 绿 ≠ 产品验证，只有 canary 能证 orchestrator 真回话）；同时把急症修复上升为**结构性边界**（AgentRuntime 控制面 in-repo 硬边界）+ **cc-headless 改造**——两条结构线 allen 今日**移交 gaga**。

## §0 昨日（07-09）收尾状态（详见 review.md）

- **已进 main / 已晋级**：P1-P3 skill 分发（#1266，`364ccf6ba`，stable 已晋级）· #1295 seed-loader 去重 · #1276 world 模板 UX + cc dev-channel 探针 + PTY 会话面（今晨由 coordinator 补 4 道行锚 gate 后合入，squash `2df027f58`）。
- **Track C（create_session 根因）= 昨日头号，本晨落地**：gaga 的 #1294 诊断为**两条被 #1223 焊接的独立链**（链A 创建事务 eager-spawn orchestrator + 链B cc PTY 在 config_dir 物化前早产），**已 rebase + CI 全绿 + 合入 main（`2d47475b2`）**，canary 部署已核实带此 commit。**唯余 canary 实测 orchestrator 真回话** → 本日头号（见 gaga track）。
- **07-09 走直接 PR 合入（未进 returns/ 台账，据 GitHub 更正）**：zhaomato **#1277**（hello v2 seed page + rebuild guide + domain fixes）· ruihua **#1204**（官网飞轮 handoff + scenarios）。
- **jjkysy 07-09 三件全落**（本晨 02:08 coordinator 合入）：#1295 seed-loader 去重 · **#1293 #1255 三命名裁定**（含 return 文档）· **#1292 项目讨论 skill re-bootstrap**。
- **仍无归档、需确认/结转**：仅 zyli canary 走查（无 return 亦无对应 PR → 本日确认状态，不默认已完成）。

## §1 头号 — create_session 根因落地 + canary 实测（#1294）

昨日审计断的那一面。#1294 把 agent 事务整个移出创建路径，恢复 #912 契约（"Session creation never waits for a transport bridge"）。**验证的红线**：test 环境跳过 `require_transport_join`、短路 `:exec.run`，所以"bridge 真 join、orchestrator 翻 :ready 并回话"**只有 canary 能证**。DoD 分两段：① **CI 绿 + 合并 = 已完成**（`2d47475b2`，含 A2 gate 破坏性验证 + 一处 full-suite 真回归修复）；② **canary 上实测 orchestrator 真回话 = 唯余项**（gaga live 验证 + coordinator 独立部署实测，两个 buff、缺一不可），②达成前不发"修好"通报。coordinator 走 `https://canary.ezagent.chat/login`（非 100.64 IP）+ mail-server magic-link 独立跑一遍。

## §2 按开发者规划

> 每行 = 一个自含闭环 track。coordinator（Claude）为 off-plan support，不占 track 行。

| 开发者 | feishu | 本日 track | 闭环/依赖说明 |
|---|---|---|---|
| **allenwoods** | 林懿伦 | **lead**：plan / handoff / close / review + 决策定夺（#1299 admin gate 合入、CapBAC/agent-layer 设计线走向、部署实测把关）。今日两条结构线均已移交 gaga（见下） | lead 位；结构性决策仍在 allen |
| **gagameow** | 黄佳佳 | **头号 + 两条结构线（allen 今日移交）**：① **#1294 落地 + canary 实测** —— 配合 coordinator subagent rebase/绿/合入（已完成，见 §0）；**canary 实测**新建 session 不超时 + @orchestrator 真回话（agent-browser 截图 + PTY join 日志）；三个 deferral 定夺/开单（mark_failed 不 drain PendingDelivery 静默丢消息 · #1277 `HELLO_NO_ORCHESTRATOR` vs manifest `requires` 的 dev 绿/canary 红分叉 · LV 缺"装载 orchestrator…"中间态）。② **AgentRuntime 控制面 in-repo 边界（SPEC + 可量化 gate）** —— `AgentRuntime` = 对 recipe×flavor **物化成果**的封装（谁托管/运行 agent = 控制面），与 `Session`（会话面）分开；产出边界 SPEC + `agent_runtime_boundary` arch gate（把 #1294 的 A2 gate 泛化为"session 面伸手进 agent 生命周期"的数值化度量）。③ **cc-headless 改造** —— 鉴于 cc-pty 仍有普遍问题，把代码中所有 agent 调用 flavor 暂改为 **cc headless** 绕过；先枚举所有设 flavor 的点（default 模板 installs、各 flavor 默认）再动，blast radius 大、分步走 | 头号；①的 canary 依赖 #1294 已合入（本晨已合），②③是 allen 今日移交的结构线，coordinator 备 codex 对抗评审 |
| **zhaomaota97** | 张宁 | ① **官网 hello session live E2E 确认**（重建工具/指南已随 **#1277** 合入 07-09）：在部署渠道上归档旧 golive session（#1243 前旧 Definition 的 stale 实例）→ 从新 Definition `ensure_app`/instantiate → **E2E 验证 greeter + curl-llm 真回复**。② **hello 访问控制选项（allen 新增）**：当前 hello 只有 public 一种（免登可查看、发消息时才提醒登陆）；增加一个**"未登陆不可查看"选项**——打开对应网页即提示"登陆后才能查看内容"。即 socialware/session 的可见性设置 public vs login-required，产品侧 + 实现 | ①直接 PR 已合（#1277），live E2E 依赖 #1294 落 canary；②独立产品项，先出方案（可见性设置落在 socialware 声明/Definition 层）再实现 |
| **zyli-developer** | 李震宇 | **canary 用户视角走查**（07-09 结转，未归档 return → 先确认状态）：以真实用户走查 canary（含刚合入的 #1276 world 模板 UX + PTY 面）；**#1294 落 canary 后重点复走** create_session + @orchestrator 回话；发现即记录/开 issue；C2 = #1245 卸载 UI 浏览器路径绿态截图 | 在带全部修复的 canary 上走查 |
| **jjkysy** | 姚升悦 | 07-09 三件（#1295/#1293/#1292）已全落。**今日主线：kanban 改版 #1298 + dealscout 改版 #1301**（其 open PR，推进到可合）。① **#1255 裁定 ✅ 已合（#1293）**；② dev-together 两条 method-delta（静态 gate 拓扑 + 机器闸≠产品验证）**已由 coordinator 写进 skill 并随 #1302 合入**——jjkysy 作为 skill owner 事后过目、如需润色再提 | 主线转向其 open PR；method-delta 写回已代办完成，仅需 owner 复核 |
| **ruihuachen-designer** | 陈瑞华 | **刷新后 canary/stable 探索式测试**：发消息延迟、session 创建、会话列表、官网 hello；发现走 Feishu | 依赖 canary 刷新 |

**Off-plan（support · coordinator/Claude）**：① **#1294 独立部署实测**（已核实 canary 带 `2d47475b2`）——走域名 `canary.ezagent.chat/login` + mail-server magic-link 独立跑 create_session + @orchestrator 回话，与 gaga 的 live 验证是两个 buff；② **PR-title lint CI**（allen #6）——PR 类型 `docs(...)` 却改了非 docs 路径（apps/*/lib、test/…）就 fail，挡 #1294 那种误导标题；③ **两条基建 follow-up**：(a) mac runner 预缓存 tailwindcss 二进制（消 GitHub-releases 504 反复 flake，#1276 撞到）· (b) 静态 gate 拓扑 + deploy E2E access（域名非 IP）写进 `docs/together/contributing/` 与 CLAUDE.md；④ 备 gaga 的 AgentRuntime SPEC codex 对抗评审。

## §3 依赖与顺序 / 并行

- **头号串行段**：#1294 subagent 绿 → 合入 main → canary 自动部署 → gaga+coordinator canary 实测。zhaomato / zyli 的 canary 复走在 #1294 落 canary 后最有价值，但都可先在 nightly / 现有 canary 起步，不必空等。
- **全程并行**：gaga 的 AgentRuntime SPEC + cc-headless 改造（allen 移交的结构线）· jjkysy #1298/#1301 · ruihua 探索 · coordinator 基建 follow-up。
- **依赖注记**：官网 hello（zhaomato）与 create_session 回话（#1294）是能力依赖而非分支依赖——orchestrator 真回话是 hello front-desk relay 的前提。

## §4 out-of-scope / backlog（登记）

- socialware 全生命周期验证（C1，07-08→07-09 结转）：#1294 落地 + 官网 hello 通后有余力再系统跑一遍；本日不设硬目标。
- `admin?/1` 业务态清理：#1299 gate（SOUND-WITH-NOTES）待 Allen 合入定夺 + 两条 follow-up（uploads roster-member 下载、gate alias/import 加固）——登记，非本日硬目标。
- CapBAC vs RBAC（#1296）/ agent-layer 边界（#1297）设计 PR：待 Allen 读后定是否形成重构线；AgentRuntime 边界 track 是其中"agent-layer"一支的落地。
- git-filter-repo 历史重写：仍需 dev 窗口冻结（延续登记）。

## §5 协作约束

- **⚠️ 硬规则：发 return 前必须看到该 PR 的 GitHub CI 全绿**（每个 check 的最终结论，不看数量）。当前开 PR 绝大多数是绿的（不是"总红被忽略"），所以这条可立、必守——CI 没绿别发 return。已写强进 dev-together skill。
- CI 闸：进 main 的 PR 需 `precommit + check_invariants` 绿 + rebase；**return 前跑完整 `ci.local`**（含 `uri_query.scan`——它只在 full-suite，不在 check_invariants；#1276 教训）；改动含**行锚豁免**文件必重锚不新增 allowlist。
- **PR 标题诚实**：类型（`docs/feat/fix/...`）要匹配真实改动——`docs(...)` 只应改 docs 路径（#1294 曾标 `docs` 却是代码修复，误导 lead）。coordinator 上 PR-title lint CI 兜底。
- **动 orchestrator/session-create/PTY 就绪的改动**：合并后 canary 实测再宣布（#1294 红线）。
- 评审基准 = `origin/main`；验证面向真实生产流程；UI 验证 agent-browser 截图第一、日志第二。
- full-suite 若仅因 tailwindcss GitHub-releases 504 挂 asset build（`Couldn't fetch …tailwindcss-macos-arm64`）= 已知 infra flake，重跑失败 job，非代码问题。

---

本计划面向全体开发者。团队向 HTML 版见 `plan.html`。
