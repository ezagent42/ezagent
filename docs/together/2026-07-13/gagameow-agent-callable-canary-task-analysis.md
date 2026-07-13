# gaga：平台 agent 可调用 / canary 自举第一步任务分析

## 1. 文档用途

本文把 2026-07-13 `gagameow`（黄佳佳）的任务转成可执行、可验收、可返回的工作清单，并明确本任务可能产生的提交内容及多 session 并行边界。

本任务的第一性质是**真实部署验证**，不是预设代码必须有改动的 bugfix。只有 canary 验证暴露出可复现的产品缺陷后，才进入对应的代码修复分支。不得为了让分支“有代码可交”而扩大范围。

## 2. 背景与目标

### 2.1 本周统一验收

本周要在部署站点至少跑通一次完整自举链：登录官网 → 进入 hello → hello 连接 kanban → kanban 把真实开发任务派给平台托管的 cc/codex agent → agent 产出真实 PR → CI、review、合并、部署 → kanban 显示任务流转。

本任务负责这条链的第一道闸：证明平台托管的开发 agent 在 canary 上**确实可创建、可连接、可接收调用并真实回复**。在此之前，下游不得把 hello→kanban 派活或 agent 产 PR 宣布为可链测。

### 2.2 为什么必须重新实测

以下改动已合入 `main`，但它们分别解决不同层的问题，不能互相替代：

- #1294 恢复 session 创建与 agent transport readiness 解耦，目标是 session 创建不等待 agent bridge，不再因 orchestrator 启动失败而超时。
- #1310 暂时让 default session 保持 plain，只是防御性 hotfix；它绕开默认 orchestrator，不证明 orchestrator 可用。
- #1326 在凭证缺失时跳过不可物化角色槽，避免创建无声僵尸；本任务续接其“配置必须真实可用、失败必须显式”的方向。
- #1332 把 orchestrator MCP server 写入主要 `.mcp.json`，并把 orchestrator 切到 `cc-deepseek`，解决 MCP bridge 未可靠启动和认证来源问题。
- #1333 自动物化 `tengu_harbor`，使 cc agent 的 development channel 注册，从而能够接收 `@mention`。

因此，“session 能创建”和“orchestrator 能收到消息并回复”是两组正交验收。两组都必须在 canary 上成立。

## 3. 任务具体内容

### 3.1 建立可追溯的验证基线

在执行产品验证前记录：

1. canary 当前部署 commit / release 标识。
2. canary 已包含 #1294、#1326、#1332、#1333；若没有，不继续做结论性验收，先交由 coordinator 部署正确版本。
3. canary 必需配置存在，但证据中不得泄漏秘密值：
   - PAT pepper 已配置；
   - `DEEPSEEK_API_KEY` 或当前实际 provider 所需凭证存在；
   - cc/orchestrator WebSocket URL 指向 canary 的 `/agent_bridge` 与 `/orchestrator_socket`；
   - 不把 token、API key、完整授权 header 写入日志、截图或仓库。
4. 使用的用户、workspace、session template/socialware、agent recipe/flavor、测试时间和测试者。

基线不满足时，输出“部署/配置阻塞”，不得把验证失败归因成产品代码 bug。

### 3.2 通过正式产品入口创建测试会话

1. 从 `https://canary.ezagent.chat/login` 走 magic-link 登录，不通过裸 RPC、任意 eval 或直接写数据库制造状态。
2. 通过 world/正式 CLI 的 sanctioned dispatch 入口创建一个全新、可识别且不会与旧实例混淆的测试 session。
3. 记录创建开始、返回时间和结果。
4. 验证创建没有重现原 5 秒超时。
5. 验证 session 创建结果可在产品 UI 重新读取，而非仅表单返回成功。
6. 若 socialware/agent 安装是异步的，分别记录“session 已创建”和“agent 已装载/ready”的时间，不把两者混成一个延迟指标。

### 3.3 验证 agent 物化与 transport readiness

对新 session 的 orchestrator / 目标开发 agent 核对：

1. agent 使用预期 recipe 与 flavor；若计划期望 `cc-deepseek`，不得实际落成无 provider 凭证的其他 flavor。
2. config home 已完成物化后才启动 PTY；不得出现先启动 PTY、后替换 config dir 的旧顺序。
3. PTY/OS 进程存在且没有卡在 first-run、API-key confirmation 或登录提示。
4. `esr-bridge` 完成 agent chat transport join。
5. `orchestrator_bridge.py` 连接 `/orchestrator_socket`，完成鉴权和 `orch:bridge` join。
6. development channel 已注册；日志可观察到与 `tengu_harbor` 生效相符的 channel registration 证据。
7. agent readiness 最终进入可接收调用的状态；不得只凭“进程存在”判定 ready。

### 3.4 验证 `@orchestrator` 真实回复

