# V1 验收压力测试 — 结果报告

**状态:** 已执行。测量运行,2026-05-22。
**测试计划:** `docs/superpowers/plans/2026-05-22-v1-stress-test-plan.md`(方法论)。
**分支:** `test/v1-stress-test-run`。
**测试驱动:** `mix ezagent.stress`(`apps/ezagent_core/lib/mix/tasks/ezagent.stress.ex`)
+ `Ezagent.StressMetrics` 采集器(`apps/ezagent_core/lib/ezagent/stress_metrics.ex`)。
该 task 是一次性测量工具,不在正常构建 / CI 中运行,不影响
`mix compile` / `mix test`。

> 英文对照版:`v1-stress-test-results-2026-05-22.md`。

---

## 1. 实际施加的资源约束

按 Allen 飞书指示(2026-05-22),BEAM 被约束到**树莓派 4/5 级别配置**:

| 杠杆 | 取值 | 方式 |
|---|---|---|
| 调度器 | **`+S 4:4`** — 4 调度器,4 在线 | `ELIXIR_ERL_OPTIONS="+S 4:4"` |
| 内存上限 | **约 4 GB** — RSS 超过 3500 MB 时驱动自动中止 ramp | `--mem-ceiling-mb 3500` |
| 运行时长 | 分钟级,非小时级 — 有界消息预算 + 找拐点的 ramp | 各场景 |

**主机:** Apple M3 Ultra,macOS 15(Darwin 25.2),SSD。物理上是
28 核 / 96 GB 机器,但 BEAM 被钉在 4 个调度器上。SQLite 在本地 SSD。

**重要说明 — 单核速度。** `+S 4:4` 复现了树莓派的*核数*,且 BEAM
被压在 4 GB 上限以下,但单个 M3 核心比 Cortex-A76(Pi 5)快数倍。因此:

- **下文的内存拐点和进程数拐点是忠实于该配置的** — 它们取决于内存和
  BEAM 进程表,而非 CPU 速度,可直接迁移到真实树莓派。
- **延迟 / 吞吐数字对真实树莓派偏乐观** — 要估算 Cortex-A76,把
  msg/s 和 dispatch/s 除以约 3–5 倍。每条曲线的*形状*(线性、平坦、
  拐点在哪个 N)是正确的;只有绝对时间会缩放。

**数据库(运行开始时记录,计划 §2.3):**
`journal_mode=wal`、`busy_timeout=2000`、`pool_size=5`。WAL 已是默认 —
无需 PRAGMA 配线。这对 H1 有实质帮助。

---

## 2. 三个问题 — 实测答案

### Q1 — 单 session 内最多多少 agent

单个 session,逐级提高 agent 成员数,注入固定消息预算,**排空到静止**后
测量持续吞吐。Sink 模式(`turn_cap=0`,echo 永不回复)用于纯容量数字。

**限速(注入 10 msg/s,真实速率 ramp):**

| N agent | dispatch p99 | dispatch max | RSS | 进程数 | repo_query p99 |
|---|---|---|---|---|---|
| 2   | 3.87 ms | 6.5 ms  | 108 MB | 315 | 1.3 ms |
| 5   | 3.79 ms | 7.1 ms  | 107 MB | 320 | 2.6 ms |
| 10  | 4.28 ms | 11.4 ms | 105 MB | 331 | 2.6 ms |
| 25  | 3.44 ms | 7.8 ms  | 108 MB | 357 | 3.2 ms |
| 50  | 4.05 ms | 8.5 ms  | 118 MB | 408 | 5.6 ms |
| 100 | 1.36 ms | 16.1 ms | 136 MB | 509 | 12.6 ms |

**突发(整个 15 000 条消息预算一次性打入 — 找真实持续上限,因为限速
注入受 `Process.sleep` 下限约束):**

| N agent | dispatch 数 | 持续 msg/s | 持续 dispatch/s | dispatch p99 | RSS |
|---|---|---|---|---|---|
| 5   | 105 000    | 1460 | 10 221 | 0.87 ms | 235 MB |
| 25  | 405 000    | 806  | 21 762 | 0.95 ms | 372 MB |
| 100 | 1 530 000  | 329  | 33 576 | 0.62 ms | **1774 MB** |

