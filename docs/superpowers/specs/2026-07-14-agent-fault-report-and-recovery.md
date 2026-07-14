# Agent 故障上报与恢复 — 通用机制 + 第一个接入者

**Status:** SPEC **v6 + main-drift amendment** — **NOT LOCKABLE for implementation。** Option **B** 已消除 P4 新增的 session→agent-domain 数据边；三份文档已对齐该边界。实现仍须等待 lead/doc-team 决定与 #1394 共用的 durable-delivery 物理机制，以及 §12-bis-B 的 cap-revoke 处置选项；本 amendment 不越权代选。
**Date:** 2026-07-14
**Source note:** `docs/notes/2026-07-13-bridge-join-timeout-silent.md`（Gaga，随 #1375 带出）
**Codex:** 四轮对抗性 review。v1 支点被证伪 · v3 "not sound enough to lock" · v4/v5 "NOT lockable"。v6 修复 v5 的七项 minimum changes，并保留全部旧证据与撤回记录。
**Empirical:** 2026-07-14 真 PTY 实测（claude v2.1.209）—— §2.6 / §2.7，**证伪了三句 moduledoc**
**Related:** #1375 · #1294/#1366 · #1311 · #1326

---

## 0. 两句话

> **① `:failed` 是一句系统证明不了的话 —— 而它炸掉了唯一能救 agent 的那条路（bind 事件 settle）。**
> **② `ReadyGate` 是【投递】闸门，却被用来挡【管理】—— 于是连人也够不到它的终端。**

---

## 1. 症状（本期接入的 fault）

cc agent 的 PTY 正常启动，`esr-bridge` 没能 JOIN。30s 超时 → `ReadyGate` 置 `:failed`。此后：

- 永久不可用（PTY 活着、`claude` 活着、Kind 进程健康）
- **零错误浮现**
- **创建者够不到它的终端**（`pty.write` / `pty.restart` 都是 action，都被闸门挡死 —— §2.5）

> ⚠️ **本 SPEC 不宣称 bridge 为什么没 join。** 曾经的因果叙事（"缺凭证 ⇒ bridge 不 join"）**已被实测证伪**（§2.7）。**病因至今未知 —— 而这正是本设计成立的理由（§3）。**

---

## 2. 已验证事实

### 2.1 超时完全静默 — CONFIRMED
`transport_readiness.ex` + `..._listener.ex` **telemetry / Logger 命中 0**。唯一名义上会响的 `dead_letter_failed_entries/2` 在 `case entries do [] -> :ok` **短路**（ready_transition.ex:139-145）。典型场景 buffer 为空 → **零输出**。

### 2.2 `:failed` 之后的投递被吞 — CONFIRMED
- dispatch 对 `:failed` 立即 `{:error, :failed}`，不缓冲不 DLQ（invocation.ex:198/222）
- `Delivery.dispatch_receive_call/3` 的 **`_other -> :ok`** 吞掉它（delivery.ex:309-332）
- **吞的不止 `:failed`** —— 还有 `:unauthorized` / `:cross_workspace_denied` / `:no_such_actor` / `:activate_timeout`
- **并非"零痕迹"**（codex 更正）：`Router.dispatch/1` 有 `router_dispatch_start`/`_error`（router.ex:79/231），消息 durable 在 `MessageStore`。真结论：**无可归因的 delivery_dropped trace / ReadMarker / DLQ / 用户可见信号**

### 2.3 恢复链的零件都在，**但决定性的那一步是断的** — CONFIRMED（codex 更正了 v3 的措辞）

零件（**都存在**）：
`AgentBridge.Registry.bind/3` 广播（registry.ex:41/166）→ `TransportReadinessListener` 订阅并转发（listener.ex:63/109）→ `on_transport_joined/1`（transport_readiness.ex:131）
超时**不清** ETS readiness 行（`fail_current_generation_locked/3` 从不调 `clear_generation_locked`，:358-366）—— **行活着，late 事件找得到它** ✅

**断在这里**：
```elixir
# transport_readiness.ex:370
case Ezagent.ReadyGate.status(agent_uri) do
  :not_ready       -> settle → :ready
  _already_settled -> {:settled, [], []}     ← :failed（及任何新态）掉这里 → NO-OP
```

> **所以闭环【不是】"本来就通"（v3 说过头了）。零件都在，但那个决定性的状态跃迁必须【改】。**

**且恢复是 incarnation-conditional 的**（codex）：late bind 只有在**原 Kind 化身还活着**时才能恢复（:63 记录 incarnation，:139/:376/:403 逐层校验）。**Kind 重启过一次，旧记录作废。**「late bind 总能恢复」是假的。

### 2.4 `pty.restart` 不 re-arm — codex 证伪 v1 支点
`pty.restart → Domain.Pty.restart/1 → cast(pid,:respawn) → PtyServer 杀 OS 子进程重起`。**从不经过** Template Class / `respawn_subprocess/2` / `ensure_pty_server` / `require_transport_join`。World UI 也没接这个 action。

### 2.5 **投递闸门挡了管理** — CONFIRMED ★（根 ②）
```elixir
# invocation.ex:218-223 —— 在 action 路由【之前】，零豁免
{:failed, _} -> {:error, :failed}      # 挡掉【每一个】action
```
- `Domain.Pty.restart/1` **全仓库唯一调用者**是 action handler（pty.ex:246）
- `pty.write` 同样是 action
- `:not_ready` + `:call` 也被挡（`ReadyGate.await` → `:activate_timeout`）

> **创建者可以【看】终端（PubSub，非 dispatch），但【写】和【重启】都够不到。#1375 给的三个权限，有两个在最需要时是死的。**

### 2.6 **实测：PTY observer 对本故障结构性失明**（claude v2.1.209，真 PTY，无凭证）

真实屏幕：`❯` + `⏸ manual mode on … Not logged in · Run /login`

| Observer | 结果 |
|---|---|
| **AuthObservers** | ❌ **不 fire。** 屏幕是 `Not logged in · Run /login`，正则是 `~r/Please run \/login/`（cc_agent.ex:221）—— **差一个词**。另三个（401/403/Invalid API key）需 API 调用，而 bridge 没 join → 无消息 → 无调用 → **永不出现** |
| **ParkedDialogWatch** | ⚠️ **fire，但是噪音。** `❯` 是**普通 REPL 提示符**（**健康 agent 实测同样渲染**）→ 对每个空闲 agent 都 emit |

`AuthObservers` moduledoc 的铁律（#1294）：*"通知面，不是 liveness 信号……canary crash-loop 933 次，observer fire **0** 次。熔断器 key off 失败的**形状**，不是**诊断**。"*

### 2.7 ★ **实测：「缺凭证 ⇒ bridge 不 join」这个因果是【假的】**

无凭证的 claude v2.1.209 **拉起了 MCP 子进程，并发出了完整的 `initialize` 握手**：
```json
{"method":"initialize","params":{"protocolVersion":"2025-11-25",…,
 "clientInfo":{"name":"claude-code","version":"2.1.209"}},"jsonrpc":"2.0","id":0}
```
**MCP 不依赖登录。** `esr-bridge` 是 stdio MCP server（mcp_config_writer.ex:161：`"command" => "uv"`），由 claude 拉起后**走自己的 WebSocket 回连 BEAM**（`EZAGENT_BRIDGE_WS_URL`）—— **整条路不经过 Anthropic 认证。**

**这句话写在三处，三处都错**：`CredentialPrecondition` moduledoc · Gaga 的 note · SPEC v1-v3。

> **⇒ bridge 为什么没 join，至今【未知】。**
> **⇒ 全部因果叙事（`/login`、凭证）从本 SPEC 删除。**
> **⇒ 「bridge 为什么没 join」另开独立调查（§12），【不阻塞本 PR】。**

