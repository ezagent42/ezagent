# Pending production migrations

Ecto migrations that have landed on `main` and must be run against the
**production** database on the next deploy. Dev/test DBs are migrated by the
normal `mix ecto.migrate` / `mix ezagent.db.reset` flow; production is the one
that needs an explicit operator action recorded here.

> Remove an entry once it has been applied to production.

## How to apply

```bash
# from the umbrella root, against the prod profile/env
MIX_ENV=prod mix ecto.migrate
```

## Open items

### `20260616000000_agent_lineage_durable_backing` — agent_lineage durable table

- **Landed in**: #493 (post-lifecycle remediation, remediation C-B / #114).
- **What it does**: additive `CREATE TABLE agent_lineage` — durable backing
  (SQLite source of truth + ETS read cache) for `Ezagent.AgentLineage`, so the
  `agent_uri → spawned_by` mapping survives a restart. Without it, every agent
  spawned before a restart becomes "foreign" and `{:spawned_by, P}` CapBAC
  matching (Decision #137, step 5.5) silently breaks after a reboot.
- **Risk**: additive (new table only); no data rewrite, no downtime.
- **Why flagged**: caught by live e2e — the merged code crashed on first boot
  with `no such table: agent_lineage` because the migration had only been
  applied to the dev DB during development. Production has not been migrated.
- **Rehydration**: on boot, `Ezagent.AgentLineage.rehydrate/0` re-populates the
  ETS cache from this table; pre-existing lineage rows are absent on the first
  prod boot (the table starts empty) and are populated going forward as agents
  spawn — acceptable, since the alternative (pure ETS) lost the mapping every
  boot anyway.