**答案:** 在建议验收门槛下(p99 `chat.send` < 250 ms),系统在单个
session **400 个 agent 时仍未触及延迟拐点**(另一次运行:400 agent、
160 800 dispatch、p99 0.05 ms、零错误)。每次 dispatch 延迟在任意 N
下都是亚毫秒级 — 编排路径很廉价。

Q1 真正的拐点是**突发下的内存**:N=100 时,15 000 条排队消息扇出到
约 150 万次 `chat.receive` dispatch,瞬时 RSS 升到 **1.77 GB**。持续
msg/s 也随 N 增大而下降(N=5/25/100 → 1460 / 806 / 329 msg/s),因为
每次 `chat.send` 的 N−1 扇出是*在 Session GenServer 内联执行*的 —
这就是关于 N 的线性成本(H3)。

> **Q1 建议 V1 数字:在任意现实消息速率下,单 session 轻松 ≥ 100
> 个 agent**(延迟不是问题)。实际上限由*突发*内存决定,而非延迟:
> 只要把单个 session 的瞬时积压限制住(每 session 入站限速),4 GB
> 内 100+ agent 是安全的。没有限速时,15k 条消息突发打入一个 100-agent
> session 单独就用掉约 1.8 GB。

### Q2 — 最多并发 session 数

逐级提高并发 session 数,每个 `1 用户 + 2 sink agent`(每 session 4 个
Kind),session 跨步累积。

| session 数 | Kind 总数 | RSS | 进程数 | ETS | spawn 吞吐 |
|---|---|---|---|---|---|
| 500   | 2 005   | 192 MB  | 2 311  | 2.6 MB  | 3493 /s |
| 1 000 | 4 005   | 280 MB  | 4 311  | 3.6 MB  | 3719 /s |
| 2 000 | 8 005   | 414 MB  | 8 311  | 5.4 MB  | 3892 /s |
| 4 000 | 16 005  | 661 MB  | 16 311 | 9.1 MB  | 3904 /s |
| 8 000 | 32 005  | 1158 MB | 32 311 | 16.6 MB | 3705 /s |

**答案:** 完美线性,未触及拐点。8000 session(32 000 Kind)占用
**1.16 GB RSS**。每 Kind 约 36 KB RSS。spawn 吞吐稳定在约 3700
entity/s — **无 DynamicSupervisor 串行化拐点(H5 被证伪)**。ETS 线性
且开销极小(32k Kind 时 16.6 MB — H4 被证伪)。

> **Q2 建议 V1 数字:≥ 8000 并发 session** 可轻松承载;按线性 RSS
> 曲线外推,4 GB 上限可容纳约 **25 000–27 000 个 session**(约 10 万
> Kind),远高于计划建议的 500-session 门槛。

### Q3 — 最多并发用户数

逐级提高空闲 User Kind 数,用户跨步累积。

| 用户数 | RSS | 进程数 | ETS | snapshot 写 |
|---|---|---|---|---|
| 5 000   | 361 MB  | 5 311   | 3.7 MB  | 0 |
| 10 000  | 624 MB  | 10 311  | 5.7 MB  | 0 |
| 25 000  | 1442 MB | 25 311  | 11.9 MB | 0 |
| 50 000  | 2752 MB | 50 311  | 22.0 MB | 0 |
| 100 000 | 4519 MB | 100 311 | 42.4 MB | 0 — **ramp 中止,RSS 超上限** |

**答案:** 内存上限守卫在 100 000 用户处触发(RSS 4519 MB > 3500 MB
上限)并干净地停止 ramp — 无 swap、无崩溃。**Q3 拐点就是 4 GB 内存
上限:约 50 000 空闲用户(2.75 GB)是最后一个安全步;约 75 000 用户
会贴在约 4 GB 线上。** 每空闲 User Kind 约 55 KB RSS。每步
`snapshot 写 = 0` — **证实计划预测:空闲用户零 SQLite 写**(User Kind
是 `{:snapshot, :on_change}`,空闲用户从不改 slice)。spawn 吞吐约
10 000 用户/s。

> **Q3 建议 V1 数字:4 GB 树莓派内 ≥ 50 000 并发(空闲)User Kind**
> — 比计划建议的 5000-用户门槛高一个数量级。注意:这是*空闲*用户。
> 发消息的活跃用户会增加 dispatch + DB 负载(见 Q1)。

---

