# 场景 34：发送者锁定的接力（传话游戏）—— 通过 legend + 规则集 + 提示模板实现完整 star-cycle

**类别**：3 —— 会话流程（编排、多 agent 路由）
**状态**：🚧 确定性层已实现并通过；实况层 = Allen 的 runbook
**作者**：Claude，team-routing-unification PR-9（spec §9，plan PR-9）

> 双语同步镜像：[`scenario.md`](./scenario.md)。

## 目的

传话游戏接力是 **team-routing-unification** 切换的标志性示例（spec §4）。用户
`@` 一个 **legend**，消息便依次接力 cc → codex → curl，每个 agent 追加一句话，
每一跳"你正在玩传话接龙"的上下文由 **提示模板** 注入 —— 完全通过
**legend + 规则集 + 提示模板** 表达，**没有接力令牌（baton），也没有模型计算的
路由**。路由表本身就是整条链。

这正是促成整个重构的场景：切换前接力的 worker 是 `agent_slots`（不是会话成员），
所以 `@` 提及悄无声息地落空（spec §1）。切换后接力是三个一等公民 **成员**，由一个
命名 **规则集**（单接收者的 `{:from, X} → Y` 规则）连接，前面挂一个 **legend** 句柄。

## 接力拓扑（spec §4）

```
@传话游戏 ──(legend 入口规则：mention(传话游戏))──▶ relay-cc
relay-cc ──(from(relay-cc))──▶ relay-codex
relay-codex ──(from(relay-codex))──▶ relay-curl      (终点 —— 线性链)
```

- **Legend** `传话游戏`：`member_set = [relay-cc, relay-codex, relay-curl]`
  （按 role_name），`fold: true`，`bound_rule_set: "telephone"`。
- **规则集 `telephone`** —— 每条单接收者，共享提示模板 `telephone_hop`：
  - pos 0（入口）：`mention(传话游戏) → relay-cc`
  - pos 1：`from(relay-cc) → relay-codex`
  - pos 2：`from(relay-codex) → relay-curl`
- **提示模板** `telephone_hop` =
  `"你在玩传话接龙。目前内容：\n{body}\n请只追加一句简短的话。"`（必须包含
  `{body}`，写入时校验）。
- **成员**（接力 agent）：设置 `role_name`、`in_session_template: true`，
  因此整支队伍可快照进一个 SessionTemplate 复用。

**为什么"完整 star-cycle"= 这条线性链（而非闭环）：** spec §4 的示例终止于
curl —— 没有 `from(relay-curl)` 规则，所以链到此结束，curl 的回复向外镜像
（给人 / Feishu）而不回环。（"full star" 指覆盖全部三种 agent 风味 —— cc + codex
+ curl —— 与场景 33 相同的矩阵，这里由接力规则集驱动。）

## 无 baton 不变量（被测属性）

路由仅靠 **发送者身份** 推进：触发下一跳的唯一因素是 `{:from, <上一成员 URI>}`
匹配上一个 agent 所发消息的发送者。没有任何 matcher 读取消息正文中的
baton / `next_hop` / 令牌字段，也没有任何接收者由消息内容派生。模型从不计算
路由 —— 规则集表静态编码了整条链。这就是
`feedback_completion_requires_invariant_test` 的结构性闸门。

## 如何搭建（成员 + 规则集 + legend + 提示模板，无 baton）

通过编排器 MCP 工具（`Ezagent.Orchestrator.Tools`，spec §3.8）—— 一次一个实时调用，
与 SessionTemplate 物化搭建队伍的方式相同（PR-7）：

1. `add_managed_member(<cc-template>, "relay-cc", true)` —— 生成并加入 relay-cc。
2. `add_managed_member(<codex-template>, "relay-codex", true)` —— relay-codex。
3. `add_managed_member(<curl-template>, "relay-curl", true)` —— relay-curl。
4. `define_prompt_template("telephone_hop", "你在玩传话接龙。目前内容：\n{body}\n请只追加一句简短的话。")`。
5. `define_rule_set_rule(mention(传话游戏), "relay-cc", rule_set: "telephone", position: 0, prompt_template_ref: "telephone_hop")`。
6. `define_rule_set_rule(from(relay-cc-uri), "relay-codex", rule_set: "telephone", position: 1, prompt_template_ref: "telephone_hop")`。
7. `define_rule_set_rule(from(relay-codex-uri), "relay-curl", rule_set: "telephone", position: 2, prompt_template_ref: "telephone_hop")`。
8. `define_legend("传话游戏", ["relay-cc","relay-codex","relay-curl"], "telephone", true)`。