1. 在新建 session 的真实聊天 UI 中发送一条带唯一 nonce 的 `@orchestrator` 指令，例如要求原样返回该 nonce 并报告自己收到的任务。
2. 保存发送前、发送后和回复后的 agent-browser 截图。
3. 保存完整 transcript，至少包括发送者、目标 mention、时间、唯一 nonce、agent 回复和 session 标识。
4. 将 transcript 与 PTY、agent bridge、orchestrator bridge 的 join/receive 日志按时间关联。
5. 确认回复来自本次新 agent，而不是旧 session、其他 agent、缓存消息或人工回复。
6. 至少再发送一次不同 nonce，证明链路不是偶发单次成功；第二次不要求重建 session。

### 3.5 验证“可被 kanban 派活”的最小能力

本任务不负责实现完整 kanban→PR 全链，但必须给下游一个可消费的放行结论：

1. 使用与 kanban 后续派活相同的 agent 身份/调用路径，发送一条最小开发任务指令。
2. agent 必须确认收到任务，并返回结构清楚的执行意图或状态，而不是只回复健康检查文本。
3. 记录可供 `jjkysy` 后续使用的 agent URI、session URI、recipe/flavor 和调用方式；秘密凭证除外。
4. 明确通知 zhaomato / jjkysy：该 agent 链是否已可链测，以及任何仍存在的限制。

“产出真实 PR”属于本周完整 demo 的后续环节；本任务只需证明平台 agent 已达到可被派活的入口条件，除非 lead 另行要求本任务直接承担首个真实 PR。

### 3.6 失败时的分层诊断与处置

失败后必须先定位层级，再决定是否写代码：

| 失败层 | 典型现象 | 本任务处置 |
|---|---|---|
| 部署版本 | canary 未包含目标 commit | 记录阻塞，交 coordinator 重新部署；不改业务代码 |
| 部署配置/秘密 | provider key、PAT pepper、WS URL 缺失或错误 | 修部署配置或形成明确交接；秘密不入库 |
| session 创建 | 创建超时、回滚、UI 假成功 | 最小复现；检查 #1294 契约及 session-create invariant，再开独立修复提交 |
| agent 物化 | 凭证缺失却建出僵尸、recipe/flavor 错 | 检查 #1326 precondition 与真实配置来源；fail loud，不加默认绕过 |
| PTY/config home | first-run 卡住、PTY 早于 config home | 检查 HomeRuntime / OnboardingBootstrap / spawn 顺序；写回归测试后修复 |
| agent bridge | agent chat transport 未 join | 检查 token、URL、channel 注册及 readiness；禁止裸 RPC 强行标 ready |
| orchestrator MCP bridge | `/orchestrator_socket` 未 join | 检查 #1332 `.mcp.json` 单一 owner、runtime priv 路径和环境传递 |
| mention 注入 | channel 未注册、消息到达但 agent 不接收 | 检查 #1333 `tengu_harbor` 物化及实际 Claude 版本行为 |
| 回复路由 | agent 已执行但 UI 无回复 | 沿 sanctioned dispatch、session URI、cap 和外部投影路径诊断；不得旁路广播 |

任何产品失败都应获得一个能在修复前失败、修复后通过的回归测试或不变量测试。不得用 retry、默认值、静默 skip 或 `:call`→`:cast` 掩盖结构问题。

## 4. 验收条件（Definition of Done）

### 4.1 产品验收：全部必需

- [ ] canary 部署版本和测试时间已记录，且确认包含目标修复。
- [ ] 通过正式登录及产品/CLI sanctioned 入口创建全新 session。
- [ ] session 创建未触发原 5 秒超时，返回结果可从产品读路径再次确认。
- [ ] 目标 agent 的 recipe、flavor、provider 配置符合预期。
- [ ] PTY 在 config home 可启动后拉起，无 first-run/凭证确认卡死。
- [ ] agent chat bridge 完成 join。
- [ ] orchestrator MCP bridge 完成 `/orchestrator_socket` join。
- [ ] development channel 注册成功，有可审计日志证据。
- [ ] 新 session 中的 `@orchestrator` 对两个不同 nonce 均产生真实回复。
- [ ] transcript、agent-browser 截图与 PTY/join 日志三者能够按时间和 URI 互相对应。
- [ ] agent 接收一条最小开发任务指令并返回明确的接单/执行状态。
- [ ] 已向下游给出“可链测”或“不可链测”的明确结论及限制。

### 4.2 证据验收：全部必需

- [ ] 证据落在新的 `docs/e2e/2026-07-13/agent-callable-canary/` 目录。
- [ ] `README.md` 写明环境、commit、步骤、期望、实际结果和结论。
- [ ] 至少一张创建后 session UI 截图。
- [ ] 至少一张包含 `@orchestrator` 指令与真实回复的截图。
- [ ] transcript 使用文本文件保存，敏感字段已脱敏。
- [ ] PTY、agent bridge、orchestrator bridge join 日志摘录已保存并脱敏。
- [ ] 若失败，证据包含失败发生层级、稳定复现步骤和下一步 owner；不得只写“失败”。

