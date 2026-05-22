# V1 验收压力测试方案

**状态：** 方案（PLAN）—— 未执行。由后续实现任务负责执行。
**作者：** Claude（Opus 4.7），应 Allen 飞书需求 2026-05-22。
**分支：** `docs/v1-stress-test-plan`
**范围：** V1 验收压力测试，**不是**一个长期的压测框架。

---

## 1. 三个问题

Allen 在 V1 验收阶段需要对以下三点给出可度量的答案：

1. **单会话内的 Agent 数量** —— 一个 session 内最多能容纳多少个 agent 作为成员
   并相互收发消息，直到延迟/吞吐开始劣化。
2. **最大会话数** —— 系统能同时承载多少个 session。
3. **最大用户数** —— 系统能同时承载多少个 user。

本文规划的是**如何度量**这三个上限，不负责拍板具体数字 —— **验收基线（§8）是
给 Allen 拍板的提案**。

---

## 2. 运行时成本模型（以代码为依据）

下面每一条结论都引用了真实模块。不臆造成本 —— 这些就是测试要去验证或推翻的数字。

### 2.1 单个实体成本（user / agent / session）

每个 user、agent、session 都是**一个 `Ezagent.Kind.Server` GenServer**
（`apps/ezagent_core/lib/ezagent/kind/server.ex`）。spawn 一个实体永远走
`Ezagent.Kind.spawn/2` → `DynamicSupervisor.start_child`
（`apps/ezagent_core/lib/ezagent/kind.ex:93`）。一个存活实体的成本：

| 资源 | 每实体 | 来源 |
|---|---|---|
| BEAM 进程 | 1 个 GenServer | `Kind.Server` |
| KindRegistry 条目 | 1 行 ETS（`Registry`，`keys: :unique`） | `kind_registry.ex` —— `put_new/2` |
| ReadyGate 条目 | 1 行 ETS | `Kind.Server.init/1` → `ReadyGate.put` |
| 进程状态 | 按 Behavior 切片的 map，键为 `behavior.state_slice()` | `Kind.Server` 状态结构 |
| 快照行 | `kind_snapshots` 表 0 或 1 行（见 §2.4） | `Kind.Snapshot` |

空闲实体内存很小（一个带几个小 map 的 GenServer 约个位数 KB）。扩展性问题在于
**能扛多少个**才会让 BEAM 进程表、ETS 或总 RSS 触顶，以及 spawn **吞吐**
（DynamicSupervisor 串行化 `start_child`）是否会成为 ramp 瓶颈。

各 Kind 的持久化策略（决定快照写入成本）：
- **Session** —— `{:snapshot, :on_change}`（`entity/session.ex:80`）
- **User** —— `{:snapshot, :on_change}`（`entity/user.ex:137`）
- **Agent** —— `:on_terminate`（`entity/agent.ex:69`）
- **Echo agent** —— `:ephemeral`（`ezagent_plugin_echo/.../entity/echo.ex:21`）—— 见 §3.2

### 2.2 派发扇出 —— 一条 `chat.send` 进入有 N 个成员的 session

这是问题 1 的核心。一次 `chat.send`（`Ezagent.Behavior.Chat.invoke(:send, ...)`，
`apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:92`）依次做：

1. **`MessageStore.write/2`**（`message_store.ex:67`）—— 一个 `Repo.transaction`，
   内含 **2 次 SQLite insert**：`messages`（upsert）+ `message_routings`
   （insert）。同步。写失败 = 发送失败（不静默降级）。
2. **1 次 PubSub 广播** 到 `esr:session:<uri>:events` —— LV 聊天流。
3. **`Resolver.resolve/4`**（`routing/resolver.ex:96`）—— 纯函数；把
   `$session_members` 魔法令牌展开成成员列表（剔除发送方）。
4. **对 N−1 个接收者各一次** → `dispatch_receive/3` →
   `Ezagent.Invocation.dispatch/1`，`mode: :cast`。每一次：
   - `ReadyGate.status` 查询 + `KindRegistry.lookup`（2 次 ETS 读），
   - 向接收者 `GenServer.cast`，
   - 接收者内部：`Kind.Runtime.handle_dispatch/4` 跑步骤 5–10：
     BehaviorRegistry 查询、**鉴权检查**（`Capability.matches?` 扫描 ctx.caps）、
     **工作区隔离检查**、参数校验、`Behavior.invoke`、切片写回、
     **`[:ezagent, :invoke, :stop]` telemetry**。
