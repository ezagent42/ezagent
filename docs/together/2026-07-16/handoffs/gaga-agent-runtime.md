# Handoff: agent runtime 侧 —— #1323 headless-MCP 落 main + cc 凭证供给面

> **Date:** 2026-07-16 · **From:** jjkysy（PR #1374 kanban 线）· **To:** gaga（agent runtime：cc plugin / provisioning / 凭证）
> **Tracking:** docs/notes/2026-07-16-kanban-fix-plan.md（v3）+ layering-debt gap3/⑩ · **Base:** `origin/main` @ 6bfe3d1b3
> **Status:** confirmed —— 诊断现读代码核实；两件事：一件是收尾 #1323，一件是凭证供给的产品化

## 0. 来龙去脉（给完全没跟这条线的你）

kanban 是我们的一块**自包含协作白板 plugin + socialware**：板是一个 passive 的 data-host agent（kanban-manager），任何操作都是一次 dispatch 到板 agent，成败只看持不持有 operate cap（钥匙）；socialware 再给会话装一个 kanban-assistant——一个 **cc-headless agent**，是这套东西的"脑"：人在 chat 里 @它说"给板加个节点"，它持板的钥匙、以自己身份 dispatch 到板宿主。协作模型 2026-07-15 定稿（带认领机制的 excalidraw 式协作，编辑权全走 CapBAC 钥匙）。

我们做了两轮真 UI 测试（两账号手动 + agent-browser e2e），挖出 ㉞ 项问题。钥匙链已实证全通（cap→dispatch→per-node 过滤都在），**卡住"脑"的两截全在 agent runtime 域**——而你正在做的正是这条线（#1434 skill 加载、#1423 Git provider/provisioning），所以落到你头上：

1. 助手有钥匙、有 persona、有 skill，但**没有 MCP 工具**去 dispatch（#1323 未进 main）——它想操作板也发不出去。
2. cc 凭证缺失时，socialware install **静默跳过** assistant 角色（⑩），用户没有任何供给凭证的面、凭证补上后也没有补物化的路。

## 1. 必读

1. Skill `ezagent-developer` —— 不变式 gate。
2. `docs/notes/2026-07-15-kanban-layering-debt.md` §④（gap3）+ ⑩ —— 原始诊断。
3. `docs/notes/2026-07-16-kanban-fix-plan.md` §X3 —— 根因归并与三面分工（下游降级=我、读侧投影=zyli、上游供给=你）。
4. #1434（8bc3bbefc）—— R1/R2 修法全文（plugin-bundle 路线），你的 MCP 修法应对齐同一套管道姿势。

## 2. 现状（哪些已修，别重做）

gap3 原报三缺口，**#1434 已修其二**：

- ✅ recipe `system_prompt` 已 thread（`system_prompt_from` fallback 读 `sandbox_content.prompt`，cc_headless_agent.ex:301-307）。
- ✅ skill 加载已通（R1 plugin-bundle：home_runtime.ex:455-458 写 `.claude-plugin/plugin.json` → cc_headless_agent.ex:314-322 `plugins_from_config_dir` → sdk_sidecar.ex:269 `EZAGENT_CC_SDK_PLUGINS` → worker.py:129-135；R2 存量 reconcile `Ezagent.Home.SkillReconcile`）。
- ❌ **MCP 桥仍断**：#1323（588a694d5，headless 从 per-agent config 载 MCP servers）**仍 branch-only 未进 main**——管道 `tmpl["mcp_servers"]→env→worker.py:125` 在，但无人填、也不读 config_dir 的 `.mcp.json`。历史现场还见过助手 cwd 的 `.mcp.json` 指向**已删 worktree** 的 `ezagent_mcp_bridge.py`（stale 路径病，落 main 时一并杜绝：桥脚本路径不能指向任何 worktree）。

## 3. 任务 A —— #1323 headless-MCP 落 main

