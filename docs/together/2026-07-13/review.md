# dev-together 复盘 · 2026-07-13

## 元数据
- `reviewed_at`: 2026-07-13
- `lead`: allenwoods
- `plan_ref`: docs/together/2026-07-13/plan.md
- `week_ref`: docs/together/2026-W29/weekly-goals.md

## §0 product 大局（what the day advanced toward the week acceptance）

W29 的统一验收是一条端到端自举链（登录官网 → hello → kanban socialware 派开发任务给平台托管 agent
→ agent 产 PR → CI/review/合并/部署 → 看板流转 → 三面绿），本周至少跑通一次。**今天推动了这条链的第一张多米诺，
并在 canary 上把它证明为真。** plan §1 的头号目标——「平台 agent 可被正常调用 / @orchestrator 真回话」——
**达成**：gaga 的 #1367 canary 验收（commit `200f91b5`）记录了一个平台托管的 `cc-deepseek` agent 经正式入口被唤醒、
两次 nonce `@orchestrator` 真实回复、一个最小开发任务被 ACCEPTED 并给出计划。这解开了困扰一周多的入口——
下游（hello→kanban 派活、agent 产 PR、看板流转）从此**可链测**。地基侧，#1361（orchestrator Session-Config MCP）+
#1362（socialware composition-cap 车道）+ #1363（07-10 复盘 / 07-13 plan）三条**自举地基**已在清晨落 main，
demo 所需的 agent 控制面 / 组合能力就位。同一天还清理了一批 CI/前端隐患（#1368 `ci.local` 确定性退出、
#1370 slot-gate JS/Elixir allowlist lockstep + CI guard、#1367/#1369 的 World Terminal 崩溃/xterm 运行时修复），
并把「前端 CI 覆盖=0」这一真实隐患（#1369 xterm bug 曾带崩上 canary）登记成明日 zyli 的开发任务（#1371）。
**诚实边界:** 第一张多米诺已证明「可跑通一次」，但整条链尚未端到端跑通；hello→kanban 与看板流转仍待明日在已解锁的入口上链测。

## §1 落地了什么（what landed — SHAs）

今天合入 `main` 的 PR 共 **13 个**（`#1361`–`#1373`）：**3 条自举地基**（清晨）+ **10 条当日 track/加固**。
其中仅 4 条走了 `returns/`（其余 9 条走直接 PR review→merge，见 §2 对账）。

**自举地基（allen · 清晨落 main）**
| PR | SHA | 作用 |
|---|---|---|
| #1361 | `d32c4a4d8` | orchestrator Session-Config domain API + surfaces；P1 cold-restart binding（codex 对抗评审车道） |
| #1362 | `a915343de` | socialware composition-cap lane v5 — owner-gated operate caps（不引入新原语） |
| #1363 | `8efe8876b` | docs：2026-07-10 复盘 + 2026-07-13 plan（W29 自举 demo）+ roster/skill 更新 |

**gaga（黄佳佳）— PTY 急症 + canary 自举第一步**
| PR | SHA | 作用 |
|---|---|---|
| #1367 | `760a86c7a` | fix(world) 安全序列化 PTY runtime status（Terminal LiveView 因不可 JSON 序列化的 `exec_pid` 崩溃）— **已部署 canary**；其验收 commit `200f91b5` = 自举第一张多米诺实证 |
| #1366 | `f518ccd48` | fix(cc,pty) 重生死循环——**真根因是 `--continue`，不是认证失败**；加 respawn-policy 断路器 + 模块重构 + 600+ 行测试 + 双语根因文档 |
| #1369 | `ebe2e3396` | fix(world) 打包 xterm 运行时（World Terminal「xterm runtime not loaded」修复） |

**zyli（李震宇）— demo UI 收口**
| PR | SHA | 作用 |
|---|---|---|
| #1365 | `bc539b190` | Close #1320（creator 自动加入 class/template session → 过滤列表可见）+ #1327（socialware 卸载证据）；overview 可见性统一 caller-scoped |

**ruihua（陈瑞华，designer）— 官网体验**
| PR | SHA | 作用 |
|---|---|---|
| #1372 | `863960a8b` | 官网飞轮 demo：可点击静态 HTML 原型（新 `index-gallery.html` 落地页 + README 用法）置于 `docs/website-demo/`（coordinator 按 designer-deliverable 约定代开 PR） |

**coordinator（allen + CC）— CI/前端加固 + 流程**
| PR | SHA | 作用 |
|---|---|---|
| #1364 | `d4cd8419a` | dev-together 规范 plan/review 模板 + §0-standing + 开工-prompt |
| #1368 | `6023e2a59` | fix(ci) `mix ci.local` 确定性退出（全 gate 过后 `halt 0`）——teardown-flake 修复，机制经隔离复现证明 |
| #1370 | `7f8f11317` | fix(world) check-mounts allowlist 对齐 + CI 内 slot-gate lockstep 守卫（JS/Elixir 行锚同步） |
| #1371 | `f31789939` | docs(todo) 登记前端 CI 覆盖开发任务（zyli，2026-07-14） |
| #1373 | `1764653e2` | docs(dev-together) 编成 designer / 非代码交付物 → PR 约定 |

