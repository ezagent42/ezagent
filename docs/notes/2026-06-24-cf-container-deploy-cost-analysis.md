# Cloudflare Containers as a deploy target after the Postgres migration — suitability + per-team daily cost

**Status:** Investigation (2026-06-24). Analysis only — not a cutover plan.
**Branch:** `investigate/cf-container-cost-pg`
**Author:** Claude (agent dev), for Allen
**Supersedes the open storage question in:** `docs/experimental/cloudflare-deploy/README.md` (#65 spike)
**Pricing source:** Cloudflare + AWS docs, fetched 2026-06-24 (see §9).

---

## 结论 (TL;DR)

迁移到 PostgreSQL **解决了原来挡住 CF Containers 的头号问题**(容器磁盘是 ephemeral,
SQLite 单文件放不住)——DB 现在是外部托管,容器变成**无状态**,这条路因此从"基本不可行"
变成"技术上可行、但有两个硬天花板"。

**成本不是瓶颈。** 单个团队(≈ 一个 workspace = deployment unit)每天的 CF 资源成本
(**按 Allen 指示:节点大概率永不休眠 → 内存 24/7 计费,见 §4/§8.2**):

| 场景 | 实例 | 假设(永不休眠 24/7) | **$/天** | $/月 |
|---|---|---|---|---|
| 典型团队 | standard-3 | CPU ~25% of 2 vCPU | **~$2.7** | ~$80 |
| 重载(多 agent + 构建) | standard-4 | CPU ~40% of 4 vCPU | **~$5.5** | ~$165 |
| 固定地板(纯挂着不算 CPU) | standard-3 / standard-4 | 只算 mem+disk 24/7 | **$1.83 / $2.71** | ~$55 / ~$81 |

(只算 CF 资源。**DB 见 §8.1**:Hyperdrive 不是数据库;但 2026-06-18 起可在 CF 控制台开
PlanetScale Postgres 并计入 CF 账单 —— 这是**全账户共享**成本,不是 per-team。)

**两个硬天花板,但 #2 现在有 CF 生态内的破解办法(§8.3):**
1. **standard-4 = 4 vCPU / 12 GiB / 20 GB disk 是 per-instance 上限,不能竖直扩。**
   (2026-02-25 的 "15x" 是**账户聚合**并发上限,不是单实例。)一个团队峰值可能顶到 4 vCPU,
   而 ESR 是单节点 BEAM 持有 session 状态,**不能把一个团队横向拆到多个容器**。**这是真正
   的硬墙。**
2. **20 GB ephemeral 磁盘 vs. agent 工作目录** —— **不再是死路**:CF 现已支持把 **R2 桶
   以 FUSE 挂载**进容器(s3fs/tigrisfs/gcsfuse),容量实质无限 + 持久,代价是**没有原生
   SSD 性能**;另有 **Snapshots(coming soon)**可持久化/恢复容器或目录磁盘。(这更正了本文
   早先"R2 不能挂载"的说法。)

**判断:CF Containers 现在"值得做 spike",成本可接受;最大的剩余硬约束是单团队 4 vCPU 上限。**
对比 AWS 新加坡(EC2/Fargate)见 **§8.4** —— AWS 同时去掉了这两个天花板,但代价是更高的常驻
计费 + 更贵的 egress + 更重的运维。放行前验证三件事(§6),配套 durable-storage/备份(§5)、
全量迁移(§7)方案。

---

## 1. Why the calculus changed: PG removes the #1 blocker

The #65 CF spike (`docs/experimental/cloudflare-deploy/README.md`) stalled on
**storage durability**: CF Container disk is ephemeral, so a single-file SQLite
Repo could not survive container restart/sleep. The team cycled through D1
(rejected — Worker-binding HTTP API, not a real Ecto adapter), libSQL/Turso
(adapter immaturity risk), and finally landed on **managed Postgres** as the
durable Repo.

That migration is now done. Consequence for CF Containers:

- The Repo (`EzagentCore.Repo` — sessions, messages, routing, snapshots, audit,
  idempotency) lives in **external Postgres**, reached over the network.
- The container itself becomes **stateless with respect to the DB**. Ephemeral
  disk is no longer fatal *for DB state*.

This is the pivot: the old "basically not viable" verdict was a storage verdict,
and storage is solved. What remains are **compute-shape** and **non-DB disk**
problems, below.

## 2. What one team actually runs (the resource shape)

A "team" maps cleanly onto the **workspace = deployment unit** model
(`docs/notes/workspace-as-deployment-unit.md`): one workspace owns its sessions,
templates, routing rules, and members. The natural CF mapping is **one container
instance per team/workspace** (BEAM holds that workspace's live session state on
one node).

Two very different cost layers run inside that node:

**(a) Orchestration core — cheap.** Per the V1 stress test
(`docs/notes/v1-stress-test-results-2026-05-22.md`), the pure routing/session
layer is tiny: **8000 sessions (32 000 Kinds) ≈ 1.16 GB RSS**, ~36 KB/Kind,
sub-millisecond dispatch. Orchestration alone would fit several teams in one
`standard-3`.

**(b) Real agent subprocesses — the actual cost driver.** A working team runs
CC/Codex/PTY/python agents, which are **OS subprocesses spawned on the same node
via erlexec** (`apps/ezagent_plugin_cc/.../spawn_plan.ex`,
`ezagent_domain_pty/server.ex`, `ezagent_domain_python/server.ex`). Each
`claude`/`codex` child is a heavyweight Node/Python process with its own memory
+ CPU, plus a real on-disk working directory (`project_cwd`) and `config_home`.
This — not the BEAM orchestration — is what consumes the container's vCPU,
memory, and disk during an active workday.

> Note: CF Containers run a **real Linux container** (the #65 plan is literally
> "run the existing BEAM Docker image on Cloudflare Containers"), not a Workers
> V8 isolate. Spawning `node`/`python`/`git`/erlexec children works as in any
> Docker container. The constraint is the **resource ceiling**, not "can it
> fork." The image must ship the `claude`/`codex` binaries.

## 3. The two hard ceilings (the real blockers)

### 3.1 Compute ceiling — standard-4 is the top, no vertical scale beyond it

Predefined instance types (CF docs, §9):

| Type | vCPU | Memory | Disk |
|------|------|--------|------|
| lite | 1/16 | 256 MiB | 2 GB |
| basic | 1/4 | 1 GiB | 4 GB |
| standard-1 | 1/2 | 4 GiB | 8 GB |
| standard-2 | 1 | 6 GiB | 12 GB |
| standard-3 | 2 | 8 GiB | 16 GB |
| **standard-4** | **4** | **12 GiB** | **20 GB** |

Custom instances are allowed but cap at the **same maximums: 4 vCPU / 12 GiB /
20 GB**. So **standard-4 is a hard wall** — you cannot buy a bigger box.

A team running 3–5 concurrent agents that each kick off a build/test run can
burst well past 4 vCPU. Because the BEAM node holds that workspace's live
session/PTY state, you **can't shard one team across instances** to get more
cores. This is the single biggest architectural concern.

### 3.2 Disk ceiling — 20 GB ephemeral vs. agent working dirs (PG does NOT solve this)

The PG migration externalized the **DB**, but agent **working filesystems** stay
local:

- `project_cwd` — the code checkout the agent operates on (repos, `node_modules`,
  build artifacts).
- `config_home` — per-agent credentials, `.mcp.json`, settings written to disk
  before launch (`spawn_plan.ex` / `cc_agent.ex`).

These live on **container-local disk**, which on CF Containers is **ephemeral
(lost on restart/sleep) and capped at 20 GB**. Two distinct problems:

- **Ephemerality** (architecturally certain): anything not in PG — code
  checkouts, build caches, agent config homes — is lost when the container
  recycles. Today this state is assumed durable on a normal host.
- **20 GB cap** (a sizing risk to validate): multiple repo checkouts + build
  artifacts + caches for an active multi-agent team can plausibly exceed 20 GB.
  Needs measurement against a real team workload before relying on it.

The clean fix is externalizing working state. **Correction (2026-06-24): CF now
*does* offer this** — Containers support mounting an **R2 bucket as a FUSE
filesystem** (capacity effectively unlimited + durable), and **disk Snapshots are
"coming soon."** So the cap is no longer a dead end — see **§8.3** for the
breakthrough and its performance caveat (FUSE is not native-SSD speed, which
matters for IO-heavy git/build dirs). It remains net-new integration work the PG
migration itself did not address.

## 4. Cost model — CF resources only

**Scope (explicit):** This counts **only Cloudflare-billed resources**.
**Postgres is external** — CF has no managed Postgres; Hyperdrive only *pools*
connections to an external origin and carries **no separate metering charge**.
PG hosting cost is therefore deliberately **out of scope** here, not forgotten.

**Unit rates (CF Containers, Workers Paid plan, fetched 2026-06-24):**
- Memory: **$0.0000025 / GiB-second** (billed on *provisioned* memory while the
  instance is **awake**; stops when it sleeps)
- CPU: **$0.000020 / vCPU-second** (billed on **active usage only**)
- Disk: **$0.00000007 / GB-second** (provisioned, while awake)
- Egress NA/EU: **$0.025/GB**, **1 TB/mo included** (pooled per account)
- Free monthly allowances (per *account*, not per team): 375 vCPU-min, 25
  GiB-hours mem, 200 GB-hours disk — consumed almost instantly at team scale, so
  treated as rounding error below.

**Deployment model costed:** the conservative **one dedicated container per
team** (you pay full provisioned memory per team). If teams' *orchestration* were
bin-packed into one shared container, memory would amortize (orchestration is
cheap — §2a), while agent CPU would still scale per-team. This model is the
upper-bound-ish per-team figure.

### 4.1 The dominant sensitivity: does the container ever sleep?

CF stops memory/disk charges only **after the instance goes to sleep** (an
inactivity timeout). A BEAM node holding **live LiveView/WebSocket connections +
running agent subprocesses + periodic timers** (PubSub, snapshot-on-change,
audit, GC sweepers) **may never hit that idle timeout during a workday — or
ever.** This single question is the swing between paying memory for ~10 awake
hours vs. 24 hours:

- standard-3 memory @ 10h awake = **$0.72/day**
- standard-3 memory @ 24h (never sleeps) = **$1.73/day**

**This is the headline cost risk and is unvalidated.** Treat "does it sleep" as a
must-measure, not an assumption.

### 4.2 Scenarios (one team, one container)

standard-3 = 2 vCPU / 8 GiB / 16 GB → mem $0.00002/s, disk $0.00000112/s awake.
standard-4 = 4 vCPU / 12 GiB / 20 GB → mem $0.00003/s, disk $0.0000014/s awake.

| Scenario | Instance | Awake | CPU avg | Mem | Disk | CPU | **Total/day** | /mo |
|---|---|---|---|---|---|---|---|---|
| **Best** (sleeps off-hours) | standard-3 | 10h (36 ks) | 0.6 vCPU (30%) | $0.72 | $0.04 | $0.43 | **$1.19** | ~$26 (×22) |
| **Realistic** (warm, ~24h mem, workday CPU) | standard-3 | 24h (86.4 ks) | ~0.5 vCPU blended | $1.73 | $0.10 | $0.86 | **~$2.7** (call it $2–2.5 if mem partially sleeps) | ~$60–75 |
| **Heavy** (multi-agent + builds, never sleeps) | standard-4 | 24h (86.4 ks) | 1.6 vCPU (40% of 4) | $2.59 | $0.12 | $2.77 | **$5.48** | ~$164 |

Egress: a single team's LiveView/WS + agent-output streaming is small and sits
inside the pooled **1 TB/mo free** NA/EU allowance → effectively **$0/team/day**
for the foreseeable team count.

**Account-level adders (not per-team):** Workers Paid base **$5/mo flat**;
Hyperdrive no separate metering; external PG hosting (out of scope).

### 4.3 Open question (cannot resolve from here)

**Is container → external-Postgres traffic billed as CF egress?** Hyperdrive sits
on CF's edge with "no separate metering," so it is *plausibly* free, but this is
**not asserted as $0** — flag for validation. For one team, DB traffic volume is
small regardless, so it can't move the verdict much either way.

## 5. Durable storage for the agent working filesystem + a full-backup design

Per Allen (2026-06-24): the agent working filesystem also belongs in durable
storage, and we need a **full-backup (全量备份) scheme**. This section makes that
concrete. Post-PG there are now **two independent durability domains**, and a
real backup story must cover *both consistently*, not just the DB.

### 5.1 The two durability domains

| Domain | Contents | Today | Backup primitive |
|---|---|---|---|
| **D1 — Postgres** | sessions, messages, routing, snapshots, audit, idempotency | durable (external PG) | PG automated backup + PITR |
| **D2 — agent FS** | `project_cwd` (code, build artifacts, `node_modules`), `config_home` (credentials, `.mcp.json`, settings) | **ephemeral container disk** | none yet — this is the gap |

**Correction (2026-06-24):** CF now supports **mounting an R2 bucket as a FUSE
filesystem** inside a Container (s3fs/tigrisfs/gcsfuse baked into the image,
mounted at startup), plus **disk Snapshots "coming soon."** So there *is* a
persistent-FS option now (§8.3). The remaining caveat is **performance**: FUSE
over R2 is **not native-SSD speed**, so IO-heavy live working dirs (`git`,
`node_modules`, builds) should stay on local SSD (within the 20 GB), while R2 FUSE
serves **large/cold data + the durable slice**. So the design is a **hybrid**:
hot working dir on local disk, durable + overflow on R2-FUSE — not "R2 can't be
mounted" as originally written.

### 5.2 Minimize the durable footprint first (classify before you back up)

Not all of D2 is equally precious. Classify, then only durably store what can't
be reconstructed:

- **Reconstructible (do NOT back up)** — `node_modules`, build artifacts, caches.
  Source of truth is the package manifest; rebuild on restore.
- **Source-of-truth elsewhere (reference, don't copy)** — committed code. The
  git **remote** is the durable copy; back up only the **commit SHA** + any
  **uncommitted working-tree diff**.
- **Genuinely durable (must back up)** — `config_home`: agent credentials,
  `.mcp.json`, settings, plus uncommitted diffs and any agent-authored scratch
  not yet pushed. This is small (KBs–MBs/agent), which keeps R2 cost and backup
  windows tiny.

This classification is what makes the 20 GB ceiling (§3.2) survivable: the *live*
disk can be large and churny, but the *durable* slice is small.

### 5.3 Live durability: snapshot-on-checkpoint to R2

- **Restore-on-start / snapshot-on-pause**: on container start, hydrate
  `config_home` (+ re-clone repos at the recorded SHA, re-apply saved diff) from
  R2; on graceful sleep / session pause, push the durable slice back. This mirrors
  the libSQL "embedded replica" pattern the #65 spike already reasoned about —
  applied to files instead of the DB.
- **Periodic incremental** during long sessions (e.g. every N minutes and on
  agent turn-boundary): rsync-style incremental of the durable slice → R2,
  encrypted. Cheap because the durable slice is small.

### 5.4 Full-backup (全量备份): cross-domain consistency is the hard part

A "full backup" of a workspace is **D1 + D2 captured at a consistent point**.
Because PG and the FS are separate stores, a naive "dump PG, then tar the FS" is
**crash-inconsistent** — the FS can advance between the two captures. The design
must anchor both to one logical instant:

1. **Quiesce the workspace.** ESR already has the primitives: freeze inbound
   dispatch (ReadyGate holds, PendingDelivery queues) and drive sessions to
   quiescence — the same "drain to quiescence" the stress harness uses. No new
   inbound is processed during the window.
2. **Mark D1.** Take a PG logical snapshot / record the PITR LSN.
3. **Mark D2.** Snapshot the durable FS slice → R2 under a per-backup prefix.
4. **Write a backup manifest** binding them: `{workspace_uri, pg_lsn_or_snapshot_id,
   r2_prefix, repo→commit_sha map, taken_at, schema_version}`. The manifest is
   the unit of "a full backup."
5. **Resume** dispatch.

This gives **per-workspace, independently restorable** full backups — which lines
up with the workspace-export bundle the deployment-unit doc already envisions
(`members + session_templates + routing_rules + sessions + messages`), now
extended with the agent-FS durable slice.

**Restore** = provision container → pull image → restore `config_home` + diffs
from the manifest's R2 prefix → re-clone repos at recorded SHAs → point Repo at
PG restored to the manifest LSN → resume. The manifest makes restore
deterministic and verifiable (you can assert SHA + LSN match).

**Cadence:** continuous PITR on D1 + periodic incremental on D2 (§5.3) for
RPO-minutes recovery; scheduled **full** manifests (e.g. daily, on workspace
pause, pre-migration) for clean restore points and DR.

### 5.5 Cost impact of the backup layer (CF-resources lens)

- **R2 storage**: durable slice is small (config_home + diffs, KBs–MBs/team) →
  pennies/month. Even daily full manifests retained 30 days stay trivial.
- **R2 has no egress fees** (a key CF property) — restores don't incur the
  Container egress rates from §4.
- **R2 Class A/B operations**: incremental syncs are many small PUTs; still
  cents/team/month at the proposed cadence.
- Net: the backup layer adds **well under $0.10/team/day** — it does **not**
  move the §4 verdict. (PG backup cost is external, out of CF scope.)

## 6. Verdict + what must be validated before go

**Verdict:** Post-PG, CF Containers move from "basically not viable" to
"**spike-worthy but not a clean production landing yet**." **Cost is acceptable
(~$1–5.5/team/day) and is not the blocker.** Three things gate a real go, none of
them cost:

1. **Sleep behavior** — does a BEAM node with live LiveView/WS + running agents
   ever hit CF's inactivity timeout? Drives the memory bill (§4.1) *and* whether
   "scale-to-zero" economics apply at all to interactive sessions (they largely
   don't if it never sleeps).
2. **Working-dir durability + 20 GB cap** (§3.2) — *no longer a hard wall* (§8.3:
   R2-FUSE mount + snapshots-soon). Now a **performance** question: validate that
   a hybrid (hot dir on local SSD, durable/overflow on R2-FUSE) is fast enough for
   `git`/build workloads; wire it to the §5 backup design.
3. **Single-team peak CPU vs. 4 vCPU** (§3.1) — *the one ceiling with no CF escape*
   — can a real multi-agent team's build/test bursts be served under standard-4?
   If not, that single team needs **AWS (§8.4)** or another non-CF host; CF can't
   give it a bigger box.

If those three clear, CF Containers + a thin Worker front (per the #65 plan) is a
reasonable target — execute the staged per-workspace **full-migration plan in
§7**. Until then, the existing cloudflared-tunnel host path stays
the production answer and CF stays a spike on throwaway subdomains (hard
boundaries from #65 README still apply).

## 7. Full-migration (全量迁移) plan

Per Allen (2026-06-24): a scheme for migrating the **whole** deployment onto CF
Containers, not just a per-team spike. The unit of migration is the **workspace
= deployment unit** (§2), so a full migration is "move every workspace, in a
defined order, with a tested rollback." The backup manifest (§5.4) is reused as
the **migration unit** — migrating a workspace ≈ taking a full backup on the old
host and restoring it on CF.

### 7.1 Preconditions (gates — do not start migration until green)

The three §6 validations must pass first, plus:
- Image: BEAM Docker image builds `linux/amd64` with `claude`/`codex` binaries +
  toolchains baked in; boots all release apps (mix.exs `releases`).
- Storage: D2 durable layer (§5) implemented and proven (restore-on-start works,
  20 GB headroom measured for the largest real workspace).
- Network: container → external PG reachable (Hyperdrive configured); egress-vs-
  metered question (§4.3) answered.
- Connectivity: LiveView/WS proven through Worker → Container, incl. reconnect
  across a container sleep/wake.

### 7.2 Strategy: per-workspace, staged, reversible (not big-bang)

Because each workspace is independently restorable, migrate **in waves**, lowest-
risk first, with DNS as the cutover switch and PG as the shared system of record:

1. **Wave 0 — pilot (throwaway subdomain).** Migrate one internal/demo workspace
   to a `*.workers.dev` / throwaway subdomain. Soak: real agent runs, LiveView,
   backup+restore drill. Do **not** touch `app.`/`dev.` DNS or tunnels (#65 hard
   boundary).
2. **Wave 1 — low-traffic real teams.** Per workspace: quiesce → full manifest
   (§5.4) → restore on CF → verify (SHA+LSN match, agents resume, DoD smoke) →
   flip that workspace's routing/DNS to CF → keep old host warm as rollback for N
   days.
3. **Wave 2..N — remaining teams**, batched by risk/size, same per-workspace
   recipe.
4. **Decommission** old host only after the last workspace has soaked clean.

**PG during migration:** keep **one shared external PG** as the system of record;
both old host and CF point at it. This makes the FS (D2) the only thing that
physically "moves," and lets cutover be a routing flip rather than a data copy.
(If PG itself is also being relocated, do that as a *separate* PITR-based
migration step **before** the compute cutover — never move both at once.)

### 7.3 Per-workspace cutover runbook

```
freeze inbound (ReadyGate hold) → drain to quiescence
  → take full manifest (PG LSN + D2→R2 + repo SHAs)   [§5.4]
  → provision CF container, restore from manifest       [§5.4 restore]
  → smoke: agents resume, LiveView connects, 1 real dispatch round-trips
  → flip routing/DNS for this workspace → CF
  → monitor; old host stays warm (rollback = flip DNS back, replay nothing
    because PG is shared and D2 diffs since freeze are small/none)
  → after soak window: retire old container for this workspace
```

### 7.4 Rollback & risk

- **Rollback unit = one workspace** (flip DNS back; shared PG means no data
  divergence if the freeze window was honored). Blast radius is one team, not the
  fleet.
- **Biggest migration risk** is *not* data — it's a workspace whose live disk or
  peak CPU exceeds the §3 ceilings only under real load. The staged waves surface
  that on a small team before it can hit a large one.
- **No silent partial migration:** every workspace is in exactly one state
  (`old`, `migrating`, `cf`, `rolled-back`) in a migration ledger; the fleet
  migration is done only when all are `cf` and the old host is retired.

### 7.5 Migration cost (CF lens, one-off)

The migration itself is cheap on CF resources: it's restore (R2 reads — **no R2
egress fee**) + normal container runtime during soak. The real cost is the
**dual-run window** (old host + CF in parallel per wave) — but the CF side is
just the §4 per-team daily rate for the teams already cut over. No separate
migration line item of note.

## 8. Follow-up Q&A (Allen, 2026-06-24)

Four questions after the first draft. Each is answered against **live CF/AWS docs
fetched 2026-06-24** (§9). Two of these supersede claims in §3–§5 above.

### 8.1 Can Postgres be hosted "on Cloudflare" (via Hyperdrive)?

**Short answer: not on CF's *own* servers — but since 2026-06-18 you can provision
managed Postgres *through* Cloudflare and put it on your CF bill.**

- **Hyperdrive is not a database.** It is a global **connection pooler + query
  cache** that sits in front of an *existing* external Postgres (any PG: RDS,
  Neon, PlanetScale, self-host). It accelerates; it does not store.
- **Cloudflare has no first-party managed Postgres.** It does not run PG on its
  own infrastructure.
- **New (changelog 2026-06-18):** you can **create a managed PlanetScale Postgres
  from the Cloudflare dashboard and bill PlanetScale usage through your Cloudflare
  account** (pay-as-you-go; contract customers from July 2026). The DB is **hosted
  by PlanetScale**, not CF — but it appears on your **CF invoice** at PlanetScale's
  standard pricing, and connects to Workers/Containers via Hyperdrive.

**Implication for "CF resources only":** the DB can now legitimately be a **CF
invoice line item**. Rough cost (PlanetScale standard pricing): **PS-10 single
node ≈ $10/mo**, **PS-10 HA (3-node) ≈ $30/mo**, **PlanetScale Metal ≈ $50/mo**,
storage 10 GB included then ~$0.125–0.50/GB. **This is a single shared cluster
serving all workspaces — an account-level cost, not per-team** → amortized it is
pennies/team/day. It does not move the per-team verdict.

> Caveat answered: container→PG traffic over Hyperdrive stays inside CF's edge and
> carries "no separate metering" — so it is *not* a Container egress line. (This
> partially resolves the §4.3 open question.)

### 8.2 Assume the node never sleeps (per Allen)

Confirmed as the baseline: a BEAM node holding live LiveView/WS + running agents +
periodic timers **will, in practice, not hit CF's inactivity timeout**. So **memory
and disk are billed 24/7** (CPU is still active-usage-only). The §4 "best case
(sleeps)" row is therefore **not operative** — use these:

| Instance | Mem 24/7 | Disk 24/7 | **Floor (mem+disk)/day** | + CPU (typical) | **/day** | /mo |
|---|---|---|---|---|---|---|
| standard-3 (2 vCPU/8 GiB/16 GB) | $1.73 | $0.10 | **$1.83** | ~$0.86 @25% | **~$2.7** | ~$80 |
| standard-4 (4 vCPU/12 GiB/20 GB) | $2.59 | $0.12 | **$2.71** | ~$2.77 @40% | **~$5.5** | ~$165 |

The **memory floor is now unavoidable** (no scale-to-zero relief). CF's one
remaining cost advantage vs. always-on VMs is that **CPU is still billed only when
actually computing** — see §8.4 for why that matters against AWS.

### 8.3 Is 20 GB a hard limit? Breaking it within the CF ecosystem

- **It is a *per-instance* limit** (standard-4 max = 20 GB; custom max also 20 GB;
  ratio ≤ 2 GB disk per 1 GiB mem). The 2026-02-25 "15×" increase was
  **account-aggregate** (disk 2 TB → 30 TB, vCPU 100 → 1,500, mem 400 GiB → 6 TiB),
  **not** per-instance. All container disk is **ephemeral** (fresh disk on wake).
- **Breakthroughs inside CF:**
  1. **R2 FUSE mount** — mount an R2 bucket as a filesystem (s3fs / tigrisfs /
     gcsfuse in the image). **Capacity effectively unlimited + durable.** Caveat:
     **not native-SSD performance** — fine for large/cold/static data, risky for
     IO-heavy `git`/`node_modules`/build trees.
  2. **Disk Snapshots (coming soon)** — quickly persist/restore a container's (or
     a directory's) disk across sleeps.
  3. **Workers KV / D1 / Durable Objects** — for structured spill, not a general FS.
- **Recommended pattern:** **hybrid** — hot working dir on the 20 GB local SSD,
  R2-FUSE for overflow + the durable slice (§5). This **dissolves blocker #2** as
  a hard wall, leaving only a **performance** question to validate for build
  workloads. Blocker #1 (4 vCPU ceiling) has **no** equivalent escape.

### 8.4 Same setup on AWS Singapore (ECS/EC2) — how cost changes

AWS **ap-southeast-1** (Singapore). Rates ≈ as of 2026-06-24 (Singapore ≈ +13%
over us-east-1; flagged approximate — confirm in AWS Calculator before quoting).
Modeled per team, **never-sleep / always-on**, 4-vCPU class to match standard-4,
durable storage included.

**Unit rates (ap-southeast-1, approx):**
- EC2 m6i.xlarge (4 vCPU/16 GiB, Intel): ≈ **$0.224/hr**
- EC2 m7g.xlarge (4 vCPU/16 GiB, Graviton): ≈ **$0.18/hr**
- Fargate: ≈ **$0.0466/vCPU-hr** + **$0.00511/GiB-hr**
- EBS gp3: ≈ **$0.10/GB-month** (durable block storage)
- Data-transfer-out: **$0.12/GB** (first 100 GB/mo free account-wide)
- (vs CF: CPU $0.072/active-vCPU-hr, mem $0.009/GiB-hr, egress $0.025/GB + 1 TB free)

**Per-team/day (never-sleep, 4-vCPU class, ~50 GB durable disk):**

| Platform | Compute/day | Durable disk/day | Egress | **/day** | /mo | 4-vCPU ceiling? | Native durable FS? |
|---|---|---|---|---|---|---|---|
| **CF standard-4** (active-CPU billing) | mem $2.59 + CPU ~$2.77 @40% | 20 GB ephem incl; R2-FUSE pennies | ~$0 (1 TB free) | **~$5.5** | ~$165 | **HARD** 4/12/20 | R2-FUSE (slow) / snapshots-soon |
| **AWS EC2 m6i.xlarge** on-demand | $5.38 (full 4 vCPU 24/7) | EBS $0.16 | $0.12/GB | **~$5.6** | ~$168 | **none** (→2xl/4xl…) | EBS/EFS native |
| **AWS EC2 m7g.xlarge** (Graviton) | $4.32 | $0.16 | $0.12/GB | **~$4.6** | ~$138 | none | native |
| **AWS EC2 m6i.xlarge + 1-yr Savings** (~40% off) | ~$3.2 | $0.16 | $0.12/GB | **~$3.4** | ~$102 | none | native |
| **AWS Fargate** 4 vCPU/16 GiB | $6.43 | EFS extra | $0.12/GB | **~$6.6** | ~$198 | task max 16 vCPU/120 GiB | EFS |

**What changes on AWS — the real story is not the headline price (all within
~1.5×), it's the trade structure:**

1. **Both CF ceilings vanish.** No 4 vCPU/12 GiB wall — pick m6i.2xlarge (8/32),
   4xlarge, etc., so a heavy team that would blow past standard-4 just gets a
   bigger box. **Native persistent EBS/EFS** solves the agent-FS durability +
   capacity problem cleanly (no FUSE perf compromise). *This — not cost — is the
   reason to consider AWS.*
2. **AWS bills provisioned CPU 24/7; CF bills CPU only when active.** CF's per-vCPU
   rate ($0.072/vCPU-hr) is actually *higher* than AWS ($0.047–0.056/vCPU-hr) — CF
   only wins because idle vCPUs cost nothing. So: **bursty / idle-heavy interactive
   teams → CF is cheaper** (drops toward $2.7–3.5/day); **high sustained CPU →
   AWS is cheaper per vCPU, and Reserved/Savings (~40%) makes AWS the cheapest
   option (~$3.4/day).** Fargate is the most expensive always-on option.
3. **Egress: CF wins decisively** — $0.025/GB + 1 TB free vs AWS $0.12/GB
   (~5×) + only 100 GB free. For a streaming-heavy app (live terminals, agent
   output over WS) AWS egress can become a real line item at scale; for one team
   it's small either way.
4. **Ops burden:** EC2 = you manage instances/OS/patching/autoscaling; Fargate =
   serverless-ish but pricier; CF = most managed (thin Worker + container). AWS
   buys headroom at the cost of more ops.
5. **DB:** on AWS you'd pair with **RDS Postgres (Singapore)** (db.t4g/db.m6g ≈
   $25–70/mo shared) instead of PlanetScale-via-CF — comparable shared cost.

**Bottom line of the comparison:** per-team daily cost is in the same ballpark
(**CF ~$2.7–5.5**, **AWS EC2 ~$3.4–5.6**, **Fargate ~$6.6**). **Cost is not the
deciding factor.** Choose **CF** for managed simplicity, cheap egress, and bursty
savings *if* every team fits within standard-4. Choose **AWS** when a team needs
more than 4 vCPU/12 GiB, when you want native persistent volumes without FUSE
compromises, or when sustained-CPU + Reserved pricing tips the math — at the cost
of higher always-on baseline, pricier egress, and more ops.

## 9. Sources

- [Cloudflare Containers — Pricing](https://developers.cloudflare.com/containers/pricing/)
- [Cloudflare Containers — Limits & Instance Types](https://developers.cloudflare.com/containers/platform-details/limits/)
- [Cloudflare changelog — new CPU pricing (active-usage based), 2025-11-21](https://developers.cloudflare.com/changelog/2025-11-21-new-cpu-pricing/)
- [Cloudflare blog — Containers public beta](https://blog.cloudflare.com/containers-are-available-in-public-beta-for-simple-global-and-programmable/)
- [Cloudflare changelog — higher container resource limits (15× account aggregate), 2026-02-25](https://developers.cloudflare.com/changelog/post/2026-02-25-higher-container-resource-limits/)
- [Cloudflare Containers — FAQ (R2 FUSE mount, ephemeral disk, snapshots coming soon)](https://developers.cloudflare.com/containers/faq/)
- [Cloudflare Hyperdrive — Overview](https://developers.cloudflare.com/hyperdrive/)
- [Cloudflare changelog — PlanetScale Postgres/MySQL billed via Cloudflare, 2026-06-18](https://developers.cloudflare.com/changelog/post/2026-06-18-planetscale-databases-cloudflare-billing/)
- [PlanetScale Postgres — pricing](https://planetscale.com/docs/postgres/pricing)
- [AWS Fargate — pricing](https://aws.amazon.com/fargate/pricing/) ·
  [AWS EC2 — pricing](https://aws.amazon.com/ec2/pricing/) ·
  [AWS EBS — pricing](https://aws.amazon.com/ebs/pricing/) ·
  [ap-southeast-1 regional rates](https://aws-pricing.com/ap-southeast-1.html)
- Internal: `docs/experimental/cloudflare-deploy/README.md` (#65 spike),
  `docs/notes/v1-stress-test-results-2026-05-22.md`,
  `docs/notes/workspace-as-deployment-unit.md`.
