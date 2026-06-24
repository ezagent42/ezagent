# 配一个 agent 自动编辑 mindmap：技术探查 + 落地方案

> 写于 2026-06-23。Skill 1 方式：每条结论带 file:line 实证。真相源 = 实际代码（worktree `df-tech`），不是 PRD 愿望。
> 问题：mindmap 节点被 claim 后，能不能配一个 cc(Claude Code) agent 自己去 `add_node`/`set_status`/`attach_artifact`？
> 需不需要配 agent / routing / agent contract？给确定的最小落地路径。

---

## TL;DR（先看结论）

1. **agent 是一个 Kind 实体**，URI = `entity://<ws>/agent/<name>`，从 AgentTemplate spawn，state 由多个 Behavior 各自持有 slice。**不是一个 orchestrator 专属概念**——orchestrator 只是"带 orchestrator 角色的 cc agent 实例"。
2. **agent 的"契约"分两层**：① 框架层 = `use Ezagent.Lifecycle` + `action` 宏（agent 自己能被 dispatch 的动作，如 `agent.receive`）；② cc agent 真正"干活"是经 **MCP 工具** —— claude 进程连进来，调一组**固定的、预先 cap 过的工具**，工具内部再 `Invocation.dispatch` 打进 runtime。
3. **routing 是反应式的**：agent 不主动轮询。默认规则 `$mentions` —— 一条消息 @ 了某 agent，才 dispatch `agent.receive` 给它。要"触发 agent 干活"= @它，或加一条 routing rule 把某类消息路由给它。
4. **agent 能不能打 `mindmap.*`？能，机制已现成。** mindmap 动作就是普通 dispatch，caller 带 `entity_uri` + caps。web UI 已经在用登录者身份打 `mindmap.add_node`（`mindmap_actions.ex:231`）。agent 有自己的 `entity://.../agent/<name>` URI，同样的 dispatch 即可。**关键证据**：claim 后 `node.owner = caller_str(ctx)`（`mindmap.ex:329`），后续 `owner_or_admin?` 检查 `node.owner == caller_str(ctx)`（`mindmap.ex:470`）—— agent claim 了，owner 就是 agent 的 URI，之后 agent 就能改这个节点。**身份模型天然支持。**
5. **缺的不是机制，是"接线"**：现成机制是给 web UI（人）和 MiroSync（系统身份）用的。要让 **cc agent** 经 MCP 自动打 mindmap 动作，缺一个 **MCP 工具**（现有 11 个 orchestrator 工具里没有 `mindmap.*`），且这个工具的扩展被**故意上锁**（设计锁，见 §6）。

---

## 1. agent 是什么（Kind / 身份 / 生命周期）

### Kind 定义与 URI

- `apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex:1` —— `@behaviour Ezagent.Kind`，`type_name → :agent`。moduledoc 自述："Agent Kind — represents an external participant (e.g. a Claude CLI session via the CC bridge) inside ESR's chat router."
- URI scheme = `entity://<workspace>/agent/<name>`。canonical 构造 `Ezagent.URI.agent(workspace_name, instance_name)`（`agent.ex:279`）→ `Ezagent.URI.entity(ws, :agent, name)`（`uri.ex:392`）。
- 例：`entity://team-alpha/agent/cc_demo`。

### 生命周期 / spawn

- `Agent.spawn/4`（`agent.ex:211`）和 `spawn_fresh/4`（`agent.ex:268`，区分 `:started` vs `:already_started`）。从一个 **AgentTemplate**（URI `template://agent/<name>`，`agent_template.ex:1`）实例化。
- spawn 经 `Ezagent.SpawnRegistry.spawn/1` 注册进 KindRegistry，记 lineage（`spawn_obligations.ex:19`）+ 绑 workspace（`spawn_obligations.ex:12`）。
- 持久化 `{:snapshot, :on_change}`（`agent.ex:154`）—— 每次状态变更落库，冷启从 db rehydrate。

### state = 多 Behavior 的 slice 组合

agent 不是一个大 handler。`agent.ex:56` 起声明一组 behaviors：

```
base_behaviors = [Identity, Sandbox, ApiKeys, CredentialGrant, ConfigEvolve]
```

每个 Behavior 拥有自己的 state slice（`:identity`/`:sandbox`/`:api_keys`/…）。curl flavor 额外挂 `Behavior.CurlAgent`（持有 `:conversation`/`:last_tokens`）。