### 2.8 `ensure_subprocess_alive/2` 在 PTY 活着时短路 — CONFIRMED
`CcAgent.ensure_subprocess_alive/2`：`cond do pty_server_alive?(agent_uri) -> :ok`。本僵尸里 PTY 恰恰活着 → **任何"确保子进程活着"式的恢复都是空转**。v1 的 `sandbox.ensure_alive` 因此作废。

---

## 3. **三条不可诊断定理 → 唯一合法的判据**

| | 来源 |
|---|---|
| 子进程自述不可信 | §2.6 实测 + #1294 |
| 文件系统不可信 | §2.7' lead 定论（`CredentialFreshness`：*"a day-old token relaunches **MUTE**"*） |
| **我们连因果都搞错了** | **§2.7 实测 —— note、moduledoc、SPEC v1-v3 三方同错** |

> # **系统无法诊断 agent 为什么不可用。所以它不该假装能。**
> **note 错了。moduledoc 错了。我错了三版。一个"会诊断"的系统只会把同一个错误自动化。**

**判据只能是 SHAPE。诊断交给唯一有能力做的实体 —— 一个能看那块屏幕的人。**

| | 职责 |
|---|---|
| **机器** | 观测 shape · 路由给发起者 · **把终端端到人面前** · **不诊断、不给指令** |
| **人** | 诊断 · 处理 |
| **机器** | 等**真实的 bind 事件** → settle |

---

## 4. 状态模型

| 状态 | 判据（**纯 shape**） | Kind 进程 | dispatch | 可被 bind 事件 settle |
|---|---|---|---|---|
| `:ready` | bridge bound | 活 | 正常 | — |
| `:not_ready` | gate armed，未到上界 | **活、健康** | cast→buffer · call→await | ✅ |
| **`:unreachable`**（新） | **到上界，bridge 仍未 bound** | **活、健康** | **快速失败，不 buffer**（T2） | **✅ ← 恢复的全部** |
| `:failed` | Kind 死 / teardown | **可能已死/已销毁** | 硬闭 | ❌ **终态**（`never resurrect` 原意完整保住） |

**`:unreachable` 三条性质缺一不可：** ① 非终态 ② 快速失败不 buffer（T2「不该一直等占资源」）③ 触发上报

---

## 5. ★ **加 `:unreachable` 的真实代价 —— 15 处审计 + 可复现 re-sweep**

> **v3 写的"代价 = 2 行"是【彻底错误】的。**
> **v4 声称"12 处、每条 dispatch 路径都覆盖"—— codex 判定【仍然是假的】：又漏了两处崩溃点（#13/#14）。**
> **本表 = codex 三轮审计的合集。** v6 不再声称凭人工数字就是“完整”；完整性由 `rg -n "ReadyGate\\.(await|status)" apps test/support --glob '*.{ex,exs}'` 的逐项分类表和 invariant ratchet 维持。

### 5.0 ★ v4 漏掉的两处（**codex 第三轮发现，都会崩**）

| # | 位置 | 为什么会崩 |
|---|---|---|
| **13** | **`invocation.ex:188` `dispatch_with_lazy_spawn/3` 的【外层】cast 结果 case** | 它只接 `:ok` / `{:error, :buffer_full}` / `{:error, :failed}` / `{:error, :incarnation_changed}` / `{:error, :dead_target}` / `{:retry, _}` —— **没有 `{:error, :unreachable}`**。内层（#2）返回新值后，**崩在上一层栈帧**。**v4 的"每条路径都覆盖"是假的** |
| **14** | **`kind.ex` `do_await_ready/1`（`Kind.spawn/2` 路径）** | `case ReadyGate.await(uri, timeout) do :ok -> …; {:error, :timeout} -> …` —— **只有两个分支**。`await/2`（#5）一旦能返回 `{:error, :unreachable}` → **`CaseClauseError`** |
| **15** | **`test/support/ezagent_template_agent_spawn.ex:131`** | `_ = ReadyGate.await(agent_uri, 5_000)` **明确丢弃结果**，随后立刻 dispatch `sandbox.update_config`；遇 `:unreachable` 会把真正原因改写成下游失败。改为模式匹配并 fail loud。 |

### 5.0-ter v6 的 #16 re-sweep 结论

按上面的精确查询重扫了 `apps/` 与 `test/support/`：production/support consumer 均已在 #5/#8/#14/#15 或 lazy-spawn 显式测试中分类。**没有找到第 #16 个 production/support consumer。** `apps/**/test/**` 内未断言 `await/2` 的 test setup 另作 test-hygiene 清理，但不算生产状态审计位点。为避免第三次虚假“完整”，新增 CI ratchet：保存已分类的 production/support `await/status` callsite 集合；新增或消失的 callsite 都使 gate 变红并要求更新本表。

### 5.0-bis **`@spec` 必须同步更新**（否则契约撒谎）

`Invocation` 的公开返回类型（invocation.ex:102）· `ReadyGate.await/2`（ready_gate.ex:134，现声明 `:ok | {:error, :timeout}`）· `PendingDelivery.buffer_if_not_ready[_locked]`（pending_delivery.ex:62/82）
另：lazy-spawn 同步路径**丢弃** `await/2` 的结果后重新 dispatch（invocation.ex:321/326）—— **必须显式测试**，否则它会把状态原因藏起来。

| # | 位置 | `:unreachable` 落到哪 | 必须做 |
|---|---|---|---|
| 1 | `invocation.ex:218` 同步路径 `case {status, mode}` | **无匹配 → `CaseClauseError` 崩** | **必改**：加 `{:unreachable, _}` 分支（豁免动作除外，见 §6） |
| 2 | `invocation.ex:261` cast 线性化点 | **无匹配 → `CaseClauseError` 崩**（且在 `PendingDelivery.with_lock` 内） | **必改**：同上 |
| 3 | `pending_delivery.ex:107` `buffer_if_not_ready_locked/3` | 非全函数 → 潜在崩 | **必改**：补全 |
| 4 | `ready_transition.ex:79` `== :failed` | 只拒 `:failed` → drain + mark_ready | ✅ **已正确**（正是要的非终态行为） |
| 5 | `ready_gate.ex:142` `await/2` | 当成"快就绪了"，**耗尽整个预算** | **必改**：`:unreachable` → 立即 `{:error, :unreachable}` |
| 6 | `transport_readiness.ex:371` `settle_join_event_locked` | **落 `_already_settled` → NO-OP → 闭环断** | **必改** ★ **决定性的一步** |
| 7 | `transport_readiness.ex:329` 超时去重 | `!= :not_ready` → no-op | ✅ 已正确 |
| 8 | `identity.ex:76` `await_ready/2` | 耗尽 ~500ms，再把失败塌缩成空 cap 集 | **必改**：快速失败 |
| 9 | `readiness.ex:11` Session config | `{:error, {:gate_failed, :readiness, :unreachable}}` | ✅ 已正确 |
| 10 | `lifecycle_case.ex:217` | 轮询到超时后测试失败 | 改：快速失败 + 明确信息（test support） |
| 11 | `lifecycle_case.ex:261` | 同上 | 同上 |
| 12 | `mix/tasks/ezagent.stress.ex:511` | 烧 2s 后报通用 timeout，**掩盖已知状态** | 改：直接暴露 `:unreachable` |

**⇒ 合计 15 处。9 处必改**（原 8 处 + #15 fail loud）**+ 3 处应改**（#10 #11 #12）**+ 3 处已正确但要写测试钉住**（#4 #7 #9）**+ 3 个 `@spec` + 1 个 callsite-ratchet gate**。

---

## 6. ★ P1 —— **豁免契约**（codex 判 v3 的判据"过宽且作者可控"，本节重做）