## §2 台账对账（accounting table）
> **对账并核两源:** 扫 `returns/` **和**当日 GitHub 合并——今天两源严重背离（4 return vs 13 merged），
> 差额全部来自直接 PR（gaga #1366/#1367/#1369、coordinator #1368/#1370/#1371 + 地基 #1361/#1362/#1363）。
> 若只看台账会漏记 gaga 的急症主量与 coordinator 的加固——正是模板 2026-07-09 警示的陷阱。

| 指标 | 数 | 备注 |
|---|---|---|
| plan.md 计划任务数 | 4 human-dev track + 1 designer 设计输入 | gaga / jjkysy / zhaomato / zyli（track）+ ruihua（设计输入） |
| returns/ 到达数 | 4 | `close-1320-1327`（zyli #1365）· `orchestrator-session-config`（allen #1361）· `socialware-composition-cap`（allen #1362）· `ruihua-flywheel-demo`（ruihua #1372）；其中 late：0 |
| 进入 stack.md 数 | 0 | 本日无 `stack.md`（走直接 PR→merge 模型；lead 直接合入 main） |
| 合入 main 数 | 13 | `#1361`–`#1373`（3 地基 + 10 当日 track/加固） |
| superseded / out-of-scope / blocked / deferred | superseded 2 · blocked 1 · deferred 2 | superseded：旧 #1320 / #1327 被 #1365 取代（待 lead 接受后关）；blocked：zhaomato 官网 hello E2E（依赖 orchestrator 真回话，mid-day 才由 #1367 证明）；deferred：gaga 的 AgentRuntime 边界 SPEC（急症挤占，结转 07-14）· jjkysy kanban 进度看板（无可见 artifact，结转） |
| GitHub PR：merged / subsumed / left-open | merged 13 · subsumed 2（#1320/#1327 由 #1365 吸收）· left-open 1（#1301 dealscout，jjkysy，末次触碰 07-12，未推进） | 逐一点名如上 |

> plan.md 本日**完整**（`lead_confirmed: true`，含 §0 standing + §5 开工 prompt），非 placeholder——不作过程缺口。

## §3 缺口 / 结转（gaps / deferrals）

- **gaga · AgentRuntime 边界 SPEC / `agent_runtime_boundary` gate（W28③ 结构线）— 未落地。** 被 PTY 重生死循环急症
  正当挤占（#1366/#1367/#1369）——**这是正确取舍**：入口不通则下游无从链测，急症优先。结转 07-14（见 §5）。
- **zhaomato · 官网首程 + hello→kanban E2E transcript — 未交付，但 blocked-not-idle。** 该 track 依赖 orchestrator 真回话，
  而第一张多米诺 mid-day 才由 gaga #1367 证明；解锁前无法链测 hello→kanban 派活。今日属被阻，非空转。结转 07-14（现已解锁）。
- **jjkysy · kanban socialware 进度看板 — 无 PR、无 return，`#1301` dealscout 末次触碰 07-12。** 今日无可见 artifact；
  **caveat:** 可能存在非 PR 的看板监控 / 协调工作，但本复盘无法核实。作为缺口跟进，明日明确交付物（见 §5）。
- **gaga 诚实旗标（独立后续，非急症本身）:** ① `test-zyli-cc-1` 无凭证（与 crash-loop 无关，属 per-agent config）；
  ② 可能还有更多 agent 需凭证下发。两者登记为 demo agent 凭证下发后续，结转 gaga 07-14。
- **前端 CI 覆盖 = 0（系统性缺口）:** 无 JS/TS 测试、`tsc --noEmit` 全项目零调用、无 ESLint/Vitest；#1369 xterm bug
  正因此带崩上 canary 才被人工 agent-browser 发现。已登记为 zyli 07-14 开发任务（#1371 / `docs/futures/todo.md` 2026-07-13 节）。

## §4 method-deltas（MANDATORY — promote, don't just collect）
> 每条发现都映射到「会抓到它的规则」；无映射规则 = 需要新增规则的信号。

