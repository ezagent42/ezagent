# F12 协调 note — 飞书 @ 解析成 agent mention（拆出单独跟进）

> **状态（2026-06-25 PM 终结）**：**F12「飞书 @ → agent 回复」能力已验证可用,无需新 mention-解析代码。** 方向 C（占位符桥接）已实现+测试后**收掉**（删分支 `feat/f12-feishu-mention-bridge`，tip SHA `057a0bb4`，reflog 可寻）。详见 §6。
> **来源**：F12 = 06-24 全流程验证发现的 high 级缺口（`docs/together/2026-06-24/evidence/blockers.md` 行 F12）。
> **owner（验证文档）**：@林懿伦（routing / mention 解析）+ @张宁（会话路由规则 UI）。
> **作者**：zyli（李震宇），2026-06-25 scoping + 收口。

## 0. 终结论（先读这段）

2026-06-25 下午用 world UI（F9 绑群）+ 真飞书群手测后,结论翻转:

1. **「飞书 @ 一个 agent → 它回复」的能力已经能用**,且**不靠新代码**——靠的是早就存在的 **text-grep**（Allen 2026-05-17，文字 `@<agent名>`）+ 本日交付的 **F9 绑群 UI** + **默认路由规则** `{:always}→[$session_users,$mentions]`。手测证据：`evidence/f12-feishu-@-agent.png`（飞书群）+ `evidence/f12-feishu-@agent-world-ui.png`（world 对话页），均为 **text-grep 路径**（操作员手打文字 `@r3-echo-pty-1`）。
2. **方向 C（占位符→文字桥接）经测无真实触发场景**:agent 在飞书无身份、不可被原生 @ 选中;bot 只是**全 app 的传输入口**（`system://credentials/feishu.yaml` 的 app_id/secret），不对应任何单个 agent。C 唯一作用是把存储文本里的 `@_user_N` 美化成可读名,**不影响路由**。→ **收掉**（已删分支）。
3. **真正可能还剩的口子（非 mention 解析,非本人范围）**:验证里 protocol-api session「无 `$mentions` 路由规则」。正常 session 靠全局默认规则即可（手测的 feishu-bing 就是,"ROUTING 0" 仍路由）。**某些 session 类型是否默认 seed 该规则** = 林懿伦/张宁的路由那半,作为独立线索移交,不在本 return。

下面 §1-§5 是当时的 scoping 记录（保留备查；方向 C 的代码面地图对将来若要做「装饰性占位符清理」仍有参考价值）。

## 1. 缺口复述

飞书 inbound 全链路到「消息进入绑定会话」均通（user 绑定 ✓ → chat→session 绑定 ✓ → `session.send` granted ✓ → 入库 ✓ → worker 订阅 ✓），但消息 `mentions: []`：飞书 @ 没被解析成指向 agent → 不路由 → 无回复。

## 2. 关键认知修正 —— 撞上一条 Allen 的已记录决策

**不是「完全没有解析」**。代码里已有 `EzagentPluginFeishu.MentionParser.extract_agent_mentions(text)`，从消息**文本**正则提取 `@<agent-name>` 并解析成 live agent URI（走 `KindRegistry`）。

`MentionParser` 的 moduledoc 白纸黑字记着 Allen 2026-05-17 的决策：

> **Why text-grep not lark mentioned_users** — lark 的 `mentioned_users` 字段带的是飞书 open_id，agent 没有飞书身份、映射不到 agent。所以**故意**用 `@<agent-name>` 文字约定。Allen 2026-05-17: "B2 路线可以,暂时只考虑文字"。

`mentions: []` 的真实原因：操作员用飞书**原生 @ 选人**，文本里留的是占位符 `@_user_1`（真实身份在 payload `message.mentions[]`），文字正则匹配不到 → 空。

⚠️ **因此「直接读 payload mentions 字段来解析 @」这条路 Allen 当初是显式否决过的。** 按 grill 文化不可擅自反转。

## 3. 三条互斥实现路径（已与产品方 zyli 过一轮）

