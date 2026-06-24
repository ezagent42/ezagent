# Handoff：kanban 全 AI 化（agent 在 chat 里自动改看板 + dev-together 融合）

> **Date:** 2026-06-25 · **From:** Claude(with Sy) · **To:** 一个独立开发者（human + cc/codex）
> **Tracking:** kanban 3 设计问题的可落地版 · **Base:** `upstream/main` @ `a56ca149`(kanban PR #964 之上)
> **Status:** confirmed（机制核对过，缺口明确）— 替换旧的 `2026-06-24-mindmap-agent-pathB-handoff.md`（基于 mindmap 旧命名，已删）。

## 0. Mission
让一个**配好的 agent 在 chat 里自动编辑看板**（建链、改 stage、认领、挂产物、出站登记 PR、进 CI），并把 **dev-together** 接成执行 cadence——最终从产品定位一路 AI 化跑到 PR + 北极星回归。

## 1. 核心架构认知（先纠正一个常见误解）
**kanban 是数据类型 plugin（一个 Kind）。agent 操作的是数据，不是网页 UI。** agent 改图 = 走和登录用户**完全同一条** `Ezagent.Invocation.dispatch` 打到 `resource://…/kanban/…?action=…`，ctx 的 caller 换成 agent 身份、caps 换成 agent 看板权限；UI 靠 LiveView 自动刷新反映。**看板 Behavior 不区分人/agent**（只看 owner + cap）。
> kanban PR #964 已把出站/CI/配置全下沉进 Kind（Behavior），world 退成纯 dispatcher——**数据 plugin 自包含,agent 直接 dispatch 到数据,不碰 UI**。这是本 handoff 的前提，已就绪。

## 2. Required reading
1. Skill `ezagent-developer` — P14（dispatch 是 Kind 间唯一路）+ CapBAC + agent 契约。
2. `docs/guide/world-coordination.md`。
3. main 在研 agent 配置：`docs/together/2026-06-24/agent-config-*.md`（backend-contract / delivery / frontend-contract）。
4. kanban Behavior：`apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex`（23 个 action + per-node CapBAC `owner_or_admin?`/`admin?`）。

## 3. 要做的事（机制已核对清楚，不卡在"做不了"）
让 agent 改 kanban = 把现成范式照搬，三件 + 一个授权事实。**（纠正早期版本里"独立 MCP server vs dispatch 注入"、"desired_caps #533 硬卡"、"照抄 cc_orchestrator_seed" 三处错判——见下。）**

| # | 要做 | 范式/依据 | 谁拍 |
|---|------|-----------|------|
| **① MCP server + tool catalog** | kanban 自带一个 MCP server，暴露精选 kanban 动作 | 照抄 orchestrator 的 **`mcp_server.ex` + `mcp_server/tool_catalog.ex`**（`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/`，固定具名工具 catalog，非任意 action）。**不要**通用 dispatch 工具/CLI（项目没有、违背"工具=能力清单"收口 P12/P14） | 建即可；**暴露哪几个动作**=Allen |
| **② handle_tool_call dispatch** | 每个工具内部 dispatch `kanban.*` | 逻辑现成=搬 `world/kanban_actions.ex` 的 `act/4`（`URI.with_action`+`Invocation.dispatch`，ctx 带 agent caller/caps）；CapBAC（owner/admin/cap）已在 `behavior/kanban.ex` 现成 | 建即可 |
| **③ 定义 kanban agent** | 普通 cc agent + 教用法 + caps（+ 挂 kanban MCP 桥） | **走 create 正路，不抄 seed**——见下 | 见下（Allen 决策点） |

**③ 怎么定义（核对过当前 agent contract）**：
- **别抄 `cc_orchestrator_seed.ex`**——它是 plugin 启动时硬塞的**内置单例编排器特例**（spawn 一个 system AgentTemplate，因编排器要被 `Session.Orchestrator` 确定性引用）。普通 agent（echo/cc/curl）**不写 `*_seed.ex`**，只注册 flavor（`AgentFlavorRegistry`），实例由用户 `mix ezagent.agent.create --flavor` 或 UI 现拉。
- **创建**：`mix ezagent.agent.create <uri> --flavor cc --cwd <kanban项目> --caps "kanban.*"`（CLI 与 UI 共用 `Behavior.Workspace.:create_agent` → `agent_create.ex` 正路；file-flavor 走 credential-cascade 拿隔离 config_dir）。
- **教用法（skill/CLAUDE.md）**：用 main 刚交付的 **agent-config**——`AgentConfig.apply_delta(agent_uri, …, %{key:"advisor.behavior", patch:%{"soul_md"=>"教 kanban 工具用法的 persona"}})`，投射成该 agent 的 CLAUDE.md。**这才是 agent-config 的用途**（只改已有 agent 的 soul/config，Non-Goals 明写"不扩 create_agent 入参、不改 AgentManifest schema"——它不创建/不挂 MCP）。
- **唯一缺口（要 Allen 拍）= 挂 kanban MCP 桥**：额外 `--mcp-config` 的注入靠 AgentTemplate content 的 `mcp_config_path` 字段（→`operator_mcp_config_path`→`spawn_plan.ex:117` 拼一条 additive `--mcp-config`，orchestrator 就这么挂 esr-orchestrator）。但 **create 正路没暴露写 `mcp_config_path`**（`agent_create.ex` 的 file_flavor_template 只写 flavor/cwd/config_dir；CLI 无 `--mcp-config`）。二选一：
  - **A（小扩正路）**：给 create 的 file-flavor template + CLI 加可选 `mcp_config_path`，透传到已有的 additive `--mcp-config` 通道（复用 `spawn_plan.ex`，不新发明）。
  - **B（零改动最干净）**：让 kanban 工具经**默认 esr-bridge**暴露（方案①②已让工具内部 dispatch + CapBAC 闸控谁能用）→ kanban agent **不需要第二个桥**，第 3 步退化成"普通 cc agent + soul_md + caps"，全走正路、零架构改动。

**授权（原以为硬卡的 #533，实为不卡）**：agent 拿 `kanban.*` cap 今天就能——create 时显式 `--caps`（`grant_initial_caps` 真授进 identity，CLI 可用），**不依赖** `desired_caps` 自动 grant（#533，那是模板驱动自动授权，kanban 用显式 caps 即可）。⚠️ admin 通配/`save_*_creds` 等敏感动作的默认 caps 边界=Allen。
**skill 的角色**：说明书（教 agent 怎么用这几个 kanban 工具），**不是能力**——能力全在 MCP 工具里。

## 4. dev-together 融合（两层对接，不合并）
看板=跨周调度（9 阶段链），dev-together=当日执行。接缝 = **4 个回写动作**（dispatch 层已落地、全带 CapBAC，在 kanban Behavior 内）：

| dev-together | 看板动作 | 方向 |
|---|---|---|
| `handoff`(lead) | 读 issue 节点 spec 卡（**不写**，看板是 spec 唯一源） | 看板→dt |
| `dive`(dev) | `claim_node` + `set_status :doing` | dt→看板 |
| `return`(dev) | `register_pr`（+可选挂 DoD 截图指针） | dt→看板 |
| `close`(lead) | `set_status :done` + `sync_prs` | dt→看板 |

**坑**：`sync_prs` 是**手动一次性扫描、非后台轮询**——close 后要有人/agent 再点一次才自动 done。人手档下两系统互不感知、靠人记得点、**零防 drift**（这正是"要命令自动回写"的真实痛点）。

## 5. 端到端流程 + 逐步 AI 化可行性（Q3）
流程已钉死在 `kanban.ex` 的 `@stages = [:positioning,:metric,:pain,:anchor,:ux,:feature,:issue,:test,:pr]`，`stage_fits?` 强制相邻推进（=交接即 gate）。评审=dev-together `review`，北极星回归=`set_metric` 回收 + `drop_subtree`。

| 步 | agent 自动? | 卡在哪 |
|---|---|---|
| positioning/pain/anchor/ux | 半自动（写内容能,"明不明确"人工 gate,设计本意） | 不卡机制 |
| metric/test/feature/issue/PR | 能 | 授权用显式 `--caps`(不卡#533);出站走 Behavior 已通 |
| 评审 | 能（agent 当 lead/dev hat） | 不拦 |
| 北极星回归/drop | 半自动 | **`check_drop`（自动判 current<target）代码没有,只有手动 `drop_subtree`**——要补 |

## 6. DoD（可展示产物）
- [ ] **真实渠道 transcript**：chat 里发一句"把 X 产品从定位推到 PR",agent 自动调 `kanban.*` 动作建链/推进/登记PR——附 dispatch 日志（caller=agent 身份、调了哪些动作）+ 看板截图。
- [ ] 全 gate 绿 + 本工作的回归测试（agent-identity dispatch 通过 CapBAC 的测试）。

## 7. Discuss-first / Deferred
**Discuss-first（先 Allen-confirm 再建）**：① kanban 暴露哪几个动作给 agent + 默认 caps 边界 ② 挂 MCP 桥方式 A（扩 create 加 `mcp_config_path`）vs B（默认 esr-bridge 不挂第二桥，零改动）。
**Deferred**：`check_drop` 自动驱动、出站带前面产物的 AI 摘要。

## 8. 最小第一步（零代码、不碰 Allen，先验流程）
人手档跑通一条全链路验"流程合不合适"：dev-together SKILL 加"看板对接 + §4 那张表",约定 issue 节点是 handoff spec 唯一源，dive/return/close 各加"人手在 world UI 点对应 dispatch + DoD 截图挂回节点",真有人按 9 棒走一遍（`stage_fits?` 强制顺序）。**诚实前提**：人手档零防 drift,这是验证脚手架不是成品。验完再请 Allen 拍 P0/P1/P2。

## 9. Dev prompt（给执行者）
> 在最新 main + kanban PR 之上,实现"agent 在 chat 里自动改看板"。**前提**：kanban 已是自包含数据 Kind(出站/CI/配置在 Behavior),agent 改图走 `Ezagent.Invocation.dispatch` 到 `resource://…/kanban/…?action=…`、ctx 带 agent caller/caps、经 per-node CapBAC——跟人改图同一条路。
> **必读**:本 handoff §3 全部 + orchestrator 三件套(`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/{mcp_server.ex,mcp_server/tool_catalog.ex}`) + `world/kanban_actions.ex` 的 `act/4` + kanban Behavior 的 action + cap 目录。
> **照抄范式建**(非新架构):① kanban plugin 自带 `McpServer`+`ToolCatalog`(照 orchestrator),暴露精选 kanban 动作 ② 每工具 `handle_tool_call` 内部搬 `kanban_actions.ex` 的 `act/4` dispatch,CapBAC 已在 Behavior。
> **定义 agent 走正路**(别抄 `cc_orchestrator_seed`):`mix ezagent.agent.create --flavor cc --caps "kanban.*"` + agent-config `apply_delta` 写 `soul_md` 教用法。授权用显式 `--caps`(不依赖 #533)。
> **要先跟 Allen confirm**(别自己拍):① kanban 暴露哪几个动作给 agent + 默认 caps 边界(admin/`save_*_creds` 等敏感动作) ② 挂 kanban MCP 桥方式——A 给 create 加可选 `mcp_config_path`(复用 `spawn_plan.ex` 已有 additive `--mcp-config`) vs B kanban 工具走默认 esr-bridge、不挂第二个桥(零改动)。
> **dev-together 融合**:实现 §4 的 4 个回写动作触发(dive/return/close → kanban dispatch),补 `sync_prs` 的自动触发(close 后)。
> **DoD**:真实渠道 transcript(agent 自动把一个产品从定位推到 PR)+ dispatch 日志 + 看板截图 + 全 gate 绿 + agent-identity CapBAC 回归测试。
> 杜绝想象:每个声称的能力 grep/read 核对;碰 world 读 `docs/guide/world-coordination.md`;PR 进任务分支、只 lead 合 main。