### 6.1 为什么不能用「required cap 是 `Manage`」推导

codex 枚举：那会豁免 **14 个 action**，包括 `publish_cr` · `rollback_cr` · `apply_config_delta` · `reconfigure` · `delete`。

> **而且分类是【作者可控】的 —— 任何插件把一个 action 声明成 Manage cap，就自动获得穿透闸门的能力。**

**否决。**

### 6.2 正确的问法：**这个动作依赖什么？**

| 动作依赖 | 被 `:not_ready` 挡？ | 被 `:unreachable` 挡？ |
|---|---|---|
| Kind 的**内部 slice 状态** | 需谨慎 | 不需要（activate 早跑完了） |
| Kind 的**外部 transport**（bridge） | 可能 | **是 —— 那正是缺的东西** |
| **都不依赖**（纯 OS/FS 副作用，如往 PTY 写字节） | **否** | **否** |

**我们真正需要的，只有一件事：**

> ## **人必须能够到坏 agent 的【终端】—— 看它、往里打字。**
> 终端 **read** 已经能用（PubSub，不走 dispatch）。缺的只有 **write** 和 **restart**。

### 6.3 **豁免契约（本 SPEC 的规范定义）**

| | |
|---|---|
| **豁免集合** | **`pty.write` · `pty.restart`。就这两个。** |
| **可穿透的状态** | **`:not_ready` · `:unreachable`** |
| **不可穿透** | **`:failed`（硬闭，`never resurrect` 完整保住）· `:unknown`（照旧 lazy-spawn）** |
| **声明方式** | action 上的**显式 flag**（默认 `false` = fail-closed）。**不从 cap 推导** |
| **防漂移** | **CI gate 把豁免集合钉死成一个精确清单 —— 多一个就红**，逼作者回来改 gate + 走 review |
| **授权** | **一行不改。** cap 检查在 `Kind.Runtime`（runtime.ex:319/468），在投递**之后**。豁免只改**投递** |
| **化身校验** | cast 路径的豁免**必须留在同一个 `PendingDelivery` URI 锁内**，且**仍要校验 expected incarnation == 当前注册 pid**（codex）。**"管理"不能成为向陈旧化身投递的借口** |

### 6.4 为什么**永远不需要穿透 `:failed`** —— **全部 5 个生产者的枚举**（不是断言，是清单）

| # | 生产者 | Kind 状态 | 判决 |
|---|---|---|---|
| ① | `kind.ex:528` **`Kind.terminate/1`** | **正在被销毁** | ✅ 硬闭正确 |
| ② | `kind/server.ex:168` 持久化失败 | **紧接 `{:stop, ...}`，进程立刻死** | ✅ 硬闭正确 |
| ③ | `transport_readiness.ex:361` 超时 | **活着、健康** ← **就是本 bug** | **v4 改产 `:unreachable`** |
| ④ | `transport_readiness.ex:386` | Kind **不在 registry**（已消失） | ✅ 硬闭正确 |
| ⑤ | `transport_readiness.ex:414` | `Process.alive?` = **false** | ✅ 硬闭正确 |

> **把 ③ 改成 `:unreachable` 后，剩下每一个 `:failed` 生产者都意味着「Kind 已死、正在死、或正在被销毁」。**

**而 ① 反过来【要求】硬闭：** `Kind.terminate/1` 是**先 `mark_failed`、再终止进程**，moduledoc 明说这是故意的权限卫生屏障 —— *"Before process lookup, the URI is definitively marked failed… This prevents an authority-bearing absorb artifact queued for a failed incarnation from landing on a later entity recreated at the same URI."*

**⇒ 存在一个窗口：gate 已 `:failed` 但 Kind 还活着。豁免动作若能穿透，就会打进一个正在被销毁的 Kind，恰好击穿那道屏障。**
**⇒ `:failed` 硬闭不只是"安全"，是【必须】。**

### 6.4-bis 两个豁免动作在非 `:ready` Kind 上跑，**安全** — CONFIRMED

`handle_write/2` / `handle_restart/2`（pty.ex:225-256）**只读 `ctx[:self_uri]`**，然后委派给 `Ezagent.Domain.Pty.*`。
**不读 Kind 的 state / transients** —— 且 `Behavior.Pty` 的 moduledoc 有一整节叫 **"Why NO transients"**（pty.ex:83）：**它按设计就没有 transients**，`activate/2` 不为它建任何东西。
PTY 未起时返回干净的 `{:error, :no_pty_server}`，**不崩**。

**佐证（作者原意）**：`handle_restart` 的 moduledoc —— *"recovering a dead agent is a **management act on the instance**, not terminal typing"*。**豁免与代码作者的原意一致。**

### 6.5 ★ **闸门如何读到这个 flag —— 需要一块 v4 之前漏写的 core 管道**

> **纠正**：v3 曾断言「可行性已验证，全程不进 Kind」。**那是错的** —— 只验了链条后半段。
> **`URI → Kind module` 的纯函数【不存在】**；Router 是从**活着的 Kind 进程**里拿 `kind_module` 的。
> 而 URI query 里的 behavior 前缀（`?action=pty.write`）是 **TELEMETRY-ONLY**（delivery.ex:267-274：*"dispatch routes on the action atom + the recipient Kind via the BehaviorRegistry"*）—— **调用方可随手伪造，不可作为权威判据。**

**已有的零件：**
- `Ezagent.URI.behavior_action/1`（uri.ex:916）→ `{:ok, {prefix, action}}` —— **纯**（只取 `action`，**丢弃 prefix**）
- `BehaviorRegistry.lookup(kind, action)`（behavior_registry.ex:47）→ behavior —— **纯**
- `def __actions__`（behavior.ex:819）—— 编译期生成的 action 元数据表 —— **纯**
- `action/2` 宏的 opts 已支持 7 个键 → **加第 8 个是既有模式的延伸**

**缺的那块（必须补）：**
`KindRegistry` 基于 Elixir `Registry`，`lookup` 返回 `[{pid, value}]`，而 **value 槽当前存的就是 pid 本身（冗余）**。
**⇒ 把 `kind_module` 存进 value 槽，新增纯函数 `KindRegistry.lookup_kind/1`（O(1) ETS，不碰进程）。**

**闸门的完整判据链（全纯、不进 Kind）：**
```
URI.behavior_action(inv.target)        → {_prefix, action}     纯
KindRegistry.lookup_kind(instance_uri) → kind_module           纯 O(1)   ← 新增
BehaviorRegistry.lookup(kind, action)  → behavior              纯
behavior.__actions__()[action]         → flag（默认 false）     纯（编译期）
```
**★ 缓存必须挂在正确的 chokepoint（codex 第三轮更正）：**
生产注册**不走** `BehaviorRegistry.register/3` —— 它是 `@doc false`，`CapabilityRegistry` 的 moduledoc 亲口称自己是它的 **"Single legitimate use"**（capability_registry.ex:95-97）。
**⇒ 豁免缓存的写入与移除，必须挂在 `CapabilityRegistry.register/3` 及其 `unregister` 对偶上（含 plugin unload）。**
预计算 `{kind, action} → exempt?`，闸门降为一次 ETS 查。

**`:unknown` 不需要分类** —— 它走 lazy-spawn，不经过豁免。v5 的「非 ready ⇒ 必然已注册」断言撤回：`current_incarnation/1` 明确可返回 `:unregistered`（transport_readiness.ex:437-441），且 `Kind.terminate/1` 先标 `:failed` 再移除 registry，存在 gate/registry 不同步窗口。