### 4.3 代码质量验收：仅在产生代码改动时必需

- [ ] 先有失败测试，再有最小修复。
- [ ] 修复保持 dispatch、CapBAC、Kind 生命周期和三层边界，不引入 live-node hack。
- [ ] 针对修改面运行相关测试并通过。
- [ ] `mix precommit` 通过。
- [ ] `mix ezagent.arch.scan`、`mix ezagent.doc.scan`、`mix ezagent.uri_query.scan`、`mix ezagent.check_invariants` 全部通过，或 `mix ci.local` 完整通过。
- [ ] `mix ci.local` 若改写无关 lockfile，提交前移除机械噪声。
- [ ] PR head CI 全绿，并基于当前 `origin/main` rebase 后 return。
- [ ] 修复合入并重新部署 canary 后，重复产品验收；本地/CI 绿不能替代复验。

### 4.4 宣布完成的红线

以下任一缺失时不得使用“已修好”“agent 已可用”“demo 已跑通”等结论：

- canary 实测；
- `@orchestrator` 真实回复；
- agent-browser 截图；
- PTY/bridge join 日志；
- 可追溯的 session/agent/commit 标识。

## 5. 提交内容与提交边界

### 5.1 必交提交：验证与证据

即使没有代码缺陷，也应提交一组可复核的验证记录：

```text
docs/e2e/2026-07-13/agent-callable-canary/
├── README.md
├── 01-deploy-baseline.txt
├── 02-session-created.png
├── 03-orchestrator-replied.png
├── 04-transcript.txt
├── 05-pty-and-bridge-join.log
└── 06-kanban-dispatch-readiness.txt
```

建议提交信息：

```text
docs(e2e): prove canary agent creation and orchestrator replies
```

该提交必须只含脱敏证据和结论，不包含 API key、PAT、cookie、magic-link token、authorization header 或完整环境导出。

### 5.2 条件提交：只在发现缺陷时产生

代码修复按失败层拆成独立、可评审提交，不把多个根因揉成一个“大修复”：

1. 回归测试/不变量测试，证明当前缺陷可稳定失败。
2. 对应层的最小产品修复。
3. 必要的运行手册或诊断说明更新。
4. 修复后 canary 复验证据。

代码提交信息按实际层命名，例如：

```text
test(orchestrator): reproduce missing canary bridge join
fix(orchestrator): preserve deployed websocket endpoint for MCP bridge
docs(e2e): verify orchestrator bridge join on canary
```

不得预先承诺上述示例一定会产生；没有复现就没有修复提交。

### 5.3 return 内容

return 必须逐项对照本文 §4，至少写清：

- `returned_at`、deadline、deadline status；
- 分支、HEAD、PR URL；
- canary release/commit；
- 每一项 DoD 的 PASS/FAIL/DEFERRED 和证据路径；
- 发现的问题、根因层级、是否已修、谁拥有后续；
- gate 与测试命令的真实输出摘要；
- 是否允许下游开始 hello→kanban / kanban→agent 链测。

## 6. 明确非目标

- 不把 #1310 当作 orchestrator 可用性的证明。
- 不在本任务中主动重做完整 AgentRuntime 边界 SPEC 或全仓 cc-headless 改造；这两项是此前未落结构线，但不在 2026-07-13 计划的明确 DoD 中。
- 不负责完整 hello→kanban→真实 PR→部署→看板流转；本任务只负责第一道 agent 可调用闸。
- 不用裸 RPC、直接 DB 写入、任意 eval、手工强行 ready、伪造 join 或测试 stub 代替产品路径。
- 不为赶进度添加 silent fallback、默认凭证、无限 retry、降级成功或长期兼容 shim。
- 不在证据仓库中保存任何秘密。

## 7. 风险与停止条件

### 7.1 已知风险

- seed flake 可能阻挡部署或启动，必须先区分 seed 阻塞和 agent 产品故障。
- #1310 可能使所选 default session 根本不安装 orchestrator；测试入口必须选择真实包含 orchestrator 的模板/socialware，或先由 lead 明确恢复路径。
- 旧 session/旧 agent 可能携带旧配置，必须新建实例，不能用旧实例成功冒充新链路通过。
- canary 多人并发创建/销毁 session 会污染日志与证据关联。
- Claude/cc 版本变化可能改变 `tengu_harbor` 或 first-run 行为，必须记录实际版本。

### 7.2 应停止并请求 coordinator/lead 的情况

