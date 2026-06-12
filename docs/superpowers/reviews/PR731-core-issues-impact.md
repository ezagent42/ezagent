# PR #731 Core 问题在新方案下的影响分析

> 日期: 2026-06-12
> 背景: PR #731 Live E2E 发现 3 个 core/domain 层问题，分析"保留 autoservice-dev 架构 + 采纳 PR #731 优点"方案下这些问题的状态

---

## 问题 1: SocialwareSession vs chat Session 共用 kind_type "session"

### 原问题

Dormant CS session cold-load 时，`SpawnRegistry` 的通用 "session" handler 将其 spawn 为 **plain Session** (有 Chat 没 Turn)。后续 `turn.open` → `{:unknown_action, :open}`。

PR #731 的 workaround: `Assembly.ensure_socialware_session/2` 显式 spawn `SocialwareSession`。

### 新方案下是否存在？

**✅ 同样存在，且影响更大。**

autoservice-dev 的 `CustomerSession.ensure_session/3` 当前 spawn 的是:

```elixir
# apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/customer_session.ex:399
Ezagent.Kind.spawn(Ezagent.Entity.Session, %{uri: session_uri, owner_uri: owner_uri})
```

这是 **plain Session**，不是 SocialwareSession。

当前 operator 接管用 synthetic turn_id (`:erlang.unique_integer`)，`turn.claim` dispatch 到这个 plain Session。**因为 turn_id 不存在，Turn 操作实际上静默失败了** — 所以没人注意到 Session 没有 Turn Behavior。但如果按方案 A (最小修正) 修复 operator 接管为真实 Turn 操作:

```elixir
TurnAdapter.open_turn(session_uri, trigger)  # → session?action=turn.open
```

这个 dispatch 会到达 plain Session → plain Session 没有 Turn Behavior → `{:unknown_action, :open}`。

**结论**: 修复 operator 接管 = 必须用 SocialwareSession。跟 PR #731 遇到的是同一个问题。

### 新方案下的处理

**选项 A (短期 — plugin 侧兜底)**: 将 `CustomerSession.ensure_session/3` 改为 spawn `SocialwareSession`（如果存在）:

```elixir
# 改: Ezagent.Entity.Session → Ezagent.Entity.SocialwareSession
# 或: 跟 PR #731 一样，Assembly.ensure_socialware_session/2
Ezagent.Kind.spawn(Ezagent.Entity.SocialwareSession, %{uri: session_uri, owner_uri: owner_uri})
```

**选项 B (长期 — Allen 修 substrate)**: distinct kind_type ("session" vs "socialware_session")，SpawnRegistry 根据 snapshot 选正确的 Kind。这是 PR #731 建议的正解。

**影响评估**: ⚠️ 中等 — plugin 侧可以兜底，但跟 PR #731 一样是 workaround。

---

## 问题 2: AgentFlavorAttributes 非持久 ETS

### 原问题

`AgentFlavorAttributes` 是 ETS 表（非持久），重启后 flavor tag 丢失。Cold-load resolver 的 flavor 步返回 `:none` → dispatch `:no_such_actor`。cc/curl agent 不受影响（kind_type 走 resolver 的 durable-snapshot 第一步）。

PR #731 的 workaround: `after_boot/0` 从 durable snapshot index 重 hydrated flavor cache。

### 新方案下是否存在？

**✅ 不存在。完全避开。**

因为:
1. 新方案不引入 `CsOrchestrator` Kind（无 agent-flavor Kind）
2. Fast agent (curl) 和 slow agent (cc) 是标准 agent-flavor Kind，它们的 kind_type 走 resolver 的 durable-snapshot 第一步 → 不受影响（PR #731 也确认了这一点）
3. 编排逻辑不在独立 Kind 中 → 不需要 flavor tag

**结论**: 这是采纳 autoservice-dev 架构（不引入 orchestrator Kind）的直接收益之一。after_boot hack 完全不需要。

---

## 问题 3: #730 producer gap

### 原问题

cc harness 的 spawn_plan 读 model/endpoint，但 `template_data_extra` 没有 producer 把它们填进去。effort 走 default ("low") 能用。curl 的 `already_registered` 在 re-provision 时刷 benign warning。

### 新方案下是否存在？

**✅ 同样存在，但与架构选择无关。**

这是 framework/tooling 层面的问题:
- cc agent 的 model/endpoint 配置需要 producer 填入 `template_data_extra`
- 跟用 CsOrchestrator Kind 还是 Session + MentionRouting 无关
- 两种方案都需要 cc agent provision，都面临同样的问题

PR #731 的做法: slow agent 的 model config 通过 agents.yaml 尝试传入 `create_agent`，但 `coerce_create_args/1` 只读 5 个已知 key → model/endpoint/effort 被 drop。PR 记录了 CONCERN 留待后续修复。

autoservice-dev 的做法: 同样是 `Workspace.create_agent` → model config 也存在传入问题。

**影响评估**: ⚠️ 低 — effort default "low" 可用，model/endpoint 需要 framework 侧修。两种方案都受影响的非阻塞问题。

---

## 总结

| 问题 | 新方案下存在? | 影响 | 处理 |
|---|---|---|---|
| #1 Session kind_type | ✅ 存在 | 修复 operator 接管必须解决 | 短期: 改 spawn SocialwareSession；长期: Allen 修 substrate |
| #2 Flavor cache | ✅ **不存在** | 零 | 不引入 orchestrator Kind = 自动避开 |
| #3 Producer gap | ✅ 存在 | 低 (effort default 可用) | 与架构无关，等 framework 修 |

### 关键结论

**采纳 autoservice-dev 架构直接消除了问题 #2**（最棘手的一个 — 需要 after_boot hack 且 Allen 建议放 core）。

**问题 #1 需要处理但比 PR #731 简单**: 只需要把 `CustomerSession.ensure_session` 的 spawn target 从 `Ezagent.Entity.Session` 改为 `Ezagent.Entity.SocialwareSession`（或等效的 ensure 函数）。不需要 PR #731 的 `after_boot` 重 hydrated 逻辑。

**问题 #3 是两个方案的共同问题**，不阻塞。

### 附带收益

新方案下还规避了 PR #731 的另一个问题:
- **Agent reply 双路径 (:receive + :send)**: 新方案 agent reply 走 `chat.send → PubSub`，单一路径。不需要 orchestrator 的 `:send` action。
