# Notifications SPEC (历史存档 — 2026-05-24)

> **状态**: 历史时点存档(2026-05-24,PR-N5 时)。位于冻结的 `docs/superpowers/`
> 树 —— 不再维护;模块名/引用为当时状态。规范的 v2 SPEC:
> `docs/superpowers/specs/2026-05-24-notification-architecture-v2.md`
> (在 PR-N5 收尾时锁定)有决策 / OQ / 迁移计划。
>
> 本文件记录了当时的消费者契约(Behavior / LV / Plugin / Test 如何与
> notifications 系统协作)。
>
> 英文镜像: `2026-05-24-notifications.md`。

## §1 背景

### PR-N1 之前 (legacy producer fan-out)

每个产生 notification 的 Behavior (Workspace.add_member /
Identity.grant_cap / Chat.join / Lifecycle.terminate / Template.fork ...)
直接调用 `Ezagent.Notifications.notify/3`,各自约定 payload 形态;
消费者 (AdminLive / NotificationsLive) 各自 `Phoenix.PubSub.subscribe`
到某个 producer-specific topic。producer ↔ consumer 是 M:N 耦合 ——
新加一个 consumer 要去每个 producer 加一个复制订阅源。

这个 fan-out 模式违反:

- **P3 (单一事实来源)** —— 没有一个地方能回答 "这个 Kind 发出哪些
  notification?"
- **P14 (dispatch 是唯一通路)** —— `Notifications.notify/3` 是绕过
  CapBAC + audit + idempotency 的旁路通道
- **P22 (可靠性原语在 core 里)** —— 每个 producer 各自手写
  retention / cursor / fan-out 语义

### PR-N1 之后 (slice-change 引入 chokepoint —— 与 legacy 共存)

PR-N1/N2/N3 引入了 SliceChange 模型: slice 变更本身就是 trigger,
每个 Behavior 的 `:invoke` 返回 `{:ok, new_slice, result}`
(或 `{:error, _}`); `Kind.Server.commit_and_notify/3` 是唯一观察到
`new_slice != old_slice` 并发出 slice-change 事件的点。消费者用
`Ezagent.SliceChange.subscribe(entity_uri)` 订阅该实体的 stream。

**当前状态 (2026-05-26): 与 legacy `Notifications.notify/3` 共存**。
若干 producer 仍直接调用 legacy 路径 —— Workspace.add_member /
remove_member (`apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:94,124`),
Identity.grant_cap (`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:301`),
Template.fork (`apps/ezagent_domain_instance_message/lib/ezagent/behavior/template.ex:543`)。
PR-N5 是计划中的清扫 sweep,把剩余调用方迁到 SliceChange chokepoint
并删除 `Notifications.notify/3`。在 PR-N5 落地之前,两条路径都会发出
通知 —— consumer 可能从任一渠道收到逻辑事件。

PR-N5 之后的终态是 `commit_and_notify/3` 一个 chokepoint ——
可审计 / 可测试 / 不被 consumer 缺席阻断。

## §2 目标

1. **每个实体一个 PubSub topic, 而不是按 (producer, consumer) 对**。
   Topic 形态: `esr:entity:<self_uri>:slice_changed`。每个 Kind 实例
   一条 stream, 该实体所有 slice 变更都流过它。

2. **producer 不依赖 consumer 在场**。无论有没有人在听, Behavior
   都会发出。`Phoenix.PubSub.broadcast/3` 是 fire-and-forget; topic
   是社交契约, 不是投递保证。(consumer-presence 要求超出范围 —— 持久
   投递属于 §9 的 queue 层。)

3. **consumer LV 通过 `Ezagent.SliceChange.subscribe/1` 订阅**。
   wrapper 把 topic-shape 契约集中起来, consumer 不再手写 topic
   字符串 (这也是 §8 invariant test 可以 grep 直接 PubSub.subscribe
   的前提)。

4. **slice 变更本身是 trigger**。Behavior 作者**永远不**直接调用
   `Notifications.notify/3` (PR-N5 invariant 完全删除 legacy 函数)。

5. **最小化 envelope (默认安全)**。broadcast 事件不携带任何 slice
   内容 —— 只携带元数据 (URI / slice_key / cursor / wall-clock /
   `:ok | :error` 摘要)。订阅者如需 slice 数据, 通过 cap-gated 读取
   重新取数。

## §3 架构

