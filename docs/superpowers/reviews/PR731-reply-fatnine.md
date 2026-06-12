@FatNine 谢谢详细的回复和纠正，逐一回应:

---

## 1. 架构澄清: Session + Behavior，不是最小修正

你说的对，需要澄清。我们 commit 到 v3 的设计文档(`docs/superpowers/specs/2026-06-10-autoservice-v2-design.md`)选定的架构是 **Session + CsOrchestrator Behavior**，不是"最小修正方案 A"。之前的回复和 merge-strategy 里有不一致的地方，已修正并推到 `autoservice-dev`。

**正确的架构**:
```
CsOrchestrator Behavior (use Ezagent.Lifecycle) on SocialwareSession Kind:
  - :receive → open turn → dispatch_after_commit fast+slow
  - agent reply → cs_orchestrator.receive → compose+settle
  - :operator_claim → cancel bot turn → reopen → compose → claim
  - :operator_settle → settle tracked turn
  - TurnDriver: 同进程 Turn 操作，不走 dispatch
  - State: cs_orchestrator namespace in Session slice
```

**对你的修正的回应**: 你说"cancel bot turn 在 dev 上是 no-op（没 bot turn）"——在当前 dev 代码上是对的，因为 bot reply 走 `chat.send` 无 Turn。但在 Behavior 方案下，bot reply **会走 Turn 生命周期**（cs_orchestrator.receive → compose → settle），所以 cancel+reopen 是完整适用的，不需要退化为 proactive-only。PR 的 cancel+reopen 全量移植是正确的。

---

## 2. 你的两个确认问题

**Q1: bot reply 非-Turn 路径是否保留 P22？**
当前 dev 路径: `chat.send → dispatch → Session → MessageStore`。MentionRouting 零匹配 → DLQ + telemetry。P22 由框架 ReadyGate/PendingDelivery/DLQ 保证，不需要 plugin 层额外处理。Behavor 方案下 bot reply 改走 Turn（cs_orchestrator.receive → compose → settle → customer_visible），P22 进一步由 `dispatch_after_commit` 加强（dead agent 不 abort turn commit）。

**Q2: CustomerFeed 50% + 双订阅是否是有意设计？**
是有意的防御设计。bot reply 走 `:chat_message` PubSub（无门控，立即可见），settled Turn 消息走 `:customer_delivery`（门控，仅 customer_visible）。消息 ID 去重防止双条。Behavior 方案下 bot reply 统一走 Turn → CustomerFeed，`chat_message` 订阅可以逐步移除。

---

## 3. api_key 冗余确认

已核实。dev `customer_session.ex:280` 的 `maybe_put_deepseek_key` 从 `opts[:deepseek_key]` 参数读 key，seed task 传 `System.get_env("DEEPSEEK_API_KEY")`。PR 的做法是直接在 provision 里读 env 并 dispatch `api_keys.put_api_key`。两条路径功能等价，P0 移植清单已标注"确认 dev 已有后决定是否冗余"。

---

## 4. 分工

这样分工:
- **你**: P0 核心 (CsOrchestrator Behavior + TurnDriver + Session spawn) — 你对 CsOrchestrator 的 Lifecycle 写法最熟
- **我们**: P1 移植 (TenantAdminLive, Assembly.Refresh, CR 恢复, 测试) — 改 content/cr plugin
- **pair review**: 各自写完互相 review

---

## 5. 文档

全部对比文档 + 设计文档 v3 + core-issues-tracker 已推到 GitHub:
- `autoservice-dev` 分支: https://github.com/ezagent42/ezagent/tree/autoservice-dev/docs/superpowers/
- `feat/autoservice-v2-merge` 合并分支已创建
