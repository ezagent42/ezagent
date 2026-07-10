# dev-together 计划 · 2026-07-10

**planned_at**: 2026-07-10 晨（GMT+9）· lead: allenwoods（coordinator: Claude 执行）
**本周目标（W28）**：在 stable 上验证 socialware 全生命周期 + 打通官网全流程；本周新增结构线 —— **收敛 agent 控制面边界**（session 面不再伸手进 agent 生命周期）。
**本日头号目标**：**落地并在 canary 实测 create_session 根因修复（#1294）** —— 让"新建 session 5 秒超时"和"@orchestrator 不回话"这条困扰一周的链，在真实部署上验证为真绿；并由 lead 把急症修复上升为**结构性边界**（AgentRuntime 控制面 in-repo 硬边界）。

## §0 昨日（07-09）收尾状态（详见 review.md）

- **已进 main / 已晋级**：P1-P3 skill 分发（#1266，`364ccf6ba`，stable 已晋级）· #1295 seed-loader 去重 · #1276 world 模板 UX + cc dev-channel 探针 + PTY 会话面（今晨由 coordinator 补 4 道行锚 gate 后合入，squash `2df027f58`）。
- **昨日头号未落**：Track C（create_session 根因）。gaga 昨夜产出 #1294，诊断为**两条被 #1223 焊接的独立链**（链A 创建事务 eager-spawn orchestrator + 链B cc PTY 在 config_dir 物化前早产）。**#1294 仍在评审 + 未 canary 实测** → 转为本日头号（见 gaga track）。
- **07-09 走直接 PR 合入（未进 returns/ 台账，据 GitHub 更正）**：zhaomato **#1277**（hello v2 seed page + rebuild guide + domain fixes）· ruihua **#1204**（官网飞轮 handoff + scenarios）。
- **仍无归档、需确认/结转**：zyli canary 走查 · jjkysy #1255 三命名裁定（无 return 亦无对应 PR → 本日确认状态，不默认已完成）。

## §1 头号 — create_session 根因落地 + canary 实测（#1294）

昨日审计断的那一面。#1294 把 agent 事务整个移出创建路径，恢复 #912 契约（"Session creation never waits for a transport bridge"）。**验证的红线**：test 环境跳过 `require_transport_join`、短路 `:exec.run`，所以"bridge 真 join、orchestrator 翻 :ready 并回话"**只有 canary 能证**。DoD 因此分两段：① CI 绿 + 合并（coordinator 派的 subagent 在做）；② **canary 上实测 orchestrator 真回话**（gaga + coordinator），②达成前不发"修好"通报。

## §2 按开发者规划

> 每行 = 一个自含闭环 track。coordinator（Claude）为 off-plan support，不占 track 行。

| 开发者 | feishu | 本日 track | 闭环/依赖说明 |
|---|---|---|---|
| **allenwoods** | 林懿伦 | **结构线：AgentRuntime 控制面 in-repo 边界（SPEC + 可量化 gate）** —— 把 #1294 的急症修复上升为命名边界：`AgentRuntime` = 对 recipe×flavor **物化成果** 的封装（谁托管/运行 agent = 控制面：物化 + 生命周期），与 `Session`（谁在跟它对话 = role/session 面）分开。产出：① 边界 SPEC（控制面/会话面接缝、in-repo vs out-of-repo 的分界与代价）；② `agent_runtime_boundary` arch gate —— 把 #1294 的 A2 gate（禁创建事务里 spawn/grant/materialize）**泛化**为对"session 面伸手进 agent 生命周期"的数值化度量（模块图可达性计数），让边界模糊可测、可 ratchet | 独立结构线；建立在 #1294 落地之上（A2 gate 已是第一颗种子）。coordinator 备 codex 对抗评审 |
| **gagameow** | 黄佳佳 | **头号：#1294 落地 + canary 实测** —— ① 配合 coordinator 的 subagent 把 #1294 rebase/绿/合入（评审见 off-plan）；② **canary 实测**：新建 session 不超时 + @orchestrator 真回话（agent-browser 截图 + PTY join 日志）；③ 三个 deferral 定夺/开单：mark_failed 不 drain PendingDelivery（静默丢消息洞）· #1277 hello `HELLO_NO_ORCHESTRATOR` 与 manifest `requires` 打架（**dev 绿/canary 红**的真实分叉，且 default 模板 `installs:[chat,orchestrator]` 未被覆盖）· LV 缺"正在装载 orchestrator…"中间态 | 头号；②依赖 #1294 合入 canary 自动部署 |
| **zhaomaota97** | 张宁 | **官网 hello session live E2E 确认**（重建工具/指南已随 **#1277** 合入 07-09）：在部署渠道上归档旧 golive session（#1243 前旧 Definition 的 stale 实例）→ 从新 Definition `ensure_app`/instantiate → **E2E 验证 greeter + curl-llm 真回复** | 直接 PR 已合（#1277）；**live E2E 能力上依赖 #1294 落 canary**（orchestrator 真回话是 hello front-desk relay 的前提）；可先在 nightly 起步 |
| **zyli-developer** | 李震宇 | **canary 用户视角走查**（07-09 结转，未归档 return → 先确认状态）：以真实用户走查 canary（含刚合入的 #1276 world 模板 UX + PTY 面）；**#1294 落 canary 后重点复走** create_session + @orchestrator 回话；发现即记录/开 issue；C2 = #1245 卸载 UI 浏览器路径绿态截图 | 在带全部修复的 canary 上走查 |
| **jjkysy** | 姚升悦 | ① **#1255 三命名裁定**（07-09 结转）：AgentPassiveAttributes / RuntimeIdentity / EntityPresenter，裁定写回 allowlist/issue；② **dev-together 方法增量 PR**（skill owner）：把本周两条 method-delta 写进 handoff 标准 / return DoD —— (a) **静态 gate 拓扑**：return 前必跑完整 `ci.local`（arch+doc+**uri_query**+check_invariants），改动含行锚豁免文件（HomePathExceptions / locality allowlist / arch anchors）尤甚（#1276 四道 gate 连环教训）；(b) **机器闸 ≠ 产品验证**：动 orchestrator/session-create/PTY 就绪的 PR，合并后**必须 canary 实测再宣布**（#1294 + 历史教训） | 独立；②是学习回路的写回，jjkysy 是 skill 单一写者 |
| **ruihuachen-designer** | 陈瑞华 | **刷新后 canary/stable 探索式测试**：发消息延迟、session 创建、会话列表、官网 hello；发现走 Feishu | 依赖 canary 刷新 |

