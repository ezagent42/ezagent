# Cap-signing "no-tail" upgrade — real-canary-data finding

**Date:** 2026-07-14. **Context:** Phase-4 ed25519 signing merged to main (`e9b99443e`, dual-read `require_signature:false`). Coordinator E2E: pull a canary DB snapshot into an isolated stack on Phase-4 code, and test the "upgrade all caps to signed, no unsigned tail" path (lead goal).

## What the E2E did

Restored canary's daily DB dump (`ezagent-deploy/backups/canary/20260713T200002Z`, 7 users, real caps) into a throwaway Postgres, ran Phase-4 code against it. **Migration "already up" → Phase-4 needs ZERO schema change** on canary (signature/key_id/grantee_uri live inside the existing `caps_json` JSON, not new columns). Then ran `Ezagent.Identity.CapSigningBackfill.dry_run/1` (the EventLog re-authorize planner).

## The result — the current EventLog-backfill is NOT the upgrade path

`dry_run` on 196 real caps: **would_sign 6 · quarantined 189 · skipped 1.** The backfill re-authorizes only from a matching `cap_granted` EventLog event, and 189 don't reconcile:

| quarantine reason | count |
|---|---|
| `malformed_authoritative_grant_event` (event exists but doesn't reconcile with the cap) | 74 |
| `unsupported_candidate_shape` (structural caps with tuple identity-keys the planner doesn't handle) | 74 |
| `missing_authoritative_grant_event` (go-live-seeded, no event) | 30 |
| `reauthorization_failed: grant_owner_unresolvable` | 11 |

**This only surfaced on real canary data** — the backfill's unit tests (22/0) used clean fixtures with matching events. Real go-live caps were seeded in ways the historical-event re-auth can't reconcile.

## The correct framing (lead insight)

There is **no big code "fix."** Caps become signed by being **re-authorized through the signing `Cap.issue`** — the EventLog-backfill is an over-engineered wrong tool. The only real distinction is **whether a cap class re-derives through the signing issue path on its normal lifecycle:**

- **Self-healing classes** — caps re-derived from a definition/recipe **through `Cap.issue`** on every activation/materialization → re-activate under signing and they come out signed, zero data surgery. (Agent structural / session / socialware caps are *candidates* for this — MUST be verified per-class, see handoff task 1; not assumed.)
- **Stored classes** — **`users.caps_json`** is a durable **seed**, read as-is at activation (dual-read), **not re-issued** → it does NOT self-sign. The 99 user caps need an explicit **re-issue-signed + rewrite-caps_json** pass.

## Cleanup buckets (196 caps → action for a no-tail signed state)

| bucket | count | action |
|---|---|---|
| upgradeable now (EventLog matches) | 6 | trivial |
| already signed | 1 | — |
| agent structural (Sandbox/ConfigEvolve/Identity/Manage/Template/Terminable) | 62 | re-activate → re-derive signed **IF** the class issues via `Cap.issue` (verify) |
| agent Hello*/Session + session caps | ~38 | re-materialize signed (verify) |
| **user authorizer caps (caps_json)** | **99** | **explicit re-issue-signed + rewrite caps_json** |

## Recommendation

- **Tonight: stay dual-read** (`require_signature:false`) — deploy-safe: new grants sign, legacy caps still authorize, crypto proven 22/0, zero schema change.
- **No-tail upgrade = a re-provision-signed operational pass, not a backfill fix.** Steps: (1) signing seed present on target; (2) re-activate/re-materialize agents+sessions (self-healing classes re-sign — after per-class verification); (3) re-issue the 99 user caps signed + rewrite caps_json; (4) genesis/admin signed by the system entity; (5) re-run `dry_run`/an audit → assert **0 unsigned** → then flip `require_signature:true`.
- The `CapSigningBackfill` (EventLog re-auth) is not the path — retire or bypass.

Isolated E2E env (throwaway PG `p4-canary-e2e-pg` :55450 + worktree) kept for deeper drill (malformed samples, per-user cap detail).
