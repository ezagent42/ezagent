# ExternalMirror Domain — session 数据镜像到 plugin 提供的外部 surface

**状态:** r3 (最终版, 取代 r1 和 r2). 2026-05-25.
**层级:** 新 Domain app `apps/ezagent_domain_external_mirror/` + `apps/ezagent_domain_instance_message/` 加 Publisher behaviour (Session Kind 实现).
**触发:** Allen 2026-05-24 (Feishu) — "请规划 ExternalMirror 的 Domain。注意 game 只是举例方便你理解这个场景, 具体 external 是什么形式 (game, chat, 等等) 由 plugin 来决定, 这个 domain 只负责 session 数据的同步, 具体数据被怎么使用 (网页、ws 通讯等) 应该是透明的". 加上 Allen 当晚 Feishu 上拍板的三层心智模型 (publisher / adapter / binding).
**前置 (全部已 merge 到 main):**
- `docs/superpowers/specs/2026-05-24-caps-data-ownership-v2.md` (PR #306 + #307 + #308 + #309 + #310) — r3 的 bind cap 结构性派生自这套 `data_owner/1` 框架。**`Ezagent.Behavior.Chat.data_owner/1` 和 `Ezagent.Entity.Session.owner/1` 已经存在** (`apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex:846` 和 `apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex:290`). `Ezagent.Behavior.IdentityAdmin.invoke(:grant_cap, ...)` 是单一 grant 入口, §5.2 已经在执行 (`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:170-220`).
- `docs/superpowers/specs/2026-05-24-notification-architecture-v2.md` (PR-N1 已落地; 生产者迁移 PR-N2…N5 在进行). 定义了 `Ezagent.SliceChange` 原语, r3 的 Publisher 层在它之上构建.
- SKILL P1 (plugin 隔离北极星); P3 (单一真实源); P9 (读什么数据 → 层级); P11 (plugin 外部集成 = Receiver Kind/Behavior 在已有 scheme 上 — **绝不 PubSub.subscribe + 外部写**); P14 (dispatch 是 Kind 间唯一路径); P15 (cap 默认窄); P16 (Kind 单一 spawn 入口); P18 (用户面无静默丢失); P22 (可靠性原语在 core; plugin 作者不能绕过); P23 (declare-don't-call plugin 合约).
- 本 Domain 退役的一次性代码:
  - `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/behavior/feishu_outbound.ex` (311 LOC; Session 上的单租户 `:notify_external` Behavior)
  - `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/session_binding.ex` (130 LOC; `feishu_session_bindings` 表)
  - `Ezagent.Behavior.Chat` 的 `maybe_notify_external/3` 投机 dispatch (`apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex:699-720`)
**双语对照:** `2026-05-24-external-mirror-domain.md` (英文版).

---

## 0a. r4 修订记录 (相对 r3 的变化)

r3 被 codex round-3 返回 `needs-attention`, 含 3 HIGH + 1 MEDIUM. Allen autonomous-mode 授权应用; r4 结构性修复全四个:

1. **HIGH-1 修正 (bind 自死锁).** r3 §8.2 让 `:bind` action body 同步调 `Ezagent.Kind.spawn(Worker)`, 同时 Worker 的 `init_slice/1` 立刻调 `Publisher.subscribe_from(...)` (对同 Session 的 `GenServer.call`). 按现有 runtime (`apps/ezagent_core/lib/ezagent/kind.ex` + `kind/server.ex`), `Kind.spawn/2 → DynamicSupervisor.start_child/2` 等 `Kind.Server.init/1` 同步跑 `init_slice/1` — Session 调用链等 Worker init 起来, Worker init 又回调 Session = 死锁. r4 通过 `handle_continue` 把 worker 启动和订阅分离: Worker `init_slice/1` 返最小 state (binding 参数; 无订阅, 无传输打开); Worker 的 `Kind.Server` 在 init 返回后调度 `handle_continue(:subscribe_and_init, state)`; 只在那里调 `Publisher.subscribe_from`. Session 的 `:bind` action body 的 `Kind.spawn/2` 只等廉价 init (无 Publisher 调); 立刻返回. 订阅几毫秒后异步发生. 那个订阅 gap 期间发的 SliceChange event 丢 (按 §3 latest-wins 可接受) — 被避免的是死锁. 见更新的 §3 + §8.2 + §6.1.

2. **HIGH-2 修正 (DynamicSupervisor restart intensity 是 supervisor 范围).** r3 有一个 `Ezagent.ExternalMirror.WorkerSupervisor` `DynamicSupervisor` 带 `max_restarts: 3, max_seconds: 30` 并声明 per-binding 隔离. OTP restart intensity 是 per-supervisor 的 — 4 个不同 binding 各崩一次 30s 内累积触发 supervisor 把所有兄弟拽下. r4 引入**两层 supervisor 拓扑**: `Ezagent.ExternalMirror.RootSupervisor` (`:one_for_one`) 监督 per-binding `PerBindingSupervisor` 实例; 每个 per-binding supervisor 自己是 `:one_for_one` `Supervisor`, 只持有 ONE Worker 子, restart intensity `max_restarts: 3, max_seconds: 30`. 现在: 单个坏 binding 的 worker 崩 → 那个 binding 的 PerBindingSupervisor 数 restart; 触发, 只那个 PerBindingSupervisor 崩; RootSupervisor 的 `:one_for_one` 策略意味着兄弟不动. RootSupervisor 自己 intensity 设宽 (`max_restarts: 100, max_seconds: 60`) 因为 per-binding-supervisor 崩应该是稀有结构事件, 不是 workload 驱动. 见更新的 §5.3 + 新 §6.3.

3. **HIGH-3 修正 (持久 binding 重水化后无 worker).** r3 有 `Behavior.ExternalMirror.init_slice/1` 在 Session Kind init 时从 `external_mirror_bindings` 表 rehydrate binding, 但 worker 的 eager-spawn 只在 `:bind` action body 内. app restart 或 Session Kind restart 后, slice 重建 (binding 在) 但 worker 不存在 → SliceChange event 发但无订阅者 → 静默 mirror 丢. r4 在两处加**reconciliation 步**: (a) `Behavior.ExternalMirror.init_slice/1` 在 Session Kind 上调度 `handle_continue(:reconcile_workers, ...)` 枚举 rehydrated binding 并幂等 `Kind.spawn/2` 每个 worker (P16 幂等保证已运行则 no-op); (b) application 启动时, `Ezagent.ExternalMirror.Application.start/2` (AdapterRegistry + BindingRegistry 已填充后) 跑 `BootReconciler` 直接查 `external_mirror_bindings` 表 + 幂等 spawn 任何 Session Kind 还没在本节点 host 的 worker (多节点情形). 两个 reconciliation 路径在 PR-EM-3 验收测试. 见新 §3.1 + 更新的 §9 PR-EM-3 验收测试 (h).

4. **MEDIUM 修正 (`target_ownership_check` 是 plugin I/O 在 Session GenServer 内, 无 timeout / 无反递归合约).** r3 让 `:bind` 在 Session GenServer 内同步调 `adapter_module.target_ownership_check(...)`, 无 timeout, 无阻止 adapter 回入 ezagent dispatch 的规则. r4: (a) 检查在 `Task.Supervisor.async_nolink/3` 里跑, 有界 timeout (default 5 秒, adapter 可通过 `target_ownership_check_timeout/0` callback 覆盖). Timeout → `{:error, :target_check_timeout}`. (b) Adapter 合约 @moduledoc 显式禁止从 `target_ownership_check/2` 内调 `Ezagent.Invocation.dispatch/1` (定规则; PR-EM-FINAL 新 invariant 测试 grep 任何 adapter 模块传递 deps 内 `Ezagent.Invocation.dispatch`). (c) Adapter 合约 @moduledoc 澄清: `event_to_payload/1` 是纯无 I/O callback; `target_ownership_check/2` 是 ONE bind-time-only adapter callback 允许做外部 API 调用 (Lark/Slack/etc 需要这个来验证成员). 两个 callback 故意是不同副作用类.

两层 supervisor + handle_continue 订阅 + boot reconciler + 有界 target 检查一起保住三层心智模型同时关闭生命周期缺陷.

---

## 0. r3 修订记录 (相对 r2 的变化)

r2 被 codex round-2 返回 `needs-attention`, 含 1 CRITICAL + 3 HIGH + 1 MEDIUM. Allen 2026-05-24 晚授权强制修订, 同时拍板三层心智模型 (publisher / adapter / binding) 为最终框架. r3 都吸收了:

1. **CRITICAL 修正 (P11 逃出不彻底).** r2 终点对 (per-binding worker Kind) 但 Session Kind 自己仍是 PubSub 订阅者 — `handle_info({:slice_changed, ...}, ...)` clause 然后 dispatch 出去. 这个 handler 就是 `Phoenix.PubSub` 消费者做路由决策 (扇出到哪些 binding), 即使叶子是 dispatch. Codex 指出: "SESSION Kind 在当 broker — 这仍然是 P11 anti-pattern, 只是上移一层". r3 结构性修正: 把 Session 提升为 **Publisher** (Allen 三层模型): Session Kind 存储自己 slice change 历史; 订阅由 binding **worker** 负责 (每个 worker 在它自己 init 时订阅); Session Kind 不知道 binding 存在. 任何模块都没有 "PubSub 订阅者 + 外部写" 这个模式 — worker 订阅的是结构化 Publisher 流 (不是裸 PubSub), 外部写发生在 worker Kind 的 `:invoke(:publish, ...)`.

2. **HIGH 修正 (per-binding 隔离是 Task-based 而非 supervised GenServer).** r2 在 dispatch 站点用 `Task.Supervisor.start_child`. 这给了 per-slice-change 崩溃隔离但每个 Task 是新 process — 没有 cursor, 没有 backpressure, 没有 429 处理, 没有 per-target rate-limit 状态. Allen 三层模型把 **stateful per-binding GenServer** 放在 binding 层: 每个 binding 一个 supervised GenServer, 拥有自己的 publish 循环 / retry 状态 / last cursor / 外部系统 backpressure. r3 把 Task-per-slice-change 替换为 supervised Worker Kind (每 binding 一个 process, 生命周期 = bind→eager-spawn / crash→restart / unbind→graceful exit).

3. **HIGH 修正 (per-adapter cap 是内联检查; 非结构性注册).** r2 声明了两个 cap 但第二个 (`{ExternalAdapter, adapter_id}`) 在 `:bind` action body 里检查, 不是结构性 cap subject 注册在 `CapabilityRegistry`. r3 让它结构化: 每个 adapter 在 plugin boot 时通过 `cap_subject/0` callback 声明, 注册到 `Ezagent.CapabilityRegistry`; `:bind` action 的 §5.2 grant 检查自然通过 adapter-cap Behavior 的 `data_owner/1` 强制 (返回 `:any` = workspace-admin grant). 此外, r3 引入 **per-target ownership callback** (`target_ownership_check(caller, target_id) :: :ok | {:error, _}`), Domain 在 BIND TIME 调用 — Bob 不能把自己 session 绑定到 CEO 的 Lark chat_id, 即使他持有两个 bind cap, 因为 Lark 那边知道 Bob 不是那个 chat 的成员.

4. **HIGH 修正 (Grill 5 — adapter↔binding 解耦结构性强制).** r2 把 `FeishuAdapter.publish/3` 和 worker Kind 放在同一 plugin; 没有任何机制阻止 plugin 作者把它们写成一个模块. Allen 拍板: 选项 (a) — Domain 通过 behaviour 形态强制不同模块. r3 的 `Adapter` behaviour 要求 `binding_module/0` callback 返回匹配的 `Binding` 模块; `Binding` behaviour 要求 `adapter_module/0` 反向声明. Domain 的 plugin 编译期检查 (`:ezagent_plugin_check`) 拒绝同时实现两个 behaviour 的模块.

5. **OQ-EM-10 解决 (worker lifecycle).** r2 留着 "实施者决定". r3 锁死: **bind 成功立刻 eager-start / 崩溃 supervised restart / slice 变化 latest-wins (不重放崩溃期间错过的事件) / unbind 时 graceful exit**. Publisher 结构化 cursor 流原则上支持 replay-from-cursor, 但 V1 worker 在 restart 时把 cursor 重置为 `:latest` (operator 需要时可手动触发重放 — 见 OQ-EM-A). §3 文档化.

6. **MEDIUM 修正 (atomicity OQ-EM-8 论证但没钉死).** r3 拍板: **Session slice 是 SoT + `BindingRegistry` ETS 是读 cache** (snapshot writer P22 处理持久化). 没有 dual-SoT atomicity 问题, 因为只有一个 SoT.

另外: r3 把 Allen 的三层心智模型作为 SPEC 主要组织原则 (§2), 而不是脚注. 之前 r2 的两段框架 ("primitives" + "flow diagram") 替换为分层 §2.1 / §2.2 / §2.3 详细走查.

---

## 1. 问题陈述 (今天什么坏了 + 架构洞察)

### 1.1 今天的痛点 (具体: Feishu)

Feishu plugin 通过一条一次性路径把 session 消息镜像到 Lark chat. 四块, 都是 plugin 特定的:

1. **side-join 表** — `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/session_binding.ex` 在 `feishu_session_bindings` SQLite 表存 `chat_id ↔ session_uri` 行.
2. **Session-Kind Behavior** — `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/behavior/feishu_outbound.ex` 在 `Ezagent.Entity.Session` 注册 `:notify_external`. 系统里唯一一个从 `:invoke` 里发字节到非 ezagent surface 的 Behavior.
3. **`Behavior.Chat` 里的投机 dispatch** — `apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex:699-720` 的 `maybe_notify_external/3` 查 Session Kind 上有没有 `:notify_external` 注册并 dispatch.
4. **plugin 自己的 admin LV** — `/plugins/feishu/bindings` 用来 bind/unbind.

这套对 Feishu 工作, 恰好一次. 不能组合. 下一个 plugin (Slack, Discord, game event 流, web-view mirror, WS 远控 surface) 面临四个结构性问题:

- **Session Kind 上的 `:notify_external` 槽是单租户.** 只有一个 plugin 能注册; 同时跑 Feishu 和 Slack 的 workspace 必须二选一.
- **"plugin 注册没?" 检查在 Chat Behavior 代码里.** 任何 Kind 上的任何 Behavior 想把自己 slice change 镜像出去都得手写同样的投机 dispatch. 模式不能跨 Behavior 组合.
- **Chat 和 FeishuOutbound 的合约是 "我们恰好都知道 action atom 是 `:notify_external`".** 没有正式接口; 没有已注册 surface 列表; 没有 per-binding cap; 没有 per-binding 生命周期.
- **每个 plugin 重写自己的 admin LV / schema / mix task / 数据模型.** 没有跨 plugin operator surface.

加第五个 — 思考下一类 adapter 时浮现: **今天 mirror frame 是 `%Ezagent.Message{}`** (触发器是 chat send). plugin 想镜像非 chat slice change (agent 的 `:idle → :running` 状态转换, session 参与者列表增长, working-copy fork, PTY 帧爆发) — 没有路径; Chat 的 `maybe_notify_external/3` 只在 `:send` 时触发.

### 1.2 架构洞察 (Allen 2026-05-24 Feishu)

三层, 按职责分离:

- **Publisher** — Session 是结构化流, 带 history / cursor / replay. Session 不知道谁消费; session 只 publish.
- **Adapter** — 无状态模块, 知道 wire format (Feishu API / Slack API / game server RPC / 浏览器内 WS). 把 publisher event 翻译为 adapter 特定 payload. 无状态, 无传输, 无 backpressure.
- **Binding** — 有状态 per-target GenServer, 拥有到 ONE target 的 publish 循环. 从 cursor 订阅 publisher, 让 adapter 翻译, 拥有外部传输调用, 处理 429 / retry / backpressure. 一个 binding = 一个 Lark chat / 一个 Slack channel / 一个 game room / 一个浏览器 WebSocket. 一个 binding 崩只影响那个 target.

Domain 拥有层级 wiring (Publisher behaviour + Binding GenServer 骨架 + Adapter 合约 + cap 形状 + invariant 测试). plugin 每个外部 surface 出两个模块: 一个 Adapter + 一个 Binding.

### 1.3 为什么是 Domain (不是 plugin, 不是 core)

按 **P9** (reads-what-data → tier):

- Domain 读 `%Ezagent.SliceChange{}` 事件来自任何 Kind (PR #303 SliceChange 原语). 读作为一等数据存储的 binding. 自己不写外部.
- plugin 读自己的外部 API (Feishu Open API / Slack Web API / game server RPC). 系统里唯一知道那个 API 存在的模块.
- `core` 错, 因为 Publisher / BindingRegistry / AdapterRegistry 由 ≥2 下游 plugin 共享 — 这是 Domain 的定义.

新 Domain — `apps/ezagent_domain_external_mirror/` — 拥有:

- `Ezagent.Behavior.Publisher` behaviour (这里定义; **首个实现是 `Ezagent.Entity.Session` 在 `apps/ezagent_domain_instance_message/`** 按 Allen 选项 (a)).
- Session Kind 上的 `Ezagent.Behavior.ExternalMirror` behaviour (`:bind` / `:unbind` / `:list_bindings`).
- per-binding Worker Kind 上的 `Ezagent.Behavior.ExternalMirrorWorker` behaviour (`:publish`).
- `Ezagent.ExternalMirror.AdapterRegistry` 和 `Ezagent.ExternalMirror.BindingRegistry` (ETS 读 cache).
- adapter / binding behaviour 合约 (`Ezagent.ExternalMirror.Adapter`, `Ezagent.ExternalMirror.Binding`).
- cap subject (per-session bind cap; per-adapter allow cap) 和守护架构承诺的 invariant 测试.

plugin 每个外部 surface 缩到两个模块: 一个 `Adapter` (无状态 wire 翻译) + 一个 `Binding` (有状态 per-target GenServer). 每个模块都是参与的最小必要.

### 1.4 信任模型

同 VM plugin 是受信代码 (PR #303 round-5 处置; Allen 2026-05-24 批). Domain 的 cap 和 per-target 检查是 **用户级 authorization** (哪个用户可以把哪个 session bind 到哪个 adapter 的哪个 target), NOT plugin-vs-plugin BEAM sandboxing. 如果 plugin 不受信, 相关边界是 OS 级隔离 (独立 VM). Non-goal #3 显式覆盖.

---

## 2. 三层心智模型

### 2.1 Publisher — Session 是结构化流

**Publisher** 是任何暴露 slice-change 历史 + cursor + replay 语义的 Kind. 定义为新 behaviour `Ezagent.Behavior.Publisher` 在 `apps/ezagent_domain_external_mirror/`. 按 Allen 选项 (a), 首个实现住在发布 domain (`Ezagent.Entity.Session` 在 `apps/ezagent_domain_instance_message/`) — NOT 在拷贝 session event 的外部镜像缓冲. Session 就是 publisher.

```elixir
defmodule Ezagent.Behavior.Publisher do
  @moduledoc """
  暴露自身 slice change 结构化流的 Kind, 带 history + cursor + replay
  语义. 订阅者从 cursor 消费 (不透明, 单调递增, per-publisher);
  publisher 保留近期事件的有界窗口, 让 restart 的订阅者可以从 checkpoint
  恢复.

  在 Kind 上实现这个 behaviour 是该 Kind 变成 mirrorable 的方式.
  ExternalMirror Domain 消费 Publisher; 它不直接观察裸 SliceChange
  envelope (那是 Publisher 的内部实现细节).

  Publisher behaviour 故意和裸 Phoenix.PubSub 分离: 订阅者看到的是
  typed `%Ezagent.Publisher.Event{}` 带 cursor 的流, 而非裸
  `:slice_changed` PubSub 消息. 这是关闭 P11 逃出的关键: 每个 external-
  mirror worker 通过 Publisher API 订阅, 而非 PubSub.subscribe.
  """

  @type cursor :: non_neg_integer() | :latest | :earliest
  @type event :: Ezagent.Publisher.Event.t()

  @doc "保留多少 event 在内存 (V1 default; 见 OQ-EM-A)."
  @callback history_retention() :: pos_integer()

  @doc """
  从 `cursor` 订阅 `subscriber_pid` 到这个 Publisher.
  - `:latest` = 只订阅未来事件 (跳过 backlog)
  - `:earliest` = 重放整个保留历史然后继续
  - integer = 从精确 cursor 恢复 (如不再保留则 raise)

  返回 `{:ok, current_cursor}` — 指向最近一次投递事件的 cursor
  (订阅者 checkpoint 这个).
  """
  @callback subscribe_from(publisher_uri :: URI.t(),
                           subscriber_pid :: pid(),
                           cursor :: cursor()) ::
              {:ok, cursor()} | {:error, term()}

  @doc "快照当前状态而不订阅. 用于延迟加入的 UI."
  @callback snapshot(publisher_uri :: URI.t()) ::
              {:ok, %{cursor: cursor(), state: term()}} | {:error, term()}

  @doc """
  从 cursor `from` (不含) 到 `to` (含, 或 :latest) 的历史.
  用于订阅者跨 restart checkpoint. 如 `from` 比保留窗口老则 raise.
  """
  @callback history(publisher_uri :: URI.t(),
                    from :: cursor(),
                    to :: cursor()) ::
              {:ok, [event()]} | {:error, :cursor_out_of_window | term()}
end
```

Session Kind 通过维护 `:publisher_history` slice (有界环; V1 default 100 events 或 1 hour, 见 OQ-EM-A) 实现, 把 `subscribe_from / snapshot / history` 暴露为 Kind 级 GenServer call. slice-change hook (PR #303 §2.1) 在每次 mutating slice 的成功 invoke 时追加到环 — 即 Publisher 机械性派生自 SliceChange 原语; Behavior 作者不显式写 Publisher 逻辑.

为什么 Publisher 而不是直接 "订阅 SliceChange topic":
- **Cursor.** restart 的 binding 需要知道 "从哪个点恢复" — 裸 PubSub 没有这个概念.
- **Replay.** 延迟加入的 UI / 网络抖动后追赶需要 `history(from, to)`. PR #303 hook 是 fire-and-forget.
- **Backpressure 边界.** Per-subscriber pacing 发生在 Publisher API; PubSub 无条件广播给所有订阅者.
- **订阅者不 import PubSub.** binding 实现者从不写 `Phoenix.PubSub.subscribe`. Publisher API 是结构性边界.

### 2.2 Adapter — 无状态 wire-format 模块

**Adapter** 是 plugin 模块, 知道如何消费 Publisher event 并为 ONE 外部系统序列化. 无状态: 没有 GenServer, 没有 ETS, 没有 rate-limit 状态, 没有 auth cache. adapter 是纯函数模块, 由匹配的 Binding GenServer 调用.

```elixir
defmodule Ezagent.ExternalMirror.Adapter do
  @moduledoc """
  无状态 wire-format 翻译者的 behaviour. 每个外部系统形态一个 adapter
  模块 (Feishu, Slack, Discord, 游戏协议, 浏览器端 WS dashboard, ...).

  adapter 不直接调外部 API. 它把 Publisher event 翻译为 adapter 特定
  payload (Lark 消息 body, Slack chat.postMessage args map, game-server
  RPC 帧). 匹配的 Binding GenServer 调 adapter, 然后做实际传输.

  分离 (adapter = 无状态翻译, binding = 有状态传输) 结构性强制:
  Domain plugin 编译期检查拒绝同时实现两个 behaviour 的模块 (Grill 5 — Allen 2026-05-24).
  """

  @doc "catalog 用的稳定字符串 id (e.g. `\"feishu\"`)."
  @callback adapter_id() :: String.t()

  @doc "给 admin LV / CmdK / 文档的人类可读名."
  @callback display_name() :: String.t()

  @doc "给 cap 发现 + admin UI 的一句话 operator 描述."
  @callback description() :: String.t()

  @doc """
  授权用户 bind 到 THIS adapter 的 per-adapter cap subject (Behavior
  module + description). plugin boot 时注册到 CapabilityRegistry.
  cap 是结构性 per-adapter authorization gate (HIGH #4 强制修订).

  Behavior 模块命名约定 `Behavior.ExternalAdapter.<adapter_id>.Allow`
  (例如 `Behavior.ExternalAdapter.Feishu.Allow`); adapter 声明该
  模块, 这样 cap 匹配代码可以引用.
  """
  @callback cap_subject() :: %{behavior_module: module(), description: String.t()}

  @doc """
  BIND TIME 检查 `caller` 是否对 `target_id` 在外部系统有访问.
  例:
  - Feishu adapter 通过 Lark API 检查 "caller 关联的 feishu_open_id
    是否是 Lark chat `target_id` 的成员?".
  - Slack adapter 检查 channel 成员资格.
  - Game adapter 检查 caller 的 game-account 是否拥有 room.

  返回 `:ok` 如果 caller 可以 bind 一个 session 到 `target_id`.
  `{:error, :not_a_member}` 是规范化拒绝 atom; adapter 可以返回其他
  原因, Domain 原样上浮 (按 P18 — 用户面 dispatch 无静默丢失).

  这是 HIGH #4 的第二道 gate: Cap 1 说 "你可以在这个 session 上 bind",
  Cap 2 说 "你可以用这个 adapter", target_ownership_check 说 "你
  实际拥有 / 是这个外部 target 的成员".
  """
  @callback target_ownership_check(caller :: URI.t(),
                                    target_id :: term()) ::
              :ok | {:error, :not_a_member | term()}

  @doc """
  把 Publisher event 翻译为 adapter 特定 payload. 纯函数 — 无 I/O.
  匹配的 Binding 消费返回值并做传输.

  返回 `:skip` 告诉 Binding 丢掉这个 event 不发布 (e.g. 只关心
  `:chat` slice 变化的 adapter 对 `:members` slice 变化返回 `:skip`).
  """
  @callback event_to_payload(event :: Ezagent.Publisher.Event.t()) ::
              {:publish, payload :: term()} | :skip

  @doc """
  声明这个 adapter 的匹配 Binding 模块. plugin 编译期检查强制
  (Grill 5): adapter 模块和 binding 模块 MUST 不同模块.
  """
  @callback binding_module() :: module()
end
```

Adapter 例 (说明性):
- `EzagentPluginFeishu.FeishuAdapter` — id `"feishu"`, `event_to_payload` 把 `:chat` slice 变化翻译为 Lark `im.v1.messages.create` JSON; 对非 chat slice 变化返回 `:skip`.
- `EzagentPluginGameRoom.RoomEventAdapter` — id `"game_room"`, `event_to_payload` 把 `:agent_state` slice 变化翻译为 game-server RPC 帧.

### 2.3 Binding — 有状态 per-target supervised GenServer

**Binding** 是有状态 GenServer 实例 — 每个 (session, adapter, target) 三元组一个 — 拥有到 ONE target 的 publish 循环. 从 cursor 订阅 publisher, 调 adapter 翻译, 做传输调用, 拥有 retry / backpressure / 429 处理. 崩溃边界 per-binding: 一个 Binding 崩不影响兄弟.

```elixir
defmodule Ezagent.ExternalMirror.Binding do
  @moduledoc """
  有状态 per-target publish 循环模块的 behaviour. Domain 提供
  GenServer 骨架 (Ezagent.Entity.ExternalMirrorWorker Kind) 持有
  publisher 订阅 + cursor + retry 状态; binding 模块实现传输 callback.

  一个 Binding 实例 = 一个 supervised process = 一个外部 target.
  崩溃隔离 per-binding (HIGH #3 强制修订): 一个 binding 崩从不影响
  同 session 的其他.
  """

  @doc """
  初始化 per-binding 传输状态. Worker Kind spawn 时调一次. `target_id`
  对框架不透明 (字符串、整数、map — adapter 解析的任何).
  `options` 带 `bound_by` (entity URI), `bound_at` 时间戳, 来自
  `:bind` action args 的 bind-time `metadata`.

  返回 binding 的运行时状态 — Worker Kind 持有并通过 publish/2 +
  terminate/2 串.
  """
  @callback init({target_id :: term(),
                  adapter :: module(),
                  options :: map()}) ::
              {:ok, state :: term()} | {:error, reason :: term()}

  @doc """
  把翻译后的 payload 发布到外部 target. 从 Worker Kind 的
  `:invoke(:publish, ...)` 内部调 (P14 — 每个外部写发生在 Kind 的
  invoke 内部).

  成功返回 `{:ok, new_state}` — state 可能带 rate-limit reset 时间、
  last-publish cursor、连接句柄.
  可恢复失败返回 `{:error, reason, new_state}` (4xx/5xx, 网络抖动) —
  Worker Kind log + telemetry 但 NOT 崩; binding 结构性健康. state
  carry forward (e.g. retry 计数器, backoff deadline).
  UNrecoverable invariant 违反 raise (BEAM let-it-crash 路径) —
  Worker Kind 的 DynamicSupervisor 重启.

  这个 callback 是实际外部字节流动的地方. adapter 已经翻译了 event;
  binding 是传输.
  """
  @callback publish(payload :: term(), state :: term()) ::
              {:ok, new_state :: term()} | {:error, reason :: term(), new_state :: term()}

  @doc """
  graceful unbind 清理. adapter 可能释放持有资源 (关 WS pid, 发
  goodbye 消息). 在 Worker Kind process 退出前调. no-op default.
  """
  @callback terminate(reason :: term(), state :: term()) :: :ok
  @optional_callbacks [terminate: 2]

  @doc "声明匹配的 Adapter 模块 (Grill 5 强制)."
  @callback adapter_module() :: module()
end
```

Binding 例 (说明性):
- `EzagentPluginFeishu.FeishuChatBinding` — 每 `(session_uri, "feishu", chat_id)` 一个; init 打开 Feishu HTTP client + 缓存 tenant token; publish post Lark 消息; 用存在 binding state 的 backoff 状态处理 429.
- `EzagentPluginGameRoom.GameRoomBinding` — 每 `(session_uri, "game_room", room_id)` 一个; init 打开到 game server 的持久 gRPC stream; publish 发 RPC 帧; stream death 时重连.

### 2.4 流程一图

```
Session Kind 上的某 Behavior invoke :send (或其他 mutate slice 的 action).
                       ↓
Ezagent.Kind.Runtime.handle_dispatch/4 step 9 — new_state 存好.
                       ↓
Ezagent.SliceChange.emit/1 fire (PR #303 §2.1) 到 session URI 的 topic.
                       ↓
Session Kind 的 Publisher 实现 (自己 GenServer 逻辑) 消费自己的
SliceChange — 追加到 :publisher_history 环, 带单调 cursor.
                       ↓
每个已订阅的 binding worker (在它自己 init/1 时通过
Publisher.subscribe_from/3 订阅) 收到 {:publisher_event, %Event{}} 消息.
                       ↓
Worker Kind 的 handle_info 翻译为 dispatched :publish Invocation 到自身
(entity://worker/<workspace>/em_<binding_hash>?action=external_mirror_worker.publish).
                       ↓
ExternalMirrorWorker Kind 的 Behavior.invoke(:publish, ...) 调:
    1. adapter_module.event_to_payload(event) → {:publish, payload} | :skip
    2. 如 :skip → return
    3. binding_module.publish(payload, binding_state)
    4. 更新 binding state; 记录 cursor checkpoint
                       ↓
Binding 在 publish/2 内做实际传输 (HTTP/WS/RPC/whatever).
crash → DynamicSupervisor restart → init/1 → subscribe_from latest cursor.
```

为什么这图关闭了 r2 关不掉的 P11 逃出:
- 唯一 PubSub 订阅者是 **Session Kind 订阅自己 topic** — PR #303 已建立的 "Kind 观察自己 slice" 模式. 不是外部集成; 平凡合规.
- binding 通过 **Publisher API** 订阅, 而非 `Phoenix.PubSub.subscribe`. 即使 Publisher 内部用 PubSub 实现, binding 代码 import `Ezagent.Behavior.Publisher`, 不是 `Phoenix.PubSub`. grep gate (Invariant 4) 强制.
- 外部写发生在 **Worker Kind 的 `:invoke(:publish, ...)`** — 通过 `Invocation.dispatch/1` 被 dispatch 的 Kind. P14 + P11 完全满足.

---

## 3. Worker 生命周期 (解决 OQ-EM-10; r4 关闭 HIGH-1 死锁)

按 Allen 2026-05-24 晚, worker lifecycle 锁死 (不再是 OQ):

- **bind 成功立刻 eager-start (r4: 分离 init 与 subscribe).** `:bind` action body 成功 (cap OK + adapter `target_ownership_check` OK + slice 写好), Session Kind 给新 binding 的 worker URI dispatch `Ezagent.Kind.spawn(Ezagent.Entity.ExternalMirrorWorker, ...)`. **Worker 的 `init_slice/1` 返最小 state (binding 参数; 无订阅, 无传输打开).** 订阅 Session Publisher 和 binding 模块 `init/1` (传输打开) 在 `init_slice/1` 返回后跑的 `handle_continue(:subscribe_and_init, ...)` 内发生 — 这是 §6.1 的 HIGH-1 死锁修. Worker process 在 `:bind` 返回时 EXISTS; 几毫秒后变 ACTIVELY-SUBSCRIBED. 那个订阅 gap 期间发的 SliceChange event 不投递 (latest-wins; 按 §3 最后一条可接受).
- **两层 supervisor 崩溃 restart (r4: per-binding 隔离).** worker 住在 **per-binding** `:one_for_one` `Supervisor` (每 binding 一个 supervisor, 含一个 Worker 子) 叫 `Ezagent.ExternalMirror.PerBindingSupervisor`; per-binding supervisor 全在顶层 `:one_for_one` `DynamicSupervisor` 叫 `Ezagent.ExternalMirror.RootSupervisor` 下. Restart 策略:
  - **Worker 子** 在每个 PerBindingSupervisor 内: `:permanent`, `max_restarts: 3, max_seconds: 30`. 触发 → PerBindingSupervisor 崩.
  - **PerBindingSupervisor** 在 RootSupervisor 下: `:permanent`, 但 RootSupervisor 的 intensity 设宽 (`max_restarts: 100, max_seconds: 60`) 因为 per-binding-supervisor 崩应稀有. 单个 binding 的 restart storm 只触发自己的 per-binding supervisor; 兄弟不动.
  这是 HIGH-2 修按 §5.3 + §6.3 — restart intensity 结构性 per-binding, 不是 supervisor-wide.
- **slice 变化 latest-wins 语义 (不重放崩溃期间错过的事件).** restart 时, worker 用 cursor `:latest` 重订阅 Publisher. 崩溃窗口期间发出的 event NOT 重放. 理由: V1 adapter 是 fire-and-forget (聊天消息, dashboard 更新) — 重放 5 秒前的 slice 变化通常害多于益 (乱序 publish, 重复通知). 真正需要 at-least-once 投递的 adapter 可以从存在自己 `:state` slice 的 checkpointed cursor 恢复 — Publisher 暴露 `subscribe_from(cursor)`. 见 OQ-EM-7.
- **binding 删除 → worker graceful exit.** `:unbind` action body 从 Session slice 移除 binding 并发 `{:graceful_shutdown, reason}` 给 worker. worker 的 `terminate/2` callback 跑 (调 binding 模块的 `terminate/2` 释放传输资源); Worker Kind 然后干净退出. supervisor 对 graceful 路径用 `restart: :transient` — 退出原因 `:shutdown` 不触发 restart.

故意 NO 自动禁用 / 熔断 / 健康检查扫描. 持续失败的 binding (`{:error, _, new_state}` 每个 publish) 继续消费 event; 下个 slice 变化 dispatch 新 `:publish`; binding 状态累积 retry 计数器; operator 看到 telemetry 告警 unbind. 这是 P2 (let-it-crash; 无 workaround) 在 binding 层 — 系统暴露失败而非隐藏.

唯一 defer 的决定是 OQ-EM-7 (投递语义 — at-most-once V1; 需要时 per-adapter cursor-based at-least-once). Cursor 支持今天就已经在 Publisher API 里; worker "restart 时从 `:latest` 订阅" 是策略选择, 可以按 adapter 改而不动 API.

### 3.1 持久 binding 的重水化 (r4 — 关闭 HIGH-3)

Binding 持久化在 `external_mirror_bindings` 表 (按 §7.1, 通过标准 P22 snapshot writer 写). Session Kind restart 或 application restart 后, binding 通过 `init_slice/1` 在 Session slice 重建 — 但按 HIGH-3, eager-spawn 只在 `:bind` action body 内发生. 没有显式 reconciliation, rehydrated binding 没有 worker → 静默 mirror 丢.

r4 reconciliation 在两个触发点跑:

1. **Session Kind init reconciliation.** `Behavior.ExternalMirror.init_slice/1` 按 session URI 读 `external_mirror_bindings` (现有行为 — 填 slice). 另外在 Session Kind GenServer 上调度 `handle_continue({:reconcile_external_mirror_workers, bindings}, ...)`. 继续枚举 binding; 每个幂等调 `Ezagent.Kind.spawn(Ezagent.Entity.ExternalMirrorWorker, %{uri: worker_uri_for(...), session_uri: self_uri, binding: binding})`. 按 **P16** (Kind 单一 spawn 入口), `Kind.spawn/2` 幂等 — worker 已在则 no-op; 没在则 spawn + per-binding supervisor wire. 订阅按 §3 handle_continue 路径在 spawn 返回后发生. 这覆盖 Session Kind restart.

2. **Application boot reconciliation.** `Ezagent.ExternalMirror.Application.start/2` 启动一次性 `Ezagent.ExternalMirror.BootReconciler` GenServer (在 RootSupervisor 下, 按 P23 排在 plugin boot 填充 AdapterRegistry + BindingRegistry 之后). BootReconciler 直接查 `external_mirror_bindings` 表 (多节点时范围 local node 的 workspace shard — V1 单节点所以简单全表读). 每个 binding 行: 幂等 `Ezagent.Kind.spawn(Ezagent.Entity.Session, %{uri: session_uri})` (确保 Session Kind 存在; 幂等) 然后 `Kind.spawn(ExternalMirrorWorker, ...)` (确保 worker 存在). Session-init reconciliation (trigger 1) 处理 Session Kind 是重建触发的常见情形; BootReconciler 处理多节点情形 (binding 行存在但 session 不 host 在本节点 — deferred — V1 单节点所以是 no-op 安全网). BootReconciler 一次后干净退出.

幂等规则:
- `Kind.spawn/2` 幂等: 已存在 → 返 `{:ok, existing_pid}`; 新 → 在合适 supervisor 下 spawn.
- Worker 的 `handle_continue(:subscribe_and_init, ...)` 幂等: 已订阅 Publisher 则 no-op (Publisher 的 `subscribe_from` 短路重复 pid+publisher 对 — PR-EM-0 实现细节).
- **幂等性**（r5 codex round-4 HIGH-3 修复）：`DynamicSupervisor` **不**通过 child id 强制唯一性 — start logic 视 child spec id 为不透明。PerBindingSupervisor 的 child spec 用 `Registry` 后端 Via 名：`name: {:via, Registry, {Ezagent.ExternalMirror.WorkerRegistry, binding_uri}}`，`WorkerRegistry` 是 app boot 时启动的 `:unique` `Registry`。重复 `start_child/2` 命中 Registry 强制的名字冲突 → 返 `{:error, {:already_started, pid}}` reconciler (§3.1) 视为成功。`binding_uri` 是完整 Worker Kind URI `entity://worker/<ws>/em_<hash>`，跨 workspace 绑定不会冲突。

PR-EM-3 验收测试 (h): bind 一个 Feishu mirror → 触发一个 chat → assert mirror 收到; kill Session Kind process → 等 restart → 触发另一个 chat → assert mirror 收到 WITHOUT 手动重 bind. 这是没 wire reconciliation 时 fail 的测试.

---

## 4. 公开 API — Domain 侧

### 4.1 bind/unbind Behavior — `Ezagent.Behavior.ExternalMirror`

注册到 `Ezagent.Entity.Session` (V1; OQ-EM-1 覆盖扩展到其他 Kind). 三个 action:

| Action | 目的 | Mode |
|---|---|---|
| `:bind` | 给这个 session 加 `(adapter_id, target_id, metadata)` binding | `:call` |
| `:unbind` | 按 `(adapter_id, target_id)` 移除 binding | `:call` |
| `:list_bindings` | 读这个 session 上所有 binding | `:call` |

**Slice** — `:external_mirror` 在 Session. 形状:

```elixir
%{
  bindings: [
    %{
      binding_id:  "feishu/oc_xxx",          # 合成的 "<adapter_id>/<target_id>"
      adapter_id:  "feishu",
      target_id:   "oc_xxx",
      metadata:    %{},
      bound_by:    %URI{},                    # caller URI
      bound_at:    ~U[...]
    },
    ...
  ]
}
```

按 **P3** (单一真实源), 这个 slice 就是这个 session 的 binding SoT. `BindingRegistry` ETS 表 (§7) 是跨 session 查询的读 cache ("哪些 session bound 到 chat oc_xxx?"), slice 不扫每个 session 答不了.

**cap_subjects** (按 CapabilityRegistry SPEC #264 + caps-data-ownership SPEC):

```elixir
def cap_subjects do
  [
    {:bind,          "bind 这个 session 的 slice 变化到外部 adapter target."},
    {:unbind,        "按 (adapter_id, target_id) 移除 binding."},
    {:list_bindings, "列出这个 session 上所有 external-mirror binding."}
  ]
end
```

**data_owner/1** (按 caps-data-ownership-v2 §3.3):

```elixir
def data_owner(%URI{scheme: "session"} = session_uri) do
  # session 上的 external-mirror binding 由 session 的 owner 拥有.
  # Session.owner/1 由 PR-OWN-2 (caps-data-ownership #308) 加.
  case Ezagent.Entity.Session.owner(session_uri) do
    {:ok, owner_uri} -> owner_uri
    :error           -> :no_owner    # spawn 中 race; 只有 bootstrap-admin 能 grant
  end
end
def data_owner(:any), do: :no_owner   # 类级 ExternalMirror cap 只 bootstrap
def data_owner({:within_session, s_uri}), do: {:scope, :within_session, s_uri}
def data_owner(_), do: :no_owner
```

效果: 创建 session S 的用户是唯一可以给别人 grant `Behavior.ExternalMirror` cap 在 S 上的主体; 非 owner 试图在自己不拥有的 session 上 bind, `Behavior.IdentityAdmin.invoke(:grant_cap, ...)` step 5.2 (caps-data-ownership §5.2) 返回 `:grant_not_owner`.

**Default grant** (按 caps-data-ownership §4.1, 从 `data_owner/1` 机械派生): session spawn 时, session 的 owner 自动收到 `%Capability{kind: :session, behavior: Ezagent.Behavior.ExternalMirror, instance: session_uri, workspace_uri: ws}`. session 创建者不需要 bind cap 设置仪式.

### 4.2 §5.2 执行走查 — bind 由三个检查 gate

`Behavior.ExternalMirror.invoke(:bind, slice, args, ctx)` 按顺序跑. Cap 1 由标准 CapBAC step 5.5 (`Ezagent.Kind.Runtime.handle_dispatch/4`) 强制; Cap 2 和 target-ownership-check 在 action body 内.

**检查 1 — session 级 bind cap (CapBAC step 5.5; pre-action).** caller 必须持 `%Capability{kind: :session, behavior: Ezagent.Behavior.ExternalMirror, instance: session_uri, workspace_uri: ws}`. 按 caps-data-ownership §4, session owner default 持. 失败 → `{:error, :unauthorized}` (标准 dispatch 拒).

**检查 2 — per-adapter allow cap (action body 内; HIGH #4 修).** caller 必须持 `%Capability{kind: :session, behavior: <adapter.cap_subject().behavior_module>, instance: session_uri, workspace_uri: ws}`. 每个 adapter 声明自己的 cap-subject Behavior 模块 (e.g. `Behavior.ExternalAdapter.Feishu.Allow`); Domain 在 plugin boot 时通过 `CapabilityRegistry.register(...)` 注册. Default grant: workspace admin grant per-adapter cap 给 opt-in 到那个 adapter 的用户 (这些 cap 的 `data_owner` 是 `:any` → 按 caps-data-ownership §3.3 workspace-admin grant). 失败 → `{:error, :adapter_not_authorized}` (按 P18 + caps-data-ownership §5.2 error code 风格, 区分 atom 让 log 易读).

**检查 3 — adapter target_ownership_check (action body 内).** Domain 调 `adapter_module.target_ownership_check(ctx.caller, args.target_id)`. adapter 的 plugin 代码检查 "caller 是否实际是这个外部 target 上的 member / 被授权?" — e.g. Feishu adapter 查 Lark API "caller 关联的 feishu_open_id 是否在 chat `target_id` 里?". 失败 → `{:error, reason}` reason 是 adapter 返回的 (典型 `:not_a_member`). 按 P18 原样上浮给 caller.

只有三个检查全过, Behavior 才写 binding 到 slice + dispatch `Ezagent.Kind.spawn(Worker)`.

### 4.3 Worker Behavior — `Ezagent.Behavior.ExternalMirrorWorker`

注册到新 `Ezagent.Entity.ExternalMirrorWorker` Kind (§7.2). 一个 action:

| Action | 目的 | Mode |
|---|---|---|
| `:publish` | 通过 adapter 翻译 Publisher event; 通过 binding 模块传输 | `:cast` |

**Slice** — `:state` 在 Worker. 形状:

```elixir
%{
  binding: %{
    session_uri:     %URI{},
    adapter_id:      "feishu",
    target_id:       "oc_xxx",
    metadata:        %{},
    bound_by:        %URI{},
    bound_at:        ~U[...]
  },
  publisher_cursor:   non_neg_integer() | :latest,
  binding_state:      term(),                   # Domain 不透明; Binding 拥有
  last_publish_at:    DateTime.t() | nil,
  last_publish_result: :ok | {:error, term()} | nil,
  publish_count:      non_neg_integer(),
  error_count:        non_neg_integer()
}
```

按 **P3**, 这个 slice 是 worker 运行时 SoT; 通过标准 P22 机制持久化, 用于 cursor checkpoint 的 restart 恢复. binding 自己的状态 (`binding_state`) 对 Domain 不透明 — binding 模块在 `publish/2` 里读回.

**data_owner/1**: `:no_owner` — worker 是框架内部; 只有 bootstrap admin 能 grant. 用户从不直接持 worker cap.

**Cap 需求**: worker dispatch 需要 `%Capability{kind: :external_mirror_worker, behavior: Ezagent.Behavior.ExternalMirrorWorker, instance: :any, workspace_uri: worker_workspace}`. 只由 binding-spawning Session Kind 通过 scope-bounded `{:within_session, session_uri}` 委托持有 (按 P15 默认窄 — 见 §7.3).

### 4.4 Domain facade

LV / CLI / admin tooling 的读侧 helper:

```elixir
defmodule Ezagent.ExternalMirror do
  @doc "列 `session_uri` 上的 binding. 读 slice (live SoT)."
  @spec list_bindings(URI.t()) :: {:ok, [binding()]} | {:error, term()}

  @doc "列至少有一个 `adapter_id` binding 的 session. 读 BindingRegistry cache."
  @spec sessions_for_adapter(String.t()) :: {:ok, [URI.t()]}

  @doc "列所有已注册 adapter (用于 picker / cap 发现)."
  @spec list_adapters() :: [%{id: String.t(), display_name: String.t(), description: String.t()}]
end
```

mutation 走 `:bind` / `:unbind` dispatch (P14). facade 只读.

---

## 5. Adapter 合约 (`Ezagent.ExternalMirror.Adapter`)

§2.2 已定义 behaviour callback; §5 列 wiring + plugin 合约细节.

### 5.1 plugin 声明 (declare-don't-call, 按 P23)

plugin 的 `Application` 模块声明 adapter + binding 对:

```elixir
defmodule EzagentPluginFeishu.Application do
  use Application
  use Ezagent.Plugin

  @impl Ezagent.Plugin
  def adapters do
    [{EzagentPluginFeishu.FeishuAdapter, EzagentPluginFeishu.FeishuChatBinding}]
  end

  # ... 其他 plugin callback (behaviors/0, kinds/0, etc.)
end
```

框架的 `Ezagent.Plugin.boot/1` 读 `adapters/0`, 对每个对:

1. 验证 adapter 模块实现 `@behaviour Ezagent.ExternalMirror.Adapter`.
2. 验证 binding 模块实现 `@behaviour Ezagent.ExternalMirror.Binding`.
3. 验证 `adapter.binding_module() == binding_module` AND `binding.adapter_module() == adapter` (Grill 5 — 双向声明).
4. 验证 adapter 和 binding 是不同模块 (Grill 5 强制; 结构性 — `assert adapter != binding`).
5. 调 `Ezagent.ExternalMirror.AdapterRegistry.register(adapter)`.
6. 调 `Ezagent.ExternalMirror.BindingRegistry.register_module(adapter.adapter_id(), binding)`.
7. 调 `Ezagent.CapabilityRegistry.register(...)` 给 `adapter.cap_subject()` 返回的 per-adapter cap subject.

`:ezagent_plugin_check` Mix 编译器在编译期强制 (1)-(4), 错声明 build fail, 而非 runtime. (5)-(7) 在 application boot 时发生.

### 5.2 AdapterRegistry + BindingRegistry — 都是只读 cache

两个 ETS 表, 由 `EzagentCore.EtsOwner` 拥有 (扩展现有 `@tables` 列; **NOT** lazy-init, 按 `EzagentCore.EtsOwner` 结构性非法强制):

- `Ezagent.ExternalMirror.AdapterRegistry` — key `adapter_id` (string), value `adapter_module`. "哪些 adapter 存在" 的单一真实源. plugin boot 时从 `adapters/0` 填. `lookup!/1` 对缺失 adapter raise (binding 引用了未加载 adapter — 结构性错, fail loud).
- `Ezagent.ExternalMirror.BindingRegistry` — key `{adapter_id, target_id}`, value `[session_uri]`. 跨 session 反向查询的读 cache (e.g. "哪些 session bound 到 Lark chat oc_xxx?"). 随 `:bind` / `:unbind` 增量填; application start 时通过读 Session-slice projection 表 (§7.1) 重建.

按 **P22** (可靠性原语在 core/Domain — plugin 作者不能绕过), 两个 registry 住在 Domain. plugin 作者从不直接调 AdapterRegistry / BindingRegistry — 他们通过 `adapters/0` 声明, 框架 wire.

### 5.3 失败语义 (per-binding 崩溃隔离; HIGH #3 r2 + r4 HIGH-2 两层修)

按 **P2** + Allen 对 OQ-EM-5 的 "per-binding 隔离" 答 + r4 的 HIGH-2 两层 supervisor 修:

结构性隔离是 **per-binding Worker Kind process 在自己 PerBindingSupervisor 下** (NOT 共享 DynamicSupervisor 把 worker 作为直接子 — r3 就这样, codex round-3 HIGH-2 标了). 两层 supervisor 拓扑:

- **`Ezagent.ExternalMirror.RootSupervisor`** (`DynamicSupervisor`, `:one_for_one`, `max_restarts: 100, max_seconds: 60`) — 子是 `PerBindingSupervisor` 实例. 宽 intensity 因为 per-binding-supervisor 崩是稀有结构事件.
- **`Ezagent.ExternalMirror.PerBindingSupervisor`** (`Supervisor`, `:one_for_one`, `max_restarts: 3, max_seconds: 30`) — 子是 ONE Worker (一个 `Ezagent.Entity.ExternalMirrorWorker` Kind process). 紧 intensity 隔离 per-binding restart 压力.

失败情形:

1. **`binding_module.publish/2` 返回 `{:error, reason, new_state}`** — 可恢复 (4xx/5xx/transient). worker log + telemetry; state 更新; 下个 event 触发新 publish. binding NOT tombstone. operator 看 telemetry 趋势.
2. **`binding_module.publish/2` raise** — UNrecoverable (invariant 违反). worker process 崩; DynamicSupervisor restart (30s 内 max 3 次). restart 时, `init/2` 用 cursor `:latest` 重订阅 Publisher (按 §3 lifecycle). state 从 snapshot 重建如有.
3. **`adapter_module.event_to_payload/1` raise** — 同 (2); worker 崩; restart; latest-wins. adapter 应该是纯函数 — raise 是 plugin bug; let-it-crash 暴露它.
4. **Restart storm 触发这个 binding 的 PerBindingSupervisor intensity** — 只那个 PerBindingSupervisor 崩; RootSupervisor 的 `:one_for_one` 策略意味着兄弟完全不动. 它们的 PerBindingSupervisor + Worker 保持运行. telemetry 告警 operator 关于崩 binding; operator unbind 恢复. (r4 修: r3 把这放共享 supervisor 上, 跨 binding 累积 restart 压力会崩兄弟; r4 两层拓扑结构性修.)

NOT 自动禁用. NOT 熔断. NOT 健康检查扫描. 按 P2: 结构性修复 (per-binding process 边界) > 症状打补丁.

per-binding GenServer 模式 vs Session Kind 上 "纯 let-it-crash" 不同, 因为这里失败模式是 **外部系统 4xx/5xx**, 不是 BEAM invariant 违反. 每个 Lark 429 都 let-it-crash 会让 Session Kind 崩死. supervised GenServer 在 state 里吸收可恢复外部失败; 真正坏的 binding 仍然崩 + restart + 最终触发 supervisor intensity (let-it-crash 兜底).

### 5.4 发现 — LV 怎么显示 "可用 adapter"

admin LV (OQ-EM-2 — CLI 在 PR-EM-5, LV 在 PR-EM-FINAL) 调 `Ezagent.ExternalMirror.list_adapters/0`, 从 AdapterRegistry 返回 `[%{id, display_name, description}]`. LV 按 caller 持有的 per-adapter allow cap 过滤 (通过 `Behavior.Identity.invoke(:list_caps, ...)` 查 caller URI), 隐藏 caller 不能 bind 的 adapter (按 P15 默认窄, 避免 submit 时 TOCTOU 惊喜).

按 **P1** (plugin 隔离北极星): 未来 plugin 作者加 Slack 镜像写两个模块 (`EzagentPluginSlack.SlackAdapter` + `EzagentPluginSlack.SlackChannelBinding`), 在 `adapters/0` 声明, 发版. 不动 core, 不动 domain, 不动 LV.

---

## 6. Binding 合约 (`Ezagent.ExternalMirror.Binding`)

§2.3 已定义 behaviour callback; §6 列 GenServer 骨架 + per-binding 状态生命周期.

### 6.1 Worker Kind 拥有 GenServer; Binding 实现 callback

`Ezagent.Entity.ExternalMirrorWorker` 是 Kind (按 P16 — 只通过 `Ezagent.Kind.spawn/2` spawn). 它的 `init/1` 调 binding 模块的 `init/1`; 后续 dispatched `:publish` action 通过 `publish/2` 串状态; `Kind.Server` terminate 时, binding 的 `terminate/2` 跑.

Worker Kind 的 `:invoke(:publish, ...)` body:

```elixir
@impl Ezagent.Behavior
def invoke(:publish, %{event: event} = _args, slice, _ctx) do
  adapter = AdapterRegistry.lookup!(slice.binding.adapter_id)

  case adapter.event_to_payload(event) do
    :skip ->
      {:ok, %{result: :skipped},
       %{slice |
         publisher_cursor: event.cursor,
         publish_count: slice.publish_count + 1}}

    {:publish, payload} ->
      binding_module = BindingRegistry.lookup_module!(slice.binding.adapter_id)

      case binding_module.publish(payload, slice.binding_state) do
        {:ok, new_binding_state} ->
          {:ok, %{result: :ok},
           %{slice |
             binding_state: new_binding_state,
             publisher_cursor: event.cursor,
             last_publish_at: DateTime.utc_now(),
             last_publish_result: :ok,
             publish_count: slice.publish_count + 1}}

        {:error, reason, new_binding_state} ->
          # 可恢复: log + telemetry; NOT 崩.
          Logger.warning("ExternalMirror publish failed",
            binding: slice.binding.binding_id,
            reason: reason
          )
          {:ok, %{result: :error},
           %{slice |
             binding_state: new_binding_state,
             publisher_cursor: event.cursor,
             last_publish_at: DateTime.utc_now(),
             last_publish_result: {:error, reason},
             publish_count: slice.publish_count + 1,
             error_count: slice.error_count + 1}}
      end
  end
end
```

Worker Kind 在自己 `init/1` 时订阅 Session 的 Publisher (NOT bind 时 — 那是 publisher 侧). 订阅通过 `Ezagent.Behavior.Publisher.subscribe_from(session_uri, self(), cursor)`. 收 `{:publisher_event, %Event{}}`, worker 通过 `Ezagent.Invocation.dispatch/1` 给自己 dispatch `:publish` (`:cast`, idempotency_key = `binding_id <> "/" <> cursor`).

为什么 dispatch-to-self 而非 inline 调 invoke: 它把 publish 通过 `Kind.Runtime.handle_dispatch/4` 路由, 让 step 5.5 CapBAC + audit + telemetry + idempotency 应用 (P14 hygiene). Self-dispatch 是已知的 Kind 惯用模式, 当外部 event 需要进入 dispatch 流时.

### 6.2 Binding `init/1` 和 `terminate/2`

`init/1` 从 `Worker Kind` 的 `init_slice/1` 调 (标准 Kind 模式). binding 设置自己传输 client (HTTP client, WS 连接, RPC stream), 如便宜验证连接, 返回初始 `binding_state`. 这里失败 = worker 启动失败 = supervisor `:permanent` 策略 retry; init 持续失败, supervisor intensity 触发 worker 留下不起 (operator 看 telemetry; unbind).

`terminate/2` graceful unbind 时跑 (按 §3 lifecycle). Worker Kind 的 `handle_call({:graceful_shutdown, reason}, ...)` 调 binding 模块的 `terminate/2` → 更新 slice `last_shutdown_reason` → 返回 `{:stop, :shutdown, ...}` → Worker Kind 干净退出 (supervisor 对 shutdown-reason 用 `:transient` 避免 restart).

---

## 7. 存储

### 7.1 Binding 在 Session slice (单一 SoT); 表是 projection

按 **P3** + Allen 对 OQ-EM-8 的拍板: Session 的 `:external_mirror` slice 就是 binding 的真实源. 持久表 (`external_mirror_bindings`, SQLite) 是由标准 P22 snapshot writer (`:on_change` 策略) 写的 snapshot projection — 和其他 Kind slice 同样机制.

```sql
CREATE TABLE external_mirror_bindings (
  session_uri   TEXT    NOT NULL,
  adapter_id    TEXT    NOT NULL,
  target_id     TEXT    NOT NULL,
  metadata_json TEXT    NOT NULL DEFAULT '{}',
  bound_by      TEXT    NOT NULL,
  bound_at      INTEGER NOT NULL,
  workspace_uri TEXT    NOT NULL,   -- 按 P21
  PRIMARY KEY (session_uri, adapter_id, target_id)
);
CREATE INDEX idx_emb_workspace ON external_mirror_bindings (workspace_uri);
CREATE INDEX idx_emb_adapter   ON external_mirror_bindings (adapter_id);
```

按 **P21** (per-tenant DB 表带 `workspace_uri NOT NULL`), 表在 per-tenant 表列 (`per_tenant_tables_have_workspace_column_test.exs` invariant test gate 新表无列).

Session Kind init 时 rehydration: `Behavior.ExternalMirror.init_slice/1` 按 session URI 范围读 `external_mirror_bindings`; 构造 slice `bindings` 列. 没有额外 rehydration 机制 — 用每个 Kind 已经用的同样 `:on_change` snapshot 流.

没有 dual-SoT atomicity 问题, 因为只有一个 SoT. 表通过 snapshot writer 从 slice 机械派生; snapshot 中崩丢一个 binding 写 (和系统每个 slice 同样语义 — caps-data-ownership SPEC 接受这个 v1 风险级).

### 7.2 ExternalMirrorWorker Kind URI 形状

`entity://worker/<workspace>/em_<binding_hash>` 其中 `binding_hash = sha256(session_uri <> adapter_id <> target_id) |> Base.encode16(case: :lower) |> String.slice(0, 12)`. 稳定: 同 binding 总映到同 worker URI (eager-spawn + restart 落同 URI).

`worker` type segment 是 `entity://` scheme 上的新 sub-type — 按 SKILL P20 / invariant 11, 这结构上合法 (entity type 是自由 name 前缀; `worker` type 加入 entity scheme 中已有的 `user` 和 `agent` type). NOT 新顶层 scheme (会违反 P11 / SPEC v2 §5.8 — invariant 8).

### 7.3 Cap 形状总结

三个 cap (按 §4.2):

| Cap | 形状 | Default 谁持 | 通过谁 grant |
|---|---|---|---|
| 1. Session bind cap | `{kind: :session, behavior: Behavior.ExternalMirror, instance: session_uri, workspace_uri: ws}` | Session owner (caps-data-ownership default grant) | `Behavior.IdentityAdmin.invoke(:grant_cap, ...)` 由 session owner |
| 2. Per-adapter allow cap | `{kind: :session, behavior: Behavior.ExternalAdapter.<id>.Allow, instance: session_uri, workspace_uri: ws}` | Default 没人 (opt-in) | `Behavior.IdentityAdmin.invoke(:grant_cap, ...)` 由 workspace admin (`data_owner` 返 `:any`) |
| 3. Worker publish cap | `{kind: :external_mirror_worker, behavior: Behavior.ExternalMirrorWorker, instance: :any, workspace_uri: ws}` | Session Kind 通过 scope-bounded `{:within_session, session_uri}` 委托 | Session spawn 时自动 grant (caps-data-ownership default grant) |

Cap 3 让 Session Kind 可以给 worker dispatch `:publish`. 用户从不直接持这个 cap — 是框架内部委托, 按 P15 scope-bounded 模式.

### 7.4 Workspace 范围 (P17 / P21)

Binding 通过 session URI 的 workspace segment 是 tenant-scoped. Domain 在 bind 时通过 `Ezagent.Capability.workspace_of/1` 从 `session_uri` 派生 `workspace_uri` (core 已存在, `apps/ezagent_core/lib/ezagent/capability.ex:324`). 存表上. 读按 `Ezagent.Persistence.scope_by_workspace/2` 范围. 跨 workspace binding (workspace A 的 Lark chat bound 到 workspace B 的 session) 由 dispatch step 5.6 (P17 invariant 13) 拒 — `:bind` invocation 带 session 的 workspace URI; out-of-band bind 到 target 要求 adapter 强制自己的跨 tenant 逻辑.

---

## 8. 与 SliceChange + caps 的 wiring

本节回答 "core / `domain.chat` / 新 Domain 具体改什么让这工作".

### 8.1 Session Kind 实现 `Ezagent.Behavior.Publisher`

`apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex` 增加:

- `@behaviour Ezagent.Behavior.Publisher` 声明.
- `:publisher_history` slice (有界环; default 100 events 或 1 hour — 见 OQ-EM-A) 在 `init/1` 初始化.
- `handle_info({:slice_changed, event}, state)` clause 追加到 `:publisher_history` 带单调 cursor (cursor 就是环的单调计数器; 不是 wall-clock).
- `Publisher.subscribe_from/3`, `Publisher.snapshot/1`, `Publisher.history/3` 的实现 — 每个是 `GenServer.call`-targeted Kind action (命名 `:publisher_subscribe_from`, `:publisher_snapshot`, `:publisher_history` — 通过新 `Behavior.Publisher` cap-only Behavior 暴露, 让 dispatch step 5.5 gate).

保留策略是 slice 字段, default 100 events. PR-EM-0 加; 保留 operator 可调通过未来 `:set_retention` action (NOT V1 — OQ-EM-A defer).

### 8.2 Bind action wiring 与 caps-data-ownership

`Behavior.ExternalMirror` 的 `:bind` action body 跑 §4.2 三个检查然后:

```elixir
def invoke(:bind, slice, %{adapter_id: aid, target_id: tid, metadata: md}, ctx) do
  with :ok <- check_adapter_allow_cap(ctx.caps, ctx.target_uri, aid),                     # 检查 2
       adapter = AdapterRegistry.lookup!(aid),
       :ok <- adapter.target_ownership_check(ctx.caller, tid) do                          # 检查 3
    binding = %{
      binding_id:  "#{aid}/#{tid}",
      adapter_id:  aid,
      target_id:   tid,
      metadata:    md,
      bound_by:    ctx.caller,
      bound_at:    DateTime.utc_now()
    }
    new_slice = update_in(slice.bindings, &[binding | &1])

    # Eager spawn worker (§3 lifecycle — bind 成功 → worker 存在).
    worker_uri = worker_uri_for(ctx.target_uri, binding)
    :ok = Ezagent.Kind.spawn(Ezagent.Entity.ExternalMirrorWorker,
                             %{uri: worker_uri,
                               session_uri: ctx.target_uri,
                               binding: binding})

    # 更新 BindingRegistry 读 cache.
    :ok = BindingRegistry.add(aid, tid, ctx.target_uri)

    {:ok, %{binding_id: binding.binding_id}, new_slice}
  else
    {:error, :adapter_not_authorized} = err -> err
    {:error, reason}                   -> {:error, {:target_ownership_denied, reason}}
  end
end
```

检查 1 (session bind cap) 在这个 body 跑前由 step 5.5 强制.

### 8.3 Worker 订阅 Publisher

Worker Kind 的 `init_slice/1`:

```elixir
def init_slice(%{session_uri: session_uri, binding: binding} = args) do
  # 从 latest 订阅 session Publisher (lifecycle §3).
  {:ok, current_cursor} =
    Ezagent.Behavior.Publisher.subscribe_from(session_uri, self(), :latest)

  # 初始化 binding 传输状态.
  binding_module = BindingRegistry.lookup_module!(binding.adapter_id)
  {:ok, binding_state} =
    binding_module.init({binding.target_id,
                         AdapterRegistry.lookup!(binding.adapter_id),
                         Map.merge(binding, %{bound_at: binding.bound_at})})

  %{
    binding:             binding,
    publisher_cursor:    current_cursor,
    binding_state:       binding_state,
    last_publish_at:     nil,
    last_publish_result: nil,
    publish_count:       0,
    error_count:         0
  }
end
```

handle_info 收到 `{:publisher_event, %Event{}}`, worker 自 dispatch `:publish` (§6.1) — 通过标准 dispatch 路由, cap 检查 3 (worker publish cap) 强制.

---

## 9. 迁移计划 (PR-EM-0 到 PR-EM-FINAL)

8 个 PR. 每个独立可发; 之间 tests pass.

### PR-EM-CORE — `Ezagent.Kind.Server` post-init continuation hook（前置）

**Owner:** `apps/ezagent_core/` — 触核心 runtime，**不**触 external_mirror。

Codex round-4 HIGH-1 修复：r4 的 split-init pattern（Worker
`init_slice/1` 返 slice；`handle_continue(:subscribe_and_init, ...)`
做副作用 subscribe + binding init）需要 `Ezagent.Kind.Server`
暴露 post-init continuation 点。当前 `Server.init/1` 只返
`{:continue, :announce_ready}`；Behaviors 没办法插入。

**改：**

- 给 `Ezagent.Behavior` 加新**可选**回调：
  `@callback post_init(args :: map(), slice :: map()) :: :ok | {:continue, term()}`
  — 返 `:ok`（无 post-init 工作）或 Server 通过自己的
  `handle_continue/2` 路由的 term。
- 扩展 `Ezagent.Kind.Server.init/1` + `handle_continue/2` 链式：
  `{:continue, :announce_ready}` → 先；然后如有任何 Behavior
  从 `post_init` 返了 `{:continue, term}`，通过连续
  `{:noreply, state, {:continue, term}}` 排队这些 continuations。
- 每 Behavior `handle_continue(term, slice, ctx)` 回调（也可选）
  接收 continuation term + 通过标准 `Kind.Server` 后更新路径
  写回 slice。

**验收：**
- 加 test-only `OwnedBehavior.PostInit` 从 `post_init/2` 返
  `{:continue, :setup_thing}` 且在 `handle_continue/3` 里写
  flag。断言 Kind spawn 后 Server `announce_ready` **和** Behavior
  post-init 都跑了，announce_ready 先（boot order invariant）。
- 向后兼容测试：现有未声明 `post_init/2` 的 Behaviors spawn 不变
  （无 continuation 噪音）。
- `mix compile --warnings-as-errors` 干净。

**为什么是 ExternalMirror PR-EM-2 的前置：** Worker Kind 需要把
SliceChange subscribe + binding.init 推迟到 `announce_ready`
之后（这样 binding 开始 publish 回时 dispatch 已 ready）。没这个扩展，
§6.1 + §3 的 split-init pattern 编译不过。

**LOC 估：** ~150（核心扩展 + Behavior 回调 + 3 测试）。

### PR-EM-0 — Publisher behaviour + Session Kind 实现 + retention 策略

**Owner:** `apps/ezagent_domain_instance_message/`.

- 在 `apps/ezagent_domain_external_mirror/` 定义 `Ezagent.Behavior.Publisher` behaviour (SPEC 家; behaviour 住新 Domain, 即使 Session 在 `domain.chat`).
- `Ezagent.Entity.Session` (`apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex`) 实现 `@behaviour Publisher`:
  - `:publisher_history` slice 加到 `init/1`.
  - `handle_info({:slice_changed, ...})` clause 追加到环带单调 cursor.
  - `subscribe_from/3`, `snapshot/1`, `history/3` 暴露为 Kind GenServer call.
- 定义 `Ezagent.Behavior.Publisher` cap-only Behavior (`dispatchable?: false`) — gate subscribe/snapshot/history action.
- Retention default: 100 events per session.
- **依赖:** PR-N1 (SliceChange hook 落地). 在 SliceChange 是 `:on` 前 inert.

**验收:** `apps/ezagent_domain_instance_message/test/` 新测覆盖 spawn 的 session 上 Publisher API — subscribe_from latest 收下个 mutation 的 event; subscribe_from earliest 重放保留历史; history(from, to) 返回正确窗口; cursor 越界 raise.

**LOC 估:** ~250.

### PR-EM-1 — `domain.external_mirror` 骨架 + AdapterRegistry + BindingRegistry

**Owner:** 新 `apps/ezagent_domain_external_mirror/`.

- 创建 app 标准 umbrella 形态; deps `:ezagent_core` + `:ezagent_domain_instance_message` 只.
- 定义 `Ezagent.ExternalMirror.AdapterRegistry` (ETS, `EzagentCore.EtsOwner` 拥有 — 扩展 `@tables` 列).
- 定义 `Ezagent.ExternalMirror.BindingRegistry` (ETS; 反向查询 cache).
- 定义 `Ezagent.ExternalMirror` facade 模块 (只读 helper 按 §4.4).
- 扩展 `Ezagent.Plugin` 合约带可选 `adapters/0` callback.
- 扩展 `Ezagent.Plugin.boot/1` 给每个声明的 `(adapter, binding)` 对调 `AdapterRegistry.register/1` + `BindingRegistry.register_module/2` + `CapabilityRegistry.register/3`.
- 扩展 `:ezagent_plugin_check` Mix 编译器带 Grill-5 校验: (a) adapter/binding 实现各自 behaviour; (b) `adapter.binding_module() == binding`; (c) `binding.adapter_module() == adapter`; (d) `adapter != binding` (不同模块).

**验收:** 新测覆盖 registry 生命周期, plugin 合约集成, Mix 编译器拒 (i) 同时实现两个 behaviour 的模块, (ii) adapter/binding 交叉引用不匹配.

**LOC 估:** ~200.

### PR-EM-2 — Adapter + Binding behaviour + Worker Kind + Worker Behavior + 双层监督

**Owner:** `apps/ezagent_domain_external_mirror/`.

- 定义 `Ezagent.ExternalMirror.Adapter` behaviour (按 §2.2 / §5).
- 定义 `Ezagent.ExternalMirror.Binding` behaviour (按 §2.3 / §6).
- 定义 `Ezagent.Entity.ExternalMirrorWorker` Kind (按 §7.2 — URI 形状 `entity://worker/<ws>/em_<hash>`).
- 定义 `Ezagent.Behavior.ExternalMirrorWorker` Behavior 带 `:publish` action (按 §4.3 / §6.1).
- 双层监督拓扑按 §5.3 + §6.3（r5 codex round-4 HIGH-2 + HIGH-3 修复 — **不要**退回单 `WorkerSupervisor`）：
  - 启 `Ezagent.ExternalMirror.RootSupervisor`（`DynamicSupervisor`, `:one_for_one`, `max_restarts: 100, max_seconds: 60`）。子 = per-binding 监督者。
  - 实现 `Ezagent.ExternalMirror.PerBindingSupervisor`（`Supervisor`, `:one_for_one`, `max_restarts: 3, max_seconds: 30`）。每个 binding 拥 ONE Worker child。
  - Worker child `:permanent`；PerBindingSupervisor 在 RootSupervisor 下 `:transient`。
- **幂等机制**（r5 codex round-4 HIGH-3 修复）：`DynamicSupervisor` **不**通过 child id 唯一性 — 重复 `start_child/2` 会默默 spawn 第二个 PerBindingSupervisor + Worker。用 stdlib `Registry` 命名 `Ezagent.ExternalMirror.WorkerRegistry`（`keys: :unique`）；PerBindingSupervisor 的 child spec 用 `{:via, Registry, {WorkerRegistry, binding_uri}}` 作 `:name`。并发 `start_child` 同一 `binding_uri` → 第二个返 `{:error, {:already_started, pid}}`（Registry 强制）；reconciler 视为成功。§3 / §3.1 reconciliation 保证依赖此唯一性契约 — `binding_uri` 是完整 Worker Kind URI 跨 workspace 不冲突。
- `Behavior.ExternalMirrorWorker` 的 `data_owner/1` 返 `:no_owner`.
- 用 mock adapter + mock binding (在 test support) 测: worker 通过 `Kind.spawn` spawn, `:publish` dispatch 路由 adapter.event_to_payload → binding.publish, slice 更新带 cursor/count.

**验收：**
- worker spawn + publish + slice 更新流程由单测覆盖
- per-binding 隔离回归：spawn 3 个 binding；kill 1 个 worker mid-publish 10× 跳闸其 PerBindingSupervisor；断言**其他**两个 PerBindingSupervisor + Worker 不受影响（RootSupervisor child count 崩后 = 2 不是 0）
- **双层拓扑 invariant test**（r5 HIGH-2）：`Supervisor.which_children(RootSupervisor)` → 断言每个 child 自己是 `Supervisor`（**不是** `Ezagent.Kind.Server`）；每个 child 的 `which_children` 恰返一个 `Ezagent.Kind.Server`。防 regression 到共享监督者拓扑
- **幂等回归测试**（r5 HIGH-3）：10 个 task 并发 `start_child` 同一 `binding_uri` → Registry 键控名上恰 1 个 Worker 进程；9 个调用返 `{:already_started, pid}`

**LOC 估:** ~340（+60 双层拓扑 + Registry wire-up + 2 新验收）。

### PR-EM-3 — `Behavior.ExternalMirror` 在 Session + bind/unbind/list_bindings + §4.2 wiring

**Owner:** `apps/ezagent_domain_external_mirror/`.

- 定义 `Ezagent.Behavior.ExternalMirror` 带 `:bind`, `:unbind`, `:list_bindings` action (按 §4.1).
- `data_owner/1` 按 §4.1 (session owner 通过 `Ezagent.Entity.Session.owner/1` — 已存在, PR-OWN-2 #308).
- `init_slice/1` 从 `external_mirror_bindings` 表 rehydrate (Ecto schema + migration 在这个 PR).
- `:bind` action body 跑 §4.2 三个检查然后 eager-spawn worker + 更新 BindingRegistry.
- `:unbind` action body 从 slice + BindingRegistry 移除 + 发 graceful shutdown 给 worker.
- 通过 Domain 的 `Application.start/2` 把 Behavior 注册到 `Ezagent.Entity.Session`.
- 加 `external_mirror_bindings` 到 `per_tenant_tables_have_workspace_column_test.exs` invariant test 的预期列.

**验收:**
- (a) bind/unbind/list 往返;
- (b) cap 1 拒 (非 owner);
- (c) cap 2 拒 (`:adapter_not_authorized`);
- (d) cap 3 用户没持;
- (e) target_ownership_check 拒 (`{:target_ownership_denied, :not_a_member}`);
- (f) target_ownership_check 超时 (mock adapter sleep > timeout → `:target_check_timeout`);
- (g) 跨 workspace 拒;
- (h) **Kind restart 后 rehydration 保留 binding AND 重启 worker** (r4 HIGH-3 修): bind 一个 probe adapter, 发 slice change, assert probe 收到; 通过 `Process.exit(session_pid, :kill)` 干掉 Session Kind process; 等 Kind 重 spawn; 再发 slice change; assert probe 收到新 event (证明 worker 被 reconcile, NOT 只是 binding 行);
- (i) bind 成功 worker eager-spawn 无死锁 (r4 HIGH-1 修): 计时 `:bind` action 调 — 必须 100ms 内返回, 即使 worker 订阅 Publisher (对正在执行 `:bind` 的 Session Kind 的 `GenServer.call`); 测试 fail (挂 / 超时) 如 r3 同步 subscribe-in-init 模式被重引.

**依赖:** PR-EM-0 (Publisher), PR-EM-1 (registry), PR-EM-2 (worker Kind).

**LOC 估:** ~350.

### PR-EM-4 — Admin LV per-session binding 管理

**Owner:** `apps/ezagent_plugin_liveview/`.

- LV 在 `/admin/sessions/:id/external_mirror` 显示 per-session binding + worker stats (last_publish_at, publish_count, last_publish_result, error_count — 从 Worker Kind `:state` slice 读).
- Bind/unbind 按钮按 cap gate (按 §5.4 P15 默认窄, 过滤 adapter dropdown 到 caller 持 Cap 2 的 adapter).
- 下钻 per-binding 近期 telemetry event (读 `Ezagent.Audit` 流).

**依赖:** PR-EM-3 (`:bind` / `:unbind` action wired).

**LOC 估:** ~300.

### PR-EM-5 — CLI 自动派生

**Owner:** core CLI.

- `mix ezagent.external_mirror.list_adapters` — 包 facade.
- `mix ezagent.external_mirror.bind <session_uri> <adapter_id> <target_id> [--metadata k=v]` — 包 `:bind` dispatch.
- `mix ezagent.external_mirror.unbind <session_uri> <adapter_id> <target_id>` — 包 `:unbind`.
- `mix ezagent.external_mirror.list_bindings <session_uri>` — 包 `:list_bindings`.
- 所有命令客户端检查 cap AND 原样上浮 dispatch 错误 (P18) — `:adapter_not_authorized`, `:target_ownership_denied {reason}`, `:unauthorized`.

**依赖:** PR-EM-3.

**LOC 估:** ~150.

### PR-EM-6 — Feishu plugin 重写 — FeishuAdapter + FeishuChatBinding; 退役 one-off

**Owner:** `apps/ezagent_plugin_feishu/`.

- 实现 `EzagentPluginFeishu.FeishuAdapter`:
  - `adapter_id/0 → "feishu"`, `display_name/0 → "Feishu (Lark)"`, `description/0`, `cap_subject/0 → %{behavior_module: EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow, description: "..."}`.
  - `target_ownership_check(caller, chat_id)` 查 Lark API "caller 关联的 feishu_open_id 是否是 chat `chat_id` 的成员?".
  - `event_to_payload(%Event{slice_key: :chat, ...})` 翻译为 Lark `im.v1.messages.create` JSON; 对非 chat slice 变化返回 `:skip` (V1 与今天 FeishuOutbound 行为对等).
  - `binding_module/0 → EzagentPluginFeishu.FeishuChatBinding`.
- 实现 `EzagentPluginFeishu.FeishuChatBinding`:
  - `adapter_module/0 → EzagentPluginFeishu.FeishuAdapter`.
  - `init({chat_id, _adapter, opts})` 打开 Feishu HTTP client + 缓存 tenant token; 返回 `{:ok, %{chat_id: chat_id, client: client, last_retry_at: nil}}`.
  - `publish(payload, state)` post 到 Lark; 用 state-tracked backoff 处理 429; 成功返回 `{:ok, state}`, 可恢复 HTTP 错返回 `{:error, reason, new_state}`.
  - `terminate(_reason, state)` 关 client.
- 在 `EzagentPluginFeishu.Application` 声明 `adapters: [{FeishuAdapter, FeishuChatBinding}]`.
- 一次性迁移脚本 `mix ezagent.external_mirror.migrate_feishu_bindings` 读 `feishu_session_bindings` 行 + 给每个 dispatch `:bind`. 给每个 binding 的 `bound_by` 用户 grant Cap 2 (per-adapter allow). 幂等.
- DELETE `EzagentPluginFeishu.Behavior.FeishuOutbound` (311 LOC).
- DELETE `EzagentPluginFeishu.SessionBinding` + `feishu_session_bindings` 表 (130 LOC + migration).
- DELETE `Behavior.Chat` 的 `maybe_notify_external/3` (`chat.ex:699-720`) — chat slice 变化现在通过通用 Session Publisher → bound worker 路径.
- DELETE Feishu 特定 mix task (`ezagent.feishu.bind` 等) — 由通用 `ezagent.external_mirror.*` 替.
- MIGRATE 现有 `feishu_session_binding` 测试 assert 到新 dispatch 路径. cap 拒测变成 "Cap 1 OK + Cap 2 missing → `:adapter_not_authorized`" 测. bind/unbind 往返 target 通用 `:bind` / `:unbind`.
- E2E 测: Feishu inbound → session → outbound 端到端通过新路径; 与旧路径行为对等 (同输入消息同 Lark API 调用).

**依赖:** PR-EM-5 (CLI 给 migration 脚本 + operator 命令).

**LOC 估:** ~400 net (新 ~600, 删 ~700).

### PR-EM-FINAL — invariant 测试 + GLOSSARY + SKILL 更新

**Owner:** `apps/ezagent_domain_external_mirror/test/invariants/` + meta.

Invariant 测试 (按 **P6** completion-claim-requires-invariant-test):

**(a) 每个 mirror publish 通过 `Invocation.dispatch/1` 到 Worker Kind.** grep gate: `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror_worker.ex` 之外任何调 `BindingRegistry.lookup_module!` 或直接 invoke `*.Binding.publish/2` 的模块是 offender. 集成测: spawn session + bind probe adapter + 触发 slice 变化 + assert publish caller pid 是 Worker Kind process (不是 Session Kind, 不是 Task, 不是 Phoenix.PubSub 消费者).

**(b) Per-binding 崩溃隔离.** 给同 session bind `BoomAdapter` (每次 publish raise) + `SurvivorAdapter` (记录); 触发 10 个 slice 变化; assert Survivor 收到全 10 个 event; assert Session Kind 活; assert BoomAdapter 的 worker 在 restart-looping (telemetry 计数器 > 0); assert 其他 binding 不受影响.

**(c) `target_ownership_check` 在 bind 成功前调.** mock adapter 的 `target_ownership_check` 记 caller URI + target; 试 bind `caller=Alice, target=bob_only`; assert 检查被 invoke AND bind 被拒以 `{:target_ownership_denied, :not_a_member}`.

**(d) BindingRegistry 从不有 session SoT 没有的行.** 周期性 invariant 测: 枚举 BindingRegistry 所有 entry; 每个 `{adapter_id, target_id}` → session_uri, 给 session dispatch `:list_bindings` 并 assert 匹配 binding 在. 抓 SoT slice 的读 cache drift.

**(e) plugin 合约 grep gate — 没有模块同时实现 Adapter 和 Binding behaviour.** `:code.all_loaded` 静态检查: 任何模块同时有 `@behaviour Ezagent.ExternalMirror.Adapter` AND `@behaviour Ezagent.ExternalMirror.Binding` fail.

**(f) `apps/ezagent_domain_external_mirror/` 下任何模块或 plugin 声明的 binding 模块的传递 deps 都没有 `Phoenix.PubSub.subscribe`.** grep gate. Binding 用 `Ezagent.Behavior.Publisher.subscribe_from/3` — 从不 PubSub 直接. 这是关闭 P11 逃出的结构性强制.

**(g) 任何 adapter 模块的 `target_ownership_check/2` callback 内无 `Ezagent.Invocation.dispatch` (或 `Kind.spawn` / `Behavior.invoke` 直接) (r4 round-3 MEDIUM 修).** grep gate 任何 plugin `adapters/0` 声明的 adapter 模块. 抓试图从 bind 时检查回入 ezagent 的 adapter 作者 — 会引起 dispatch-during-dispatch 死锁因为 `:bind` 自己是 dispatched action.

**(h) 两层 supervisor 拓扑保持 (r4 round-3 HIGH-2 修).** 测试 assert `Ezagent.ExternalMirror.RootSupervisor` 是 `DynamicSupervisor`, 子全是 `Supervisor` 模块各持一 Worker — NOT `DynamicSupervisor` 把 Worker 作为直接子. 抓"优化"扁平化树重引累积 restart intensity bug.

**(i) Session Kind init AND application boot 时跑 reconciliation (r4 round-3 HIGH-3 修).** 两个子测: (i.1) bind 一个 probe adapter, 只 restart Session Kind, 发 slice change, assert probe 收到. (i.2) bind 一个 probe adapter, restart 整个 application (完整 Application stop + start), assert BootReconciler 跑了 worker 在任何测试 slice change 发前 spawn + subscribe.

Meta 更新:
- `GLOSSARY.md` Decision Log 加下个序号 entry: "ExternalMirror Domain — Publisher behaviour 在 Session, Adapter (无状态) + Binding (有状态 per-target supervised GenServer) 合约; bind cap 通过 caps-data-ownership-v2 (session owner grant); per-adapter allow cap + per-target ownership 检查; worker 生命周期 = eager / supervised-restart / latest-wins / graceful-unbind."
- `ezagent-developer` SKILL 更新: 新 how-to ("How-to: 写 ExternalMirror adapter + binding"); 新 anti-pattern ("不要复制 Feishu one-off outbound 形状 — 用 ExternalMirror Domain"); 新 anti-pattern ("不要从 binding `Phoenix.PubSub.subscribe` — 用 `Publisher.subscribe_from/3`").

**验收:** 全 6 个 invariant 测过; 临时重引每个 anti-pattern → 对应测 fail 来 gate-verify.

**LOC 估:** ~250.

### 顺序

严格序:
- **PR-EM-0** → 先 (Publisher).
- **PR-EM-1** → PR-EM-0 后 (Domain 骨架).
- **PR-EM-2** → PR-EM-1 后 (worker Kind 需 registry).
- **PR-EM-3** → PR-EM-2 后 (`:bind` 需 worker spawn + registry).
- **PR-EM-4** + **PR-EM-5** PR-EM-3 后并行 (LV + CLI 都消费 `:bind`).
- **PR-EM-6** → PR-EM-5 后 (migration 脚本需 CLI).
- **PR-EM-FINAL** → PR-EM-6 后 (invariant gate 关架构承诺).

总估 ~8 PR, 顺序 ship 3 周, PR-EM-4/5 并行 2 周.

---

## 10. Non-goal

Domain 显式不做:

1. **实现任何具体传输.** 没有 HTTP client, 没有 WS client, 没有到 game server 的 FFI. 每个 binding 自带传输.
2. **管理外部系统认证.** Feishu binding 持 Lark tenant token; Slack binding 持 Slack OAuth token. Domain 不知外部凭证概念.
3. **抵御 in-VM plugin 代码.** 同 VM plugin 受信 (PR #303 round-5 威胁模型, Allen 2026-05-24 批). per-adapter cap + per-target ownership 检查是用户级 authorization, NOT BEAM sandboxing. 一个发恶意 exfiltration binding 的 plugin 作者可以发到任何持有凭证的地方 — 控制是关于阻止 INNOCENT 用户 bind 到自己不拥有的 target, 不是关于容纳恶意代码.
4. **替代 Chat Domain.** Chat 是 entity-to-entity 消息带意图寻址. ExternalMirror 是单向 session-state 复制. 它们共享 slice (Chat slice 变化是 mirror frame) 但不共享代码路径.
5. **替代 `Ezagent.Notifications` / `SliceChange`.** 这个 Domain 消费 SliceChange 原语 (通过它坐之上的 Publisher 层). 不与 notification 层 cap 形状竞争或覆盖.
6. **提供通用 inbound 路径.** 外部系统 inbound (Feishu webhook → ESR Chat) 留在 plugin 自己 `InboundDispatcher` (按 P11). 这个 Domain 只 OUTBOUND.
7. **缓冲或持久 mirror frame 超过 Publisher retention.** V1 retention 100 events / 1 hour (OQ-EM-A). 需要 at-least-once 投递 + 长期重放的 adapter 自己实现外部侧 dedup / log.
8. **自动禁用 / 熔断 / 健康检查 binding.** 按 **P2** (let-it-crash, 无 workaround): 坏 binding 留活, 通过 telemetry 暴露失败, 需要 operator unbind 移除. 无静默退化路径.

---

## 11. 开放问题 (3 个剩余 — 实施时给 Allen 拍板的窄技术决策, NOT SPEC-批准阻塞)

### OQ-EM-7 — 投递语义: at-most-once vs at-least-once

V1 worker lifecycle (§3) 是 **restart 时 latest-wins** (不重放崩溃期间错过的 event). 需要 at-least-once 的 adapter 原则上可以在自己 `binding_state` slice 存 cursor checkpoint + restart 时 `subscribe_from(cursor)` — Publisher API 今天就支持.

**选项:**
- (a) **V1 = 全 adapter at-most-once**; Adapter @moduledoc 大声文档化; defer per-adapter at-least-once 到具体用例.
- (b) **V1 = per-adapter opt-in 通过 `Adapter.delivery_semantics() :: :at_most_once | :at_least_once`**; 当 `:at_least_once`, worker 每次成功 publish 时 checkpoint cursor + restart 时恢复.

**推荐:** **(a)** V1. 按 P8 (less invented, more assembled) — 没真 adapter 需要前不加 per-adapter 开关. Feishu 是 fire-and-forget chat; 错过的 event operator 手动重发可恢复. Game-room adapter (推测例) 需要 at-least-once; defer 到真实.

### OQ-EM-A — Publisher retention 策略 default

**选项:**
- (a) **100 events** (基于计数; 每 session 常数内存成本).
- (b) **1 小时 wall-clock** (基于时间; 与 operator "我能追多远?" 直觉对齐).
- (c) **两者 MIN** (谁先 evict 谁).

**推荐:** **(a) 100 events.** 常数内存是生产可用赢 (P4) — operator 不用基于流量模式推理 per-session 内存. 100 events 够现实 "binding restart 用了 30s" 恢复; 更长中断本来就 operator 驱动.

### OQ-EM-B — Publisher 历史存储: 内存环 vs SQLite 表

**选项:**
- (a) **只内存环.** Session Kind restart 时丢. Worker 从 `:latest` 重订阅.
- (b) **内存环 + Publisher restart 时按需从 `kind_snapshots` 恢复.** 每个 slice 变化多一次 Publisher-history slice snapshot 写; Session Kind init 时恢复.
- (c) **内存环 + 通过 P22 writer 异步写专 `publisher_events` SQLite 表.** 抗 Session Kind restart AND application restart.

**推荐:** **(a) 内存 + Publisher restart 时按需从 SQLite 恢复** (实际是选项 (b), 中间路径). 内存环是热路径读; 现有 `kind_snapshots` 机制 (P22) 异步持久 slice. Session Kind restart 时, 环从 snapshot rehydrate — worker 如有 checkpoint 可从 cursor 恢复. 没新表; 与系统每个 slice 同样.

defer (c) 直到 adapter 真需要跨 application restart 重放 (当前零用例).

---

## 附录 A — 交叉引用

- **SKILL P1** (plugin 隔离北极星) — 加新 adapter = 2 模块 + 1 声明. 不动 core / domain / 其他 plugin.
- **SKILL P2** (let-it-crash; 无 workaround) — 坏 binding 留活, fail loudly, 需 operator unbind. 无静默自动禁用.
- **SKILL P3** (单一真实源) — Session slice 是 binding SoT; AdapterRegistry / BindingRegistry / `external_mirror_bindings` 表是 cache / projection.
- **SKILL P9** (reads-what-data → tier ownership) — Domain 读 SliceChange + binding (通用); plugin 读外部 API (特定). Domain 放置合理.
- **SKILL P11** (plugin 外部集成 = Behavior 在已有 Kind) — ExternalMirror Behavior 在 Session Kind + ExternalMirrorWorker 在自己 Kind. 每个外部写发生在 Kind 的 `:invoke`. 任何地方都没有 PubSub-subscriber-然后-外部-写.
- **SKILL P14** (dispatch 是 Kind 间唯一路径) — bind / unbind / publish 全走 `Invocation.dispatch/1`.
- **SKILL P15** (cap 默认窄) — per-adapter allow cap (Cap 2) 把 bind 窄到特定 adapter; worker publish cap (Cap 3) 只通过 `{:within_session, _}` 委托持.
- **SKILL P16** (Kind 单一 spawn 入口) — ExternalMirrorWorker 只通过 `Ezagent.Kind.spawn/2` spawn; 对已在运行的幂等.
- **SKILL P18** (用户面无静默丢失) — `:bind` 返不同 error atom (`:unauthorized` / `:adapter_not_authorized` / `:target_ownership_denied`). Inbound transport 解构 + 上浮回去.
- **SKILL P22** (可靠性原语在 core/Domain; plugin 作者不能绕过) — AdapterRegistry + BindingRegistry + WorkerSupervisor 在 Domain.
- **SKILL P23** (declare-don't-call plugin 合约) — `adapters/0` callback; 框架 wire 注册 + cap subject.
- **caps-data-ownership-v2 §3.3 + §4 + §5.2** — `Behavior.ExternalMirror.data_owner/1` 返 session owner; default grant 给 session owner; `Behavior.IdentityAdmin.invoke(:grant_cap, ...)` 强制 grant 规则.
- **notification-architecture-v2 §2.1** — SliceChange 原语; Publisher 层坐之上.

## 附录 B — 工作例: Alice 把自己 session 镜像到 Lark chat

Setup (PR-EM-3 + PR-EM-6 落地后已就位):
- Alice (`entity://user/team-alpha/alice`) 创建 session `session://default/team-alpha/standup`. 按 caps-data-ownership default grant, Alice 持 `%Capability{kind: :session, behavior: Behavior.ExternalMirror, instance: session_uri, workspace_uri: workspace://team-alpha}` (Cap 1).
- Workspace admin 早先给 Alice grant `%Capability{kind: :session, behavior: Behavior.ExternalAdapter.Feishu.Allow, instance: session_uri, workspace_uri: workspace://team-alpha}` (Cap 2 — per-adapter allow).

动作: Alice 跑 `mix ezagent.external_mirror.bind session://default/team-alpha/standup feishu oc_lark_abc123`.

1. CLI 解析 + 构造 `%Invocation{target: <session>?action=external_mirror.bind, args: %{adapter_id: "feishu", target_id: "oc_lark_abc123"}, ctx: %{caller: alice_uri, caps: alice_caps, mode: :call}}`.
2. `Invocation.dispatch/1` → `Kind.Runtime.handle_dispatch/4`.
3. Step 5.5 CapBAC: Alice 持 Cap 1 → pass.
4. Step 5.6 跨 workspace: 同 workspace → pass.
5. `Behavior.ExternalMirror.invoke(:bind, slice, args, ctx)` body 跑:
   - 检查 2 (Cap 2): Alice 持 → pass.
   - 检查 3 (`target_ownership_check`): Feishu adapter 查 Lark "Alice 关联的 feishu_open_id 是否在 `oc_lark_abc123` 里?". Lark 说 yes → pass.
6. Slice 更新; eager-spawn `Kind.spawn(ExternalMirrorWorker, %{uri: entity://worker/team-alpha/em_<hash>, ...})`.
7. Worker `init_slice/1`: 用 cursor `:latest` 订阅 Session Publisher; 调 `FeishuChatBinding.init({chat_id, FeishuAdapter, opts})`; binding 打开 Feishu HTTP client.
8. CLI 返 `{:ok, %{binding_id: "feishu/oc_lark_abc123"}}`.

Bob (其他用户) 发 `:send` 到 `session://default/team-alpha/standup`:

1. 标准 Chat 流追加消息; `:chat` slice 变.
2. SliceChange hook fire → Session Kind 的 Publisher 追加到环带 cursor N.
3. Worker 收 `{:publisher_event, %Event{cursor: N, slice_key: :chat, ...}}`.
4. Worker 自 dispatch `:publish` 带 idempotency_key `"feishu/oc_lark_abc123/N"`.
5. Worker 的 `:invoke(:publish, ...)`: `FeishuAdapter.event_to_payload(event)` → `{:publish, %{msg_type: "text", content: ...}}`. `FeishuChatBinding.publish(payload, state)` post 到 Lark `/open-apis/im/v1/messages?receive_id_type=chat_id`. 返 `:ok`.
6. Worker slice 更新: cursor=N, last_publish_at=now, publish_count++.
7. Lark chat 显示 Bob 消息.

失败例: Lark 返 429.
1. `FeishuChatBinding.publish/2` 返 `{:error, :rate_limited, %{state | retry_after: t}}`.
2. Worker log + telemetry; slice 更新 error_count++; binding state 持 backoff deadline.
3. 下个 slice 变化到; binding 的 `publish/2` 检 deadline; 如还在 backoff, 又返 `{:error, :backoff, state}` (或队列 + 延迟重发 — binding 选).
4. deadline 过, 下个 publish 正常.
5. Operator 在 admin LV 看到 `last_publish_result: {:error, :rate_limited}`; 持续可选择 unbind.

端到端: Alice 从不碰 `entity://worker/...`. Bob 不知 mirror 存在. Adapter 作者写 1 文件 6 callback; binding 作者写 1 文件 3 callback. Domain 拥有其他全部.