### "agent" vs "orchestrator" vs "cc_orchestrator"

- **没有 `cc_orchestrator` 这个 Kind 或宏**。`cc_orchestrator-<session_disc>` 是**实例名 pattern**。
- orchestrator = 一个 cc-flavor 的 **agent 实例**，扮演"给 session 拉人/配 routing"的角色。`ensure_orchestrator/3`（`orchestrator.ex:14`）从 `cc-orchestrator` AgentTemplate spawn 一个 agent。
- 结论：**"配一个 agent"= spawn 一个 Agent Kind 实例**，跟 orchestrator 同源、不是另一种东西。

---

## 2. agent contract / behavior（它能做什么、怎么声明）

### 两层契约

**第一层（框架）**：agent Kind 用 `use Ezagent.Lifecycle` + `action` 宏声明它**能被 dispatch 的动作**。最核心的是 `agent.receive`：

- `apps/ezagent_domain_agent/lib/ezagent/behavior/agent/receive.ex:88`：
  ```elixir
  action(:receive, args: %{message: :map}, returns: %{}, caps: [:receive], modes: [:cast])
  def handle_receive(%{message: msg}, ctx) do
    case Delivery.deliver_agent_receive(msg, ctx) do
      :ok -> {:ok, %{}, []}                                  # subprocess_ws：异步回
      {:sync, r} -> {:ok, %{}, [sync_result_effect(...)]}    # in_process_sync：curl
    end
  end
  ```
- 即：session 把消息 dispatch 给 agent，agent 的 `receive` handler 把消息**经 AgentBridge 投给外面的 cc 进程**，不在 Elixir 里"想"。

**第二层（cc agent 真正干活）= MCP 工具**。cc agent = 外面跑的 claude 进程，经 WebSocket bridge 连进来，调一组 MCP 工具。工具内部才 `Invocation.dispatch` 打进 runtime。详见 §5。

### Delivery 全链路

- 入站（session→cc agent）：`Session.send` →（routing）→ `agent.receive` → `Delivery.deliver_agent_receive`（`delivery.ex:38`）→ 建 `AgentBridge.Payload` → `AgentBridge.deliver`（`agent_bridge.ex:10`）→ cc adapter `send(channel_pid, {:agent_bridge_push, "to_claude", ...})`（`bridge_adapter.ex:20`）→ WS push 给 claude。
- 出站（cc agent→session）：claude 经 MCP 回复 → cc adapter `handle_client_event("reply", ...)`（`bridge_adapter.ex:30`）→ `dispatch_reply` → `Invocation.dispatch`（`bridge_adapter.ex:162`）把消息打回 session，caller = agent_uri，caps = `session.send`。

**关键发现**：**没有"agent 订阅 session 自动反应"的后台监听机制**。agent 全程反应式——被 dispatch `receive` 才动，回复也只在它自己选择时（调 MCP 工具）。

---

## 3. routing（消息怎么到 agent）

### 路由是声明式规则，反应式触发

- RoutingRegistry = ETS 表族（`routing_registry.ex:1`），规则持久化在 `routing_rules` 表（`rule_store.ex:22`，字段 `matcher_data` / `receivers` / `workspace_uri` / `enabled` …）。
- Resolver 是唯一收口：`resolve(message, session_uri, members) → [recipient_uri]`（`resolver.ex:143`）。
- 默认系统规则（`default_rules.ex`）：matcher `{:always}`，receivers `["$session_users", "$mentions"]`。即：**每条消息**广播给所有 user 成员 + **被 @ 到的 agent**。
- `$mentions` 展开（`resolver.ex:320` 区段）：读 `message.mentions`，过 `valid_member?` 信任边界，排除 sender。**这是 mention-gated 路由原语**——没被 @ 的 agent 收不到 dispatch。

### 要"触发 agent 干活"怎么做

两条路：
1. **@ 它**（mention）—— 默认规则就会 dispatch `agent.receive` 给它。
2. **加一条 routing rule** 把某类消息路由给它。运行时改规则有动作 `routing.add_rule`（`behavior/routing.ex:14`，caps `[:add_rule]`），写库 + 立即 reload ETS（`routing.ex:149`，`load_into_registry`）。orchestrator 工具 `define_rule_set_rule`（`tools.ex:554`）就是这么给 worker agent 配 relay 规则的。