（`{:from, X}` 规则的 `X` 是成员解析后的 URI；`define_rule_set_rule` 会把接收者
`role_name` 解析为实时成员 URI。）

## 验证 —— 两个层级

### 层级 1 —— 确定性的 resolver 级不变量测试（CI，必须通过）

**文件**：`apps/ezagent_core/test/e2e/scenario_34_sender_locked_relay_test.exs`。

把 `telephone` 规则集装入一个隔离的 `RoutingRegistry` ETS 表（生产加载形态），
在路由层断言（`Resolver.resolve_with_ctx/4` + `Matcher`，无实时 agent、无 DB、
无模型）：

- **闸门 (a)** —— legend 入口触发：`@传话游戏`（经由虚拟 `legend_triggers`，而非
  `:mentions`）解析到 `relay-cc`，携带 `prompt_template_ref: "telephone_hop"`。
- **闸门 (b)** —— 每个 `{:from, X}` 跳路由到下一跳，携带 `telephone_hop` 上下文；
  `relay-curl` 是终点（解析不到下一跳）。
- **闸门 (c)** —— 完整链端到端解析，纯粹靠把上一接收者作为下一发送者来推进
  （回路里无模型），产生有序拓扑 `[relay-cc, relay-codex, relay-curl]`；并有一个
  结构性的无 baton 闸门：断言每个 matcher 只读发送者/legend（绝不读正文内容），
  每个接收者都是静态成员 URI，每跳单接收者（§3.3）。
- **闸门 (b-变体)** —— 同一套 legend-trigger 机制也能驱动 `$session_members`
  广播（spec §5 语义 B）—— 无需新原语。

运行：

```bash
cd apps/ezagent_core && MIX_ENV=test mix test \
  test/e2e/scenario_34_sender_locked_relay_test.exs
```

8 个测试，0 失败。

### 层级 2 —— 实况 runbook（Allen 的环境 —— 真正的闸门，Standard 3）

**Harness**：
`apps/ezagent_domain_chat/test/e2e/scenario_34_sender_locked_relay_live_test.exs`
—— `@moduletag :live`，默认 SKIPPED；仅由 `SCENARIO_34_LIVE=1` 解除。它不伪造
实况通过，也不会仅凭环境变量就通过。Allen 发出真实的 `@传话游戏 <词>` 后，harness
**用系统自身的生产读取路径轮询实况会话里已投递+已渲染的接力**
（`Ezagent.MessageStore.recent_in_session/2` —— 就是 LV 聊天切片 `:last_message`
与重入回放所用的同一查询），寻找一条正文被 `telephone_hop` 提示模板渲染过的消息
（即携带该模板字面包裹文本 —— 证明 `render_for_delivery/4` 在该跳注入了模板，链已
到达一次真实的模板化投递）。若在轮询预算内（默认 45s，每 1.5s 一次）未观察到该证据，
就 **`flunk/1`**，写明期望 vs. 实见 —— 绝不 `assert true`。agent-browser 截图仍是
固有的手动、agent 侧步骤。

**可程序化观察的断言 vs. 手动步骤**：

- harness 断言（经生产路径读取）：`SCENARIO_34_SESSION_URI` 里落入一条经
  `telephone_hop` 渲染的 `chat.receive`。可选地导出已解析的成员 URI（终跳发送者）把
  闸门收紧到 codex→curl 跳：
  ```bash
  export SCENARIO_34_RELAY_CODEX_URI=entity://agent/<ws>/<relay-codex>  # 终跳发送者
  export SCENARIO_34_RELAY_CURL_URI=entity://agent/<ws>/<relay-curl>    # 可选提示
  # 若 define_prompt_template 用了不同文本，覆盖标记：
  export SCENARIO_34_HOP_TEMPLATE_MARKER=你在玩传话接龙
  # 如需调整轮询预算/节奏：
  export SCENARIO_34_OBSERVE_TIMEOUT_MS=45000
  export SCENARIO_34_OBSERVE_INTERVAL_MS=1500
  ```
- 手动（测试进程内无法断言）：Feishu 群会话线程的 agent-browser 截图（下面第 6 步）
  —— Standard 3 强制证据，由 Allen 在 agent 侧捕获。

**Allen 必须做的精确用户协助步骤**（这些需要 Allen 的环境 —— 运行中的服务、真实
Feishu 群、provider 凭据、agent-browser）：