5. **`maybe_notify_external/3`** —— 多一次 ETS 查询；除非有插件注册了
   Session Kind 的 `:notify_external`，否则空操作。

**放大效应 —— telemetry 尾部。** 每次成功派发都发出
`[:ezagent, :invoke, :stop]`。`Ezagent.Audit.attach/0`（`audit.ex`）处理它，
**每个事件做两件事**：(a) 向 `esr:audit:stream` 做 `Phoenix.PubSub.broadcast`，
(b) 向 `Ezagent.Audit.Writer` `GenServer.cast`。Writer **批量写**
（`audit/writer.ex` —— 每 100ms 或满 500 行 flush，`insert_all`），所以审计 DB
成本被摊薄 —— 但 **PubSub 广播是逐事件的，不批量**。

**一条 `chat.send` 进入 N 个成员（接收者为 User/Agent，无自动回复）的扇出形状：**

```
1   chat.send 派发           （Session）
+   1 次 MessageStore 事务   = 2 次 SQLite 写（messages + message_routings）
+   1 次 session-events PubSub 广播
+   (N-1) 次 chat.receive 派发      → (N-1) 次 Behaviour.invoke
+   (N-1) 次逐接收者 PubSub 广播（User → user-events；Agent → bridge send）
+   N    次 [:ezagent,:invoke,:stop] telemetry 事件（1 send + N-1 receive）
+   N    次 audit-stream PubSub 广播
+   N    次 Audit.Writer cast（批量 → 约 N/500 次 SQLite insert_all flush）
```

所以**一条逻辑消息 → 约 2 次 SQLite 写 + 约 (2N+1) 次 PubSub 广播 +
N 次派发 + N 次审计 cast**。PubSub 扇出与派发数都随 N **线性增长**。每条消息的
SQLite 写次数是*常数*（2）—— 直到加上自动回复（§2.6）。

### 2.3 DB 是单写者（很可能是瓶颈）

`EzagentCore.Repo` 用 `Ecto.Adapters.SQLite3`（`repo.ex`）。SQLite 串行化所有
写者。连接池配置：
- **dev**（`config/dev.exs:25`）：`pool_size: 5`。
- **prod**（`config/runtime.exs:29`）：`pool_size` 取 `POOL_SIZE` 环境变量，默认 5。
- **test**（`config/test.exs:8`）：`pool_size: 20`、`queue_target: 1000`、
  `queue_interval: 5000` —— 在 Phase 9 调高，因为集成测试同时从测试 sandbox、
  Audit.Writer、cap 加载、按租户写路径打 Repo。

更大的 Ecto 连接池**不会**给 SQLite 带来写并行 —— 同一时刻只有一个写事务提交。
每次 `chat.send` 做一个 2-insert 事务；Audit.Writer 加一次周期性 `insert_all`；
每次 `:on_change` 快照再加一次写。持续流量下它们争抢这唯一的写者。**须确认 DB
是否处于 WAL 模式** —— config 和 Repo 模块里都没有 `after_connect`/PRAGMA 配置
（grep 无结果），所以 journal 模式就是 `ecto_sqlite3` 的默认值。WAL 与 rollback
journal 会显著改变写争用上限；测试须在开跑时记录实际的 `PRAGMA journal_mode`
和 `PRAGMA busy_timeout`。

### 2.4 快照写入成本（`{:snapshot, :on_change}`，PR #199 背景）

Session 和 User Kind 都是 `{:snapshot, :on_change}`。`Kind.Server` 在**每次派发后**
调用 `Ezagent.Kind.Snapshot.maybe_save/4`（`server.ex:117/123/137/145`）。
`:on_change` 的 `maybe_save`（`kind/snapshot.ex:150`）比较 `old_state == new_state`
（BEAM 值相等），**仅在切片变化时**写：

- **`chat.send`** 返回 `{:ok, slice, %{stored: true}}` —— Chat 切片
  （`members` / `monitors` / `last_seen`）**未变**。所以一次普通消息发送**不会**
  触发 Session 快照写。很好 —— 单纯的消息流量不会放大快照写。
- **`chat.join` / `chat.leave` / 成员 `:DOWN`** **会**修改切片
  （`chat.ex:280-296`、`:305`、`:334`）→ 一次**同步** `save_now/3`
  （`kind/snapshot.ex:177`）：把切片 `term_to_binary` + `KindSnapshot.upsert`
  （一次 SQLite 写）。

