# 团队路由统一 —— 规则集、Prompt 模板、Legend 与 Member-Provenance

**日期**：2026-06-01
**状态**：spec **rev 2** —— 纳入 codex 对抗 review（1 CRITICAL + 4 HIGH + 若干 MED）与 Allen 的设计决策。待最终 review → writing-plans。
**取代**：orchestrator 私有的 `agent_slot` 机制（clean cutover，§3.8）。

## 1. 动机

搭建实时 `传话游戏` relay（cc → codex → curl，每棒追加一句，镜像到飞书群）暴露了四个问题，它们其实是**同一个纠缠的设计缺口**：

1. **流程里的 agent 不知道自己在流程里。** worker 只看到上一棒的原始消息。让模型在消息体里自传播协议很脆弱——gpt-5.5 把 pop 算错跳了一棒。角色上下文应由**路由表**承载，不是塞进消息。
2. **没地方挂这个上下文**——规则只有 `matcher` + `receivers` + `enabled`，没有"该告诉 receiver 什么"。
3. **`@`-mention 不对称**——对 session **成员**自动通（默认 `always → [$session_users, $mentions]` + 成员过滤的 `$mentions`），但 relay 的 **slot worker** 不是成员，`@` 静默消失。
4. **两套并行机制**（"slot worker" vs "session member"）做同一件事。

统一洞察（Allen）：一个 "slot" 就是**带额外 facet 的 member**；一个多 agent 流程就是**一组共享 prompt 模板的单 receiver 规则**，前面可挂一个 **legend**（折叠团队并触发其流程的用户把手）。

## 2. 当前状态（基于代码，codex 已确认）

- **路由规则**（`RuleStore`，表 `MentionRouting`）：扁平行 `{matcher_data, receivers :: [String.t()], enabled, workspace_uri, source, created_by, applies_to_users}`。**没有 `rule_set`/`position`/`prompt_template_ref`**、无分组。`Behavior.Routing.add_rule` 只收 `{table, matcher_json, receivers}`，**不** enforce 单 receiver。
- **`Resolver.resolve/4` 只返回 `[URI.t()]`**（`resolver.ex:158/163/188`）；`query_table/3` 把 `{matcher, value}` 塌成 `receivers_of(value)`。**没有调用方知道命中了哪条规则**——prompt 注入的承重缺口。
- **投递**：`Behavior.Chat.handle_send/2` 遍历 recipients；`dispatch_receive_call/3` 传未改的 `%Message{}`。agent 投递（`AgentBridge`）构造 payload 文本（天然注入点）；**user 收消息那条只存 message id**（`chat.ex:526/567/573/585`），可见正文是共享的持久化消息，**不是** per-recipient 渲染。
- **Slot worker**：`template_working_copy.agent_slots` 存 `{slot_name, source_agent_template_uri, live_worker_uri, generation}`（`chat.ex:367/373`）。`update_agent_template`/回滚/重生依赖 **source-template URI + live-worker URI + generation 计数**（`tools.ex:192/647/747`、`agent.ex:272`）。Slot worker 不是成员。
- **Session 成员**：`:members` = `{URI, %{online: bool}}`——无 provenance、无 creator/owner、无 role-name 别名。
- **mention 是具体 URI**：`Matcher.mention/1` 匹配 `message.mentions` 里的字符串（`matcher.ex:142`）；LiveView/Feishu 裸 mention 对着活成员/agent URI 解析。**没有 session 内的符号把手**。
- **SessionTemplate** 内容 = `{agent_slots, routing_rules, orchestrator_template_uri, default_workspace_uri}`（version-hash）。**成员不进模板**；`create_session/3` 只 join `[effective_owner, orchestrator_uri]`（`ezagent_domain_chat.ex:512/604`）。
- **`Ezagent.Message` 是普通值 struct**——不是 Kind，无 lifecycle/hook。
- **Capability action-axis 已实现合并**——`Capability` 有 `:action`（默认 `:any`），`matches?/2` 把它当第 5 维（PR #503/#426）。（rev-1 误写成 pending。）

## 3. 设计

### 3.1 Member facet（吸收 slot）

成员变成 `{URI, meta}`，`meta` 除 `online` 外携带：

- **`provenance`** —— 创建/拥有该成员的 principal URI（用户或 orchestrator agent）。通用。**单一职责：管理授权**——谁能重配/删除该成员，以及编辑引用它的 routing rows。cap `{:manages, provenance_uri}` 用 **action `:manage`**（用*现有*的 action-axis）授权。orchestrator worker = provenance 为该 orchestrator 的成员。
  > "agent 回给谁"不是 facet，是路由："只回 owner" = 规则 `from(agent) → [owner]`；管理授权管住谁能编辑这些行。私有 agent 的默认 = 建时配一条 owner-only 路由规则。（动态情形如"回给刚 @ 我的人"用新的 `$sender` 变量——§3.2。）