| # | 发现（finding） | 会抓到它的规则（existing/new） | 去向：skill-change / process-debt |
|---|---|---|---|
| 1 | coordinator 早前把 PTY 重生死循环误诊为「认证失败」；gaga 用单变量 D-vs-E 受控实验证伪（933 次崩溃 / 0 次 auth-observer 命中），真根因是 `--continue`。 | **existing** — `feedback_reproduce_failure_before_component_benchmarks`（root-cause 前先 e2e 复现真实失败，不臆断culprit）。gaga 恰好照做。 | **process-debt（强化，非改 skill）**：把「reproduce-first / 单变量隔离」作为根因诊断的显式验收；记入 gaga profile 强项。owner: lead。 |
| 2 | 前端事实上零 CI 覆盖（无 tsc/ESLint/测试），#1369 xterm bug 因此带崩上 canary，仅人工 agent-browser 发现。 | **new** — 需要一道**前端 CI gate**（`tsc --noEmit` 起步）；现有 gate 只证「打包成功」不证类型/行为。 | **process-debt → 已转开发任务**：#1371 登记 zyli 07-14 分期实施（tsc→ESLint→Vitest→Playwright smoke）。owner: zyli。 |
| 3 | 急症（PTY 死循环）正当挤占了计划的结构线（AgentRuntime 边界 SPEC）；若不显式登记，结转会隐形丢失。 | **existing** — `plan.md` §6 out-of-scope 登记 + review §3 结转（deferral 须 lead 裁定、显式记，不 dev 自宣）。 | **process-debt**：本复盘 §3 + §5 已显式结转 gaga AgentRuntime SPEC；无 skill 改动。owner: lead/gaga。 |
| 4 | 4 return vs 13 merged 严重背离——9 条走直接 PR 不进 returns，只看台账会漏记 gaga 急症主量与 coordinator 加固。 | **existing** — review 命令的「对账并核两源」（returns/ + GitHub 合并双扫，2026-07-09 zhaomato/ruihua 前例）。本复盘 §2 已双扫。 | **无 skill 改动**：规则已存在并被遵守；记为正例。 |
| 5 | designer（ruihua）交付非代码原型，经 coordinator 代开 PR（#1372）纳入 review 轨。 | **existing（今日新落）** — #1373 已把「designer / 非代码交付物 → PR」编成约定。 | **skill-change 已落（#1373）**：约定成文，无需再改。 |

## §5 次日规划建议（next-day planning suggestions）

第一张多米诺已证明——07-14 的重心从「证明入口」转向「沿链往下推、并补回被急症挤占的结构线」：

1. **zhaomato 解除阻塞、优先链测。** hello→kanban 依赖的 orchestrator 真回话已通，07-14 让他跑
   「官网首程 + hello greeter + curl-llm 真回复」E2E transcript（此前唯一的阻塞已清）。
2. **gaga 补结构线 + 凭证下发。** 把今日让位的 AgentRuntime 边界 SPEC / `agent_runtime_boundary` gate 拉回为头号；
   并处理他诚实旗标的 demo agent 凭证下发（`test-zyli-cc-1` 等）。急症已收口，结构线不能再滑。
3. **jjkysy 明确交付物。** kanban 进度看板今日无可见 artifact——07-14 给出**可核实**的交付（看板上有 demo 各环节任务卡 + 至少一条跨环节验收），
   并把 #1301 dealscout 推到 mergeable。避免再次「无 PR 无 return」。
4. **zyli 转前端 CI。** #1320/#1327 已收口；07-14 起 #1371 前端 CI 覆盖任务，**先 `tsc --noEmit` 进 CI**（最高性价比，直接防 xterm 类 bug）。
5. **ruihua 承接飞轮原型落地。** 把 #1372 原型的 IA/视觉方向接入真实 world/hello LiveView 面（设计输入，走 Feishu，不占 track 行）。
6. **序列化提示:** zhaomato（hello/官网）与 zyli（前端 CI，触 `world` assets）若同触 `world` 面，按 `world-coordination.md` 串行 `styles.css`。

## §6 roster 更新（single writer）
> `review` 是 `docs/together/team.md` 中 `current_track`/`latest_return` 的**唯一写入方**。以下为 07-14 方向。

- **zyli**（李震宇）: `current_track` → 前端 CI 覆盖任务（分期，先 `tsc --noEmit` 进 CI；#1371 登记）· `latest_return` → `#1365 (2026-07-13)`（Close #1320+#1327）
- **gaga**（黄佳佳）: `current_track` → AgentRuntime 边界 SPEC / `agent_runtime_boundary` gate（W28③ 结构线，补回）+ demo agent 凭证下发 · `latest_return` → `#1367 canary 验收 (2026-07-13, commit 200f91b5)` — 自举第一张多米诺 + PTY 急症（#1366/#1369）
- **zhaomato**（张宁）: `current_track` → 官网 hello live E2E transcript（greeter + curl-llm 真回复；**现已解锁**）· `latest_return` → `#1312 (2026-07-11)`（本日 blocked，无新 return）
- **jjkysy**（姚升悦）: `current_track` → kanban socialware 整体进度监控 + 测试（可核实交付）+ 推 #1301 dealscout 到 mergeable · `latest_return` → `kanban-rework-final (2026-07-10)`（本日无 PR/return）
- **ruihua**（陈瑞华）: `current_track` → 官网体验：把飞轮原型 IA/视觉接入真实 world/hello LiveView 面（设计输入，不占 track 行）· `latest_return` → `#1372 (2026-07-13)`（官网飞轮 demo）