**结论**：agent 不轮询。"自动编辑 mindmap"的触发点必须是**某个消息/事件经 routing 落到 agent 上**，agent 收到后在它的 cc 侧逻辑里决定调 mindmap 工具。

---

## 4. agent 怎么 dispatch mindmap 动作（身份 + caps + per-node CapBAC）

### mindmap 动作就是普通 dispatch

- mindmap Kind = data resource，URI `resource://<ws>/mindmap/<name>`（`mindmap.ex:9`，`pattern: :resource`）。
- 动作清单（`behavior/mindmap.ex:36` 起）：`add_node` / `rename_node` / `move_node` / `remove_node` / `set_stage` / `claim_node` / `unclaim_node` / `set_status` / `attach_artifact` / `detach_artifact` / `set_metric` / `get_tree` / `export_markmap` / `import_markmap`（+ 新增中的 `drop_subtree`，见 `impl-drop.md`）。每个动作声明 `caps: [:动作名]`。
- dispatch 模板（`miro_sync.ex:171`，系统身份版）：
  ```elixir
  target = Ezagent.URI.with_action(uri, :mindmap, action)
  Ezagent.Invocation.dispatch(%Ezagent.Invocation{
    target: target, mode: :call, args: args,
    ctx: %{caller: <caller_uri>, caps: <caps>, reply: {:caller_inbox, self()}}
  })
  ```

### per-node CapBAC：agent claim 后就能改（身份模型天然支持）

- `data_owner(_) → :no_owner`（`mindmap.ex:170`）：**没有实例级 owner 收口**，授权全在 handler 内 per-node 做。
- claim 把 owner 设成 caller（`mindmap.ex:329`）：
  ```elixir
  new_nodes = Map.put(t.nodes, id, %{node | owner: caller, status: :claimed})  # caller = caller_str(ctx)
  ```
- 授权检查（`mindmap.ex:470`）：
  ```elixir
  defp owner_or_admin?(ctx, node),
    do: admin?(ctx) or (node.owner != nil and node.owner == caller_str(ctx))
  ```
- `caller_str(ctx)` = `ctx.caller` 的字符串化 URI（`mindmap.ex` 同区段）。
- **推论（确定）**：agent A（URI `entity://ws/agent/A`）`claim_node` → `node.owner = "entity://ws/agent/A"`。之后 A 再打 `set_status`/`attach_artifact`，handler 里 `node.owner == caller_str(ctx)` → `true` → 放行。**agent 跟 user 在这套检查里完全同构，不需要特判 agent。**
- caps 模型：每个动作框架层先查声明的 cap（`caps: [:set_status]` 等），再进 handler 做 per-node owner 检查。两道门。

### 已有的两个真实 caller 范例

1. **web UI（人）**：`world/mindmap_actions.ex:231` —— `caller: socket.assigns.current_entity_uri`, `caps: socket.assigns.current_caps`。登录者身份直接打 `mindmap.add_node`/`claim_node`/`set_status`。
2. **MiroSync（系统）**：`miro_sync.ex:183` —— `caller: Ezagent.URI.user(:system, :admin)`, `caps: [admin_genesis_cap]`（wildcard `kind: :any` → 过 `admin?`）。

**给 agent 用，就是第三个 caller**：caller = agent 的 entity_uri，caps = agent 该有的 mindmap caps。机制零改动。

---

## 5. cc agent 怎么接入（bridge / token / 跑在哪）

- **bridge 两种 transport**（`agent_bridge.ex:1`）：`:subprocess_ws`（cc/codex，外部子进程 + WS，异步）/ `:in_process_sync`（curl，inline 同步）。
- **token 流**：`TokenStore.mint/1`（`token_store.ex:14`）持久化 per-agent token 到 `cc-channels.yaml`；cc 进程连 WS 时带 `{agent_uri, token}`，`Socket.connect/3`（`socket.ex:19`）常数时间验证；`Registry.bind`（`registry.ex:40`）记 `agent_uri → channel_pid`。
- **跑在哪**：cc agent = 外面一个 claude 子进程（PTY），由 `cc_agent/spawn.ex:51` `spawn_for_local_pty` 拉起，`ensure_pty_server`（`spawn.ex:154`）跑 `claude`。bridge 断了能自愈（`deliver_ensuring` → `default_heal`，`agent_bridge.ex:237`，从 snapshot 重拉子进程）。
- **cc agent 怎么"动作"系统**：经 MCP。orchestrator-role 的 cc agent 连一个 MCP bridge（`mcp_server.ex`），调工具。SessionManager（`session_manager.ex`，一个 GenServer，**不是 Kind**）执行工具：4 道门（验 bridge token → 结构性 caller 校验 → session 侧重建 orchestrator 的 caps → dispatch），cc 侧**不带任何 cap**，caps 在 session 侧从 orchestrator 的 `:identity` slice 重建（`session_manager.ex:351`）。
- **能不能配成"监听某 mindmap 自动编辑"？** 没有现成的"监听"。cc agent 只有被 dispatch（@/routing 触发）才动。但被触发后，它**可以**调 MCP 工具去 dispatch —— 前提是有那个工具。

