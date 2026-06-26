# 2026-06-26 kanban 这一轮：调查 + 开发计划 + 实施 总索引

> 一轮工作的统一入口。基线：`feat/kanban-agent-e2e`（off upstream/main，含 #1004/#1007 kanban-as-role + RF-1..9 + #1012 dev-together 2026-06-26）。
> 所有文档逐条 file:line 实证（skill-1 `project-discussion-esr-ng` 核实）。

## 1. 已实施（代码已提交）
- **B1 动作进路由 + B2 github 硬 CI 门** → 见 `docs/status/kanban-agent-e2e/b1-b2-impl.md`（决策留档）。
- **全闭环 e2e 27/27 + 真 UI 看板截图** → 见 `docs/e2e/2026-06-26-kanban-agent-dev-loop/`（round-1/2/3）。

## 2. 当前 UI/架构调查（`2026-06-26-current-ui-kanban-probe/`）
- `kanban-dev-flow.md` — kanban 插件开发流程手册（三层架构 / 数据流 / 25 动作 vs 24 白名单 / 四类改动动哪层 / gate 拦什么）。
- `session-operations.md` — 怎么在 session 中操作（invite agent → routing 规则 → 发消息触发；看板操作面；B1 桥）。
- `agent-config.md` — agent 配置（#992 flavor+config 统一后怎么建/配 agent、kanban-manager、cc-headless brain）。
- `missing-tools-and-tasks.md` — 全自动闭环还缺什么 + **按优先级的开发任务清单（P0/P1/P2）**。

## 3. 流程重设计（`2026-06-26-kanban-flow-redesign/`）
- `flow-redesign.md` — dev-together × kanban × ezagent 真正该有的流程 + 每阶段产物（两轴：产品轴=board / 时间轴=dev-together，用 board_node_id 缝合）。
- `missing-capabilities.md` — 缺失能力分析，**重点：register_pr 人工断点 + 该不该新建 github 入站 plugin（结论：该有）**。
- `kanban-skills-replan.md` — 2 个 kanban skill 跟 dev-together #1012 对齐的重规划。

## 4. 核心结论（一页速览）
- **kanban 现状**：看板 = 一个 agent（role `kanban-manager` × flavor `native`），board 在 agent `:kanban` snapshot；25 个动作经 `entity://<ws>/agent/<id>?action=kanban.<x>` dispatch。**没坏，是"半自动 + UI 入口缺"**。
- **"接入不对"真相**：kanban 插件 `config_surface/0` 没声明（`application.ex:106-114` 注释承认"K4 再加"但 #1007 漏了）→ world Plugins 页没有 kanban 可点入口，只能直接敲 URL。
- **四个人工断点**：sync_prs 无定时器 / register_pr 手填 / relay 公告没接路由 / goal→树无自动入口。
- **两块整缺**：会思考的 worker agent 没接看板 / config_surface 没声明。

## 5. 开发任务（按优先级，三层铁律：连接器在 plugin、world 纯 dispatcher、core 不碰、走 dispatch）
- **P0** worker agent↔看板接力（**近 core，先找 Allen**）+ bind_session 自动/UI 入口 + **config_surface 声明（最快见效）**。
- **P1** GitHub 入站 plugin（先轮询仿 MiroSync，后 webhook）。
- **P2** 需求自动拆解（goal→节点树）。
