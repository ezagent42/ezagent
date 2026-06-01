# 团队路由统一 —— 规则集、Prompt 模板、Legend 与 Member-Provenance

**日期**：2026-06-01
**状态**：spec（设计原则上已由 Allen 在飞书确认；待书面 review + codex 对抗 review）
**取代**：orchestrator 私有的 `agent_slot` 机制（见 §6 Slot 退休）

## 1. 动机

搭建实时 `传话游戏` relay（cc → codex → curl，每棒追加一句，镜像到飞书群）暴露了四个问题，最终发现它们其实是**同一个纠缠在一起的设计缺口**：

1. **流程里的 agent 不知道自己在流程里。** 每个 worker 只看到上一棒的原始消息。cc 碰巧认出了触发词，codex/curl 只是"顺着聊"。让模型在消息体里自传播协议指令很脆弱——gpt-5.5 就把 剩余 的 pop 算错、跳过了一棒。角色上下文应该由**路由表**承载，而不是塞进消息让模型自己算。
2. **没地方挂这个上下文。** 当前一条路由规则只有 `matcher` + `receivers` + `enabled`，没有"该告诉 receiver 什么"的字段。
3. **`@`-mention 不对称。** `@` 一个普通 session **成员**会自动路由（系统默认规则 `always → [$session_users, $mentions]` + 成员过滤的 `$mentions` 魔法 token）。但 relay 的 worker 是 orchestrator 的 **slot worker**，故意不是成员，所以 `@` 根本到不了——消息没命中任何 worker 规则，静默消失。
4. **两套并行机制**（"slot worker" vs "session member"）做的其实是同一件事——一个 agent 参与一个 session——却有不同的管理、命名、快照、路由语义。

统一的洞察（Allen）：一个 "slot" 其实就是**带了三个额外 facet 的 member**；一个多 agent 流程其实就是**一组共享 prompt 模板的单 receiver 路由规则**，前面可以挂一个 **legend**（一个用户可见把手，折叠团队并触发其流程）。

## 2. 当前状态（基于代码，2026-06-01）

- **路由规则**（`Ezagent.Routing.RuleStore`，表 `MentionRouting`）：扁平行 `{matcher_data, receivers :: [String.t()], enabled, workspace_uri, source, created_by, …}`。`receivers` 已经是**列表**（支持多 receiver）。**没有"规则集/分组"概念**——relay 是 3 条独立行，仅靠"同一 session scope"关联。
- 规则上**没有 prompt/上下文字段**。
- **Slot worker**：`Orchestrator.Tools.add_agent_slot/write_matcher` 在 `template_working_copy.agent_slots` 记录命名 slot，在 orchestrator lineage 下（cap #2 `{:spawned_by, orch}`）spawn worker，按 slot 名路由。Slot worker **不是** session 成员。
- **Session 成员**：chat slice 的 `:members` 是 `{URI, %{online: bool}}`——**没有 provenance、没有 creator/owner、没有稳定 role-name 别名**。
- **SessionTemplate** 内容 = `{agent_slots, routing_rules, orchestrator_template_uri, default_workspace_uri}`（version-hash）。**成员不进快照**——由 `create_session/3` 在运行时 join。

所以今天"slot 的三个能力"（lineage 受限管理、稳定 name→URI、模板快照）只长在 slot 上；成员一个都没有。下面的设计把这些能力移到成员上，并让 slot 退休。

## 3. 设计

### 3.1 Member 长出三个 facet

session 成员变成 `{URI, meta}`，`meta` 在现有 `online` 之外携带：

- **`provenance`** —— 创建/拥有该成员的 principal 的 URI（一个用户，或一个 orchestrator agent）。**通用**，不限于 orchestrator。它的**单一职责是管理授权**：谁可以重配/删除这个成员，**以及编辑引用它的 routing rows**。一个 cap `{:manages, provenance_uri}`（泛化 slot 的 `{:spawned_by, orch}`）授权这两件事。orchestrator worker 就是 provenance 为该 orchestrator 的成员。

  > "一个 agent 回给谁" **不是** member facet，而是纯**路由**（Allen 2026-06-01）："只回 owner" = 一条规则 `from(agent) → [owner]`；"只处理 owner 的消息" = 该 agent 只在 matcher 为 `from(owner)` 的规则里当 receiver。上面的管理授权管住谁能编辑这些行，所以 owner 直接在路由表上控制 agent 的受众——**不需要单独的 audience 字段**（避免重复机制）。私有 agent "只回 owner" 的默认，也只是建 agent 时默认配一条 owner-only 路由规则，而不是一个字段。