**`lookup_kind/1` miss 的统一 fail-closed 契约：** 对 `:not_ready` / `:unreachable` / `:failed` 的任何动作，miss 都返回 `exempt? = false`，绝不猜 kind、绝不信 URI action prefix、绝不 fallback 到 allowlist；发 telemetry `[:ezagent, :dispatch, :gate_exemption_metadata_missing]`，metadata 至少含 `instance_uri`、`status`、`action`，然后走该状态的普通硬门语义。三项钉死测试：① unregistered + `:not_ready` 的 `pty.write` 不穿透；② unregistered + `:unreachable` 的 `pty.restart` 不穿透且快速失败；③ terminate 的 `:failed` 窗口即使 registry miss 仍对两个豁免动作硬闭。

### 6.6 豁免缓存的一致性协议

ETS 跨表没有事务；因此采用**安全可见性顺序 + 补偿回滚**，由 `CapabilityRegistry` 的既有单一注册入口执行：

- register：先校验全部 metadata/conflict；依次写 `Subjects` → `BehaviorRegistry` → **ExemptionCache 最后写**。中间窗口最多“少豁免”（fail closed），永不“有豁免但 action 尚不可路由”。任一步 raise，按反序只删除仍指向本 `behavior` 的本次写入（cache → behavior → subject），再 re-raise；幂等重注册不删除既有行。
- unregister：**ExemptionCache 最先 compare-delete**（仅当仍指向本 `behavior`/flag），然后 compare-delete `BehaviorRegistry`，最后删 `Subjects`。因此 unload 一开始就 fail closed；迟到的 v1 unload 不得删掉 v2 replacement 的 cache/route。
- `CapabilityRegistry.register/3` / `unregister/3` 各自在一个仅保护这三张 node-local metadata ETS 表的 mutation lock 下执行整个序列；不引入 DB 或跨层 coordinator。
- 测试在每个注入式 raise 点读取三表，证明无 half-installed exemption；并发 register/unregister replacement 测试证明 compare-delete 不误删新版本。

### 6.5 `:not_ready` 期间投递是否安全 —— 是

`activate/2` 跑在 `handle_continue` 里，**`handle_continue` 先于任何 mailbox 消息被处理**（codex 确认）。
⇒ 在 `:not_ready` 期间投递的消息，**处理时 activate 必然已完成**。**不存在"读到半成品 state"的风险。**
（残余：一个卡死的 activate 会让管理 `call` 排在它后面耗掉自己的超时预算 —— 是可用性问题，不是正确性问题。记录在案。）

---

## 7. 恢复闭环（**去掉全部因果叙事**）

```
到上界 → :unreachable（不是 :failed）+ 写 agent_faults + durable envelope
   ↓
发起者打开终端（§6 让 pty.write / pty.restart 能投递）
   ↓
【人看现场，自己判断，自己处理】     ← 机器不知道该做什么，也不假装知道
   ↓
真实的 bridge bind 事件到达
   ↓
settle_join_event_locked（§5 #6 已改为接受 :unreachable）→ drain → mark_ready
   ↓
:ready ✅  + resolve agent_faults + durable resolved envelope
```

**限制（必须写进文档，不许含糊）：** 恢复是 **incarnation-conditional** 的 —— **只有原 Kind 化身还活着时**，late bind 才能 settle。Kind 重启过 ⇒ 旧记录作废 ⇒ 走正常的重新 arm 路径。

---

## 8. Lead 已定（不再 re-litigate）

| | |
|---|---|
| **原则** | 谁发起 → 出问题 → 反馈给谁 → 谁处理 |
| **T2** | 未决必须有上界，不该一直等占资源 → 30s 保留；`:unreachable` 快速失败不 buffer |
| **T3** | 建一张最小的 per-agent 故障记录 |
| **OQ-1** | **(A)** 管理动作豁免投递闸门 —— **契约见 §6（v4 收窄为 2 个 action / 不含 `:failed`）** |
| **泛化** | P1/P3/P4/P5 做成**通用 agent-fault 机制**；本期只接入一个 `fault_kind` |
| **Bug A/B** | 独立后续（§12） |

---

## 9. 方案

### P1 — 豁免契约（core）★ **§6 是规范定义**
- action 显式 flag（默认 `false`）；豁免集合 = `pty.write` + `pty.restart`；可穿透 `:not_ready` / `:unreachable`；**`:failed` 硬闭**
- **CI gate 钉死集合**（多一个就红）
- cast 豁免留在同一 `PendingDelivery` 锁内 + **仍校验 incarnation**
- **不改授权**

### P2 — `:unreachable`（**含 §5 的 15 处审计**）

- `ReadyGate` 加状态（`@type` + `put/2`）**+ §5 全部 15 处逐条落实 + 3 个 `@spec` + classified-callsite ratchet**
- 超时分支：`mark_failed_locked` → **`mark_unreachable_locked`**（置 `:unreachable` + 把已 buffer 的 cast **dead-letter**，reason `:unreachable`；**at-most-once 丢失是刻意的**，T2）
- `settle_join_event_locked` / `drain_pending_then_mark_ready_locked`：**接受 `:unreachable`**，只拒 `:failed`
- **ETS readiness 行保持 armed**（late settle 需要它）

#### ★ P2-a — readiness 行所有权、listener restart 重建与清除

**问题**：core 的 `Kind.terminate/1` **不能**调 `TransportReadiness.clear/1`（反向依赖：domain_agent → core，不可逆）。而 OTP `terminate/2` 对 **brutal kill 无保证**。

**机制（零跨层，覆盖【所有】死法）：**

> **`require_transport_join/2` 把精确 incarnation PID 与绝对 deadline 一起写进 readiness ETS 行，并把同一 PID 传给 `TransportReadinessListener.arm_timeout/5`；listener 为每个 armed row 同时拥有 timer + `Process.monitor(incarnation_pid)`。**

- **覆盖优雅退出、崩溃、brutal kill、supervisor 重启** —— `:DOWN` 一律会到
- **化身替换**由既有的 `discard_stale_record`（readiness_decision 里的 incarnation 校验）兜底
- **完全在 domain_agent 内部**，core 一行不改，**不需要任何新的 teardown callback 契约**
- monitor ref 存在 listener state；`:DOWN`/timeout 都先重读 ETS row 并做 generation + PID 相等性校验，旧消息不能清新 incarnation
- readiness public named ETS row 由 `TransportReadiness.init/0` 创建（transport_readiness.ex:45），不归 listener；所以 **listener 单独重启时 row 存活，而今天的 timer 全丢**。这是 pre-existing production bug：armed agent 可永久 `:not_ready`。**v6 在本期修复，不 spin out**，因为重建正是 P2 正确性的一部分
- arm-time row 扩为 `{uri, timeout_ms, deadline_unix_ms, generation, incarnation_pid}`；listener `init/1` 枚举全部 row：PID 活且仍为当前 registry incarnation → monitor，并以 `max(deadline-now, 0)` 重建 timer；已过期 → self-send 立即 timeout；PID 死/mismatch/unregistered → generation-conditional clear。不能用 monotonic deadline，因为 VM restart 后原点不可比较
- 删除 `arm_timeout/3` 的 `Task.start + sleep` fallback：listener 未启动时 arm 必须 fail loud，让监督树顺序错误暴露；fallback 没有 monitor/reconstruction
- **arm 不分配 `fault_epoch`，不访问 Repo。** `require_transport_join/2` 的 arm row 插入位于 `with_transition_locks/2` 内，该函数是 `PendingDelivery.with_lock/2` 再套 `:global.trans/4`（transport_readiness.ex:57-90,507-523）；任何 DB round-trip 放进去都会把 cluster transition lock 变成 I/O lock。而 cc `ensure_pty_server/4` 在启 PTY 前直接调用 `require_transport_join/1`（spawn.ex:442-443），arm-time DB 还会无声地把生成 agent 耦合到 Repo 可用性。两者都禁止。

### P3 — `agent_faults`（多态 + durable fencing + reconciliation）