---

## 6. 落地方案：配一个 agent 自动编辑 mindmap（最小可行路径）

### 现成能组合的 vs 要新建

| 件 | 状态 | 实证 |
|---|---|---|
| ① agent 身份（entity_uri） | **现成**：spawn Agent Kind 即得 | `agent.ex:211` |
| ② mindmap 动作 + per-node 授权 | **现成**：agent claim 后 owner=agent_uri，`owner_or_admin?` 自然放行 | `mindmap.ex:329` / `:470` |
| ③ dispatch 机制 | **现成**：`Invocation.dispatch` + `with_action(uri,:mindmap,action)` | `miro_sync.ex:171` |
| ④ routing 触发 agent | **现成**：@ 它 / `routing.add_rule` | `resolver.ex:320` / `routing.ex:149` |
| ⑤ cc agent 接入 + token | **现成**：bridge/token/PTY | `agent_bridge.ex` / `token_store.ex` |
| ⑥ **cc agent 经 MCP 打 `mindmap.*` 的工具** | **要新建**（且有设计锁） | §6 下文 |
| ⑦ agent 拿 mindmap caps | **要接线**：grant 给 agent | §6 下文 |

### 路径 A（最小、推荐 PoC）：world 入口当"agent 手"，不碰 MCP 工具锁

最省事：让 agent 经它已有的 `agent.receive` 收到任务后，**回复一条结构化指令**，由 world 层（已有 `mindmap_actions.ex` dispatch 链）代打。但这绕了一层、不够"自动"。

更直接的 PoC：**给 agent 一个专用 Behavior**，让 agent Kind 自己暴露一个动作（如 `agent.work_mindmap`），handler 内直接 `Invocation.dispatch` 打 `mindmap.*`，caller = self_uri（agent 自己），caps 来自 agent 的 identity slice。触发靠 routing（@agent）。这条**不碰 MCP 工具锁**，纯框架内组合：
- 新建 `Ezagent.Behavior.Agent.MindmapWorker`（`use Ezagent.Lifecycle` + `action(:work_mindmap, ...)`）。
- handler 读消息 → 决策 → 一串 `mindmap.claim_node` / `set_status` / `attach_artifact` 的 dispatch，caller=self。
- **但**：决策逻辑若要"智能"（让 claude 想），还是得把消息投给 cc 进程、等它回 MCP 工具调用 —— 又回到路径 B。所以路径 A 只适合**规则化自动编辑**（如"收到 PR webhook → set_status done"）。

### 路径 B（真·cc agent 智能编辑）：加一个 MCP 工具

让 claude 进程自己决定调 `mindmap.add_node` 等。需要：
1. **新增一个 MCP 工具**（如 `mindmap_edit`），在两处注册：
   - cc 插件 schema：`mcp_server/tool_catalog.ex`（`tool_schemas/0`）加一个 `%{name, description, inputSchema}`。
   - session 域 canonical 名单：`orchestrator/tools/tool_catalog.ex:4` 的 `@tool_names`。
2. **SessionManager 加 `run_tool_op(:mindmap_edit, args, opts)` 子句**（`session_manager.ex:388` 区段），preflight cap 检查 → `Invocation.dispatch(mindmap_uri?action=mindmap.<动作>)`，caller = agent_uri，caps = 重建出的 agent caps。
3. **架构决策点（必须 Allen review）**：现有工具集**故意上锁**，`tools.ex:81` 写明 "Design locks (CI-gated)"，明确禁 `:grant_cap`、禁 slot、禁 fork。`general-purpose` 探查结论："cannot and should not be extended to arbitrary action dispatch — would violate P14/P22"。**加一个 `mindmap_edit` 工具不是"任意 dispatch"**（它限定 kind=mindmap、限定动作白名单、走正常 caller+caps 的 P14 dispatch），但**它确实扩了 orchestrator 的权能边界**，必须走 Decision Log。

