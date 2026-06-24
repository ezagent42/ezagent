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
full-migration plan. All four are in the deliverable.

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