**Off-plan（support · coordinator/Claude）**：① 驱动 #1294 subagent → 对抗评审（含 A2 gate 破坏性验证）+ rebase + 完整 gate 集 + 合入 → 与 gaga 一起 **canary 实测 orchestrator 回话**；② **两条基建 follow-up**：(a) mac runner 预缓存 tailwindcss 二进制（消 GitHub-releases 504 反复 flake，#1276 收尾撞到）· (b) 把静态 gate 拓扑写进 `docs/together/contributing/`；③ 备 Allen 的 AgentRuntime SPEC codex 对抗评审。

## §3 依赖与顺序 / 并行

- **头号串行段**：#1294 subagent 绿 → 合入 main → canary 自动部署 → gaga+coordinator canary 实测。zhaomato / zyli 的 canary 复走在 #1294 落 canary 后最有价值，但都可先在 nightly / 现有 canary 起步，不必空等。
- **全程并行**：Allen AgentRuntime SPEC（独立结构线）· jjkysy ①② · ruihua 探索 · coordinator 基建 follow-up。
- **依赖注记**：官网 hello（zhaomato）与 create_session 回话（#1294）是能力依赖而非分支依赖——orchestrator 真回话是 hello front-desk relay 的前提。

## §4 out-of-scope / backlog（登记）

- socialware 全生命周期验证（C1，07-08→07-09 结转）：#1294 落地 + 官网 hello 通后有余力再系统跑一遍；本日不设硬目标。
- `admin?/1` 业务态清理：#1299 gate（SOUND-WITH-NOTES）待 Allen 合入定夺 + 两条 follow-up（uploads roster-member 下载、gate alias/import 加固）——登记，非本日硬目标。
- CapBAC vs RBAC（#1296）/ agent-layer 边界（#1297）设计 PR：待 Allen 读后定是否形成重构线；AgentRuntime 边界 track 是其中"agent-layer"一支的落地。
- git-filter-repo 历史重写：仍需 dev 窗口冻结（延续登记）。

## §5 协作约束

- CI 闸：进 main 的 PR 需 `precommit + check_invariants` 绿 + rebase；**return 前跑完整 `ci.local`**（含 `uri_query.scan`——它只在 full-suite，不在 check_invariants；#1276 教训）；改动含**行锚豁免**文件必重锚不新增 allowlist；判"绿"以每个 check 最终结论为准，不以数量为准。
- **动 orchestrator/session-create/PTY 就绪的改动**：合并后 canary 实测再宣布（#1294 红线）。
- 评审基准 = `origin/main`；验证面向真实生产流程；UI 验证 agent-browser 截图第一、日志第二。
- full-suite 若仅因 tailwindcss GitHub-releases 504 挂 asset build（`Couldn't fetch …tailwindcss-macos-arm64`）= 已知 infra flake，重跑失败 job，非代码问题。

---

本计划面向全体开发者。团队向 HTML 版见 `plan.html`。
