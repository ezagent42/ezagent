# SPEC — 用 kanban 穿起团队开发全流程（AI 化）

> 日期 2026-06-26 ｜ 收敛自：flow-redesign + missing-tools + 用户 6 个设计点 + ABCD 驱动场景。
> 状态：**计划稿，待用户/Allen 拍板后开工**。基线 `feat/kanban-agent-e2e`（含 #1004/#1007 + RF-1..9 + #1012）。

> ⚠️ **关于现有零碎提交（保留待整理，非本 spec 设计依据）**：
> PR #1017 里的 **2 个 kanban skill**（off/on）+ **一串 github 类 B1/B2 修改**（bind_session/post_handle 接力、create_commit_status 硬门）是**整体设计之前的零碎提交，可能过时**。
> **本 spec 一律以整体性流程为准从头设计**，不把这些零碎提交当基础、不在计划里假设它们已就位。
> 它们**保留**（不删），但**开发完成后统一整理**：能复用的并入整体结构、过时的删除、命名/边界对齐到本 spec。下面 §6 能力表标注"现有代码可能部分覆盖"仅作 reconcile 提示，**不作为已交付**。

---

## 0. 目标 + 驱动场景

**目标**：一块 kanban board 作为产品真相源 + 调度器，把"定位→…→PR→上线回收"整条团队开发流程串起来，**全程在 chat 里发生**，派活/认领/提交/CI/合并/评估可给人、也可给 agent，理论上全自动。

**驱动场景（ABCD，无角色岗位，谁都能干全活）**：
1. **A** 在 chat 里认领 kanban 链条「定位→北极星→痛点→锚点→UX→**功能**」这一段，逐节点交文档（artifact）。
2. **A 派活**：把「功能」下的 issue/test 节点派给 **B、C**（人或 agent）。
3. **B、C** 各自开发 → 提交 PR → **自动 CI**（硬门）→ **A 合并**。
4. **D** 评估北极星指标，回写看板 + 反馈（指标不达标 → drop 回 pain 重选）。
5. 或 **A 一个人**走完全部，也成立。
6. **kanban 是存证线**：每一步的 artifact（上传的文件 or 链接）**同时像 dev-together 一样开文件夹、提交进 PR 仓库** → 仓库存证。
7. **A、D 是人；B、C 可能是 agent**，在 chat 里自动互动。

---

## 1. 两轴模型（来自 flow-redesign，是本 spec 的骨架）

| | 产品轴 = kanban board | 时间轴 = dev-together |
|---|---|---|
| 载体 | 一个 agent（role `kanban-manager`×flavor `native`），9 阶段节点树在它 snapshot | `docs/together/<date>/` 每日文件夹 |
| 真相源 | 产品状态（节点 stage/owner/status/artifacts/metrics） | 当天开发流水账（plan/returns/stack/review） |
| 节律 | 节点级、按完成晋级（一节点可跨多天） | 天级 PDCA |

**缝合键 = `board_node_id`**：dev-together 每个 plan 任务 / return / PR 都必填它指向的 board 节点；节奏每步顺手 dispatch 一个 `kanban.*` 回写产品轴。

---

## 2. 完整流程（每步：谁 · 在哪 · 读什么 · 产出/kanban 动作 · chat 怎么发生）

| # | 阶段/动作 | 谁 | chat 里怎么发生 | kanban 动作 | 产物（落看板 + 落仓库存证） |
|---|---|---|---|---|---|
| 1 | 拆解 定位→功能 | A（人） | A 在会话 @board-agent 或经编排 agent | `add_node`×N + `set_stage` 建 9 阶段链 | 每节点 artifact = 该阶段文档（html/md） |
| 2 | 认领 | A | A 发"认领 n6" | `claim_node` | owner=A；relay 公告入路由 |
| 3 | 派活给 B/C | A | A @B @C / 发"派 issue 给 worker" | `claim_node`(给 worker URI) | owner=worker agent |
| 4 | 开发 | B/C（agent） | worker agent 收到 inbound → 真 claude 决策 | `set_status doing` | 代码分支 + commit |
| 5 | 提交 PR | B/C | worker 开 PR（或 github 入站自动捕获） | `register_pr`（自动） | 节点挂 kind=pr artifact |
| 6 | CI 硬门 | 系统 | PR 事件触发 CI-gate agent | `push_pr`（verdict→commit status） | GitHub status check 红/绿 |
| 7 | 合并 | A | A 看绿了点合（人工闸） | — | merged |
| 8 | 自动 done | 系统 | sync_prs 轮询 merged | `set_status done`（自动） | 节点 done |
| 9 | 北极星评估 | D（人） | D 发评估结果 | `set_metric` / `drop_subtree` | 指标回写；不达标 drop 回 pain |