| 路径 | 做法 | 与 Allen 决策的关系 |
|---|---|---|
| **A** | 直接读 payload `mentions[].id/name` → 映射 agent URI（可能需新 `feishu_agent_bindings` 表） | **反转** 2026-05-17 决策。最 robust 但必须 Allen 本人签字改 ARCHITECTURE Decision Log。 |
| **B** | 保持 text-grep 不动，修真正的闭环堵点 = 验证里那条 protocol-api 会话**无路由规则**（补默认 `{:always}→[$session_users,$mentions]` seeding） | 完全尊重决策。但不解决「原生 @ 选人」的占位符问题。 |
| **C ✅ 选定** | payload 带 mentions 时，把文本里的占位符 `@_user_N` 还原成被 @ 者的 `name`，再喂给现有 text-grep 解析 | 最小改动、最贴决策精神（agent URI 仍由文字解析做唯一权威，不引入 payload→agent 身份映射）。**仍是 spec 边缘的行为变更，合并前需 Allen 点头。** |

**zyli 选定方向 C**（2026-06-25 AskUserQuestion）。理由：让飞书原生 @ 真正可用，同时不触碰「Ezagent 是 agent URI 唯一权威 / 文字解析」的设计底座。

## 4. 实现 C 的代码面地图（Explore 已勘）

| 环节 | 文件 | 关键行 | C 路径要做什么 |
|---|---|---|---|
| webhook 入口 | `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/webhook_plug.ex` | `handle_event/2` 69-91 | 从 `msg["mentions"]` 取 payload mentions，传给下游 |
| WS 长连入口 | `EzagentPluginFeishu.WsClient`（与 webhook 共用 EventDecoder） | — | 同上，两个 transport 都要 |
| body 解码 | `event_decoder.ex` | `build_body/1` 37-105 | 现仅返回 `{text, attachments}`；C 路径需把 payload mentions 一并带出（或单独返回 `{text, attachments, raw_mentions}`） |
| 占位符还原 + 解析 | `mention_parser.ex` | `extract_agent_mentions/1` 62-79 | C 核心：用 payload mentions 的 `key`(`@_user_N`)→`name` 映射，把 text 里的占位符替换成 `@<name>`，再走现有正则 |
| inbound 派发 | `inbound_dispatcher.ex` | 88-89 | `mentions = MentionParser.extract_agent_mentions(text)` 改为先做占位符还原 |
| 消息结构 | `apps/ezagent_core/lib/ezagent/message.ex` | `mentions` 字段 16/68 | 无需改，已支持 |
| 路由消费 | `apps/ezagent_core/lib/ezagent/routing/resolver.ex` | `$mentions` 展开 353-376 | 无需改，mentions 填上就能路由 |

**注意 B 与 C 不互斥**：验证里那条 protocol-api 会话「无路由规则」是独立的第二个堵点（即便 mention 解析对了，会话没有 `$mentions` 的规则也不路由）。建议 F12 实现时**顺带确认默认规则 seeding**（`default_rules.ex` `seed_default_rule/0` `{:always}→[$session_users,$mentions]`）对 protocol-api 会话是否生效——这是 @张宁「会话路由规则」那半的接口面。

## 5. 测试基线（实现时需补）

- `mention_parser_test.exs`：现有覆盖纯文字 `@<name>`，**无** payload-mention 用例 → C 路径需加占位符还原用例。
- `event_decoder.ex`：加带 `mentions` 的 payload 解码用例。
- `category_04_feishu_test.exs`：`make_msg/1`(409-423) 现在 hard-code `mentions: []` → 加一条「原生 @ 选人 → 占位符还原 → 路由到 agent」的 e2e。

## 6. 下一步

1. 把方向 C 报给 Allen 拿一个明确「行为变更 OK」的签字（因为它改了 inbound 解析行为，虽不反转「文字权威」底座）。
2. 由 @林懿伦 在新分支 `feat/f12-feishu-mention-bridge`（或并入 routing 线）实现 C；@张宁 负责会话路由规则 UI / 默认规则 seeding 的那半。
3. F9（本分支）+ F10（配 key UI）+ F12 都好后，按 `docs/together/2026-06-24/returns/zyli-fullflow-validation-0624.md` §5 复跑「飞书群→agent 回复操作员闭环」。