**对测试的含义：** session 的*成员变动*（join/leave、agent 崩溃）才是快照写的
放大器，**不是**消息量。agents-per-session 场景必须两者都测 —— session 构建时的
join 风暴 **以及** 稳态消息流。

### 2.5 PubSub 扇出

每个 session 有两类消费者：
- **session-events** topic（`esr:session:<uri>:events`）—— LV 聊天流。
- **audit-stream** topic（`esr:audit:stream`）—— 每个 LV `/admin` 视图，
  外加每次派发一次广播（§2.2）。

一个 topic 上有 M 个 LV 订阅者时，每次广播就是 M 次消息投递。值得警惕的是
audit-stream 广播：它**每次派发都触发一次** —— 重流量下即便只连了一个 admin LV，
audit-stream topic 也是一条全局热路径。

### 2.6 循环放大 —— 组合爆炸风险

如果 agent 自动回复，消息量会爆炸。Echo agent
（`ezagent_plugin_echo/.../behavior/echo.ex`）在 `:receive` 时会向 session 派发
一条新的 `chat.send`。moduledoc 里写了一个防护：`Resolver` 把消息*发送方*
排除在扇出之外，所以 echo 的回复不会回环到*同一个* echo agent。**但对一个
session 里有 N 个 echo agent 的情况，这个防护不够**：

- Agent A 的回复是 A 发出的 `chat.send` → 扇出给 B、C…（除 A 外所有人）。
- Agent B 收到后回复 → 扇出给 A、C… —— 以此类推。
- 一条人类消息进入有 N 个自动回复 agent 的 session，会触发一个大致按几何级数
  增长的级联，直到某处把它丢弃。

Chat/Resolver 里**没有全局轮次计数器或消息预算上限**（已确认 —— Resolver 只做
发送方剔除 + 按 URI 去重）。所以一个朴素的「N 个 echo agent 互聊」测试度量的
是失控过程，不是容量。

**因此本方案强制要求有界流量（§7）。**

---

## 3. 方法论

### 3.1 不调用真实 LLM 来制造负载

V1 验收必须度量 **ezagent 的编排成本**，而非 OpenAI/Claude 延迟。用桩 agent：

- **Echo 插件**（`apps/ezagent_plugin_echo`）—— 已经是参考桩。它的 `:receive`
  会回派一条 `chat.send`。用它走*自动回复*路径，但**必须**配合 §7 的轮次上限，
  因为它会放大。
- **一个被动「sink」agent** —— 为了在*不放大*的前提下度量纯扇出，测试需要一个
  `:receive` 为空操作（计数但永不回复）的 agent。echo 会放大，sink 不会。
  **实现任务动作：** 在测试支撑模块里加一个极小的 `sink` behavior/Kind（或在
  echo behavior 上加一个关闭回复的开关）。推荐在 echo 上加开关（agent init 参数
  里 `reply: false`），这样不必新建插件。**这是实现任务唯一要写的测试代码** ——
  其余是一个 driver 脚本。
- 真实的 `cc.agent` / `curl_agent` 明确不在范围内 —— 它们引入 PtyServer / HTTP
  延迟，会掩盖编排成本。

### 3.2 程序化 spawn N 个实体

所有 spawn 走 `Ezagent.Kind.spawn/2`（唯一入口，不变量）。driver（一个 mix
任务，§6）循环：

- **Users：** `Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: ..., initial_caps: ...})`。
  大数量时跳过 `mix ezagent.user.create` 的建库行流程，直接用 `default_caps()`
  spawn Kind —— 测试度量的是 *Kind* 容量，不是身份建库路径。
- **Agents：** 直接 spawn echo Kind（`:ephemeral` —— 无快照噪声），或经 echo
  的 `cc.agent` 风格 Template Class。
- **Sessions：** spawn `Ezagent.Entity.Session`，随即**立刻 `WorkspaceRegistry.bind/2`**
  （不变量 4 —— `MessageStore.write` 会对未绑定 session 经
  `Persistence.workspace_uri_for!/1` 抛错）。
- 每个 agent/user 通过 `chat.join`（一个 `:call`）加入 session。