- **`role_name`**（可选）—— 稳定别名（如 `"relay-cc"`），与 URI 解耦。规则/legend 按 role_name 指向成员；`role_name → 当前 URI` 重启后保持。（slot 的稳定命名能力。）
- **`in_session_template`**（bool，默认 false）—— 该成员是否进 **SessionTemplate** 快照（§3.7）。模板实例化/fork 时 `true` 的被重建，`false` 的只是运行时。（relay 团队 = true；临时访客 = false。）（rev-1 的 `in_template` 改名，更清楚是哪个 template。）
- **Spawn-source 状态**（spawn/受管成员才有——codex HIGH）：`source_template_uri`、`live_worker_uri`、`generation`。这是旧 `agent_slots` tuple 携带的状态；member 模型**必须**携带它，否则 member 级的 `update_agent_template`（起新 generation、repoint 路由、终止旧 worker）、回滚、持久化、无冲突重生都做不了。普通用户邀请的成员这些为 nil。

provenance 普通、无 role_name、无 spawn-state、`in_session_template: false` = 今天的普通成员。向后兼容。

### 3.2 动态 matcher / 模板变量（新增——Allen #1，codex MED）

matcher 代数（`from/text_contains/mention/in_session/and/or/not`）+ 收件魔法 token（`$session_members/$session_users/$mentions`）表达不了**动态受众**（"回给刚 @ 我的人"），也喂不了动态模板。新增：

- **`$sender`** 收件 token —— 展开为命中消息的 sender（像其它魔法 token 一样成员过滤）。让"回给上一棒 sender"纯走路由。
- **模板变量**，源自命中消息 + receiver：`{sender}`、`{flavor}`、`{body}`、`{session}`、`{sent_at}`。v1 变量集固定 + 有文档，后续可扩展。（无 `$self` 自环：`$sender` 排除 receiver 自身，fail-closed，避免 agent 回自己。）

### 3.3 规则集（schema + API 改动——codex HIGH）

**规则集**是一组命名、有序的单 receiver 规则，构成一个流程。在扁平 schema 上不是免费的，需要：

- `routing_rules` **新增列**：`rule_set`（名，可空）、`position`（int）、`prompt_template_ref`（名，可空）。
- **`Behavior.Routing.add_rule` 增加** `rule_set`/`position`/`prompt_template_ref` 参数，且当 `rule_set` 设了时 **enforce 单 receiver**（多 receiver 扇出 = 显式广播规则，§3.6 B）。
- **`RuleStore.load_into_registry/1` + `Resolver`** 发布并携带 `prompt_template_ref`（及规则身份）进 match 结果——见 §3.5。
- 集的可选 **entry** 规则（legend `@`-触发所触发）。
- 现有扁平规则新列全 nil → 行为不变。

### 3.4 Prompt 模板 + 投递变换 —— **路径 A**（Allen）

一个**命名、可复用**的模板，渲染到投递给某规则 receiver 的消息上。**v1 = 路径 A：零新抽象。** 在*现有的*逐 recipient 投递步上，投递代码用命中规则的模板调一个 render 函数（有就套）：

```
render_for_recipient(message, recipient, matched_rule_ctx) :: rendered
```

- **模板化**（Allen ①+②）：占位符见 §3.2；引擎刻意简单（对固定变量集做扁平替换）；`{body}` 必须出现（写模板时校验）保证原文不丢。
- **命名 + 共享**：规则按名引用模板（`prompt_template_ref`）；整个规则集复用一个模板。存储：session 内 `prompt_templates` map（open question §8.1：以后可上 workspace 级注册表）。
- **两个投递站点、全体成员**（Allen ⑤）：agent 投递渲染进 payload 文本；**人类投递渲染成显示/渲染时的后缀**（不 per-recipient 入库——化解 codex MED-2）。所以"全体成员"成立、无需 per-recipient 存储。
- **不是 hook 系统。** 一个可注册/排序/插拔的投递 hook 子系统（称 "B"）**是**新抽象，**显式推迟**（§7）。v1 把 render 写成**一个函数**放在接缝上，将来真出现第二种变换（页脚/脱敏）再上 B——YAGNI。

### 3.5 Matched-rule 穿透（CRITICAL——codex）

prompt 注入是 per-flow/per-rule 的（"你在传话游戏里"绑在命中规则上、不绑 receiver），所以投递变换**必须**知道命中了哪条规则。现在 `Resolver.resolve/4` 返回裸 `[URI]`、fan-out 丢了规则。需要改：

