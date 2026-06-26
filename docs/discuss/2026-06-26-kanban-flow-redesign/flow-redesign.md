# 真相源 — kanban 支持的团队开发流程（flow redesign）

> 日期 2026-06-26（重写为真相源，supersedes 本文旧版）｜ 配套 SPEC：`docs/discuss/2026-06-26-kanban-team-flow-spec.md`。
> 本文**详细说明 kanban 支持的开发流程**，是流程的单一真相源。所有论断带 file:line（skill-1 核实）。
> ⚠️ 现有零碎提交（2 skill + B1/B2 github 修改）保留待整理，**非本文设计依据**（见 SPEC 顶部声明）。

---

## 0. 定位

一块 kanban board = 一个 agent（role `kanban-manager`×flavor `native`，`application.ex:64/76`），9 阶段节点树存它 snapshot 的 `:kanban` slice。board 既是**产品真相源**又是**调度器**。dev-together 是开发节奏；两者用 **`board_node_id`** 缝成一条流水线，**全程在 chat 发生**，每个角色（人/agent）的每步顺手 dispatch `kanban.*` 回写 board。

---

## 1. 两轴 + 9 阶段链

- **产品轴（空间）= board**：9 阶段固定接力链 `positioning→metric→pain→anchor→ux→feature→issue→test→pr`（`kanban.ex:38`），节点级按完成晋级（一节点可跨多天，`set_stage` 收口相邻校验 `stage_fits?`）。
- **时间轴（节奏）= dev-together**：`docs/together/<date>/` 每日文件夹 + 8 命令（plan/handoff/dive/return/push/close/review/init）。
- **缝合键 `board_node_id`**：dev-together 每个 task/return/PR 必填它指向的节点；节奏每步 dispatch 一个 `kanban.*`。

---

## 2. 完整开发流程（每阶段：谁 · dev-together 命令 · kanban 动作 · 产物 · chat）

> ABCD 驱动场景：A 认领到「功能」交文档 → 派活 B/C(agent) → 开发提交 PR → 自动 CI → A 合 → 自动 done → D 评北极星。A/D 人、B/C agent，全在 chat。

| 阶段 | 谁 | dev-together 命令 | kanban 动作 | 自动挂载的产物 |
|---|---|---|---|---|
| 定位→功能 建链 | A | `plan`（读周目标+花名册+**board get_tree**） | `add_node`×N + `set_stage` | 各阶段文档（见 §3 artifact） + `plan.md` 挂板级 |
| 派活 | A | `handoff`（从 issue 节点 content 生成） | `claim_node`（owner=worker） | `handoffs/<task>.md` **自动挂 issue 节点**（§4） |
| 认领开发 | B/C(agent) | `dive`（读 handoff） | `claim_node`+`set_status doing` | 任务分支 |
| 提交 | B/C | `return` | `register_pr`（自动，见 github 入站） | `returns/<task>.md` **自动挂该节点** + PR artifact |
| CI 硬门 | 系统 | — | `push_pr`（verdict→commit status） | GitHub status check |
| 合并 | A | `push`/`close`（lead 合 main） | `sync_prs`→`set_status done`（自动） | `stack.md` 挂 PR 棒 |
| 评估 | D | `review` | `set_metric`/`drop_subtree` | `review.md` 挂 close/上线棒 |

---

## 3. Artifact 模型（Challenge 1 解法）

**现有 artifact 已足够用**：`%{tool, kind, ref, url, content}`（`shared.ex:122`，content inline ≤64KB）。挂载经 `attach_artifact`（小内容）/ `attach_upload`（上传文件）。

**核心原则：artifact 必须"读得到"——上线后、别人、别的机器上的 agent/CI 都能读。所以 raw 本地文件路径不是合法 artifact**（只在生成它的那台机器上有，部署/换人/换 agent 就死）。按**可读性保证从强到弱**排，只用前三种：