URI 用 SPEC v3 §5.15 的规范 3 段按租户形式：
`entity://agent/<workspace>/echo_<n>`、`session://default/<workspace>/stress_<n>`。

### 3.3 触发聊天流量

driver 以受控速率（令牌桶节流器）向目标 session 派发 `chat.send`，每场景每次
运行有**固定的消息总预算**（§7）。每条消息是一个带短文本体的
`%Ezagent.Message{}`。对 agents-per-session 场景，消息可以 `@mention` 全体成员
（强制全扇出）或不 mention（Resolver 展开 `$session_members`）；两者都测 ——
不 mention 是现实默认值，且会走完整的成员扇出。

### 3.4 测试环境

- 在一个**专用的 `:prod` 或 `:bench` 构建**上跑，用真实落盘 SQLite DB（不用
  test Sandbox —— Sandbox 按测试串行化，会掩盖真实连接池争用）。显式固定
  `POOL_SIZE` 并记录。
- 单 BEAM 节点（V1 是单节点）。记录主机：核数、RAM、磁盘类型（SSD 还是机械盘
  会显著改变 SQLite 写延迟）。
- 开跑时记录 `PRAGMA journal_mode` + `busy_timeout`（§2.3）。
- **【需人工】** Allen / 运维须指定测试机器 —— 见 §9。

---

## 4. 场景

每个场景：spawn → 预热 → ramp → 稳态保持 → 拆除。每个 ramp 步长保持足够时间让
指标稳定（建议每步保持 ≥60s）。每次运行用**固定消息预算**（§7）。

### 场景 A —— 单会话 agent 数（问题 1）

一个 session，逐步增加成员数，每步在稳态流量下保持。

- **Ramp：** 2 → 5 → 10 → 25 → 50 → 100 个 agent（全部为同一 session 成员）。
- **流量：** 固定 driver 在保持窗口内以固定速率注入 M 条消息总量；接收者用
  **sink agent**（无自动回复）测容量数，再用一次**单独的有界自动回复运行**
  （echo agent + 轮次上限，§7）来度量回复扇出成本。
- **主指标：** 随 N 增长的派发延迟 p50/p99 与 messages/sec；每条消息的扇出是
  N−1 次派发（§2.2）。
- **ramp 停止条件：** p99 派发延迟首次超过 §8 基线，或 BEAM/DB 出现异常（§5）。

### 场景 B —— 最大会话数（问题 2）

很多 session，每个成员不多，流量轻。

- **Ramp：** 10 → 50 → 100 → 250 → 500 → 1000 → 2000 个 session，每个固定小成员数
  （如 1 user + 2 sink agent）。
- **流量：** 每 session 低固定速率（如 1 条/session/10s），使场景度量的是*承载*
  众多 session，而非消息吞吐。
- **主指标：** 总 BEAM 进程数、总 RSS、KindRegistry ETS 大小、session spawn
  吞吐（DynamicSupervisor 串行化）、构建时 join 风暴产生的快照写速率（§2.4）。
- **停止条件：** RSS 逼近主机上限、spawn 吞吐崩塌，或 `kind_snapshots` 写队列堆积。

### 场景 C —— 最大用户数（问题 3）

很多 user Kind，少量 session。

- **Ramp：** 100 → 500 → 1000 → 5000 → 10000 个 user Kind。
- **流量：** 用户大多空闲（现实中用户不会持续发消息）；一个小活跃子集（如 5%）
  以轻速率发送。
- **主指标：** 进程数、RSS、KindRegistry ETS 大小、User `:on_change` 快照行为
  （User 快照只在 User 切片变化时写 —— 空闲用户不产生写；须确认）。
- **停止条件：** 同场景 B。

### 场景 D —— 组合（现实混合）

一次混合运行，逼近一个合理的 V1 部署形态，以捕捉孤立场景漏掉的交互效应
（DB 争用是三者共享的）。

- **形态（提案，Allen 可调）：** 如 200 user、50 session 平均每个 5 成员、
  10% 的 session 是带有界自动回复 echo agent 的「繁忙」session，其余轻流量。
- **主指标：** 混合负载下的端到端 p99 派发延迟与 SQLite 写队列深度 —— 这是最
  接近「V1 够不够好」的数字。

---

## 5. 测什么

每场景、每 ramp 步、在稳态保持窗口内采样：