- **`role_name`**（可选）—— 一个稳定的、对人友好的别名（如 `"relay-cc"`），与 agent 的 URI 解耦。路由规则和 legend 可以按 `role_name` 指向成员；`role_name → 当前 URI` 的绑定在重启后保持（URI 可能变，role-name 不变）。这就是 slot 的稳定命名能力，挪到了成员上。
- **`in_template`**（bool，默认 false）—— 该成员是否进 SessionTemplate 快照（见 §3.5）。让模板能携带"这个团队的成员"以及它的规则。

provenance 为某 principal、无 `role_name`/`in_template` = 一个普通成员（今天的行为）。完全向后兼容。

### 3.2 规则集 Rule-Set

**规则集**是一组命名、有序的路由规则，构成一个逻辑流程。性质：

- 集内每条规则**恰好一个 receiver**（一个成员 URI 或 `role_name`）。（多 receiver 扇出用多条规则、或一条专门的广播规则表达——见 §3.4 (B)。）这消除了"一规则多 receiver"的歧义。
- 集内规则可**共享一个命名 prompt 模板**（§3.3）——"多规则、一模板"取代"一规则、多 receiver + 一注入"。
- 集有一个可选的 **entry** 规则（legend 的 `@`-触发所触发的规则）。
- 机制上：在路由规则行加一个可空的 `rule_set`（名字）+ `position`，以及一个可空的 `prompt_template_ref`。"集"就是某 session scope 内共享同一 `rule_set` 名的行。（v1 不需要新表；若约定不够，后续可加 `rule_sets` 元数据行管 entry/排序。）

### 3.3 Prompt 模板

一个**命名、可复用**的模板，套用到投递给某规则 receiver 的消息上：

- **模板化**（Allen ①+②）：支持占位符 `{sender}`、`{flavor}`、`{body}`、`{session}`（可扩展）。**v1 引擎刻意保持简单**——对一组固定、有文档的变量做扁平的 `String.replace/3` 式替换；**不**做条件/循环/partial 这类语言。`{body}` **必须**出现（在写模板时校验），保证原消息绝不被静默丢弃。
- **命名 + 共享**：模板按名字被规则引用，所以整个规则集的各棒可复用同一个"你在 <flow> 里，追加一句简短的话"模板。（存储：session 的 working copy / template 里一个 `prompt_templates` map，按名字索引，session 内可复用。）
- **作用域 = 所有 session 成员**（Allen ⑤）：注入作用于**每一个成员 receiver**——像邮件转发的页脚——不只 agent。（理由：人类队友也可能受益于"[经 <flow> 转发]"这种上下文；而且"只对 agent"是个不必要的特例。）Resolver/投递路径按 receiver 把命中规则的模板套到投递 payload 上。

### 3.4 Legend

**Legend** 是团队/流程的用户可见把手：

- 形态：`{name, member_set（它折叠的 URI/role_name）, bound_rule_set, fold: bool}`。
- **UI**：折叠 legend 下的成员在成员列表里收进单个 legend 条目（解决"100 个 agent 把列表搞乱"——Allen）。它们仍是一等成员（可单独 `@`、可快照、可被路由 scope）。
- **`@legend` 语义**（Allen A/B —— 选定默认 A）：
  - **(A) 默认** —— `@legend` 触发该 legend 的**绑定规则集**（触发其 entry 规则；如 `@传话游戏` → entry → 链式跑）。
  - **(B) 特例** —— 一个规则集可以是纯广播（entry 规则扇出全体成员）；那只是规则集的一种，不是单独机制。
- legend 本身是一个路由目标：`@legend` 通过规则 `mention(legend) → entry` 解析。legend 是 session 内的；v1 不支持嵌套。

### 3.5 模板快照纳入成员

`SessionTemplate` 内容新增一个 `members` 列表（`in_template: true` 的那些），与 `agent_slots`（移除——见 §6）、`routing_rules`（现含 `rule_set`/`prompt_template_ref` 字段）、一个 `prompt_templates` map、`legends` 并列。于是模板捕获整个团队：谁在里面、怎么路由、每棒拿什么角色上下文、前面挂哪个 legend——通过 fork/instantiate 复用。（version-hash 扩展覆盖新字段。）

## 4. 实例 —— 传话游戏在新模型里

- 一个 **legend** `传话游戏`，`member_set = [relay-cc, relay-codex, relay-curl]`（按 `role_name`），`fold: true`，`bound_rule_set: "telephone"`。
- 三个**成员**（relay agent），各自 `provenance = <创建者>`、一个 `role_name`、`in_template: true`。
- 一个**规则集** `telephone`：
  - entry：`mention(传话游戏) → relay-cc`
  - `from(relay-cc) → relay-codex`
  - `from(relay-codex) → relay-curl`
  - 三条规则共享 **prompt 模板** `telephone_hop`：`"你在玩传话接龙。下面是目前的内容：\n{body}\n请只追加一句简短的话。"`
- 用户 `@传话游戏`（默认 A）→ 触发 entry → cc 拿到消息 + `telephone_hop` 上下文 → 回复 → 路由给 codex → … → curl。每个 agent 也能单独 `@`（它们是成员）。整个 legend + 规则集 + 模板可快照成 SessionTemplate 复用。