#### ★ P3-a — 为什么 v4 的 "generation 相等性" 挡不住竞态（codex 判 **Critical**）

```
t0  超时在锁内校验 generation，决定写入
t1  释放锁（DB I/O 不在锁内 —— 这是对的）
t2  late bind 到达 → settle → 【清掉】故障行
t3  t0 那个【延迟的写入】执行 → 【故障行被复活】     ← 相等性标记挡不住"删除之后再插入"
```

#### ★ P3-b — timeout 后惰性分配 durable `fault_epoch`（arm 无 DB）

| | |
|---|---|
| **`fault_epoch`** | **首次确认该 generation 已 `:unreachable` 后，在两层 transition lock 之外由 DB 原子分配**。使用独立的内部 allocator 表 `agent_fault_epoch_counters(agent_uri PK, last_epoch)`：`INSERT ... last_epoch=1 ON CONFLICT(agent_uri) DO UPDATE SET last_epoch=agent_fault_epoch_counters.last_epoch+1 RETURNING last_epoch`。它跨 VM restart/node 单调；不用 process counter 或 wall clock。**allocator 绝不改 `agent_faults` 状态行**；否则一个迟到的旧 allocator 可以把更新的 open fault 改成 resolved/换 epoch。 |
| **写入（超时）** | `UPDATE ... status='open' ... WHERE agent_uri=? AND fault_epoch=?`，只允许当前 arm 打开自己的行。 |
| **清除（settle）** | **不 DELETE** —— `UPDATE ... status='resolved', resolved_at=? WHERE agent_uri=? AND fault_epoch=?`。 |

惰性协议是：① timeout 在既有 generation + incarnation 锁内检查后只把 gate 变为 `:unreachable`，不做 DB I/O；② 锁外从独立 counter row 分配 epoch；③ 短暂重进 transition lock，只在 row 仍是同 generation/PID 且 gate 仍 `:unreachable` 时把 epoch 附到 readiness row，否则烧掉该 epoch（间隙无害，且因 allocator 表与状态表分离，不会改动较新 fault）；④ 再到锁外 `INSERT agent_faults ... ON CONFLICT DO UPDATE ... WHERE excluded.fault_epoch > agent_faults.fault_epoch`，将同 epoch 改为 open，并执行写后重读；⑤ 写后发现 gate 已 `:ready` 或 armed row 不再是该 generation/epoch，立即 `UPDATE ... resolved WHERE fault_epoch=?`。**timeout 路径不直接通知**；domain_agent 在发布 opened envelope 前完成 source-side re-read/fencing，session 只按 P4 的 opened/resolved durable envelopes 维护 obligation，不回读 gate 或 `agent_faults`。

**原子性判决：没有任何路径需要把 epoch 分配与 arm row 插入做成同一个原子操作。** arm row 的 node-local 线性化身份是 `{generation, incarnation_pid}`；`fault_epoch` 只 fencing timeout 之后的 durable row writers。新 generation 在旧 timeout 分配/附着之间取代 row 时，旧 epoch 只会被烧掉；它不能附着到新 generation，也不能打开新 fault。因此选项 (b) 保留了 v6 的 fencing，同时严格优于选项 (a)：(a) 虽能把 DB 移出锁，仍把 Repo 可用性放在 spawn 路径上。

**DB 可用性契约（显式）：arm transport gate 不需要 DB 可用。** DB 不可用时，`require_transport_join/2` 仍正常写 node-local row、设 `:not_ready`、建 timer/monitor，spawn 不因 Repo 失败。若 DB 在 timeout 时仍不可用，gate 仍 fail-loud 地进入 `:unreachable`，Logger/telemetry 仍发出；durable fault row/人类通知延后，由 workspace-owner source reconciler 固定周期重试 epoch 分配和 open 协议。不降级成无 fencing 写入，也不因 Repo 故障撤销 `:unreachable`。

#### P3-c — 表

| 列 | 说明 |
|---|---|
| `agent_uri` **PK** | 一行 / agent（**状态行，不是事件流**） |
| `workspace_uri` NOT NULL | `Ezagent.URI.workspace_of/1` 返回 `%URI{} | :any`；精确 string dump 与 `:any` fail-loud 契约见下文。 |
| **`fault_epoch`** (int) | DB 分配的 fencing token |
| **`status`** | `:open` / `:resolved`（**永不删行**） |
| `fault_kind` | **开放**。本期只写 `transport_not_joined` |
| `occurred_at` / `resolved_at` | |
| `observations` (json) | **只装观测**：`bridge_bound?: false` · `kind_alive?` · `timeout_ms`。**不放 `credentials_present?`**（§2.7）**不放屏幕快照**（分层；UI 实时取） |
| `handler_uri` / `notified_epoch` | **从 `agent_faults` 删除。** session 不得回填或 claim agent-domain row；通知状态由 P4 的 session-owned obligation row 持有。 |

- `agent_fault_epoch_counters` 是 domain_agent 内部 allocator，不是 UI/query projection；只有 `agent_uri` + `last_epoch`。它与 `agent_faults` 分表，使 stale/superseded allocation 只留 gap，不能改动当前 fault 的 status/payload。
- `workspace_uri` 的精确持久化：`Ezagent.URI.workspace_of/1` 返回 `%URI{} | :any`（uri.ex:709-725）。schema 使用现有 `Ezagent.Ecto.URI`（实际模块名；`ecto/uri_type.ex:23-26,69-73`）把 `%URI{}` dump 为 string；raw query 必须显式 `URI.to_string/1`。`:any` → 明确 `workspace_scope_required` error + telemetry/log，禁止 NULL、`"any"` 或裸 workspace 名。
- **Context API `Ezagent.Agent.Faults`**（domain_agent）拥有全部 fault 查询与状态变更；session code 不得调用它。migration 落 core repo（**单 Repo 是既有约束，不是架构论据** —— codex 的 ownership smell，如实记录）
- P3 的 outward seam 只产出 self-contained fault envelope：`{agent_uri, workspace_uri, fault_kind, fault_epoch, occurred_at, observations}`。它不得包含 owner/handler，也不得要求消费者回读 `agent_faults`。该 envelope 进入与 #1394 共用的 durable-delivery seam；具体共用 outbox/worker/schema 由 lead/doc-team review 决定，P3 不新建第二套 retry scheduler。

### P4 — durable processing：周期 reconciler + best-effort wakeup

#### ★ P4-a — 事件契约（v4 完全没定义，本节补齐）

| | |
|---|---|
| **顺序** | timeout 只持久化 open row；PubSub 仅是 wakeup hint。reconciler 启动即跑、固定周期跑、事件到达时提前跑。 |
| **Topic** | 通用 agent-fault events topic（domain_agent 拥有） |
| **Payload** | `{:agent_fault, agent_uri, fault_kind, fault_epoch}` |
| **Dedup key** | `{agent_uri, fault_epoch}` |
| **listener 找不到行 / 行已 `:resolved`** | **跳过**（不为一个已恢复的故障通知） |
| **投递保证** | PubSub 只作 best-effort wakeup；durable handoff 必须经与 #1394 共用的 delivery seam 重投，直到 session-owned obligation 已 durable ingest。session 不以扫描 `agent_faults` 补漏。 |