| 指标 | 怎么测 | 为什么 |
|---|---|---|
| **派发延迟 p50/p99** | `[:ezagent, :invoke, :stop]` telemetry 带 `duration_us`（`kind/runtime.ex:88`）。挂一个直方图 handler。 | 核心编排成本数字。 |
| **messages/sec 吞吐** | 每秒 `chat.send` 派发数（driver 侧计数器 + telemetry 交叉核对）。 | 问题 1 的头条。 |
| **BEAM 进程数** | 采样 `:erlang.system_info(:process_count)`。 | 问题 2、3 的天花板。 |
| **总内存（RSS + 分类）** | `:erlang.memory/0`（`:total`、`:processes`、`:ets`、`:binary`）+ OS RSS。 | 问题 2、3 的天花板。 |
| **ETS 大小** | 对 `Registry`（KindRegistry）、ReadyGate、SchemeRegistry、RoutingRegistry 表取 `:ets.info(table, :size)` + `:memory`。 | KindRegistry 争用/大小假设。 |
| **SQLite 写延迟** | 包裹/观测 `MessageStore.write` + `Audit.Writer` flush + `Snapshot.save_now`；发出计时 telemetry。仓库已有 `[:ezagent, :persistence, :written]`（`kind/snapshot.ex:202`）—— 扩展加上时长度量。 | DB 争用假设（§2.3）。 |
| **DB 队列深度** | Ecto telemetry `[:ezagent_core, :repo, :query]` 事件暴露 `queue_time`。挂 handler；`queue_time` 逼近 `queue_target` 时告警。 | 连接池耗尽 / 写者串行化。 |
| **快照写速率** | 计数 `[:ezagent, :persistence, :written]` 事件；与 join/leave/DOWN 事件关联。 | §2.4 的变动放大检查。 |
| **调度器利用率** | `:scheduler.utilization/1`（保持窗口内采样）。 | BEAM 是 CPU 受限还是 IO 受限（在等 SQLite）。 |
| **邮箱深度** | 对 Audit.Writer、Snapshot.Writer 及最热的 Session/Agent 采样 `Process.info(pid, :message_queue_len)`。 | 反压检测（writer 无条件 cast —— §2.2、`audit/writer.ex` moduledoc）。 |

采样：一个轻量收集进程每 1–5s 轮询 `system_info`/`memory`/`ets`，每次运行写一份
CSV/JSONL。telemetry 直方图聚合延迟。运行期间**不要**保持 audit-stream PubSub
订阅，除非就是要测它 —— 它本身就是负载。

---

## 6. 工具

对本仓库务实 —— 不引入新框架。

- **Driver：一个 Mix 任务。** `mix ezagent.stress`，置于
  `apps/ezagent_core/lib/mix/tasks/`（与现有 `ezagent.bootstrap`、
  `ezagent.snapshot.*` 任务并列）。参数：`--scenario a|b|c|d`、`--ramp`、
  `--message-budget`、`--rate`、`--turn-cap`、`--out <path>`。它经
  `Ezagent.Kind.spawn/2` spawn 实体、绑定 workspace、join 成员、节流派发
  `chat.send`，并干净关停。
- **指标：telemetry + 采样器。** 给已存在的事件挂 handler
  （`[:ezagent, :invoke, :stop]`、`[:ezagent, :persistence, :written]`、Ecto 的
  `[:ezagent_core, :repo, :query]`）。加一个 `StressMetrics` 收集模块，持有直方图
  + 周期性 `system_info` 采样器并写出结果文件。`ezagent_web/telemetry.ex` 已是
  可参照的范式。
- **观测：** 运行时用 `:observer` 交互查看；怀疑泄漏时用 `:recon`
  （`:recon.proc_count/2`、`:recon.bin_leak/1`）做进程/二进制取证。这些是诊断
  手段，不是数据源 —— 采样器写出的 CSV/JSONL 才是记录。
- **唯一要写的测试代码：** `mix ezagent.stress` 任务、`StressMetrics` 收集器，
  以及 echo 的 `reply: false` 开关（§3.1）。不建永久 harness、不接 CI ——
  V1 验收是一次性度量。

---

## 7. 循环放大安全（强制）

容量测试必须度量*容量*，而非失控过程（§2.6）。driver **必须**用**两种**机制
约束流量：

1. **固定消息预算。** 每次运行恰好注入 M 条由 driver 发起的 `chat.send`，之后
   停止注入。M 是运行参数。