- **Y（现象）**：chat 里 @kanban-assistant 让它操作看板 → 它有钥匙、有 skill、有 persona，但零看板工具，dispatch 不出去。
- **X（根因）**：cc-headless worker 的 MCP servers 装配链无人填——esr-bridge MCP 起不来。
- **建议方案**：把 #1323 rebase 到当前 main 落地；对齐 #1434 的姿势（per-agent config_dir 为 SoT，经 env 透传给 sidecar/worker，不动 `setting_sources=[]`）；桥脚本路径从部署位派生（照 SkillRegistry/HomeRuntime 的 `$EZAGENT_HOME` 口径），**绝不硬编码 worktree/repo 路径**。
- **DoD**：
  - [ ] 真 UI e2e：普通用户会话装 kanban sw，@assistant 说"给板加个节点"，助手经 esr-bridge dispatch `kanban.add_node` 成功、板上见节点（真渠道 transcript + 每步截图，非单元 stub）
  - [ ] 回归测试锁住"config_dir 有 `.mcp.json` → worker options 里出现该 server"
  - [ ] 桥脚本路径断言：不含任何 worktree/repo 绝对路径

## 4. 任务 B —— cc 凭证供给面（⑩ 静默 skip 的上游）

- **Y（现象）**：无凭证源时 install 静默跳过 kanban-assistant，只有 server log；用户后补凭证也没有任何"补物化"的路，会话面的"未装载"横幅永远失真（㉑，读侧归 zyli）。
- **X（根因）**：skip 的判定点是 `Ezagent.Agent.CredentialPrecondition`（apps/ezagent_domain_agent/lib/ezagent/agent/credential_precondition.ex——自动物化车道里"该 flavor 对该 installer 能不能起"的守卫：非 admin installer 的解析链 = 自有 pointer → workspace-shared → NONE，NONE 即 skip，故意 loud-skip 而非造一个永远 not_ready 的废 agent）。**机制本身是对的**；缺的是两头：凭证的**绑定/供给面**（用户/管理员没有地方给 workspace 或 agent 配 Claude 凭证）+ 凭证就位后的 **reconcile**（skip 记录是 install 时刻快照，session_creator.ex:234 `record_unfilled_role_slots`；补员不走 install）。
- **分工边界**：skip 数据已返回（session_creator.ex:329-343 `%{skipped: ...}`），向导/横幅显示归 zyli；**你 own**：
  1. **凭证供给入口**：给 workspace 或 agent 配 Claude 凭证的正路（`UserDefaultSource`/`WorkspaceSharedSource` 两源现成，缺的是绑定面——形态你域内定，可先只做 operator 路 + 文档）。
  2. **补物化路**：凭证就位后，对 `unfilled_agent_role_slots` 里的 role 重跑物化（走 `DefinitionAgents.materialize_definition_agents` 同款管道，幂等——"a role already joined is skipped" 语义已在 session_creator.ex:168），并清掉对应 skip 行——这是让 ㉑ 读侧修（zyli）不需要"永久失真兜底"的根治。
  3. **skip 可观测**：telemetry + 结构化 reason（"缺 Claude 凭证" vs 其他失败），供 UI 消费。
- **DoD**：
  - [ ] e2e：无凭证建会话（角色 skip 且 reason 结构化可查）→ 配凭证 → 触发补物化 → assistant 进成员表、skip 行清掉（横幅侧依赖 zyli PR，可先以数据断言验收）
  - [ ] 补物化幂等测试（重复触发不重复建员）
  - [ ] skip telemetry 断言

## 5. 通用 DoD（两任务都要）

- [ ] All gates green：arch.scan / doc.scan / uri_query.scan / check_invariants / format / test / :ezagent_plugin_check
- [ ] CI（precommit + check_invariants）绿 on PR head + rebase main（机器 return gate）
- [ ] e2e 证据按"每步截图"规矩留 docs/e2e/

## 6. 红线

- 补物化走 `Domain.Agent` 门面 / materialize 管道（#1411），不手搓 spawn+join。
- 凭证不落 recipe/manifest（recipe 是 flavor-agnostic 配方）；供给面进你域的凭证机制。
- 不把"skip 重试"做成无限重试假强保证——凭证不存在就是不存在，供给面+补物化才是修。
- host login 不流向 co-tenant 造出的 agent（#161/DoD 6，CredentialPrecondition moduledoc 的存在理由——别在补物化里绕开它）。
- 别动 kanban plugin behavior / BoardProvision / kanban 前端（我在飞）；别动 world 本体前端（zyli 在飞）。

## 7. merge

两任务可两个 PR（A 先，B 后或并行），进你的任务分支（不进 main），rebase main，lead 合并。