## 3. 哪个瓶颈最先出现

计划排了五个假设。结合数据:

### H1 — SQLite 单写者争用 — **未确认**

被预测为最可能的瓶颈在树莓派级资源下**没有**咬住。原因是 WAL 模式
(已是默认)。即使在最猛的突发下(15 000 条消息 → N=100 时 150 万
dispatch):

- `repo_queue_time` p99 维持在 **0.04–0.21 ms** — Ecto 连接池从未争用;
  无朝 `queue_target` 方向的队列积压。
- `repo_query_time` p99 维持在 **1.5–17 ms** — 单条 SQLite 写延迟随
  并发适度上升但从未成为限制者。
- 一次持续限速运行维持了 **约 500 chat.send/s**(驱动的注入下限,
  非 DB 限制),`repo_query` p99 = 3.4 ms,零错误。单 WAL 写者轻松
  吸收约 1000 insert/s + audit 批量。

计划建议的吞吐门槛(≥ 200 chat.send/s)有大量余量被满足。**H1 是真实
的架构属性,但不是 V1 上限** — WAL 已缓解。

### H2 — Audit-stream PubSub 扇出 — **未观察到作为限制者**

`[:ezagent,:invoke,:stop]` 每次 dispatch 触发,`Ezagent.Audit` 把每个
广播到 `esr:audit:stream`。本次运行没有挂 LV `/admin` 订阅者,所以广播
就是一次 registry 查找 + 空操作。telemetry handler 尾部(每事件广播 +
`Audit.Writer` cast)被吸收:N=100 突发时持续 33 576 dispatch/s,零
错误,调度器无饱和。**H2 未在最坏情况下被触发**(最坏情况是许多
`/admin` LV 订阅者放大这条 firehose)— 对开着 admin 看板的生产部署
它仍是真实风险,缓解措施(批量/合并 audit-stream 广播)仍值得做,但
它在本次测量运行中**没有**咬住。

### H3 — 每消息 dispatch 开销 × 扇出(关于 N 线性)— **确认为吞吐形状**

这是数据真正显示的瓶颈。一次 `chat.send` 打入 N 个成员会**在 Session
GenServer 内联**执行 N−1 次 `chat.receive` dispatch。突发结果:

- N=5 → 1460 msg/s;N=25 → 806 msg/s;N=100 → 329 msg/s 持续。吞吐
  **随 N 近似线性**下降 — 正是 H3 预测。
- 总 dispatch/s 反而随 N *上升*(10k → 22k → 34k)— BEAM 每条逻辑
  消息做更多工作;Session 是串行瓶颈,而非 DB。
- 每次 dispatch 延迟全程亚毫秒 — 成本在*数量*,不在单次延迟。

H3 对 V1 **可接受**,如计划预测:延迟没问题,线性成本只在突发下的
超大单 session 才有影响。记录实际 N 上限;不要过早批量化。

### H5 — DynamicSupervisor spawn 串行化 — **被证伪**

spawn 吞吐在每个 ramp 中持平到上升:约 3700 entity/s(场景 B,至
32k Kind)和约 10 000 用户/s(场景 C,至 100k Kind)。无串行化拐点。

### H4 — KindRegistry / ETS 争用 — **被证伪**

ETS 线性且廉价增长:100 000 Kind 时 42 MB。dispatch 延迟不随实体总数
上升。分区的标准库 `Registry` 扩展良好。

**结论 — 谁最先咬住:** 在树莓派级资源下,H1/H2/H4/H5 都没有成为 V1
上限。**约束性限制是内存** — 总 RSS — 而 **H3(线性扇出)是吞吐的
*形状***。预测的失败顺序(H1→H2→H3→H5→H4)对 V1 是错的:内存是墙,
H3 定斜率,而 DB(H1)— 得益于 WAL — 有充裕余量。

---

## 4. 循环放大发现(计划 §2.6 / §7)

驱动给每条消息 body 打上带 `hop` + `turn_cap` 的 `meta` map;echo 的
`:receive` 回复路径被扩展(本次运行唯一一处测试支持代码,
`Ezagent.Behavior.Echo`)来遵守它 — `turn_cap=0` = sink(永不回复)、
`hop >= turn_cap` = 停止。

一次有界自动回复运行(`turn_cap=3`)证实 §2.6 风险真实且严重:

| N agent | 注入数 | 产生的 dispatch 数 | 放大倍数 |
|---|---|---|---|
| 5  | 15 | 9 555   | 约 640× |
| 10 | 15 | 150 330 | 约 10 000× |

15 条人类消息打入一个 10-agent 自动回复 session,在 turn cap 停止级联
前产生了 **150 330 次 dispatch**。级联随 N 几何增长。**turn cap 起作用
了** — 每次运行都终止,零错误 — 但这具体证明了 **`Chat`/`Resolver`
里没有全局 turn 计数器或消息预算**(计划 §2.6,确认)。对带自动回复
agent 的 V1,这是生产隐患:单条消息能自我放大成失控。

> **建议:** 在生产 `Message` envelope 加一个 hop/turn 计数器 +
> `Resolver` 级别的级联上限,或者明确规定自动回复 agent(echo 及未来
> 任何一个)必须自带回复守卫。压测的 echo 标志只是测试支持,**不是**
> 生产修复。

---

## 5. 崩溃 / 错误

**无。** 跨所有场景所有 ramp 步 — 包括 150 万 dispatch 突发和 100 000
用户 ramp — `dispatch_errors = 0`。唯一的"停止"是 `--mem-ceiling-mb`
守卫故意在场景 C 100 000 用户处中止(RSS 4519 MB)— 一次干净的、预期
内的停止,不是崩溃,机器从未进入 swap。

---

## 6. 建议(按优先级)

1. **Q1/Q3 的约束性限制是内存。** 按内存给树莓派部署定容量:每 Kind
   约 36 KB(session+成员)、每空闲用户约 55 KB。4 GB 树莓派可容纳约
   5 万空闲用户 *或* 约 2.5 万 session — 按实际负载混合调整。
2. **加每 session 入站限速。** 把单个 session 推入困境的唯一方式是
   无界*突发*(Q1:15k 消息 → 1.8 GB 瞬时)。一个适度的入站限速能
   消除 Q1 唯一的内存隐患。
3. **给生产加级联上限。** §4 循环放大发现是最可操作的风险。在
   `Message` envelope 放 hop 计数器、在 `Resolver`(或
   `Chat.invoke(:send)`)放上限,让自动回复级联在结构上有界,而非靠
   每个插件。
4. **批量化 audit-stream PubSub 广播(H2)。** 本次运行不是限制者,但
   一旦生产里 `/admin` LV 订阅这条每-dispatch firehose 它就会是。
   `Audit.Writer` 已批量化 DB 路径;对广播也照做。
5. **H1(SQLite)对 V1 没问题 — 保持 WAL。** V1 除确保 WAL 保持为
   journal 模式外无需动作。仅当未来负载持续 >> 500 chat.send/s 时再看。
6. **V1 最终签收前在真实树莓派硬件上重跑。** 本次运行的内存/进程数
   拐点可直接迁移;延迟/吞吐数字对 Cortex-A76 偏乐观约 3–5 倍。
   `mix ezagent.stress` 已提交且可重跑,正是为此。

---

## 7. 如何复现

```sh
# 树莓派级配置,隔离的 DB home:
export ELIXIR_ERL_OPTIONS="+S 4:4"
export EZAGENT_HOME=/tmp/esr-stress-home
export MIX_ENV=dev
mix ecto.create && mix ecto.migrate

# Q1 — 单 session agent 数(突发模式找真实上限):
mix ezagent.stress --scenario a --ramp 5,25,100 --hold-ms 3000 --rate 0 --turn-cap 0 --out /tmp/a.jsonl
# Q2 — 最大 session 数:
mix ezagent.stress --scenario b --ramp 500,1000,2000,4000,8000 --hold-ms 5000 --out /tmp/b.jsonl
# Q3 — 最大用户数:
mix ezagent.stress --scenario c --ramp 5000,10000,25000,50000,100000 --hold-ms 4000 --out /tmp/c.jsonl
# 循环放大(有界 echo 自动回复):
mix ezagent.stress --scenario a --ramp 5,10 --rate 5 --turn-cap 3 --out /tmp/echo.jsonl
```

每次运行向 `--out` 追加每 ramp 步一个 JSON 对象。`--rate 0` 是无限速
突发模式;`--turn-cap 0` 是 sink 模式(无自动回复)。