2. **自动回复轮次上限。** 任何用到 echo（自动回复）agent 的场景，消息体中携带
   一个**跳数计数器**（如 `body.meta.hop`），echo 的 `:receive` 回复路径受门控：
   **当 `hop >= turn_cap` 时不回复**。`turn_cap` 是运行参数（建议 3–5），以确定性
   方式限制级联深度。
   - **实现任务动作：** 在 echo behavior 的回复路径加上跳数检查（与 §3.1 的
     `reply: false` 开关并列）。这是测试支撑层的事 —— 用开关/参数门控它，
     生产 echo 行为不变。
3. **driver 看门狗。** driver 跟踪观测到的 `chat.send` 计数与期望上限
   （`M × 扇出 × turn_cap`）；若观测值超出上限到一定余量，则中止运行并标记
   「放大未被约束」—— 这本身就是一个发现。

对于*纯容量*数字（问题 1–3），优先用 **sink agent**（不回复），这样扇出恰为
每条消息 N−1、预算精确。仅在专门做「自动回复成本几何」子度量时才用
echo + 轮次上限。

---

## 8. 瓶颈假设（排序）

对什么会最先崩的排序预测。每条：为何、测试如何确认、候选缓解。

### H1 —— SQLite 单写者争用（最可能）

**为何：** `EzagentCore.Repo` 是 SQLite；同一时刻一个写者（§2.3）。每次
`chat.send` 是一个 2-insert 事务；Audit.Writer 加周期性 `insert_all`；每次
`:on_change` 快照（join/leave/DOWN）再加一次写。更大的 Ecto 连接池不增加写并行。
在场景 A 的高消息速率下，或场景 D 的混合负载下，单写者就是吞吐天花板。

**确认：** messages/sec 触顶而 CPU **未**饱和；Ecto `[:ezagent_core, :repo, :query]`
的 `queue_time` 攀升逼近 `queue_target`；`MessageStore.write` p99 延迟上升；
Audit.Writer 邮箱增长。

**候选缓解：** 确认并启用 **WAL journal 模式**（最大单一杠杆 —— 先记录当前模式）；
调高 `busy_timeout`；批量 `message_routings` insert；考虑每次 `chat.send` 的
`messages` upsert + routing insert 能否合并为单条语句；更长期看，给 message
store 换非 SQLite 写者。对验收而言，WAL + 一个有据可查的 msgs/sec 上限大概率够。

### H2 —— PubSub audit-stream 扇出成为全局热路径

**为何：** 每次派发都发出 `[:ezagent, :invoke, :stop]`；`Ezagent.Audit`
**逐事件、不批量**地把它广播到 `esr:audit:stream`（§2.2、§2.5）。在
N×msgs/sec 派发量下这是一条高频单 topic；每个 `/admin` LV 订阅者再翻倍。

**确认：** 即便 DB 空闲，调度器利用率也随派发量上升；PubSub/`Phoenix.PubSub`
进程显示高 reductions；（仅测试时）关掉 audit attach 后吞吐可测量地上升。

**候选缓解：** 批量 audit-stream 广播（Writer 已批量了 DB 路径 —— 对广播路径
照做）；或对 audit-stream 广播做采样/合并;或让 LV `/admin` 改为按间隔拉取，
而非订阅这条逐派发的消防水管。

### H3 —— 每消息派发开销 × 扇出（随 N 线性）

**为何：** 一条 `chat.send` 进入 N 个成员 = N−1 次 `chat.receive` 派发，每次
跑完整 `Kind.Runtime` 路径：BehaviorRegistry 查询、鉴权 cap 扫描
（对 ctx.caps 做 `Enum.any?`）、工作区隔离检查、参数校验、telemetry（§2.2）。
成本随 N 线性增长 —— 对场景 A，即便 DB 完美，这也是单会话 agent 数的内在成本。

**确认：** 单条 `chat.send` 的 p99 派发延迟随成员数 N 成比例增长；
flamegraph/`:recon` 显示时间花在 `handle_dispatch` 而非 Repo。

**候选缓解：** 对 V1 大概率*可接受* —— 记录线性成本与实际 N 上限。若某个子步骤
占主导（如 cap 扫描），就微优化那一处。不要过早批量化派发。

### H4 —— 高实体数下的 KindRegistry / ETS 争用

