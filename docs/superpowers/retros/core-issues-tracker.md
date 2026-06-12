# Core Issues Tracker — 合并后必须回顾

> 日期: 2026-06-12 | 来源: PR #731 Live E2E 发现
> ⚠️ 合并完成后逐项验证，不可遗漏

---

## Issue #1: Session kind_type 共用

**发现**: PR #731 Live E2E bug。`SocialwareSession` 和 chat `Session` 共用 kind_type `"session"`。`instance_message` 注册的通用 `SpawnRegistry` "session" handler 把 dormant CS session cold-load 成 plain Session (有 Chat 没 Turn) → `turn.open` → `{:unknown_action, :open}`。

**PR #731 workaround**: `Assembly.ensure_socialware_session/2` 显式 spawn `SocialwareSession`

**新方案下状态**: ⚠️ 仍存在。autoservice-dev 的 `CustomerSession.ensure_session` spawn 的是 `Ezagent.Entity.Session` (plain)，修复 operator 接管时需要 Turn Behavior → 必须用 SocialwareSession。

### 短期修复 (合并时)

```elixir
# customer_session.ex:406 — 改 spawn target
- Ezagent.Kind.spawn(Ezagent.Entity.Session, %{uri: session_uri, ...})
+ Ezagent.Kind.spawn(Ezagent.Entity.SocialwareSession, %{uri: session_uri, ...})
```

或使用 PR #731 的 `Assembly.ensure_socialware_session/2` 模式。

### 长期修复 (Allen)

- **Owner**: Allen
- **方案**: distinct kind_type (`"session"` vs `"socialware_session"`)，或 snapshot-aware spawn handler (根据 snapshot 选 Session/SocialwareSession)
- **PR #731 flag**: "generic AgentFlavorAttributes rehydration from the durable slice at boot likely belongs in core"

### 验证

- [ ] `CustomerSession.ensure_session` spawn target 确认
- [ ] Operator 接管 `TurnAdapter.open_turn` dispatch 返回 `{:ok, turn_id}` (非 `{:unknown_action, :open}`)
- [ ] Server 重启后 dormant session cold-load 为 SocialwareSession (有 Turn Behavior)

---

## Issue #2: AgentFlavorAttributes ETS 非持久

**发现**: PR #731 Live E2E bug #1。`AgentFlavorAttributes` 是 ETS 表（非持久），重启后 flavor tag 丢失。Cold-load resolver 的 flavor 步返回 `:none` → dispatch `:no_such_actor`。cc/curl agent 不受影响（kind_type 走 resolver 的 durable-snapshot 第一步）。

**PR #731 workaround**: `after_boot/0` 从 durable snapshot index 重 hydrated flavor cache

**新方案下状态**: ✅ **消失**。不引入 CsOrchestrator Kind → 无 agent-flavor Kind → 不需要 flavor cache。

### 框架改进 (Allen)

- **Owner**: Allen
- **方案**: `AgentFlavorAttributes` 持久化应该放 core —— 从 durable snapshot 自动恢复。任何 agent-flavor Kind (cc/curl/未来的新 flavor) 都受影响
- **PR #731 flag**: "generic AgentFlavorAttributes rehydration from the durable slice at boot likely belongs in core"

### 验证

- [ ] 新方案下确认无 agent-flavor Kind (除 cc/curl)
- [ ] Server 重启后 cc/curl agent 正常 cold-load (kind_type 走 durable-snapshot 第一步，已确认不受影响)

---

## Issue #3: #730 Producer Gap

**发现**: PR #731 发现。cc harness 的 `spawn_plan` 读 model/endpoint，但 `template_data_extra` 没有 producer 把它们填进去。effort 走 default ("low") 能用。curl 的 `already_registered` 在 re-provision 时刷 benign warning。

**PR #731 处理**: 文档记录 CONCERN，留待后续修复。PR 依赖 #723 + #730 (按约定走 main 单独 PR)。

**新方案下状态**: ⚠️ 仍存在。与架构无关，两种方案都需要 cc agent provision → 都面临同样问题。

### 修复

- **Owner**: Allen/framework
- **方案**: cc 的 `template_data_extra` 需要 producer 填入 model/endpoint/effort
- **临时**: effort default "low" 可用；model/endpoint 暂时用 default 值

### 验证

- [ ] cc agent provision 时 model/endpoint/effort 是否正确传入
- [ ] curl agent re-provision 时 `already_registered` warning 是否消除

---

## 相关文档

- PR #731 FINDINGS: `docs/superpowers/demos/2026-06-12-autoservice-v2/FINDINGS.md` (PR 分支)
- 影响分析: `docs/superpowers/reviews/PR731-core-issues-impact.md`
- PR 回复: `docs/superpowers/reviews/PR731-reply-draft.md` §六
- 合并策略: `docs/superpowers/reviews/merge-strategy.md`