- `Resolver.resolve` 返回 **`[{recipient_uri, matched_rule_ctx}]`**（或 recipient→ctx map），`matched_rule_ctx` 至少带 `prompt_template_ref` + 规则 id。向后兼容：一个薄 helper 给不需要 ctx 的调用方返回旧的 `[URI]`。
- `Behavior.Chat.handle_send/2` fan-out + `dispatch_receive_call/3` 把 `matched_rule_ctx` 穿到逐 recipient 投递，由它调 `render_for_recipient/3`（§3.4）。
- 两条规则投同一 recipient：规则集/单 receiver 模型（§3.3）让这很少见；真发生时 `position` 高（或第一条）的模板胜（确定性、有文档）。v1 不拼接。

### 3.6 Legend + 单独解析层（codex HIGH）

**Legend** = `{name, member_set（URI/role_name）, bound_rule_set, fold: bool}`。

- **UI**：折叠 legend 的成员收进单个 legend 条目（去乱——Allen）。它们仍是一等成员（可单独 `@`、可快照）。
- **`@legend` 语义**：**(A) 默认**——触发绑定规则集的 entry 规则。**(B)**——规则集可以是纯广播（entry 扇出全体）：只是规则集的一种，不是单独机制。
- **解析层（非裸 mention）**：legend 是 session 内的*符号把手*、不是 member/agent URI，所以**不能**走 `Matcher.mention/1`（它匹配具体 URI），否则静默丢/投错。引入一个 **legend 注册表**（session 内 `name → {member_set, bound_rule_set}`）；mention 解析器（LiveView + Feishu）在走 URI-mention 路径**之前**，先把 legend 名解析成"触发它的 entry 规则"。legend 是 session 内的；不支持嵌套（v1）。

### 3.7 SessionTemplate + create_session 物化（codex HIGH）

`SessionTemplate` 内容新增 `members`（`in_session_template: true` 的）、`prompt_templates`（命名 map）、`legends`；`agent_slots` 移除（§3.8）。version-hash 扩展覆盖新字段（write-once/hash-checked 的 `Behavior.Template` 能容纳新字段）。**但实例化路径必须改**：现在 `create_session/3` 只 join `[owner, orchestrator]`——它**必须物化模板的 `members`**（从 `source_template_uri` 重建 spawn 成员、登记 provenance/role_name、装上规则集 + prompt_templates + legends），实例化/fork 出来的团队才真出现。这是 codex 指出的承重契约改动。

### 3.8 Slot 退休——clean cutover（Allen：不做向后兼容）

`Orchestrator.Tools` 的 `add_agent_slot`/`remove_agent_slot`/`update_agent_template`/`write_matcher(receiver_slot_names)` 及 slot 名路由**移除**，替换为：

- **加成员** `provenance = <orchestrator>`（+ `role_name`、`in_session_template`、spawn-source 状态）——通过 `{:manages, provenance}`（action `:manage`）获得 lineage 受限授权。
- **定义规则集规则**，按 `role_name` 指向成员，带 `prompt_template_ref`。

orchestrator MCP 工具面**重写**成这些 member+规则集工具（clean cutover——现有 orchestrator 重新接线；这是有意的破坏性改动，不是 nil 默认）。现有 SessionTemplate 残留的 `agent_slots` 直接弃用（dev 环境，无生产模板要保）。退休的 `prompt_override` no-op 参数被 `prompt_template_ref` 取代。`remove_agent_slot` 静默删规则的坑（PR #519 可观测性）被吸收：规则集是显式增删单元，成员移除会报告其对规则集的影响。

## 4. 实例 —— 传话游戏

- **Legend** `传话游戏`：`member_set = [relay-cc, relay-codex, relay-curl]`（按 role_name），`fold: true`，`bound_rule_set: "telephone"`。
- **成员**（relay agent）：`provenance = <创建者>`、role_name、spawn-source 状态（模板/generation）、`in_session_template: true`。
- **规则集 `telephone`**（各单 receiver、共享模板 `telephone_hop`）：entry `mention(传话游戏) → relay-cc`；`from(relay-cc) → relay-codex`；`from(relay-codex) → relay-curl`。
- `telephone_hop` = `"你在玩传话接龙。目前内容：\n{body}\n请只追加一句简短的话。"`。
- 用户 `@传话游戏` → legend 注册表解析 → entry 规则触发 → cc 收到被 `telephone_hop` 渲染的消息 → 回复 → 路由给 codex → … → curl。agent 是成员（可单独 `@`）；legend+规则集+模板+成员可快照成 SessionTemplate 复用。
- **user→user 页脚**（同一套机制）：规则 `always (from $user) → $session_users` + 模板 `"{body}\n\n（该消息由 {sender} 于 {sent_at} 发送）"`——agent 在 payload 里拿到、人类看到的是渲染时后缀。

## 5. 已定决策