**贯穿：仓库存证**——第 1/2/9 步的文档 artifact，除挂看板节点外，同时落 `docs/together/<date>/<topic>/` 文件夹并随 PR 进仓库（上传文件存路径、外链存链接）。

---

## 3. 每阶段产物 + 仓库存证（用户点 1/4）

- **每节点 artifact** = 该阶段交付物：定位/北极星/痛点文档、UX 线框 html、功能卡 Gherkin、issue spec、test 用例、PR 链接。**inline content ≤64KB 直接进快照**（已支持），大文件/外链存引用。
- **plan/review 的 html 产物挂特定阶段**（用户点 4）：plan html 挂在「定位/功能」棒，review html 挂在「PR/上线」棒——用 `attach_artifact %{kind:"html", content/url}`。
- **仓库存证**（用户点 1）：新增一条**"artifact → PR 仓库"落盘**机制——节点 artifact 同步写进 `docs/together/<date>/` 并随该节点的 PR 提交。需要一个动作或 connector（见 §6 能力 G）。

---

## 4. chat 驱动 + agent 化（用户点 3/5/6）

- **全程 chat**：人/agent 在 session 里发消息 → routing 规则匹配 → dispatch 到对应 agent → agent dispatch `kanban.*`。kanban-manager 是 passive（不收 chat），由**编排/worker agent** 代它操作。
- **A/D 人、B/C agent**：B/C = cc-headless agent（真 claude brain），收 inbound 自动决策 + 操作看板 + 开 PR。
- **接力无环 DAG**：动作完成吐 `[kanban:<event>]` 公告 → routing 命中下一 agent（用 mention/阶段标记精确命中，防 A→B→A 环）。

---

## 5. 多仓库（用户点 2，开放问题）

- 现状：`set_board_config` 一块板配**一个** `github_repo`（`board_config.ex`）。
- 需求：一块 kanban 可能对应**多个仓库**（前端仓 + 后端仓 + …）。
- 方案候选：① 节点级 repo（每个 issue/PR 节点可指定 repo，board 配默认 repo）；② board 配 repo 列表 + 节点选其一。**待拍板**（影响 register_pr/push_pr/github 入站的 repo 解析）。

---

## 6. 要建的能力（按依赖排，三层铁律：plugin/world/不碰 core，走 dispatch）

> 下表是**整体流程需要的能力（从头设计的目标态）**。★ 标记的有**现有零碎代码可能部分覆盖**——开发时 reconcile（复用对的、删/改过时的、对齐本 spec），**不假设已交付**。CI 硬门（verdict→GitHub commit status）也属此类（现有 B2 代码待 reconcile）。

| ID | 能力 | 层 | 依赖/风险 | 现有零碎? |
|---|---|---|---|---|
| **A** | `config_surface/0` 声明 → Plugins 页有 kanban 入口 | kanban plugin + world | 低，纯插件 | 无 |
| **B** | `bind_session` 自动（建板时绑当前会话）/ 给 UI 入口 | kanban plugin + world | 低 | ★ B1 |
| **GH** | **`ezagent_plugin_github`（新独立 plugin，github 全部 in+out 从 kanban 抽出，不再混在 kanban）**：出站(`create_issue`/`post_comment`/`get_pull`/`create_commit_status`) + 入站(轮询 list PRs 按分支名自动 `register_pr` / `sync_prs` merged→done / PR 事件驱动；后 webhook)。github token 归它。kanban 经 dispatch 调它，它 dispatch 回 kanban(register_pr/set_status)。 | 新 plugin | 大，**重构：从 kanban 抽 github** | ★ github.ex/B2/sync_prs/register_pr/push_pr 现都在 kanban，**待抽出** |
| **CI** | CI 判据**计算**(`check_pr_gate` 读 board，产品语义)**留 kanban**；**推 commit status** 由 kanban dispatch 给 **GH plugin** 执行 | kanban(算) + GH(推) | 中 | ★ B2 推 status 部分待拆给 GH |
| **E** | **worker agent ↔ 看板接力**（cc-headless worker + 自动 routing 规则） | 配置/seed + 用 RuleStore/create_agent 现成 API | 中，**近 core 边界，先跟 Allen 确认设计** | ★ B1 接力骨架 |
| **F** | 需求自动拆解（goal→节点树，LLM agent） | 编排 agent | 大，P2 | 无 |
| **G** | **artifact → PR 仓库存证**（节点 artifact 落 docs/together 文件夹随 PR 进仓库） | kanban plugin connector | 中（用户点 1） | 无 |
| **H** | 多仓库支持（节点级/列表级 repo） | kanban plugin | 中，**待拍板 §5** | 无 |
| **T** | 板级时间线通道（日/周总结 + plan/review/stack 按 date/week 挂板级，新 `:timeline` 字段 + UI 侧栏） | kanban plugin + world | 中 | 无 |