```
Producer (任意 Behavior)
    │
    │   Behavior.invoke/4 返回 {:ok, new_slice, result}
    ▼
Ezagent.Kind.Runtime.handle_dispatch/4
    │
    │   diff: new_slice != old_slice ?
    ▼
Ezagent.Kind.Server.commit_and_notify/3    ◄── 观察 slice 变更的
    │                                          唯一节点
    │   1. 应用 slice
    │   2. Ezagent.Snapshot.maybe_save/4   ◄── 先持久化 (这样 snapshot
    │                                          crash 不会让订阅者收到
    │                                          一个从未真正落盘的事件
    │                                          —— PR-N1 round-2 修复)
    │   3. Ezagent.SliceChange.emit/4      ◄── 然后发出
    ▼
Ezagent.SliceChange.emit/4
    │
    │   构造最小化 envelope (5 个键, 无 slice 内容)
    │   per-URI cursor 递增 (Cursors GenServer)
    │   Phoenix.PubSub.broadcast(esr_pubsub, topic(self_uri), envelope)
    ▼
{:slice_changed, %{uri, slice_key, cursor, event_at, result_summary}}
    │
    ▼
Consumer LV (AdminLive / NotificationsLive / ExternalMirror Worker …)
    │
    │   mount(_, _, socket): SliceChange.subscribe(entity_uri)
    │   handle_info({:slice_changed, event}, socket):
    │       — 若 event.slice_key 在 cares_about 列表, 通过
    │         Ezagent.Kind.get_slice(uri, slice_key) 或
    │         Ezagent.Invocation.dispatch/1 (cap-gated 读) 重新取数
    │       — 应用到 assigns / push patch / push flash
```

### 持久化意图 (LV 重连)

`Ezagent.NotificationSubscriptions` 是一个 protected ETS 注册表
(GenServer 串行化写入), 用于持久化订阅意图。某个 LiveView crash 后
重连, 用户的 "我订阅了这条 stream" 意图跨越重连存活。该注册表维护
(entity_uri, stream, ctx) 三元组; LV 重 mount 时调用
`register_subscription/3` 重新绑定。

这是订阅状态的唯一 ETS 持有者 —— consumer 代码直接的
`Phoenix.PubSub.subscribe` 是 volatile runtime side;
`NotificationSubscriptions` 是 durable side。

## §4 Cap 模型

cap 模型把**producer**和**consumer**分开:

### producer —— 不做 cap 检查

producer 不对 caller cap 做闸门。某 Behavior 的 `:invoke` 之所以
能修改 slice, 是因为在 dispatch step 5.5 (`Kind.holds_cap?/2`
查询 `Behavior.required_caps/0`) 那一步已经过了 cap 检查。
slice-change emit 是对 "这次合法的修改发生了" 的系统级观察, 不需
要二次 cap。

system principal (`Ezagent.SystemPrincipal.Catalog` —— 见 PR-CC-1
2026-05-25) 是 boot-time + async-replay slice 变更典型的 "producer"
身份; 它们不持有 cap, 因为它们不在 dispatch, 只在观察。

### consumer —— cap-gated

`Ezagent.Behavior.Notifications` (注册在 User Kind 上):

- **Subject**: `(User|Agent, :subscribe, Ezagent.Behavior.Notifications)`
- **`dispatchable?/0`**: `false` —— cap-only, 没有 `:invoke` dispatch
- **默认授予**: 每个新建 User 在注册时 (Identity.create/3 → cap
  注入) 自动获得自己 entity URI 上的 `Notifications.:subscribe` cap

`SliceChange.subscribe/1` 在 wrapper 边界查这个 cap: caller URI 必
须持有目标 entity URI 上的 `Notifications.:subscribe` cap 才能订阅。
wrapper 在 cap 拒绝时直接 raise (let-it-crash) —— 没有静默的订阅
意图丢失。

跨 workspace 订阅由标准 `:cross_workspace_denied` 规则把关 (dispatch
step 5.6 / invariant 13); 非 system-workspace 的 caller 订阅其他
workspace 的实体会得到明确的拒绝。

## §5 producer 清单 (当前, 2026-05-26)

producer **不是**手工维护的清单 —— 任何 `:invoke` 会修改 slice
的 Behavior 都是隐式 producer。下表仅作定向参考:

| Behavior | Action | 改动的 slice | consumer 兴趣 |
|---|---|---|---|
| `Ezagent.Behavior.Workspace` | `:add_member` / `:remove_member` | `workspace_members` | AdminLive / WorkspaceMembersLive |
| `Ezagent.Behavior.WorkspaceUserAdmin` | `:create_user` | `users` (workspace-scoped users index) | AdminLive |
| `Ezagent.Behavior.Identity` | `:grant_cap` / `:revoke_cap` | `caps` | AdminCapsLive |
| `Ezagent.Behavior.UserCredentials` | `:set_password` | `credentials` | (audit-only —— UI 重读) |
| `Ezagent.Behavior.UserTokens` | `:mint` / `:list` / `:revoke` | `tokens` | TokensLive |
| `Ezagent.Behavior.Chat` | `:send` / `:join` | `chat_history` / `chat_members` | ChatLive (实时滚动) |
| `Ezagent.Kind.Server` | terminate 流程 | `lifecycle_status` | AdminLive / ObservabilityLive |
| `Ezagent.Behavior.Template` | `:fork` | `template_lineage` (新 template URI) | TemplatesLive |
| `Ezagent.Behavior.FeishuUserBinding` | `:bind` / `:unbind` | `feishu_binding` | FeishuBindingsLive |
| `Ezagent.Behavior.FeishuSessionBinding` | `:bind` / `:unbind` | `feishu_session_binding` | FeishuBindingsLive |
| `Ezagent.ExternalMirror.Worker` | 每次 `:publish` | publisher slice | DebugPanel (publish 健康度) |