### caps 接线（⑦，两条路径都要）

agent 要能打 `mindmap.add_node` 等，得持有对应 cap。两种给法：
- **claim-then-edit**（最省 cap）：agent 只需 `:claim_node` cap，claim 后 owner=自己，后续编辑靠 per-node owner 检查放行（`mindmap.ex:470`）。**这是最小 cap 面**，跟用户的"节点被 claim 后配 agent 编辑"诉求完全吻合。
- **admin agent**：给 agent wildcard cap（过 `admin?`），能改任意节点 —— 权能太大，不推荐除非是"系统维护 agent"。

cap 怎么落到 agent：agent 的 caps 存在它的 `:identity` slice，session 侧 `Identity.list_caps_for(agent_uri)` 读出来（`session_manager.ex:351`）。grant 走统一 grant chokepoint（见 `2026-06-17-unified-grant-chokepoint.md`，未细查）—— **这是接线的具体动作**，要确认 grant 路径能给一个 worker agent 发 `mindmap:claim_node` cap。

### 推荐落地顺序

1. **PoC 用路径 A 的规则化版本**：spawn 一个 worker agent，grant `:claim_node` + 编辑 caps，加一条 routing rule 把"mindmap 任务消息"路由给它，agent 用 `MindmapWorker` behavior 规则化地 claim+编辑。**全程框架内，不碰 MCP 锁，不需要 Allen 改架构**（只是新 plugin Behavior）。
2. **要 claude 真"想"再上路径 B**：加 `mindmap_edit` MCP 工具 —— **此处暂停等 Allen**（扩 orchestrator 权能边界 = Decision）。

---

## 7. 问题1：除了 Miro/GitHub，其他出站需求清单（PRD 实证）

来源：`docs/discuss/df-prd/`（worktree `ezagent-yao`）。三桶：A=真出站连接器（推数据出去，像 Miro），B=节点挂 ref（只挂链接，无 live sync），C=入站拉取（从外部拉数据回来闭环）。

| 工具 | 桶 | 实证 |
|---|---|---|
| **GitHub** | **A + C** | A：出站走 external_mirror adapter 把节点状态推成 issue/PR/评论（`01-工具选型.md:94`, `04-spec.md:143`）。C：GraphQL 拉"我 assignee 的 open issue/待 review PR"追踪自己工作（`01-工具选型.md:93`）。**主集成，已决策**，已有 impl spec（`impl-github.md`, `github-outbound-and-attachment-interaction.md`）。 |
| **飞书 Feishu** | **A + C** | A：external_mirror 复用飞书插件出站 `{FeishuAdapter, FeishuChatBinding}`，把 spec/周报推飞书群+文档（`03-思维导图.md:185`, `06-...:89`）。C：订阅文档/表格变更事件（`drive.file.bitable_record_changed_v1`）→ inbound dispatch → agent 实时追踪（`01-工具选型.md:121`）。**飞书出入站都现成**（`00-总览.md` 结论2）。**入站订阅未实测（风险 R7）**。 |
| **excalidraw** | **A + B** | agent 直接生成 `.excalidraw` JSON（或 mermaid→excalidraw 转），文件落 ezagent 库、路径当产物挂节点（`01-工具选型.md:58`, `04-spec.md:85`）。**要自研** connector 读写 + React 组件嵌 socialware。 |
| **markmap** | 内部（非出站） | Markdown 真相源存 ezagent 库，`markmap-lib` 在 Node 端转 HTML/SVG 塞 socialware 渲染（`01-工具选型.md:52`）。**不走 external_mirror**，但**要自研** Node 渲染 pipeline。 |
| **Obsidian** | **B + C**（仅个人向） | Local REST API + MCP，agent 能 CRUD 个人笔记（`01-工具选型.md:116`）。**明确不做团队真相源**，仅个人/技术辅助，后置。 |
| **XMind** | **B** | 仅导入/导出兼容格式，初稿用它画再转 markmap（`01-工具选型.md:53`）。**明确不做真相源**，无云 API、无 live sync。 |
| **Notion / Linear** | **B（竞品/方法论，非集成目标）** | 只在竞品分析出现（`02-...:106-139`），借鉴 daily cycle/weekly changelog/dogfooding，**不计划 sync 外部实例**。 |
| **PostHog / Umami / Metabase** | **C（不在 MVP）** | 主文档未列为集成目标。指标收集走 ezagent 内部状态机汇总 + "闭环看板"，非外部推。**后置（PMF engine 才议）**。 |
| **Jira / Slack** | — | 全文未提（Jira）/ 用飞书群非 Slack。**不在范围**。 |
| **SQLite/Postgres** | 内部 | 真相源永远在 ezagent 自带库，"先别上外部数据库"（`01-工具选型.md:17`）。 |