---

## 7. 分阶段开发计划（每 phase：交付 + 测试 + gate）

**Phase 1 — UI/接线打通（让流程在界面上能走，低风险先做）**
- A `config_surface` + B `bind_session` 入口/自动。
- 交付：Plugins 页能点进 kanban；建板自动绑会话。
- 测试：world 渲染 e2e + 截图；bind_session 单测已有。

**Phase 2 — 抽出 `ezagent_plugin_github` + 自动 CI 闭环（拔人工断点）**
- **GH 抽出**：建 `ezagent_plugin_github`，把 kanban 现有 github 全部（`github.ex` + connectors 的 github 动作 + B2 推 status + `sync_prs`/`register_pr`/`push_pr`）**抽进新 plugin**；加**入站**（轮询 list PRs 按分支名自动 `register_pr`，仿 MiroSync）+ PR 事件驱动。
- kanban 只留 **CI 判据计算**（`check_pr_gate` 读 board），经 dispatch 调 GH 推 status；kanban↔GH 全程走 `Invocation.dispatch`（P14）。
- 交付：github 独立成 plugin、kanban 不含 github 代码；PR 出现自动登记 → CI 硬门自动推 → merged 自动 done，无人手填。
- 测试：真 test-ezagent repo e2e（开 PR→自动 register→自动 status→merge→自动 done）+ 截图。

**Phase 3 — agent 接力（chat 全自动）**
- E worker agent（cc-headless）+ routing 规则 + G 仓库存证。
- 交付：A 在 chat 派活 → worker agent 自动开发提交 → CI → A 合 → D 评估，ABCD 场景全跑通。
- 测试：全闭环 chat e2e（人/agent 混合）+ 每步截图。
- **gate：E 近 core，Phase 3 开工前跟 Allen 确认设计。**

**Phase 4 — 增强（按需）**
- F 需求自动拆解 + H 多仓库 + webhook 升级。

**Phase 5 — 统一整理（开发完收口，用户要求）**
- **B2 github 部分在 Phase 2 已抽进 `ezagent_plugin_github`**（不在 Phase 5 原地 reconcile）。
- Phase 5 处理剩余：**B1 接力**复用对的/删过时的、对齐本 spec；**2 个 kanban skill** 按 `kanban-skills-replan.md` 对齐 dev-together + 本 spec；**删 `attach_code_file`**（sha/pr blob 下线，§flow-redesign §3）。
- 删整体流程不再需要的零碎动作/字段；统一文档（本轮 discuss 收敛成最终 design+plan+readme）。
- gate：全量 mix test 绿 + CI 绿 + 无遗留死代码。

---

## 8. 待你/Allen 拍板

1. **多仓库**（§5）：一板一仓 vs 节点级 repo vs board repo 列表？
2. **worker agent 接线（能力 E）**：用现成 RuleStore/create_agent API 做（我判断不算改 core），还是要 Allen 先过设计？
3. **仓库存证（能力 G）**：artifact 落 `docs/together/<date>/` 的具体约定（文件命名/目录）？
4. **Phase 顺序**：先 Phase 2（自动 CI，最痛）还是先 Phase 1（UI 接线，最快见效）？
5. **真 brain**：B/C 用 cc-headless 真 claude（要凭证 + 成本），还是先 dispatch-as-agent 模拟跑通机械链？
