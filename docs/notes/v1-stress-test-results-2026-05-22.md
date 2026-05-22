# V1 Acceptance Stress-Test — Results

**Status:** EXECUTED. Measurement run, 2026-05-22.
**Plan:** `docs/superpowers/plans/2026-05-22-v1-stress-test-plan.md` (the methodology).
**Branch:** `test/v1-stress-test-run`.
**Driver:** `mix ezagent.stress` (`apps/ezagent_core/lib/mix/tasks/ezagent.stress.ex`)
+ `Ezagent.StressMetrics` collector (`apps/ezagent_core/lib/ezagent/stress_metrics.ex`).
This task is a one-off measurement tool; it does not run in a normal
build / CI and does not affect `mix compile` / `mix test`.

> **[zh]** Chinese parallel: `v1-stress-test-results-2026-05-22.zh_cn.md`.

---

## 1. Resource profile actually applied

Per Allen's Feishu instruction (2026-05-22), the BEAM was constrained to
a **Raspberry-Pi-4/5-class profile**:

| Lever | Value | How |
|---|---|---|
| Schedulers | **`+S 4:4`** — 4 schedulers, 4 online | `ELIXIR_ERL_OPTIONS="+S 4:4"` |
| Memory ceiling | **~4 GB** — driver aborts the ramp if RSS > 3500 MB | `--mem-ceiling-mb 3500` |
| Run length | Minutes, not hours — bounded message budgets, knee-finding ramps | per scenario |

**Host:** Apple M3 Ultra, macOS 15 (Darwin 25.2), SSD. Physically a
28-core / 96 GB box, but the BEAM was pinned to 4 schedulers. SQLite
on local SSD.

**Important caveat — per-core speed.** `+S 4:4` reproduces a Pi's
*core count* and the BEAM was held under a 4 GB ceiling, but an M3
core is several times faster than a Cortex-A76 (Pi 5). So:

- **Memory knees and process-count knees below are profile-faithful**
  — they depend on RAM and the BEAM process table, not CPU speed, and
  transfer directly to a real Pi.
- **Latency / throughput numbers are optimistic** for a real Pi —
  divide msg/s and dispatch/s by roughly 3–5× for a Cortex-A76
  estimate. The *shape* of every curve (linear, flat, the location of
  the knee in N) is correct; only the absolute timing scales.

**Database (recorded at run start, plan §2.3):**
`journal_mode=wal`, `busy_timeout=2000`, `pool_size=5`. WAL was already
the default — no PRAGMA wiring needed. This materially helps H1.

---

## 2. The three questions — measured answers

### Q1 — Agents per session

One session, ramp the agent-member count, drive a fixed message budget,
**drain to quiescence** and measure sustained throughput. Sink mode
(`turn_cap=0`, echo never replies) for the pure-capacity numbers.

**Paced (10 msg/s injected, the realistic-rate ramp):**

| N agents | dispatch p99 | dispatch max | RSS | procs | repo_query p99 |
|---|---|---|---|---|---|
| 2   | 3.87 ms | 6.5 ms  | 108 MB | 315 | 1.3 ms |
| 5   | 3.79 ms | 7.1 ms  | 107 MB | 320 | 2.6 ms |
| 10  | 4.28 ms | 11.4 ms | 105 MB | 331 | 2.6 ms |
| 25  | 3.44 ms | 7.8 ms  | 108 MB | 357 | 3.2 ms |
| 50  | 4.05 ms | 8.5 ms  | 118 MB | 408 | 5.6 ms |
| 100 | 1.36 ms | 16.1 ms | 136 MB | 509 | 12.6 ms |

**Burst (whole 15 000-message budget fired at once — finds the true
sustained ceiling, since paced injection is `Process.sleep`-floor-bound):**

| N agents | dispatches | sustained msg/s | sustained dispatch/s | dispatch p99 | RSS |
|---|---|---|---|---|---|
| 5   | 105 000    | 1460 | 10 221 | 0.87 ms | 235 MB |
| 25  | 405 000    | 806  | 21 762 | 0.95 ms | 372 MB |
| 100 | 1 530 000  | 329  | 33 576 | 0.62 ms | **1774 MB** |