对比今天：3 个临时 slot worker + 3 条手写 sender 规则 + 一个模型自算的 baton 协议（在最弱的模型那里就崩了）。

## 5. 已定决策

| # | 决策 | 选择 |
|---|------|------|
| ① / ② | 注入形态 + 静态/模板 | **模板化**，占位符 `{sender}/{flavor}/{body}/{session}`；v1 引擎刻意简单（扁平替换，`{body}` 必填） |
| ③ / ④ | 多 receiver / 多规则 | **单 receiver 规则的规则集**；规则**共享命名模板**；无一规则多 receiver、无拼接歧义 |
| ⑤ | 注入作用域 | **所有 session 成员**（邮件页脚模型），非仅 agent |
| A/B | `@legend` 语义 | **A**（触发绑定规则集）为默认；**B**（广播）= 规则集的一种 |
| — | provenance | **通用 member facet，单一职责**：对成员 + 其 routing rows 的管理授权；"回给谁"是纯路由（非 facet）；slot 的 `spawned_by` 是 orchestrator 特例 |

## 6. Slot 退休

`Orchestrator.Tools` 的 `add_agent_slot` / `remove_agent_slot` / `write_matcher` / slot 名路由 收敛为：

- **加一个 `provenance = <orchestrator>` 的成员**（+ 可选 `role_name`、`in_template`）——通过泛化的 `{:manages, provenance}` cap 获得同样的 lineage 受限授权。
- **定义规则集规则**，按 `role_name` 指向成员。

这去掉了 slot↔member 重复、以及 `@`-mention 不对称（orchestrator worker 现在是成员）。`remove_agent_slot` 静默删规则的坑（todo，已被 PR #519 部分缓解）被吸收：规则集给了一个明确的增删单元，成员移除对规则集的影响会被报告。

注：`add_agent_slot` 现有的 `prompt_override` 参数（目前是 no-op 占位）被规则集 prompt 模板机制取代。

## 7. 迁移 / 向后兼容

- 成员默认 `provenance: nil`（或 session owner）、无 `role_name`、`in_template: false` → 与今天一致。
- 现有扁平规则 `rule_set: nil`、`prompt_template_ref: nil` → 行为如今（不套模板）。
- 系统默认 `always → [$session_users, $mentions]` 规则不变；`$mentions` 成员过滤不变。
- 现有 SessionTemplate（无 `members`/`prompt_templates`/`legends` 键）加载时这些默认为空。
- orchestrator slot：提供一次性 shim，在过渡期把现有 `agent_slots` 读成 members-with-provenance；或直接 clean cutover（长期不留 live slot）。在实现计划里定。

## 8. 不在本期范围（v2+）

- 富模板语言（条件/循环/partial）—— v1 是扁平替换。
- 嵌套 legend；跨 session legend。
- 专门的 `rule_sets` 表 + 一等 entry/排序元数据（v1 用 `rule_set` 名 + `position` 列 + 约定）。
- 更广的"消息没命中任何 worker → 静默默认 fan-out"可观测性缺口（todo #9 第二层）——相关但单独追踪；本 spec 缩小了它的影响面（成员 + `$mentions` 覆盖常见情况）。

## 9. 待 review 的 open question

1. **模板存储**：session working copy/template 上的 `prompt_templates` map（建议）vs workspace 级命名模板注册表（复用更广、面更大）。v1 = session 内 map；若要 workspace 复用请指出。
2. **role_name 唯一性/作用域**：session 内唯一？legend 内唯一？（建议：session 内。）
3. **`{:manages, provenance}` 对 routing rows 的作用域**：确认管理 cap 恰好授权编辑引用被管成员的那些 routing rows——这是"owner 直接在路由表上控制 agent 受众"的机制。
4. 现有 slot 的 **cutover vs shim**（§7）。
5. **`{:manages, provenance}` 的 cap 形态** —— 是否与待办的 capability action-axis 工作组合（另一条 todo），还是先独立落？

## 10. 测试 / 验证（实现计划里展开）

- Resolver 单测：规则集单 receiver 路由；prompt 模板套用（占位符、`{body}` 必填校验）；legend `@`-触发 → entry。
- Member-facet 测试：provenance 管理 cap 授权"成员 + 其 routing rows"（并拒绝非 owner）；"只回 owner"纯用路由规则表达、路由正确；role_name → URI 重启重绑；`in_template` 快照往返。
- 不变量门（按 `feedback_completion_requires_invariant_test`）：一个测试，当 slot 式机制重新出现、或一个规则集流程需要模型自算路由时**失败**。**live 层**仍是绑定飞书群里的 传话游戏 往返（真 cc/codex/curl），现在纯用 legend + 规则集 + 模板表达（无 baton）。