- 超时点：`Logger.error` + telemetry `[:ezagent, :agent, :fault]`（带 `fault_kind`；telemetry 元数据本来就接受开放 map —— codex 确认可行）
- **domain_agent 只发布 self-contained fault envelope**，**从不调用** session 的所有权/通知代码；durable handoff 的 transport/ack 由共享 substrate 承担，不是 `domain_agent → domain_session` 业务调用
- **domain_agent source reconciler** 只在 workspace-owner node 解释 node-local truth；gate `:ready` → resolve 同 epoch；gate `:unreachable` 且 armed row 还没 epoch → 执行 P3-b 的锁外 allocate→conditional attach→open 协议；已有 epoch 但无 open row → backfill open；`:not_ready` 不分配 epoch/不开 fault；非 owner node/无 armed row 不凭本地 `ReadyGate` 改共享行
- **session ingress** 从 durable handoff envelope 幂等插入 session-owned `agent_fault_notification_obligations`；natural key `{agent_uri, fault_epoch}`，列至少含 envelope 全字段、`handler_uri`、`status`、`attempts`、`next_retry_at`、timestamps。成功插入/确认已存在即构成 durable-ingest acknowledgement；不得读取或写入 `agent_faults`。
- **session notification reconciler** 只扫 `agent_fault_notification_obligations`，用显式 owner-resolution service 解 owner，原子 claim obligation，再 `Notifications.notify`。失败按共享 retry seam 的策略释放/续期 claim；成功标 applied。`handler_uri` 只写 session-owned obligation。
- source resolve 与人类通知可能竞态；因此 shared envelope contract 必须能表达同 `{agent_uri, fault_epoch}` 的 `opened`/`resolved` 状态，session ingress 以 epoch 幂等折叠，resolved obligation 不通知。具体事件/row 表达属于 #1394 unified-mechanism review，不能靠 session 回读 agent row 修补。
- **`:no_owner` 不许静默** → loud log + telemetry（运维是 handler）
- **通知内容 = 现状 + 终端入口。零补救指令。** 现文案「run `/login`」是**无效指令**（且其因果前提已被实测证伪），删除，**且不许换成另一句硬编码的**

### P5 — 消灭 `Delivery` 的 catch-all（**但保留一条 loud 的意外分支**）
```elixir
:ok            -> mark delivered
{:error, r}    -> Logger.error + record_delivery_dropped_trace(..., r)
other          -> Logger.error("UNEXPECTED dispatch return: …") + trace   # ← codex：裸删会让未来的新返回值崩
```
**日志量**：按 reason 分计数器 + rate-aware 日志（codex：`:unauthorized` / `:no_such_actor` 可能高频）

### P6 — UI + invariant + arch gate
- World：展示 `agent_faults`（按 `fault_kind` 泛化）+ **终端入口**
- Invariant：**豁免集合恰好等于 allowlist**（多一个就红）· **`:unreachable` 必须能被 bind 事件 settle** · **`:failed` 对所有动作硬闭**
- arch gate anchor：禁止其它绕过路径

### P7 — Projection 原则的判决

**采用受限版本：** timer、monitor、PubSub wakeup 都是 projection，必须能从 readiness armed row / durable fault row 重建。**拒绝强版本：** `ReadyGate` 与 readiness ETS 都是 node-local，不能单独作为共享 DB 行的 cluster authority；“DB-write 前重读 gate”在 read 与 UPDATE/notify 之间仍有 TOCTOU，会产生已恢复却被通知的窗口。周期 reconciliation 能最终关闭行，却不能撤回已发的人类通知。因此 durable row 使用 DB-allocated fencing epoch，只有 workspace-owner node 解释本地 gate；跨域通知则使用 P4 的 opened/resolved durable envelope + session-owned obligation。物理 outbox 是否以及如何泛化，统一留给 #1394 lead/doc-team review；不得把“durable storage”冒充“durable processing”。

---

## 10. 不做

- ❌ 不用 observer 做判据 · ❌ 不用文件系统判 auth · ❌ **不做任何诊断**
- ❌ **不宣称 bridge 为什么没 join**（§2.7 —— 我们不知道）
- ❌ B/C/D 的判据与恢复事件不在本 PR（各自需要实证）
- ❌ 不改 `pty.restart` 语义 · 不碰 #1382

---

## 11. **撤回记录**（诚实留痕）

| 版本 | 主张 | 为什么错 |
|---|---|---|
| v1 | `sandbox.ensure_alive` | `ensure_subprocess_alive/2` 在 PTY 活着时短路（§2.8）→ **空转** |
| v1 | `check_materialized/2` 作判据 | 文件在 ≠ 认证（lead 定论） |
| v1 | `agent_faults.remedy` | 系统无法诊断 → 任何 remedy 都是假指令 |
| v1 | 「re-arm 就是恢复，触发器是重启终端」 | codex：`pty.restart` 不 re-arm |
| v2/v3 | 「缺凭证 ⇒ bridge 不 join」 | **§2.7 实测证伪** |
| v3 | 「闭环本来就通」 | codex：决定性的 settle 分支是断的 |
| v3 | 「加状态代价 = 2 行」 | codex：**两处 dispatch 会 `CaseClauseError` 崩**；实际 12 处审计 |
| v3 | 「豁免判据 = Manage cap」 | codex：**过宽（14 个 action）且作者可控** → §6 重做 |
| v3 | 「15 处状态读取」 | codex：实际 **12 处**。那个数字是没做审计的证据 |
| v3/v4 | 「可行性已验证：全程不进 Kind」 | **`URI → Kind module` 的纯函数根本不存在**。只验了链条后半段 → §6.5 补 `KindRegistry.lookup_kind/1` |
| **v4** | 「**12 处，每条 dispatch 路径都覆盖了**」 | **codex：又漏 2 处崩溃点**（外层 cast case、`Kind.do_await_ready/1`）。**审计是 14 处** |
| **v4** | 「generation 条件化写入就够了」 | **codex（Critical）：相等性挡不住"删除后再插入"** → P3-b 改为**永不删行 + 单调 `arm_seq` CAS** |
| **v4** | 「teardown 时清 ETS 行」 | **codex：没有 layer-valid owner；`terminate/2` 对 brutal kill 无保证** → P2-a 改为 **listener `Process.monitor`** |
| **v4** | `workspace_name!/1` 推导 workspace_uri | **codex：它返回【裸名字】，不是 URI** → 改用 `Ezagent.URI.workspace_of/1`（且 `:any` → fail loud） |
| **v4** | 「缓存挂 `BehaviorRegistry.register/3`」 | **codex：那是 `@doc false`**；生产 chokepoint 是 `CapabilityRegistry.register/3` |
| **v5** | process-local `System.unique_integer/1` 可排序 durable row | VM restart/node change 后计数重置；旧高值可永久 wedge 新写入 → DB 分配 `fault_epoch` |
| **v5** | arm 只需把 generation 传 listener | monitor 必须绑定**精确 incarnation PID**；listener restart 还必须从存活 ETS row 重建 timer + monitor |
| **v5** | 「先落库再 PubSub；丢了不致命，因为行 durable」 | durable storage ≠ durable processing；没有 replay/reconciler 就会永久无人处理 |
| **v5** | 非 ready ⇒ KindRegistry 必然有 kind | `current_incarnation/1` 可为 `:unregistered`，terminate 还有 failed-before-removal 窗口 → lookup miss 必须 fail closed + telemetry |
| **v5** | 「14 处完整审计」 | `test/support/ezagent_template_agent_spawn.ex:131` 丢弃 await 结果 → #15；用 callsite ratchet 取代人工完整性承诺 |
| **v5** | `workspace_of/1` 可直接写 string column | 返回 `%URI{} | :any`；必须 `Ezagent.Ecto.URI`/`URI.to_string/1`，`:any` fail loud |
| **v5** | 缓存“挂 register/unregister”已足够具体 | 三表跨 ETS 非原子；必须定义 fail-closed 写序、mutation lock、compare-delete 与异常补偿 |
| **v6 proposal** | 所有 derived thing 只需重读 ReadyGate，无 fencing/outbox | **部分拒绝**：node-local gate 不是 shared-row cluster authority，read-before-write/notify 有 TOCTOU；仅 timer/monitor/wakeup 采用 rebuildable projection |
| **v6** | 在 arm 时分配 DB `fault_epoch` | arm row 在 `PendingDelivery.with_lock/2` + `:global.trans/4` 内插入（transport_readiness.ex:57-90,507-523），导致 DB round-trip 进 global lock；且 cc spawn 在 `ensure_pty_server/4` 内先 arm（spawn.ex:442-443），会新增 Repo 对 spawn 的硬依赖。改为 timeout 后锁外惰性分配；arm 无 DB。 |
| **v6 流程** | SPEC 已称 LOCKABLE，但 plan/handoff 仍是 v5 | 2/3 执行文档仍传递已撤回机制，LOCKABLE 判决无效。本次将三文档逐 Gate/DoD 对齐后才重新宣布。 |
| **v6 + #1402** | session notification reconciler 扫/claim `agent_faults`，因为当前 scanner 没列 `Ezagent.Agent.Faults` 就视为可接受 | 这是从门下钻：scanner 的 exact forbidden map 不等于允许的架构。Option **B** 删除该边；session 只持有自己的 notification obligation。 |
| **v6 + #1394** | fault notification 自建第二套 durable retry/reconciler | lead 已锁定两者必须统一；P3/P4 现在只定义 producer/consumer seam，不选择物理 substrate。 |