**Answer:** at the proposed acceptance bar (p99 `chat.send` < 250 ms),
the system **does not hit a latency knee even at 400 agents** in one
session (a separate run held 400 agents, 160 800 dispatches, p99
0.05 ms, zero errors). Per-dispatch latency stays sub-millisecond at
every N — the orchestration path is cheap.

The real knee for Q1 is **memory under a burst**: at N=100, 15 000
queued messages fan out to ~1.5 M `chat.receive` dispatches, and the
transient RSS climbs to **1.77 GB**. Sustained msg/s also falls as N
grows (1460 → 806 → 329 msg/s for N=5/25/100) because each `chat.send`
runs its N−1 fan-out *inline in the Session GenServer* — that is the
linear-in-N cost (H3).

> **Q1 recommended V1 number: comfortably ≥ 100 agents per session**
> at any realistic message rate (latency is a non-issue). The practical
> ceiling is set by *burst* memory, not by latency: keep a single
> session's instantaneous backlog bounded (a per-session inbound rate
> limit) and 100+ agents is safe inside 4 GB. Without a rate limit, a
> 15 k-message burst into a 100-agent session alone uses ~1.8 GB.

### Q2 — Max concurrent sessions

Ramp concurrent sessions, each `1 user + 2 sink agents` (4 Kinds/session),
sessions accumulate across steps.

| Sessions | Kinds total | RSS | procs | ETS | spawn throughput |
|---|---|---|---|---|---|
| 500   | 2 005   | 192 MB  | 2 311  | 2.6 MB  | 3493 /s |
| 1 000 | 4 005   | 280 MB  | 4 311  | 3.6 MB  | 3719 /s |
| 2 000 | 8 005   | 414 MB  | 8 311  | 5.4 MB  | 3892 /s |
| 4 000 | 16 005  | 661 MB  | 16 311 | 9.1 MB  | 3904 /s |
| 8 000 | 32 005  | 1158 MB | 32 311 | 16.6 MB | 3705 /s |

**Answer:** perfectly linear, no knee reached. 8000 sessions (32 000
Kinds) sit in **1.16 GB RSS**. ~36 KB RSS per Kind. Spawn throughput is
rock-steady ~3700 entities/s — **no DynamicSupervisor serialisation
knee (H5 refuted)**. ETS grows linearly and trivially (16.6 MB at 32 k
Kinds — H4 refuted).

> **Q2 recommended V1 number: ≥ 8000 concurrent sessions** held
> comfortably; extrapolating the linear RSS curve, a 4 GB ceiling
> holds roughly **25 000–27 000 sessions** (~100 k Kinds) before the
> memory limit — far above the plan's proposed 500-session bar.

### Q3 — Max concurrent users

Ramp idle User Kinds, users accumulate across steps.

| Users | RSS | procs | ETS | snapshot writes |
|---|---|---|---|---|
| 5 000   | 361 MB  | 5 311   | 3.7 MB  | 0 |
| 10 000  | 624 MB  | 10 311  | 5.7 MB  | 0 |
| 25 000  | 1442 MB | 25 311  | 11.9 MB | 0 |
| 50 000  | 2752 MB | 50 311  | 22.0 MB | 0 |
| 100 000 | 4519 MB | 100 311 | 42.4 MB | 0 — **ramp aborted, RSS > ceiling** |

**Answer:** the memory-ceiling guard fired at 100 000 users (RSS
4519 MB > 3500 MB ceiling) and stopped the ramp cleanly — no swap, no
crash. **The knee for Q3 is the 4 GB memory ceiling: ~50 000 idle
users (2.75 GB) is the last safe step; ~75 000 users would sit at the
~4 GB line.** ~55 KB RSS per idle User Kind. `snapshot writes = 0` at
every step — **confirms the plan's prediction that idle users cost
zero SQLite writes** (User Kind is `{:snapshot, :on_change}` and an
idle user never changes its slice). Spawn throughput ~10 000 users/s.

> **Q3 recommended V1 number: ≥ 50 000 concurrent (idle) user Kinds**
> inside a 4 GB Pi — an order of magnitude above the plan's proposed
> 5000-user bar. Note: this is *idle* users. Active users that send
> messages add dispatch + DB load (see Q1).

