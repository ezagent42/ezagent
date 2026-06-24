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

## 3. 三个缺口（agent 自动改图卡在这；要 Allen 拍）
| # | 缺口 | 现状/依据 | 备注 |
|---|------|-----------|------|
| **P0** | 看板没有 MCP 工具入口 | orchestrator 的 MCP 基建是它专用硬编码工具集；看板无 tool catalog + mcp.json + bridge | 决：独立 MCP server 进程（抄 orchestrator `uv run --script`）还是 dispatch 注入（抄 cc bridge inline-mint） |
| **P1（最硬）** | `desired_caps` 没真正 grant 进 live agent 身份 | 字段进了 `AgentTemplate`,但"灌进 live identity 切片"调用点不存在（`member_template.ex` 明写是 PR-5 #533 flagged follow-up） | **不接上,agent dispatch 改图被 CapBAC 直接拒。** ⚠️ 别用 inline-mint 跳过——对含 admin 通配 + `save_*_creds` 凭证的敏感动作,inline-mint 是授权收口的倒退 |
| **P2** | skill 按名解析无通用注册表 | 现在只有 orchestrator skill 硬编码 source | 新 skill（如 `kanban/board-editor`）从名字找文件的通用机制要补 |

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
| metric/test/feature/issue/PR | 能 | feature/PR 卡 P1 |
| 评审 | 能（agent 当 lead/dev hat） | 不拦 |
| 北极星回归/drop | 半自动 | **`check_drop`（自动判 current<target）代码没有,只有手动 `drop_subtree`**——要补 |

## 6. DoD（可展示产物）
- [ ] **真实渠道 transcript**：chat 里发一句"把 X 产品从定位推到 PR",agent 自动调 `kanban.*` 动作建链/推进/登记PR——附 dispatch 日志（caller=agent 身份、调了哪些动作）+ 看板截图。
- [ ] 全 gate 绿 + 本工作的回归测试（agent-identity dispatch 通过 CapBAC 的测试）。

## 7. Discuss-first / Deferred
**Discuss-first（先 Allen-confirm 再建）**：P0/P1/P2 三缺口的具体机制（尤其 P1 grant 方式：正统 delegated vs inline-mint，敏感动作不能图省事）。
**Deferred**：`check_drop` 自动驱动、出站带前面产物的 AI 摘要。

## 8. 最小第一步（零代码、不碰 Allen，先验流程）
人手档跑通一条全链路验"流程合不合适"：dev-together SKILL 加"看板对接 + §4 那张表",约定 issue 节点是 handoff spec 唯一源，dive/return/close 各加"人手在 world UI 点对应 dispatch + DoD 截图挂回节点",真有人按 9 棒走一遍（`stage_fits?` 强制顺序）。**诚实前提**：人手档零防 drift,这是验证脚手架不是成品。验完再请 Allen 拍 P0/P1/P2。

## 9. Dev prompt（给执行者）
> 在最新 main + kanban PR 之上,实现"agent 在 chat 里自动改看板"。**前提**：kanban 已是自包含数据 Kind(出站/CI/配置在 Behavior),agent 改图走 `Ezagent.Invocation.dispatch` 到 `resource://…/kanban/…?action=…`、ctx 带 agent caller/caps、经 per-node CapBAC——跟人改图同一条路。
> **必读**:`docs/together/2026-06-24/agent-config-*.md`(main 在研 agent 配置) + kanban Behavior 的 23 个 action + cap 目录。
> **要先跟 Allen confirm 的三缺口**(别自己拍):① 给看板做 MCP 工具入口(独立 MCP server vs dispatch 注入) ② 把 `AgentTemplate.desired_caps` 真正 grant 进 live agent 身份(#533,`member_template.ex` 待办;敏感动作别用 inline-mint) ③ skill 按名解析通用注册表。
> **dev-together 融合**:实现 §4 的 4 个回写动作触发(dive/return/close → kanban dispatch),补 `sync_prs` 的自动触发(close 后)。
> **DoD**:真实渠道 transcript(agent 自动把一个产品从定位推到 PR)+ dispatch 日志 + 看板截图 + 全 gate 绿 + agent-identity CapBAC 回归测试。
> 杜绝想象:每个声称的能力 grep/read 核对;碰 world 读 `docs/guide/world-coordination.md`;PR 进任务分支、只 lead 合 main。