| # | 形态 | url/content | 谁能读 | 上线/redeploy 后 |
|---|---|---|---|---|
| 1 | **repo 路径**（存证后，能力 G） | `url`=仓库内路径 | 任何有 repo 权限的人/agent/CI | ✅ git 里，最强 |
| 2 | **inline content**（≤64KB） | `content` 直接进快照 | 任何能访问 board 的（真相源自带） | ✅ 在 DB 快照里 |
| 3 | **上传文件**（`attach_upload`） | `url`=ezagent uploads URI，签发下载 href（`kanban_actions.ex:261`） | 任何 ezagent 服务覆盖到的 | ⚠️ 绑部署的 uploads 存储，存储不备份会丢 |
| ~~4~~ | ~~raw 本地文件链接~~ | ~~`file://…`~~ | **只有那台机器** | ❌ **不用** |
| 5 | **外部链接**（飞书/figma） | `url`=外链 | 取决于外部权限 | ⚠️ 弱（死链/权限墙），**必须镜像进仓库**（仓库里留含链接的占位 md，做到"仓库能查到"） |

**保留的便利工具（不动）**：**Excalidraw** 内嵌编辑器（`ExcalidrawModal.tsx`）= UX/线框棒的画图工具，画完把 scene elements 序列化成 JSON 存进 `artifact.content`（inline，`kind="excalidraw"`，`Kanban.tsx:496`/`:390` 渲染回显）——正好走 inline content（2）这条"读得到"的路，**artifact 收敛不影响它**。同理任何"画完/填完 → 序列化成 ≤64KB JSON/文本进 content"的便利工具都自然兼容。

**"怎么保证读到" = 优先级 1→2→3**：
- 文本/spec/Gherkin/线框 JSON（小，含 Excalidraw 场景）→ **inline**（2）。
- 要版本化、要 CI/别的 agent 读、要上线后还在 → **commit 进仓库**（1，能力 G）= 最强保证。
- 二进制/大文件 → `attach_upload` 进 uploads 库（3），url 是 ezagent 管理的 uploads URI（**不是本地路径**），ezagent 服务在哪都能签 href 读；要长期存证再 commit 进仓库。
- 外链（5）只当便利，**真相必须镜像进仓库**。

**结论：废弃 `attach_code_file`（sha/path→github blob，`connectors.ex:152`）**——它是"把文件钉在某 commit sha 的 blob"窄特例，有了仓库存证（1）就用稳定 repo 路径，不需要 sha 钉死的 blob。**Phase 5 删该动作 + 移出白名单**（连带 register_pr 手填被 github 入站取代，SPEC 能力 D）。

> 即：artifact 形态 = inline content / repo 路径 / uploads URI 三条「读得到」的路；raw 本地链接和 sha/pr blob 下线，外链必须镜像进仓库。

---

## 4. dev-together 自动产物 → 阶段映射 + 自动挂载（Challenge 2 解法）

dev-together 命令**自动运行产生的文档**（`docs/together/<date>/`）按**两类**自动挂载，**不靠人手贴**：

### 4a. 节点级产物（产品轴）—— 挂到具体 9 阶段节点
某个节点的交付物，挂那个节点：

| 产物 | 来源(file:line) | 挂哪个节点 | 怎么自动挂 |
|---|---|---|---|
| `handoffs/<task>.md` | `handoff.md:33/36` | 该 task 的 **issue 节点**（handoff=节点 spec） | handoff 跑完按 `board_node_id` dispatch `attach_artifact`(kind=handoff) |
| `returns/<task>.md` | `return.md:25/72` | 该 task 的**节点**（return=交付物） | return 跑完 dispatch `attach_artifact`(kind=return) + `register_pr` |
| 节点交付物（spec/Gherkin/Excalidraw 线框/PR） | — | 对应阶段节点 | `attach_artifact`（inline/upload/repo，见 §3） |

### 4b. 板级时间线产物（时间轴）—— 挂到板级时间线通道，**不挂单个产品节点**
**日/周总结、plan、review、stack** 这类**跨多节点、总结一天/一周**的产物，挂在单个 9 阶段节点上不合理（它不是某节点的交付物）。它们挂在**板级"时间线"通道**（按 `<date>`/`<week>` 键）：