1. **启动服务** —— `make run-server`，编排器 + 接力 worker 服务在线，可经
   `http://100.64.0.27:10042` 访问（Tailscale IP —— Allen 远程，
   `feedback_remote_browser_ip`）。
2. **在 ESR Feishu 群里 seed + 绑定接力队伍**（每个群恰好一个绑定）：通过上面 8 个
   编排器工具调用搭建队伍（或物化一个已保存的 SessionTemplate），然后导出绑定：
   ```bash
   export SCENARIO_34_FEISHU_CHAT_ID=oc_xxxxxxxxxxxxxxxx   # 绑定的群 chat_id
   export SCENARIO_34_SESSION_URI=session://generic/<ws>/<relay-session>
   ```
3. **三种风味的 provider 凭据全部在线**：Anthropic（cc，经 proxy）、`codex login`
   （codex）、DeepSeek key（curl）。缺凭据是用户协助步骤，不能悄悄打桩蒙混
   （`feedback_esr_e2e_standards`）。
4. **从绑定群发一条真实 Feishu 消息**：`@传话游戏 苹果`。（程序化 dispatch /
   `send_cursor` 读取都不够 —— Standard 3 要求真实的入站 Feishu 消息。）
5. **运行受控 harness** —— 它轮询实况会话并断言已投递+经 `telephone_hop` 渲染的接力
   往返（预算内未到达即 flunk）：
   ```bash
   SCENARIO_34_LIVE=1 MIX_ENV=test mix test \
     apps/ezagent_domain_chat/test/e2e/scenario_34_sender_locked_relay_live_test.exs
   ```
   它读 `MessageStore.recent_in_session/2`（生产路径），监视经 `telephone_hop` 渲染的
   消息。可选地用 `SCENARIO_34_RELAY_CODEX_URI`（终跳 codex→curl 的发送者）收紧闸门。
   同时在 phx 日志确认：relay-cc → relay-codex → relay-curl 各自发出经 `telephone_hop`
   渲染的 `chat.receive`，每条回复向外镜像（`FeishuClient.send_text OK (code=0)`）。
6. **agent-browser 截图** 群会话，显示完整接力往返 —— 手动、agent 侧（Standard 3
   强制证据；harness 无法在测试进程内捕获）：
   ```bash
   agent-browser open  http://100.64.0.27:10042     # 或 Feishu 网页群
   agent-browser screenshot  /tmp/scenario34-relay-roundtrip.png
   ```

## 失败模式

- **slot 机制回归** —— 若 `add_agent_slot` / `write_matcher` 复活，接力将按
  slot 名而非成员路由，破坏 `@` 提及。由 `orchestrator_slot_retirement_test.exs`
  （PR-8）+ 层级 1 闸门 (c) 无 baton 结构检查覆盖。
- **由正文派生路由** —— 若某跳 matcher 改成 `text_contains(<令牌>)`，模型就在计算
  路由。层级 1 闸门 (c) 属性 1 对任何读正文的 matcher 失败。
- **`telephone_hop` 缺 `{body}`** —— 渲染器会丢弃原始消息。`define_prompt_template`
  在工具边界拒绝（`:body_placeholder_required`）。
- **legend 经 URI 路径误路由** —— CJK legend 名进入 `:mentions` 会让 `[URI.t()]`
  cast 崩溃；legend 改走虚拟 `legend_triggers`（层级 1 闸门 a）。

## 交叉引用

- 规格：`docs/superpowers/specs/2026-06-01-team-routing-unification.md` §4
  （示例）、§3.3（规则集）、§3.4（提示模板/path-A）、§3.6（legend）、§9（测试）。
  Plan PR-9。
- 组合 PR-2..PR-8 的路由原语：Resolver `resolve_with_ctx`、
  `Ezagent.Routing.Legend`、`Ezagent.Routing.Matcher` 的 `{:from,_}`/`{:mention,_}`、
  `Ezagent.Routing.PromptTemplate`、`Ezagent.Orchestrator.Tools` 的成员/规则集工具。
- 镜像场景 33（full-star，全风味），但由接力规则集 + legend 驱动，而非按风味的
  编排器 @ 提及。
- 标准：`feedback_esr_e2e_standards`（实况 Feishu 群同步，Standard 3）、
  `feedback_completion_requires_invariant_test`（无 baton 结构闸门）、
  `feedback_remote_browser_ip`（agent-browser 用 Tailscale IP）。
