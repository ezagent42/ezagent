# Return — CF Containers deploy suitability + per-team daily cost (post-PG)

> **Task:** cf-container-cost-pg (investigation — is CF Containers a good deploy target now that the DB is on Postgres; per-team daily CF cost)
> **Branch:** `investigate/cf-container-cost-pg` (off `main` @ `ca2e6f2df87e`)
> **PR:** none
> **Dev:** Claude (agent)
> **returned_at:** 2026-06-24 (+0800)
> **deadline:** n/a — no `plan.md` exists for 2026-06-24
> **deadline_status:** out_of_scope

## What's done

A grounded investigation, written as a durable note. Scope grew during the run
per Allen: base question + agent-FS durable storage + full-backup design +
full-migration plan + **four follow-up questions** (§8: PG-on-CF/Hyperdrive,
never-sleep baseline, 20 GB breakthrough, AWS Singapore comparison). All in the
deliverable.

**Follow-up answers (§8) — two of them updated my own earlier claims:**
- **8.1 PG on CF?** Hyperdrive ≠ DB (it's a pooler/cache in front of external PG);
  CF has no first-party Postgres. **But since 2026-06-18 you can provision managed
  PlanetScale Postgres from CF and bill it on your CF account** (~$10–50/mo,
  *shared* not per-team). Container→PG over Hyperdrive isn't a Container-egress line.
- **8.2 Never-sleep baseline (per Allen):** memory+disk billed 24/7 (CPU still
  active-only). Per-team: **~$2.7/day (standard-3) / ~$5.5/day (standard-4)**;
  floor (mem+disk only) $1.83 / $2.71/day.
- **8.3 20 GB cap — no longer a dead end:** CF now supports **R2-FUSE mount**
  (unlimited + durable, but not SSD-speed) + **disk snapshots (soon)**. The hard
  wall is now just blocker #1 (**4 vCPU ceiling, no CF escape**). *Corrects the
  earlier "R2 can't be mounted" claim in §3.2/§5.*
- **8.4 AWS Singapore (ap-southeast-1):** per-team/day **CF ~$2.7–5.5** vs **EC2
  ~$3.4 (Reserved) – 5.6 (on-demand)** vs **Fargate ~$6.6**. Same ballpark — cost
  isn't the decider. AWS **removes both CF ceilings** (bigger boxes + native
  EBS/EFS) and bills CPU 24/7 (CF bills CPU only when active → CF wins on
  bursty/idle, AWS wins on sustained-CPU + Reserved). CF wins egress decisively
  ($0.025/GB+1TB free vs $0.12/GB+100GB free).
- **8.5 Alpha recommendation + containerization check:** **stay on Mac + cloudflared
  tunnel** — sidesteps every blocker at $0 per-team compute (M3 Ultra ≫ standard-4).
  Audited the docker stack: **BEAM ✅, agents ✅ (claude/codex/uv/node/git baked into
  `Dockerfile.prod`), tunnel ✅ (cloudflared service)** — but **Postgres ❌ BLOCKING**:
  `docker-compose.prod.yml` predates the PG migration (no postgres service, no
  `DATABASE_URL`) while `runtime.exs` now *raises* without it → prod stack would
  crash on boot. Proxy is host-side (⚠️). Documented ~80%-done + exact gap-closing
  steps. **Flagged as a separate follow-up task, not done in this docs-only return.**

**Headline findings:**
- The **PG migration removed the #1 blocker** (ephemeral container disk couldn't
  hold a single-file SQLite Repo). The container is now DB-stateless → CF
  Containers go from "basically not viable" to "spike-worthy."
- **Cost is NOT the blocker.** Per team (≈ one workspace = deployment unit),
  **CF-resources-only** daily cost: **~$1.2 best / ~$2.5 realistic / ~$5.5 heavy**
  (standard-3→standard-4, the swing driven by *does the BEAM node ever sleep*).
  ~$26–164/team/month. Egress sits inside the pooled 1 TB/mo free tier. PG is
  external = out of CF scope by design.
- **The real blockers are two hard ceilings, not money:** (1) standard-4 =
  4 vCPU / 12 GiB / 20 GB is the *top* — no vertical scale, and a single BEAM
  node can't shard one team across instances; (2) the **20 GB ephemeral disk vs.
  agent working dirs** — PG solved DB durability but NOT the `project_cwd` /
  `config_home` filesystem.
- **Agent-FS durable storage + full-backup design** (§5): two durability domains
  (PG + agent-FS), minimize durable footprint (don't back up `node_modules`;
  back up SHA + uncommitted diff + `config_home`), R2 snapshot-on-checkpoint, and
  a **cross-domain-consistent full backup** via quiesce → PG LSN + R2 snapshot +
  manifest binding them. Backup layer adds <$0.10/team/day.
- **Full-migration plan** (§7): per-workspace staged waves, shared PG as system
  of record so cutover is a DNS/routing flip (not a data copy), per-workspace
  rollback, migration ledger, no big-bang.

## DoD artifact

Research return → the DoD is the analysis doc itself:

- **`docs/notes/2026-06-24-cf-container-deploy-cost-analysis.md`** (on this branch)
  — full reasoning, pricing math, cost table, two ceilings, durable-storage +
  full-backup design, full-migration plan, sources (CF docs fetched 2026-06-24).

Pricing verified against live Cloudflare docs; cost math shown per-line; every
load-bearing claim grounded in repo code (`spawn_plan.ex`/`cc_agent.ex` for
on-disk `project_cwd`/`config_home`; stress-test note for sizing;
workspace-as-deployment-unit for the per-team mapping).

## Gate status

Docs-only branch — no `mix` gates apply (no code touched). Markdown only.

## Merge request

- **Merge** `investigate/cf-container-cost-pg` → `main`.
- Two new files, both additive, zero conflict risk:
  - `docs/notes/2026-06-24-cf-container-deploy-cost-analysis.md`
  - `docs/together/2026-06-24/returns/cf-container-cost-pg.md` (this file)
- **Note for the lead:** this return *creates* `docs/together/2026-06-24/`.
  There is no `plan.md` for today — if the lead opens the day properly, fold this
  in as an `out_of_scope` return (preserve, don't count as planned work), per the
  ledger rules.
- Supersedes the open storage question in
  `docs/experimental/cloudflare-deploy/README.md` (#65) — consider cross-linking
  on merge.

## Caveats / open questions (in the doc, flagged not asserted)

- Whether a BEAM node with live LiveView/WS + running agents ever hits CF's idle
  timeout (the single biggest cost + economics sensitivity) — **needs validation**.
- Whether container→external-PG traffic is billed as CF egress (Hyperdrive "no
  separate metering" suggests not, but not asserted $0).
- 20 GB disk exceedance is a sizing *risk to measure*, not a proven fact.