**同一个病，二十二次：拿没验证过的东西当支点。**
**v6 的每个新增支点都有 file:line 与会变红的 falsifier。**

---

---

## 12-bis. ★ 与 #1394（entity-caps durable-retry）的冲突与合并 —— **交文档团队 review 决策**

> **发现时机**：v6 完稿后 check main（origin/main 已领先 7 个 commit）。
> **状态**：#1394 是 **lead-locked 的纯文档计划，尚未实施**（只有 plan + handoff 两个 doc 文件，无 outbox migration）。

### A. 两条 lead-locked 的线，在并行造【同一类机制】

| | **#1394**（entity-caps P1(A)） | **本 SPEC**（agent fault） |
|---|---|---|
| **病** | 打给 **not-ready** 目标的 grant/revoke 被**静默丢弃**（`PendingDelivery` ETS-bounded → `DLQ` 是 diagnostic-only，**无 replay/ACK/retry**） | 故障与通知被**静默丢弃**（无记录、无路由、丢了就没了） |
| **修法** | **durable outbox 表** `{target, op, cap_id, status, attempts, next_retry}` + **在 target 的 `announce_ready`/recovery 时重试** + **survives restart** | **durable fault row** + domain-agent envelope producer + session-owned notification obligation；delivery/retry substrate 必须与左列共用 |

**⇒ 同一个病（silent drop），同一类解（durable + retry-on-recovery + 活过重启）。**

> ### **Lead 决策（2026-07-14）：机制【必须合并】，不许并行造两套。**
> 具体怎么合（谁是底座、谁是消费者、outbox 是否泛化成通用 durable-op 表）—— **交文档团队 review 时决策。**

### B. ★ 一条**今天就存在**的冲突（我们【继承】它，不是引入）

`:absorb_cap` / `:revoke_cap` **当前确实走 `PendingDelivery`**（#1394 plan 原文）。
而**现有的 `mark_failed_locked` 已经在 dead-letter 整个 buffer** —— 本 SPEC 的 `mark_unreachable_locked` **行为不变**（只是换了 reason）。

> **⇒ 今天，一次 transport 超时就会把一条 pending 的 `:revoke_cap` 丢进 DLQ。revoke 丢失 ⇒ cap 留着。**
> **⇒ 这正是 #1394 存在的全部理由，也是【同一个静默丢弃病】的又一个实例。**

**我们不是引入它 —— 但我们正在重写那段代码。留着不动 = 明知故犯。**

**三个选项（交 review 决策，本 SPEC 不擅自选）：**
1. `mark_unreachable_locked` 的 dead-letter **排除 cap op**（`:absorb_cap` / `:revoke_cap`），把它们留在 buffer 里等恢复
2. **等 #1394 先落地**（它会把这两种 op 移出 `PendingDelivery`），本 PR 排在其后
3. 本 PR 先落，**显式记录这条已知的安全丢弃**，由 #1394 收口

**排序风险**：若本 PR 先落且不做 1，则在 #1394 落地前的窗口里，**每一次 transport 超时都可能静默丢掉一条 cap revoke**。

本 amendment 使 **选项 2（等 #1394 durable delivery 先落地）最便宜**：P3/P4 已改成共享 durable-delivery seam，不再要求先建 fault-specific retry worker；之后只需把 fault envelope 注册为第二类 producer/consumer。这里仅记录成本，不替 lead 选择 1/2/3；三项仍全部 deferred to lead/doc-team review。

### C. #1402（AgentRuntime ownership boundary）—— 新 arch 门禁

`apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs` + scanner：扫 `ezagent_domain_session` 对 agent 运行时的调用，`@allowlist` 用 `source_anchor`（精确函数 + 精确调用表达式）逐条钉死。

**禁止集（精确枚举）**：`Entity.Agent.spawn_from_template_content/manifest` · `Domain.Pty.alive?/status` · `Domain.Pty.Server.phase` · `ActionSet.Sandbox.read_persisted_state`；上下文判定还覆盖 `SpawnRegistry.ensure_live/spawn_detailed` · `Lifecycle.destroy` · `SessionManager.*` · `KindRegistry.lookup`（agent 形状目标）。

**⇒ `Ezagent.Agent.Faults` 不在禁止集里，本设计的 session-side notification reconciler 今天【不会】让门禁变红。**

**但**：它会新增一条 **session → agent 域**的边，**而那个 PR 的全部目的就是收缩这类边**。

> **不许从门下钻过去。** 这条边必须摆上台面：**明着加进 #1402 的 allowlist（带 review），或者重新设计让它不存在。** → **交 codex 决策（§12-ter）。**

### D. 基线核对（已验证）

**本 SPEC 依赖的 19 个文件，在这 7 个 commit 里【一个都没被动过】** ⇒ 全部 file:line 引用**仍然有效**。
#1399（ed25519 签名）碰了 `cap.ex` / `capability.ex`，**没碰 `capability_registry.ex`** ⇒ P1 的豁免缓存 chokepoint **完好**。需 rebase。

## 12-ter. Normative decision — Option **B**, remove the edge

**Decision:** session 永不读取、claim、回填或 reconcile `agent_faults`；不向 #1402 gate 添加 allowlist。`ezagent_domain_agent` owns `agent_faults` and emits a self-contained durable fault envelope. `ezagent_domain_session` owns `agent_fault_notification_obligations` and performs only durable ingest, owner resolution, claim/retry, and `Notifications.notify` from that table.

**为什么不是 A：** #1402 的目标不是“scanner 绿”而是收缩 Session 对 Agent control/runtime 的 ownership。其 design 明确规定 Session→Agent 依赖只允许窄 facade、反向依赖禁止（`docs/superpowers/specs/2026-07-14-agent-runtime-boundary-design.md:28-40,128-141`），并把 agent control plane 归 `ezagent_domain_agent`、conversation plane 归 `ezagent_domain_session`（同文件 `:54-65`）。给 fault-row mutation 加 allowance 会把新债务永久钉进一张目标为空的 shrink-only ledger。

**gate 事实：** gate 动态扫描 `apps/ezagent_domain_session/lib/**/*.ex`（`apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs:6-15,188-200`）；allowance identity 是 exact `path + class + source_anchor`（scanner `:368-373`），anchor 是 `definition|Module.function(full normalized args)`（scanner `:359-366`）。exact forbidden calls 位于 scanner `:12-19`；contextual `ensure_live`/`spawn_detailed`、`Lifecycle.destroy`、`SessionManager.*`、agent-shaped `KindRegistry.lookup` 位于 `:259-330`。`Ezagent.Agent.Faults` 今天确实不在该集合，但 scanner 自称 syntax-only closed classifier（`:2-10`）；未命中不构成架构许可。