**为何：** 每个实体是一行 `Registry`（ETS）；每次派发做 `ReadyGate` +
`KindRegistry` 查询（§2.1、§2.2）。在 10k+ 实体（场景 C）下表很大；高并发派发
下分区 ETS 可能出现读争用。

**确认：** `:ets.info` 内存如预期增长（大小没问题）；但若派发延迟随*总实体数*
上升而与每会话扇出无关，则怀疑 registry 争用。

**候选缓解：** stdlib `Registry` 已分区 —— 大概率没事；若有，增加分区数。
最可能 H4 是非问题，测试会确认 ETS 线性且廉价地扩展。

### H5 —— ramp 期 DynamicSupervisor spawn 串行化

**为何：** `Ezagent.Kind.spawn/2` → `DynamicSupervisor.start_child` 经 supervisor
串行化。spawn 1 万个实体就是 1 万次串行调用 —— 这是 *ramp 期*成本，不是稳态成本。

**确认：** 给 spawn 循环计时；若每秒 spawn 实体数触顶，supervisor 就是瓶颈。

**候选缓解：** 对测试可接受（慢点 ramp）；对生产，已有多个按 Kind 的 supervisor
（`supervisor/0` 回调）—— 把 Kind 分散到它们上。记录即可，不因此卡 V1。

**预测崩溃顺序：** H1（DB 写）→ H2（审计 PubSub）→ H3（线性扇出）→
H5（spawn ramp）→ H4（ETS，大概率永不）。

---

## 9. 验收标准 / 基线 —— **提案，Allen 拍板**

以下数字是**提案**。由 Allen 拍板实际基线。它们按单节点 V1、商用硬件估算。

| 维度 | 提议「V1 够好」 | 「需改进」 |
|---|---|---|
| **单会话 agent 数** | ≥ 25 个 agent 全为成员，向该 session 稳态 5 msg/s 时 p99 `chat.send` 端到端扇出 < 250 ms | 在 ≤ 25 个 agent 时 p99 > 1 s |
| **最大会话数** | ≥ 500 个并发 session 承载，RSS < ~2 GB，spawn + 空闲稳定 | 低于 200 session 即不稳 |
| **最大用户数** | ≥ 5000 个 user Kind 承载，RSS < ~2 GB，空闲 | 低于 1000 user 即不稳 |
| **组合（D）** | 现实混合下稳态 p99 派发 < 250 ms，SQLite `queue_time` 远低于 `queue_target` | 队列持续堆积或 p99 > 1 s |
| **吞吐** | 全系统稳态 ≥ 200 `chat.send`/s 而无 DB 队列堆积 | < 50 /s |

**每个数字都是提案 —— V1 基线由 Allen 设定。** *执行*任务的交付物是一张填满实测
数字的结果表，外加针对 Allen 拍板的基线给出清晰的「达标 / 未达标」，以及一份
按 §8 编排的优先缓解清单。

---

## 10. 需人工 / Allen 的步骤 —— 【需人工】

依据记忆 `feedback_flag_user_assist_steps`，逐一标出需要人参与的步骤：

1. **【需人工】指定测试机器。** 运行**不可**在共享 dev 机或 CI runner 上 ——
   它会打满 BEAM、DB 和磁盘 IO。Allen / 运维挑一台专用主机并记录其规格（§3.4）。
2. **【需人工】授权测试构建 + DB。** 运行用 `:prod`/`:bench` 构建配真实落盘
   SQLite DB，与任何真实数据隔离。需有部署权限的人来准备。
3. **【需人工】长时间运行。** 场景 D 与 B/C 的高步长可能跑数十分钟到数小时。
   若在共享基础设施或过夜运行，Allen 应批准时间窗。
4. **【Allen】拍板验收基线（§9）。** 提议数字是占位 —— V1 通过/不通过由 Allen 决定。
5. **【Allen】批准自动回复轮次上限值（§7）。** 建议 3–5；由 Allen 确认 V1 下
   「现实的 agent 对话深度」是多少。

---

## 11. 不在范围内

- 多节点 / 分布式 BEAM（V1 是单节点）。
- 真实 LLM 驱动的 agent（`cc.agent`、`curl_agent`）—— 度量到的成本会被外部延迟
  主导，而非编排。
- 永久压测框架或 CI 性能门 —— 这是一次性的 V1 验收度量。
- 网络传输压测（Feishu sidecar、Phoenix Channels WS）—— 与三个问题正交；
  如有需要另立项。