| # | 决策 | 选择 |
|---|------|------|
| ①/② | 注入形态 + 静态/模板 | **模板化**，变量 `{sender}/{flavor}/{body}/{session}/{sent_at}`；v1 引擎扁平替换、`{body}` 必填 |
| ③/④ | 多 receiver / 多规则 | **单 receiver 规则的规则集**，共享**命名**模板；需 schema/API 改动（§3.3） |
| ⑤ | 注入作用域 | **全体成员**，两个投递站点（agent payload / 人类渲染后缀） |
| A/B | `@legend` | **A**（触发规则集）默认；**B**（广播）= 规则集的一种 |
| dyn | 动态受众/变量 | **加 `$sender` token + 模板变量**（§3.2） |
| transform | 投递机制 | **路径 A**（现有投递接缝上 render、写成单函数）；**hook 子系统 B 推迟** |
| provenance | 作用域 | **通用 member facet，单一职责** = 对成员 + 其 routing rows 的管理授权；用现有 action-axis（`:manage`） |
| slots | 迁移 | **Clean cutover**，不做向后兼容；MCP 工具重写 |

## 6. 迁移 / cutover

Clean cutover（Allen）。新 member 字段默认 nil/false → 普通成员行为如今。现有扁平规则（新列 nil）不变。系统默认 `always → [$session_users, $mentions]` + `$mentions` 过滤不变。旧 SessionTemplate 加载时新字段为空；残留 `agent_slots` 弃用。orchestrator MCP 工具面被替换（有意破坏性改动——无生产 orchestrator 要保）。

## 7. 不在本期范围（v2+）

- **投递 hook 子系统（B）**——可注册/排序/插拔的变换。v1 只在接缝上放一个 render 函数；B 是显式 future（Allen 的 Claude-Code-hooks 方向）。
- 富模板语言（条件/循环/partial）——v1 扁平替换。
- 嵌套 / 跨 session legend。
- workspace 级共享模板注册表（v1 = session 内 map）。
- 更广的"消息没命中 worker → 静默默认 fan-out"可观测性缺口（todo #9 第二层）——这里影响面缩小，单独追踪。

## 8. 已定决策（Allen 2026-06-01 确认按建议）

1. **模板存储** → v1 用 **session 内 `prompt_templates` map**。workspace 级共享注册表是 future（§7），不进 v1。
2. **role_name 唯一性/作用域** → **session 内唯一**。
3. **`{:manages, provenance}` 对 routing rows** → **复用现有 capability 机制**（`Ezagent.CapabilityRegistry` + `Kind.holds_cap?` → `Identity.list_caps_for/1` → `Capability.matches?/2`，带 action 维）。不新造机制。只新增：(a) 在相关 Behavior 上声明 `:manage` action；(b) routing-row 编辑 action 对 `{:manages, provenance}`（scoped 到受影响成员的 provenance）做 cap-check。
4. **Spawn-source 状态放哪** → **member `meta` 字段**（provenance / role_name / in_session_template / source_template_uri / live_worker_uri / generation）。若实践中 chat slice 变重，旁表（按 member URI 索引）作为 fallback（plan 里按实测定）。
5. **Resolver 返回形态**（§3.5）→ 实现计划里审计调用方后定；默认 **recipient→ctx map** + 一个向后兼容的 `[URI]` helper，取对现有 `resolve/4` 调用方扰动最小的。

## 9. 测试 / 验证

- **Resolver/matcher**：规则集单 receiver 路由；`$sender` 展开（排除自身、成员过滤）；matched-rule ctx 被返回 + 穿透。
- **投递变换**：模板渲染（占位符、`{body}` 必填校验）；agent payload 站点；人类渲染后缀站点；两规则同 recipient 的确定性。
- **Member facet**：`{:manages, provenance}`（action `:manage`）授权"成员 + 其 routing rows"、拒绝非 owner；"只回 owner"纯用路由规则表达、路由正确；role_name → URI 重启重绑；spawn-source/generation 在 update/回滚/重生的往返；`in_session_template` 快照 + **create_session 物化**往返（实例化模板 → 团队真出现）。
- **Legend**：`@legend` 经注册表解析 → entry 规则触发；legend 名不会从 URI-mention 路径投错。
- **不变量门**（`feedback_completion_requires_invariant_test`）：当 slot 式机制重现、或规则集流程需要模型自算路由时**失败**的测试。
- **Scenario 34（Allen）**：live 层——绑定飞书群里的 传话游戏 往返（真 cc/codex/curl），纯用 legend + 规则集 + 模板表达（无 baton）——**必须 e2e 通过**，且全套必须**无功能回归**（cutover 动了 Resolver/Chat/RuleStore/templates/orchestrator-tools，现有 routing/mention/chat/orchestrator e2e 场景必须保持绿）。