| 产物 | 来源(file:line) | 性质 | 挂哪 |
|---|---|---|---|
| **日/周总结 HTML**（你最初给我看的两个） | dev-together 日/周总结能力 | 跨节点的日/周复盘 | **板级时间线**，键=`<date>`/`<ISO-week>` |
| `plan.md` | `plan.md:29` | 当日计划（跨节点） | 板级时间线，键=`<date>` |
| `stack.md` | `push.md:34` | 当日合并顺序（跨节点） | 板级时间线，键=`<date>` |
| `review.md` | `review.md` | 当日复盘（跨节点） | 板级时间线，键=`<date>`；指标回写仍 `set_metric`/`drop_subtree` 到具体节点 |

> **板级时间线 = 一个新的板级字段**（与现有板级 `:drops` 同构——tree 是 `%{nodes, root_id, seq, drops}`，`shared.ex:22`，再加一个 `:timeline`/`:summaries`，按日期/周存 `{kind, url/content, date}`）。这是要补的小能力（进 SPEC §6，记为能力 **T**）。前端在看板页开一个"时间线/日周总结"侧栏渲染它，**不污染 9 阶段画布**。

**两类的真相源都同时落 `docs/together/<date>/`（随 PR 进仓库 = 仓库存证）**；看板这边：节点级挂节点、板级挂时间线通道。

**机制**：dev-together 命令（off 文件版 / on dispatch 版）每步**多做一个挂载 dispatch**（节点级→`attach_artifact`+`board_node_id`；板级→新的板级时间线 attach）。这要求：
- dev-together 台账（plan/return）加 `board_node_id` 字段（SPEC 缺口 B，`kanban-skills-replan.md` 落实）；
- on 版命令产出文档后自动 dispatch attach；off 版写文件后由人/脚本 attach。

> 即：**dev-together 自动跑 + 自动挂**——产物落 `docs/together/` 文件夹（随 PR 进仓库 = 仓库存证）**同时**挂到对应阶段节点（= 看板存证）。两份存证，一次产出。

---

## 5. 仓库存证（artifact 随 PR 进仓库）

每节点 artifact 除挂看板外，**同时落 `docs/together/<date>/<board-node>/` 并随该节点的 PR 进仓库**（SPEC 能力 G）：
- 上传的文件 → 存进仓库目录，artifact `url` 指仓库路径；
- 外链 → artifact `url` 存链接（仓库里留一个含链接的 md 占位，做到"仓库里能查到"）。
- 多仓库（SPEC §5，默认节点级 repo）：artifact 进它所属节点的 repo。

---

## 6. 与 SPEC 的关系 + 要建的能力

本文是**流程真相源**；要把它跑起来需 SPEC §6 的能力（按 Phase）：
- Phase 1：config_surface(A) + bind_session(B) — UI 接线。
- Phase 2：**抽出 `ezagent_plugin_github`**(GH，github 全部 in+out 从 kanban 抽出) + CI 自动闭环 — **自动 register_pr 取代手填**。kanban 只留 CI 判据计算、经 dispatch 调 GH 推 status。
- Phase 3：worker agent 接力(E) + 仓库存证(G) + dev-together 自动挂载(§4) + 板级时间线(T) — chat 全自动。
- Phase 5：统一整理——**删 `attach_code_file`**（§3）、reconcile B1 + 2 skill、收敛文档。

**github 边界（重要）**：所有 github 操作（建 issue/PR 评论/读 PR/推 status/入站轮询）归 **`ezagent_plugin_github`**，**不混在 kanban**。kanban 只持有 board 真相源 + CI 判据计算（`check_pr_gate` 读 board），经 `Invocation.dispatch` 调 GH plugin 做 github；GH plugin dispatch 回 kanban（register_pr/set_status）。github token 归 GH plugin。

**变更摘要（相对旧设计）**：① artifact 收敛成 attach_artifact 一条路、sha/pr blob 下线；② dev-together 自动产物按 §4 映射（节点级 + 板级时间线）；③ **github 全部抽成独立 plugin**、register_pr 手填被 github 入站自动化取代。