---

## 3. Which bottleneck bit first

The plan ranked five hypotheses. With data:

### H1 — SQLite single-writer contention — **NOT confirmed**

The most-likely-predicted bottleneck did **not** bite at Pi-class
resources. WAL mode (already the default) is the reason. Even under the
hardest burst (15 000 messages → 1.5 M dispatches at N=100):

- `repo_queue_time` p99 stayed at **0.04–0.21 ms** — the Ecto pool was
  never contended; no queue backup toward `queue_target`.
- `repo_query_time` p99 stayed **1.5–17 ms** — individual SQLite write
  latency rose modestly with concurrency but never became the limiter.
- A sustained paced run held **~500 chat.send/s** (the driver's
  injection floor, not a DB limit) with `repo_query` p99 = 3.4 ms and
  zero errors. The single WAL writer comfortably absorbs
  ~1000 inserts/s + audit batches.

The plan's proposed throughput bar (≥ 200 chat.send/s) is met with
large headroom. **H1 is a real architectural property but not a V1
ceiling** — WAL already mitigates it.

### H2 — Audit-stream PubSub fan-out — **NOT observed as a limiter**

`[:ezagent,:invoke,:stop]` fires per dispatch and `Ezagent.Audit`
broadcasts each to `esr:audit:stream`. In this run no LV `/admin`
subscriber was attached, so the broadcast is a single registry lookup +
no-op. The telemetry-handler tail (the per-event broadcast + the
`Audit.Writer` cast) was absorbed: at N=100 burst, 33 576 dispatch/s
sustained with zero errors and no scheduler saturation. **H2 was not
exercised at its worst case** (the worst case is many `/admin` LV
subscribers multiplying the firehose) — that remains a real risk for a
production deployment with admin dashboards open, and the mitigation
(batch/coalesce the audit-stream broadcast) is still worth doing, but
it did **not** bite this measurement run.

### H3 — Per-message dispatch overhead × fan-out (linear-in-N) — **CONFIRMED as the throughput shape**

This is the bottleneck the data actually shows. One `chat.send` into N
members runs N−1 `chat.receive` dispatches **inline in the Session
GenServer**. Burst results:

- N=5 → 1460 msg/s; N=25 → 806 msg/s; N=100 → 329 msg/s sustained.
  Throughput falls **~linearly in N** — exactly the H3 prediction.
- Total dispatch/s actually *rises* with N (10 k → 22 k → 34 k) — the
  BEAM is doing more work per logical message; the Session is the
  serial chokepoint, not the DB.
- Per-dispatch latency stays sub-ms throughout — the cost is *count*,
  not per-call latency.

H3 is **acceptable for V1** as the plan predicted: latency is fine, and
the linear cost only matters for very large single sessions under
burst. Document the practical N ceiling; do not prematurely batch.

### H5 — DynamicSupervisor spawn serialisation — **REFUTED**

Spawn throughput was flat-to-rising across every ramp: ~3700
entities/s (Scenario B, up to 32 k Kinds) and ~10 000 users/s
(Scenario C, up to 100 k Kinds). No serialisation knee.

### H4 — KindRegistry / ETS contention — **REFUTED**

ETS grew linearly and cheaply: 42 MB at 100 000 Kinds. Dispatch latency
did not rise with total entity count. The partitioned stdlib `Registry`
scales fine.

**Verdict — what bit first:** none of H1/H2/H4/H5 became a V1 ceiling
at Pi-class resources. **The binding constraint is memory** — total
RSS — and **H3 (linear fan-out)** is the throughput *shape*. Predicted
order of failure (H1→H2→H3→H5→H4) was wrong for V1: memory is the wall,
H3 sets the slope, and the DB (H1) — thanks to WAL — has comfortable
headroom.

---

## 4. The loop-amplification finding (plan §2.6 / §7)

The driver tags every message body with a `meta` map carrying `hop` +
`turn_cap`; the echo `:receive` reply path was extended (this run's one
piece of test-support code, `Ezagent.Behavior.Echo`) to honour it —
`turn_cap=0` = sink (never reply), `hop >= turn_cap` = stop.