PR #357 的 MED batch 把 Chat.join + Lifecycle.terminate + Template.fork
加入了隐式 producer 集合 (在此之前它们仍在调用 legacy
`Notifications.notify/3` —— PR-N5 sweep 已迁移)。

## §6 consumer LV

当前 consumer (post-PR-N5 audit, 2026-05-26):

| LV | 订阅 | 关心的 slice key |
|---|---|---|
| `EzagentPluginLiveview.AdminLive` | 当前用户 URI + 当前 workspace URI | `caps`, `workspace_members`, `lifecycle_status` |
| `EzagentPluginLiveview.AdminCapsLive` | 当前用户 URI (admin self) | `caps` |
| `EzagentPluginLiveview.NotificationsLive` | 当前用户 URI | all (mount 时用 `cares_about` 列表过滤) |
| `EzagentPluginLiveview.ObservabilityLive` | system workspace URI (仅 admin) | `lifecycle_status` (跨租户审计上下文) |
| `EzagentPluginLiveview.ChatLive` | 当前 session URI | `chat_history`, `chat_members` |
| `EzagentPluginLiveview.WorkspaceMembersLive` | 当前 workspace URI | `workspace_members` |
| `EzagentPluginLiveview.TokensLive` | 当前用户 URI | `tokens` |
| `EzagentPluginLiveview.FeishuBindingsLive` | 当前用户 URI + 当前 workspace URI | `feishu_binding`, `feishu_session_binding` |
| `Ezagent.ExternalMirror.Worker` | bound session URI | `chat_history` (event_to_payload → 外部系统) |

`NotificationsLive` 是规范的 "通知抽屉" —— 展示 caller entity URI +
所在 workspace 的不过滤 slice-change feed。

## §7 故障模式

### F1 —— producer emit 时 raise

如果 `SliceChange.emit/4` raise (例如 PubSub 挂了, Cursors GenServer
crash 了), wrapper 有 `rescue` 子句, 用 `Logger.error` 记录 producer
URI + slice_key + exception, 然后返回 `:ok` 给调用方。slice 修改仍然
落盘 (在 emit 之前已经 commit 完 —— 见 §3 step 2); 仅 notification
丢失。这是 `feedback_let_it_crash_no_workarounds` 的 let-it-crash
取舍 —— 我们宁可丢一次通知, 也不要让通知系统的故障阻塞 dispatch。

PR #357 codex r1 P27 audit 验证了 rescue 子句到位 + `Logger.error`
提供了足够上下文调试 "用户报告没收到通知"。

### F2 —— Workspace SoT 不一致

如果 entity URI 的 workspace 段与 `WorkspaceRegistry.lookup(entity_uri)`
返回不一致, `SliceChange.emit/4` 以 URI 段为准 —— URI 的 workspace
段是 SoT (per SPEC v3 §5.15 + invariant 4); registry 是 cache。emit
按 URI 段进行, `workspace_sot` invariant test 在 producer 触发此分歧
时让 build 失败。

### F3 —— topic 无订阅者

Phoenix.PubSub 在 broadcast 到零订阅者的 topic 时静默 no-op。这是
设计如此 —— producer 不依赖 consumer 在场 (§2)。后到的订阅者只
看到订阅点之后的 slice-change; 历史回放明确超出范围 (§9)。

### F4 —— cursor 回退

`Ezagent.SliceChange.Cursors` 是 per-URI 单调递增计数器 (GenServer
串行化写入)。如果它回退 (进程 crash + 从旧 snapshot 重启), 订阅者
可能看到重复 cursor —— 它们应当用 `(uri, cursor)` 做幂等处理。
invariant test `slice_change_cursor_monotonic_test.exs` 在并发 emit
场景下验证 GenServer 的单调性。

## §8 invariant 测试

### 已落地 (2026-05-26 核实)