**依赖图证明：** `ezagent_domain_agent` deps 只有 core、domain_identity、domain_agent_bridge（`apps/ezagent_domain_agent/mix.exs:36-49`），所以它不解 owner、不调用 session/Notifications workflow。session 已单向依赖 domain_agent（`apps/ezagent_domain_session/mix.exs:63-68`），但 Option B 的 notification path 也不使用该依赖：它只消费共享 substrate 交付的 plain envelope，并写自己的 obligation table。domain-agent 不调用 session；session 不调用 `Ezagent.Agent.Faults`；core substrate 不含 Agent/Session 业务词汇。故没有循环，也没有把同一 edge 改名搬家。

**#1394 unification seam（lead-owned）：** producer contract = durable enqueue of a typed, idempotent envelope; consumer contract = durable ingest acknowledgement keyed by producer key; retry scheduling/recovery trigger/attempt accounting are the shared substrate. Fault key 是 `{agent_uri, fault_epoch}`；cap key 仍由 #1394 决定。两边不各建 sweeper。物理 table/module/event grammar deferred to lead/doc-team review。

**Gate amendment:** add an architecture experiment that injects `Ezagent.Agent.Faults.list_open/0` and `Ezagent.Agent.Faults.claim_notification/2` into a Session production fixture and requires RED, while the obligation-only consumer remains GREEN. Implementer may extend the classifier with a new exact class or a separate boundary gate; silently relying on today’s omission is forbidden。

## 12. 独立后续（不在本 PR）

- **★ bridge 到底为什么没 join？** §2.7 证伪了凭证归因。**病因未知**（`uv` 不在 PATH？`EZAGENT_BRIDGE_WS_URL` 不通？token 缺失？bridge 脚本自炸？）→ **独立调查，不阻塞本 PR**（本设计**刻意**不依赖病因）
- **Bug A** — `AuthObservers` 正则永不匹配（v2.1.209 实测）
- **Bug B** — `ParkedDialogWatch` 核心假设为假（健康 agent 的 REPL 就渲染 `❯`）。**10 秒 falsifier**：grep 生产日志 `PARKED on an UNKNOWN dialog`

---

## 13. Falsifier

| 声明 | falsifier |
|---|---|
| 超时静默 | 制造超时 → 断言零 telemetry / 零 error 日志（**现在必须红**） |
| 闸门挡管理 | 对非 `:ready` agent 发 `pty.write` → **现在必须**失败；P1 后必须成功 |
| **豁免不泄漏** | **非**豁免动作（含 `publish_cr` / `reconfigure` / `delete`）对 `:unreachable` agent → **必须**仍被挡 |
| **`:failed` 仍硬闭** | **豁免动作**对 `:failed` agent → **必须**仍被挡 |
| 授权未变弱 | 无权限者的 `pty.write` → **必须**仍 `:unauthorized` |
| **闭环真的通** | `:unreachable` agent → 制造一次 bind → **必须** `:ready`。**Sabotage：换回 `:failed`，此测试必须红** |
| **化身条件** | Kind 重启后再 bind → **必须【不】**恢复旧 gate |
| **加状态不崩/不吞** | **15 处逐一喂 `:unreachable`**；#13/#14 不 `CaseClauseError`，#15 必须 fail loud；callsite 集合改变时 ratchet 红 |
| **fault epoch restart/node safe** | 分配 epoch，重启 VM/换 node 再 arm → 新 epoch 必须更大；旧 epoch update 必须 0 rows。Sabotage：换回 process-local allocator 必须红 |
| **arm 无 DB / 无锁内 I/O** | Repo 不可用时调 `require_transport_join/2` 仍成功 arm，且开始 spawn 不访问 Repo；静态 gate 证明 `with_transition_locks/2` 临界区内无 Faults/Repo 调用。Sabotage：把 epoch allocator 放回 arm 必须红 |
| **lazy epoch 不串 generation** | generation A timeout 后阻塞 epoch allocation，re-arm 为 generation B 并让 B open，再放行 A：A 的 epoch 可留 counter gap，但不得附着 B、改动 B 的 open row、open/通知 A；对调 allocator 与 state table 到同一行时测试必须红 |
| **timeout 时 DB 失效可重试** | arm 后断 Repo 并让 gate timeout：gate 必须仍 `:unreachable` 且有 log/telemetry；恢复 Repo 且不发 PubSub，source reconciler 仍必须分配/附着 epoch、open row，通知链最终处理 |
| **故障行不会被复活** | timeout 写被阻塞 → settle → 放行 timeout → reconciler 后必须 `:resolved` 且零通知 |
| **旧 generation 不能覆盖新的** | epoch=5 延迟 update 撞 epoch=6 → 必须 0 rows |
| **ETS 行在【任何】死法后被清** | 优雅退出 / 崩溃 / **brutal kill（`Process.exit(pid, :kill)`）** → readiness 行**必须**已清 |
| **listener restart 可重建** | arm 后杀 listener（不杀 ETS owner/Kind）→ 新 listener 必须重建同 deadline 的 timer + 同 PID monitor；过 deadline 进入 `:unreachable`；杀 PID 清 row |
| **durable processing** | persist open row 后丢弃 PubSub/重启 producer+consumer → shared substrate 仍 durable-ingest session obligation，回填 obligation.handler_uri 并恰好通知一次 |
| **Option B 无 session→agent edge** | 在 Session production fixture 注入 `Ezagent.Agent.Faults.list_open/0` 或 `claim_notification/2` → architecture experiment 必须 RED；真实 notification reconciler 只查 `agent_fault_notification_obligations` 且 GREEN |
| **durable handoff 不靠 PubSub** | 持久化 open fault 后丢弃全部 wakeup 并重启 producer/consumer → shared substrate 最终把 envelope durable-ingest 到 obligation；sabotage 为 PubSub-only 必须红 |
| **resolved 不误通知** | 阻塞 opened envelope，先 durable 交付同 epoch resolved，再放行 opened → obligation 最终 resolved 且零 notify；session 不允许回读 `agent_faults` 获得答案 |
| **#1394 机制未分叉** | repository inventory 出现 fault-specific retry scheduler 与 cap-delivery retry scheduler 两套 attempt/backoff/recovery loops → gate/review 必须 RED |
| **cluster authority** | 非 workspace-owner node 的空/unknown ReadyGate 不得 resolve/open shared row；owner node truth 才能推进 |
| **workspace_uri 形状正确** | schema/raw 两路都存 `URI.to_string(workspace://…)`；`:any` → `workspace_scope_required` + telemetry，DB 无 row |
| **lookup_kind miss fail closed** | `:not_ready`/`:unreachable` registry miss 的两个 exempt action 都不穿透并发 telemetry；`:failed` terminate 窗口仍硬闭 |
| **cache 不半安装** | register 每个注入 raise 点都无 exemption-only row；unregister 开始即无 exemption；replacement race 不被 late compare-delete 清除 |
| 豁免集合无漂移 | CI gate：集合 ≠ allowlist ⇒ **红** |
| observer 失明 | §2.6 已跑 |
| **凭证归因是假的** | §2.7 已跑（无凭证 claude 照样发 MCP `initialize`） |

## Final lockability verdict（written after three-doc cross-check）

**Option B is LOCKED; the implementation package is NOT LOCKABLE yet.** SPEC、plan、handoff 已核对一致；只剩 lead/doc-team 拥有的 #1394 physical-unification mechanism 与 §12-bis-B cap-revoke option 1/2/3 两项决定。两项落文档后才可改判 LOCKABLE。