A bounded auto-reply run (`turn_cap=3`) confirms the §2.6 risk is real
and severe:

| N agents | injected | resulting dispatches | amplification |
|---|---|---|---|
| 5  | 15 | 9 555   | ~640× |
| 10 | 15 | 150 330 | ~10 000× |

15 human messages into a 10-agent auto-replying session produced
**150 330 dispatches** before the turn cap stopped the cascade. The
cascade grows geometrically in N. **The turn cap worked** — every run
terminated, zero errors — but this demonstrates concretely that **there
is no global turn counter or message budget in `Chat`/`Resolver`**
(plan §2.6, confirmed). For V1 with auto-replying agents this is a
production hazard: a single message can self-amplify into a runaway.

> **Recommendation:** add a hop/turn counter to the production
> `Message` envelope + a `Resolver`-level cascade cap, OR document that
> auto-replying agents (echo and any future one) must carry their own
> reply guard. The stress-test echo flag is test-support only; it is
> **not** a production fix.

---

## 5. Crashes / errors

**None.** Across every scenario and every ramp step — including the
1.5 M-dispatch burst and the 100 000-user ramp — `dispatch_errors = 0`.
The only "stop" was the deliberate `--mem-ceiling-mb` guard halting
Scenario C at 100 000 users (RSS 4519 MB) — a clean, intended stop, not
a crash, and the machine never went to swap.

---

## 6. Recommendations (prioritised)

1. **Q1/Q3 binding constraint is RAM.** Size a Pi deployment by memory:
   ~36 KB/Kind (session+members) and ~55 KB/idle-user. A 4 GB Pi holds
   roughly 50 k idle users *or* ~25 k sessions — adjust for the actual
   workload mix.
2. **Add a per-session inbound rate limit.** The only way to push a
   single session into distress is an unbounded *burst* (Q1: 15 k
   messages → 1.8 GB transient). A modest inbound rate cap removes the
   only Q1 memory hazard.
3. **Add a cascade cap to production.** The §4 loop-amplification
   finding is the most actionable risk. Put a hop counter in the
   `Message` envelope and a cap in `Resolver` (or `Chat.invoke(:send)`),
   so auto-reply cascades are bounded structurally, not per-plugin.
4. **Batch the audit-stream PubSub broadcast (H2).** Not a limiter in
   this run, but it will be once `/admin` LVs subscribe to the
   per-dispatch firehose in production. The `Audit.Writer` already
   batches the DB path; mirror that for the broadcast.
5. **H1 (SQLite) is fine for V1 — keep WAL.** No action needed for V1
   beyond ensuring WAL stays the journal mode. Revisit only if a future
   workload sustains >> 500 chat.send/s.
6. **Re-run on real Pi hardware before final V1 sign-off.** This run's
   memory/process knees transfer directly; the latency/throughput
   numbers are optimistic by ~3–5× for a Cortex-A76. `mix ezagent.stress`
   is committed and re-runnable for exactly this.

---

## 7. How to reproduce

```sh
# Pi-class profile, isolated DB home:
export ELIXIR_ERL_OPTIONS="+S 4:4"
export EZAGENT_HOME=/tmp/esr-stress-home
export MIX_ENV=dev
mix ecto.create && mix ecto.migrate

# Q1 — agents per session (burst mode finds the true ceiling):
mix ezagent.stress --scenario a --ramp 5,25,100 --hold-ms 3000 --rate 0 --turn-cap 0 --out /tmp/a.jsonl
# Q2 — max sessions:
mix ezagent.stress --scenario b --ramp 500,1000,2000,4000,8000 --hold-ms 5000 --out /tmp/b.jsonl
# Q3 — max users:
mix ezagent.stress --scenario c --ramp 5000,10000,25000,50000,100000 --hold-ms 4000 --out /tmp/c.jsonl
# loop-amplification (bounded echo auto-reply):
mix ezagent.stress --scenario a --ramp 5,10 --rate 5 --turn-cap 3 --out /tmp/echo.jsonl
```

Each run appends one JSON object per ramp step to `--out`. `--rate 0`
is unpaced burst mode; `--turn-cap 0` is sink mode (no auto-reply).