1. **`slice_change_event_carries_no_slice_content_test.exs`**
   (`apps/ezagent_core/test/invariants/`) —— broadcast envelope 只允许
   5 个键 (URI / slice_key / cursor / event_at / result_summary)。
   断言 `old_slice` / `new_slice` / `result` / `caller` / `kind_module`
   都不泄漏 (PR-N3 codex r2 HIGH-1 修复)。这是本文撰写时唯一已落地的
   PR-N invariant 闸门。

### 计划中 (PR-N5 sweep, 未落地)

v2 SPEC 原本规划 PR-N5 sweep 包含 5 道闸门。2026-05-26 时点中 4 道
仍是 TBD —— 因为 `Ezagent.Notifications.notify/3` **仍在使用**(数个
producer 没迁移)。slice-change chokepoint 跟 legacy `Notifications.
notify/3` 共存; PR-N5 会把两者合一。计划中的 invariant:

2. **`no_direct_notifications_notify_test.exs`**(计划)—— grep 闸门:
   `Ezagent.SliceChange` 内部以外没有调用 `Ezagent.Notifications.
   notify/3`。跟随 PR-N5 删除 sweep 同时落地。

3. **`no_pubsub_broadcast_to_slice_change_topics_test.exs`**(计划)
   —— grep 闸门: `Ezagent.SliceChange` 模块以外没有向
   `esr:entity:*:slice_changed` topic 做 `Phoenix.PubSub.broadcast`。

4. **`no_pubsub_subscribe_to_slice_change_topics_test.exs`**(计划)
   —— grep 闸门: `Ezagent.SliceChange` 和 `Ezagent.NotificationSubscriptions`
   以外没有 `Phoenix.PubSub.subscribe` 到 slice-change topic。

5. **`every_behavior_mutating_slice_is_producer_test.exs`**(计划)
   —— 每个 `Behavior` 的 `invoke/4` 在 slice 变更时,在
   `apps/ezagent_*/test/integration/` 下都有断言 slice-change 发出
   (`assert_receive {:slice_changed, _}`) 的集成测试。这是
   `feedback_completion_requires_invariant_test` 的架构目标 invariant。

PR-N5 单独跟踪;sweep 落地时本 SPEC 会更新("计划中"段并入"已落地")。

## §9 超出范围

- **跨 workspace fan-out**。Notification 留在 caller 的 workspace 内
  (per invariant 13)。跨 workspace 观察者 (例如 system-workspace 管理员)
  通过 cross_workspace cap 订阅; 这由 §4 + invariant 13 覆盖, 不需要
  任何跨 workspace fan-out 机制。

- **持久 queue / 回放**。slice-change 事件是瞬态的 —— emit 时没有订
  阅者就丢了。要做持久 queue (offline-user 收件箱, mobile push 在 app
  启动时回放) 需要单独的 Kind (大概是 Resource 方案
  `resource://notification_queue/<workspace>/<user>`), 自带 retention /
  ack 语义。v1 范围外; 在 `docs/futures/todo.md` 的 "Notification
  durability" 条目下跟踪。

- **webhook fan-out 到外部系统**。用 ExternalMirror Domain (invariant 15)
  —— Adapter 上的 `event_to_payload/1` 通过 `Publisher.subscribe_from/3`
  订阅 slice-change stream。直接从 binding 模块 `Phoenix.PubSub.subscribe`
  是 P11 违例, invariant 16 会抓到。

- **多区域 (multi-region)**。Phoenix.PubSub fan-out 默认单节点。
  多区域需要 `Phoenix.PubSub.Redis` (或类似) 配置; topic 形态不变,
  但 SPEC 不规定 transport。在 `docs/futures/todo.md` 的
  "Phoenix.PubSub multi-region" 条目下跟踪。

- **notification 去重**。订阅了重叠 entity URI (例如 user + workspace)
  的 consumer 可能收到逻辑重复事件。去重是 consumer 责任
  (按 `(uri, cursor)` 幂等处理, 见 §7 F4)。

---

## 另见

- `apps/ezagent_core/lib/ezagent/slice_change.ex` —— emit 原语 +
  envelope 形态 moduledoc
- `apps/ezagent_core/lib/ezagent/notification_subscriptions.ex` ——
  持久化意图 ETS 注册表
- `apps/ezagent_core/lib/ezagent/behavior/notifications.ex` ——
  User Kind 上的 cap Behavior
- `apps/ezagent_core/lib/ezagent/kind/server.ex` `commit_and_notify/3`
  —— 唯一 emit chokepoint
- `docs/superpowers/specs/2026-05-24-notification-architecture-v2.md`
  —— 规范的 v2 SPEC (决策 / OQ / 迁移)。Allen 的 mental-model 修正
  (chat ≠ notification; notification = 跨 surface 同一 entity 的状态
  同步; 临时 notify 被禁) 在该 SPEC 的 §2 中。