- canary 没有目标 commit 或无法部署；
- 缺少必要的受控部署权限或登录邮件；
- 必须改变生产秘密或共享部署配置，但没有授权；
- 测试结果要求推翻既定 orchestrator provider/flavor 决策；
- 发现需要跨 session/domain 的架构改造，已超出本任务验证范围。

## 8. 多 session 拆分与并行评估

### 8.1 可拆分的工作单元

| 单元 | 内容 | 是否可并行 | 输出 |
|---|---|---|---|
| A. 历史与契约核对 | 核对 #1294/#1310/#1326/#1332/#1333 和现有测试保障 | 可以，纯只读 | 基线/风险清单 |
| B. canary 部署就绪检查 | 版本、环境变量名、WS URL、PAT pepper、部署状态；只记录存在性，不读取秘密值 | 可与 A、C 并行，但配置修改须 coordinator 串行 | 部署基线 |
| C. 验收步骤与证据模板 | 准备 nonce、截图清单、日志过滤关键词、README 模板 | 可以，纯本地 | 可执行验收脚本/模板 |
| D. canary 产品验证 | 登录、创建 session、等待 agent ready、发 mention、收回复 | **不可多 session 并行操作同一环境** | 主验收证据 |
| E. 日志关联分析 | 对 D 产生的固定时间窗日志做脱敏、关联 | D 有首批数据后可并行只读 | join/receive 时间线 |
| F. 缺陷修复 | 仅在 D/E 确认具体失败层后，测试驱动修复 | 不应提前并行；不同根因确认独立后才可拆 | 独立修复提交 |
| G. 证据整理与 return | 汇总 DoD、生成最终结论 | 可在 D 后与无关修复文档并行，但由主 session 最终裁定 | evidence commit + return |

### 8.2 推荐方案：三 session，单一 canary 操作者

推荐最多使用三个 session：

1. **主 session（唯一 canary writer）**
   - 负责 D、最终 G；
   - 唯一执行创建 session、发送 mention、可能的清理操作；
   - 维护测试时间窗、nonce、session URI、agent URI 和最终 PASS/FAIL 状态。
2. **部署/日志 session（只读）**
   - 负责 B，并在 D 开始后负责 E；
   - 不改 canary 状态，不创建 session，不发送消息；
   - 把日志按主 session 提供的时间窗和 URI 过滤、脱敏。
3. **代码/测试审计 session（本地只读，条件转修复）**
   - 负责 A、C；
   - D 失败且主 session 给出明确失败层后，才进入 F；
   - 一次只处理一个根因，在自己的分支/工作树写失败测试和最小修复。

该方案能并行消化等待时间，又不会让多个 session 同时改 canary、争抢同一 agent 或污染证据。

### 8.3 不推荐方案

- 多个 session 同时在 canary 创建 session、发送 `@orchestrator`：日志、nonce、agent identity 容易串线，验收证据失真。
- 在不知道失败层前，分别让多个 session修改 session、PTY、MCP、mention 路径：会形成竞争性修复，无法判断哪项真正生效。
- 每个 session 各自维护一份 DoD：容易产生多个相互矛盾的“完成”结论。DoD 台账必须由主 session 单写。

### 8.4 并行度结论

- **分析准备阶段：适合 3 session 并行。** A、B、C 共享输入但不共享写状态。
- **真实验证阶段：1 个主 session 串行操作 + 1 个日志 session 并行只读。**
- **修复阶段：先串行定位，再按已证实的独立根因最多拆 2 个实现 session。** 若根因触及相同文件或同一启动链，则保持单 session。
- **最终结论阶段：单 session 汇总。** 任何辅助 session 都只能返回证据，不能单独宣布任务完成。

## 9. 推荐执行顺序

1. 主 session 建立 DoD 台账、测试 nonce 和证据目录。
2. 并行完成历史契约核对、部署就绪检查、证据模板准备。
3. 主 session 确认 canary 版本/配置满足验收前提。
4. 主 session 串行完成创建 → ready → bridge join → 两次 mention 回复 → 最小派活。
5. 日志 session 在固定时间窗内完成 join/receive 关联与脱敏。
6. 若全部通过，直接提交证据并 return；不要制造代码修改。
7. 若失败，先按 §3.6 定层，再为单一根因写失败测试与最小修复。
8. 修复通过本地 gate、PR CI、rebase 后部署 canary，完整重复步骤 4。
9. 主 session 逐项核对 §4，只有全部必需项满足后才发“可链测”通知。

## 10. 任务完成的一句话标准

在可追溯的 canary 版本上，通过正式产品入口创建全新 session，证明目标平台 agent 完成 PTY、agent bridge、orchestrator MCP bridge 与 channel registration，连续两次真实响应带唯一 nonce 的 `@orchestrator` 指令，并能确认接收最小开发任务；全过程有脱敏 transcript、agent-browser 截图和 join 日志，且所有代码改动（若有）通过完整 gate、PR CI 和部署后复验。