**出站需求净结论**：真正要"像 Miro 一样的真出站连接器"的只有 **GitHub、飞书、excalidraw** 三个（GitHub/飞书已决策且部分交付，excalidraw 要自研）。入站拉取闭环主要是 **GitHub（assignee 工作追踪）+ 飞书（变更订阅，未实测 R7）**。其余都是挂 ref / 内部渲染 / 后置 / 竞品参考。

---

## 8. 最关键待定决策（要 Allen / 工程师定）

1. **【架构 Decision】路径 B 的 `mindmap_edit` MCP 工具要不要加？** 现有工具集 CI 上锁（`tools.ex:81`）。加它扩 orchestrator 权能边界，必须走 Decision Log。倾向：先不加，PoC 用路径 A 跑通规则化自动编辑。
2. **【接线】grant 怎么给 worker agent 发 `mindmap:claim_node` 等 cap？** 统一 grant chokepoint（`2026-06-17-unified-grant-chokepoint.md`）能不能给一个非 orchestrator worker agent 发 resource-kind cap？未细查，落地前要确认。
3. **【触发语义】"配 agent 自动编辑"的触发点是什么消息/事件？** 没有后台监听。要明确：是人 @agent？是某 webhook（GitHub PR 事件）入站后路由给 agent？还是 mindmap 状态变更 emit 事件 → 规则路由给 agent？这决定要不要给 mindmap 加"状态变更 emit"（当前 mindmap 动作只 commit 树，未见对外 emit 路由事件 —— 待确认）。
4. **【flavor 选择】这个"编辑 agent"是 cc（要 claude 想）还是 curl/规则化？** cc = 智能但要路径 B 的 MCP 工具；规则化 = 路径 A 框架内搞定。用户说"cc agent"，但若编辑逻辑是确定规则，curl/Behavior 更省事且不碰锁。

---

## 附：核心 file:line 索引

- agent Kind / URI / spawn：`apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex:1,154,211,279`
- agent.receive：`apps/ezagent_domain_agent/lib/ezagent/behavior/agent/receive.ex:88`
- AgentTemplate：`apps/ezagent_domain_agent/lib/ezagent/entity/agent_template.ex:1`
- orchestrator（agent 实例非 Kind）：`apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator.ex:14`
- routing 默认规则 / 展开 / add_rule：`resolver.ex:143,320`、`behavior/routing.ex:14`、`routing.ex:149`
- bridge / token / spawn：`agent_bridge.ex:1,10,237`、`token_store.ex:14`、`cc_agent/spawn.ex:51,154`
- MCP 工具系统：`orchestrator/mcp_server.ex`、`mcp_server/tool_catalog.ex`、`session_manager.ex:287,351,388`、`orchestrator/tools.ex:81,554`、`orchestrator/tools/tool_catalog.ex:4`
- mindmap Kind / 动作 / 授权：`apps/ezagent_plugin_mindmap/lib/ezagent_plugin_mindmap/mindmap.ex:9,170`、`apps/ezagent_plugin_mindmap/lib/ezagent/behavior/mindmap.ex:36,329,470`
- mindmap dispatch 范例（系统/web 身份）：`apps/ezagent_plugin_mindmap/lib/ezagent_plugin_mindmap/miro_sync.ex:171,183`、`apps/ezagent_plugin_world/lib/ezagent/world/mindmap_actions.ex:97,231`
- PRD：`docs/discuss/df-prd/01-工具选型.md`、`03-思维导图.md`、`04-spec与用户旅程.md`、`06-产品闭环与有效性评估.md`、`00-总览.md`
