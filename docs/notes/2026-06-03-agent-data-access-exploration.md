# Agent 运行时读数据能力 — 探索 / 设计 scoping

> 分支:`explore/agent-data-access`(off main #546)。
> 起因:CS 客服 demo 的 **GAP #1** — 售前 AI 客服只能话术周旋,**运行时读不到真实数据**(库存/订单),
> 不论是 DB 还是线上数据源(HTTP API / RPC / curl)。本文档基于现有代码,把"怎么加读数据能力"的设计空间摸清,
> 给出候选路径 + 第一个可证伪实验。**先设计、后实验。**

本文档是 scoping,不是最终方案;边界(哪些产品侧能做、哪些要等地基)在 §6。

---

## 1. 问题陈述

cc 客服(claude TUI agent)在一个 session 里接客,客户问"羽绒服 XL 有现货吗",AI 只能用话术周旋,
因为它**没有任何工具去读真实库存**。我们要的是:让一个在会话中的 agent 能发起一次数据读取
(DB / HTTP API / RPC),拿到结果,据此回答。

## 2. 关键澄清:两种"agent 读数据",答案不同

| 框架 | 谁在读 | 机制 | 适用 |
|---|---|---|---|
| **A. cc-agent(LLM TUI)** | claude 进程 | 调一个 **MCP tool**(它唯一的对外手) | ✅ CS 客服就是这个 |
| **B. ezagent Behavior/Kind agent** | ezagent 原生 actor | action 里 `:effect_returning`(进程内 HTTP/DB)/ `:dispatch_returning`(跨 Kind) | 原生 actor,非 cc TUI |

**CS 客服是框架 A。** 框架 B 是另一类"agent"(ezagent 自己的 Behavior 驱动的),它读数据已经有 sanctioned 路径
(`:effect_returning`,plugin 侧、不动核心 —— 见 `behavior.ex:1153-1168`、`new-contract.md:95-215`),
但**那条路不直接服务 cc 客服**,因为 cc 客服不调 Behavior、只调 MCP tool。两条别混。

下面聚焦框架 A(cc-agent 经 MCP 读数据)。

## 3. cc-agent 怎么拿到工具(现状,grounded)

- cc-agent 启动时,sandbox 里写入 MCP 配置;**bridge MCP 永远在**(`cc_agent.ex:1154-1179` `assemble_settings_mcp_args/3`,
  `--mcp-config <bridge>` 强制,operator 的 `operator_mcp_config_path` 只能**叠加**、删不掉 bridge)。
- 编排器的 8 个工具就是这么来的:`orchestrator_bridge.py`(stdio MCP 前端 ↔ Phoenix Channel `orch:bridge:<uri>` 后端)
  + `mcp_server.ex`(`tool_schemas/0` 声明、`run_tool/3` 分发、`to_mcp_result/2` 包结果)+ CapBAC(工具跑在编排器
  绑定的 caps 上下文里,LLM 只给 operation 参数,caller/caps/session 全服务端注入 —— `mcp_server.ex:787-797`)。
- **技能(skill)是 template-time**:`apply_orchestrator_role_bootstrap/2`(`cc_agent.ex:460-531`)spawn 前把
  `ezagent-session-orchestrator` skill 拷进 sandbox,**之后没有运行时再加 skill 的路**。
  `Manage` 的 `:reconfigure` 显式未实现(`manage.ex:94-103` → `:reconfigure_unsupported`);Template 的 `reconfigure/4` hook
  还不存在;domain.agent spec D6/PR-6 才会让"desired skills"有 owner(`2026-06-02-domain-agent-design.md:109,126`)。

**结论(关键 seam)**:别把它想成"运行时装 skill"(此路 template-time、堵死)。想成
**"agent 已经有一条热线(它已连的 MCP bridge)—— 给这条热线加读数据的工具"**。
工具是否能被**正在运行**的 agent 看见,取决于 MCP `tools/list` 是否会在会话中被重新拉取(见 §5 未解问题)。

## 4. 现有可复用积木(都已存在,不用从零)

| 积木 | 状态 | 位置 |
|---|---|---|
| HTTP 客户端 | ✅ 在用 | `:httpc` stdlib;模板见 `plugin_curl_agent/api_client.ex:44-84`、`plugin_feishu/client.ex` |
| DB 读 | ✅ | `EzagentCore.Repo`(SQLite)+ `Ezagent.Ecto.KindSnapshot`(`get/1`、`list_in_workspace/1`) |
| 工具框架 | ✅ | 8-tool 模式:`tools.ex` + `mcp_server.ex` `tool_schemas/0`/`run_tool/3` + CapBAC |
| 叠加 MCP server | ✅ | `operator_mcp_config_path` 经 `--mcp-config` 叠加(`cc_agent.ex:1163-1178`) |
| 结构化错误 | ✅ | `{:error, {:http, status, body}}` / `{:transport, _}` 模式现成 |
| **读数据 tool 本身** | ❌ 待加 | 新函数 + schema + dispatch 分支 |
| **read-cap 形状** | ⚠️ 需设计 | 现有 caps 都是 mutation 向(`:within_session`/`:spawned_by`),读 cap 要新形状 |

## 5. 三条候选路径 + 评估

### 路径 1 —— 给 agent 已连的 MCP bridge 加读工具(**推荐起点**)
在 agent 已经连着的 bridge 上,新增一个读工具(如 `query_inventory`),handler 用 `:httpc`/`Repo` 取数。
- **优点**:不碰 template-time skill 那堵墙;复用现成 CapBAC + 工具分发;域内改动。
- **风险/未解**:① **正在运行的 agent 能否不重启就看到新工具?**(MCP `tools/list` 是否会在会话中重拉,
  或响应 `notifications/tools/list_changed`)—— 这是整件事的命门,必须先实验。② 编排器的工具绑定 orchestrator caps,
  **plain worker(客服)连的是 chat esr-bridge,得让读工具对 worker 可见**,不是只给编排器。
- **边界**:改 `ezagent_domain_chat` / bridge = **域**,可能踩 Allen 的地盘(见 §6)。

### 路径 2 —— 叠加一个我们自己的 MCP server(**最产品侧、最不碰地基**)
写一个独立的小 MCP server(Python/Elixir,暴露 `query_inventory`,内部 `:httpc`/读 JSON/读 DB),
经 agent template 的 `operator_mcp_config_path` 叠加进去。
- **优点**:**纯 config + 一个外部 server,不动 core/domain**;完全产品侧,符合"暂不动地基"约束。
- **缺点**:**template-time** —— 只对**新建**的 agent 生效;给运行中的客服加,要重建/重连。CapBAC 不自动覆盖
  (这个 server 是我们自己的,鉴权/数据范围得自己管)。
- 适合:先证明"客服能用工具读真数据并回答"这件事本身,绕开"运行时注入"难题。

### 路径 3 —— ezagent Behavior `:effect_returning`(**记录,暂不用于 cc 客服**)
若未来"客服"是 ezagent 原生 Behavior agent(非 cc TUI),读数据就用 `:effect_returning`,plugin 侧、零核心改动。
- 现在不适用(cc 客服不调 Behavior),但值得记:**框架已经为"原生 agent 读数据"留好了 sanctioned 口子**。

## 6. 边界:产品侧能做 vs 要等地基(Allen)

- **产品侧可立刻原型**:路径 2(自带 MCP server + template 叠加)。不碰 core/domain。
- **要 Allen / domain.agent 推进**:
  - "运行时把工具/技能注入**正在跑**的 agent" —— 命门问题若答案是"必须重连",则归 domain.agent 的
    `reconfigure`/desired-skills(PR-6,D6)。我们**提需求**,不自己改 `Manage`/`Template` 契约。
  - read-cap 形状(`{:external_data_read, source}` 之类)进 CapBAC —— 核心鉴权模型,Allen 域。
  - 给 worker(非编排器)开放工具面 —— 动 bridge/域,先和 Allen 对齐再做。

> 沿用上轮约定:**地基只提意见、等 Allen;产品侧自己推进。** 所以第一个实验走**路径 2**(纯产品侧)。

## 7. 建议的第一个实验(最小、可证伪)

**目标**:证明"一个 cc 客服能调用一个读数据工具、拿到真实库存、据此回答",并顺带测命门问题。

**E1(路径 2,纯产品侧)**:
1. 写一个最小 MCP server `inventory_mcp`(单工具 `query_inventory(sku)`,先读一个本地 JSON / SQLite 的假库存表 —— 数据源可换)。
2. 经 agent template 的 `operator_mcp_config_path` 叠加给一个**新建**的客服 worker。
3. 客户问"羽绒服 XL 有货吗" → 看 AI 是否真调 `query_inventory` 并用返回数据回答(而非话术)。
4. **判定**:AI 回答里含工具返回的真实数字 = 通过。录一段对照(改库存 → 答案跟着变)证明是真读、非编造。

**E2(测命门,决定要不要找 Allen)**:E1 跑通后,在 agent **运行中**给它已连的 MCP server **新增**一个工具,
不重启 agent,看下一轮 `tools/list` 是否出现新工具。
- 出现 → 运行时长工具面可行,路径 1 有戏(再谈 worker 工具面 + read-cap)。
- 不出现 → 运行时注入必须靠重连/重建 → 归 domain.agent PR-6,我们提需求给 Allen。

实验只动我们自己的 server + 一个新建 demo agent,**不改 core/domain/bridge**。E2 只读 `tools/list` 行为,不改契约。

## 7b. 实验结果(2026-06-03,已跑)

harness 在 `docs/notes/evidence/agent-data-access/`(`inventory_mcp.py` 零依赖 stdio MCP server + `inventory.json` 假库存 + mcp config)。

### E1 —— 外部 MCP server + cc-agent 读真数据(**通过**)
直接 `claude -p --mcp-config inventory.mcp.json`(**完全不经 ezagent**),问"羽绒服 XL 有货吗":
- AI 答:"✅ 有货,库存 **7 件**,¥899,上海仓" —— 与 fixture 完全一致。
- server call log 证明是真调用(非编造):`tools/call name=query_inventory args={'query': '羽绒服 XL'}`。
- 对照:问"羽绒服 L"(库存 0)→ AI 答"库存为 0,暂时缺货"。不同商品不同真答 = 真读。

**结论**:产品方向成立 —— 定制读数据能力可以做成**外挂在 ezagent 之外的 MCP server**,cc-agent 直接用,零 ezagent 改动。

### E2 —— 运行中 agent 能否不重启长出新工具(命门,**通过**)
单会话内:server 在第一次 `query_inventory` 调用后,自己长出第二个工具 `query_orders` 并发 `notifications/tools/list_changed`。
server log:
```
tools/list id=1            ← 初始(只有 query_inventory)
tools/call id=2 query_inventory
phase2 self-trigger → query_orders + tools/list_changed
tools/list id=3            ← claude 收到通知后【重新拉列表】
tools/call id=4 query_orders ← 调用了运行时新增的工具
```
AI 两步都答对(库存 7 件 + 订单 O-1001 已发货/顺丰)。

**结论(命门已答)**:**claude 的 MCP client honor `tools/list_changed`,会话中重拉工具列表并用上新工具。**
所以"运行时给活着的 agent 加能力"**在协议层通**。两种利用:
- **产品侧(路径 2)**:我们自己的外部 MCP server 运行时长工具 + 发通知 → **不需要 ezagent 的 reconfigure 就能给活 agent 加能力**。比预期更强。
- **地基(路径 1)**:ezagent 的 bridge 目前发**静态** tools 文件(`load_tool_schemas` 读文件);要支持运行时长工具,bridge 需在 session 可用工具变化时重算工具面 + 发 `tools/list_changed`。这归 Allen/domain,但 E2 证明了**值得做**(claude 端已经接得住)。

### E1b —— 挂到 ezagent spawn 的 in-session worker(**配置打通,被地基的 worker 生命周期挡住**)
建了 agent template `template://agent/system/cc-presale-inventory`(`content.mcp_config_path` → `operator_mcp_config_path`,
即外部 inventory MCP;role=default)。经编排器 `add_managed_member` 在 csdemo 真 session 里 spawn 出 worker
`cc_presale_inv-6077…`。证据链:
- **add_managed_member 成功**(当时本分支 off main #546 缺 G-mcp `structuredContent` 处理,
  会报 `expected record, received string`;曾在本分支 re-apply 了一个 `as_struct_content` 包装修复)。编排器确认
  "售前客服坐席已就绪 … in_session_template:true"。

  > **2026-06-08 更新(rebase 到 main 后的验证 — 记录 gap)**:rebase 到 `origin/main` @ `e6d372ec` 后,
  > 该 `as_struct_content` 补丁**已被证伪并剔除**。证据:带补丁时 `orchestrator_mcp_e2e_test` + `scenario_33_full_star_test`
  > 共 **6 个测试转红**;去掉补丁的对照组 **0 红**。根因:main 契约 = 单值 tool 结果是**裸 URI 字符串**,
  > 内部消费者(`RuleStore.uri_to_string/1` / `KindSnapshot.get/1` / `URI.new!/1`)依赖裸串,一刀切包成
  > `%{"result" => …}` 砸了它们。**未决 gap**:"live claude 是否仍拒裸串 `structuredContent`" 是 **client 侧**行为
  > (repo 内无该错误串、bridge verbatim 转发、tool 无 outputSchema),只有真实 claude 能复现 —— 留作独立协议 smoke 探针,
  > 见 spec `docs/superpowers/specs/2026-06-08-autoservice-socialware-migration-direction.md` §4。
- **inventory MCP 确实挂上了**:worker 的 claude argv 实测含 `--mcp-config …/inventory.mcp.json`(在强制 chat bridge 之后,additive)。配置层完全打通。
- **但 worker 不处理 chat**:客户 @mention → `AgentBridge deliver dropped: :timeout`,worker 零回复,inventory_mcp.py 始终没被拉起(claude 没走到处理消息那步)。chat esr-bridge 进程在跑,但 worker claude 没 join channel / 没消费消息。

**结论**:**数据接入这一层是对的**(inventory MCP 成功挂到 in-session worker、add_managed_member 通);卡点是
**cc-worker 的 chat-reply 生命周期**(deliver timeout / channel-join),跟 G-worker、#539 `deliver_ensuring`、
#512 EagerBridge 同一类 —— **地基问题,非本探索的数据接入设计**。按约定:产品侧把 E1/E2 证清楚(已做),
worker 生命周期归 Allen,提需求等推进。所以 E1b 的"live UI 版"暂时录不了;E1 的可交付是终端回放视频(已做)。

> 未排除的次因:本 worker 用了最小 `claude_config_dir`(仅 .claude.json)+ role=default,与会能回复的 demo worker
> (orchestrator-role、完整 config dir)不同;但即便如此,deliver timeout 指向 channel 生命周期而非配置缺失。

### 还没测
- read-cap / 真实数据源鉴权 —— 见 §8。

## 8. 待 Allen / 待定

- E2 的命门结论 → 决定"运行时能力注入"是否要进 domain.agent。
- read-cap 形状(谁能读哪些数据源)—— 核心 CapBAC,Allen 域。
- 真实数据源(线上库存/订单 API)接入方式 —— 产品侧定,但要注意鉴权/PII,不放 demo fixture 以外的真数据。
