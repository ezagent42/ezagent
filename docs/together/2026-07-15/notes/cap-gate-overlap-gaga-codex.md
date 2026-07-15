# Coordination note — gaga #1412 ↔ codex no-tail cap-gate/chokepoint overlap

**2026-07-15.** Recorded so it isn't lost when codex's no-tail branch returns.

## What overlaps
gaga's **#1412** (`79f4f402a`, merged — capability-auth Task 3-6 readers + a new email-inbound authority seam) touches the **same cap gate/chokepoint surfaces** that codex's **no-tail self-healing build** (`feat/cap-signing-notail-upgrade`, per `docs/superpowers/specs/2026-07-15-cap-signing-no-tail-self-heal.md`) also changes:

- **`apps/ezagent_core/test/invariants/entity_caps_access_gate_test.exs`** — the #1409 write-side gate. #1412 modified it; codex's no-tail **P2** extends it + removes the retired-backfill allowlist entries from it. **Same file → semantic merge, not clobber.**
- **`apps/ezagent_core/test/invariants/cap_issue_chokepoint_test.exs`** — new invariant added by #1412; codex's no-tail also hardens the `Cap.issue` chokepoint.
- **Email-inbound unsigned mint** — #1412 **already removed** email's unsigned inline mint (fresh durable join + receiver-bound signing). That is one of the "future issue-sites" codex's no-tail **P0** targets. **Complementary, done early — codex must NOT re-do it.**

## Reconciliation (relayed to codex via lead)
When codex rebases `feat/cap-signing-notail-upgrade` on latest `main` (its handoff already requires per-phase rebase):
1. Merge its gate-extension + backfill-allowlist-removal changes **on top of gaga's `entity_caps_access_gate_test.exs` edits** — same file, reconcile semantics, don't overwrite gaga's.
2. Reconcile with gaga's `cap_issue_chokepoint_test.exs` rather than adding a duplicate/conflicting chokepoint invariant.
3. **Do NOT re-implement email inbound** — it's done; the resolver-coverage gate should count email-inbound as already-covered (signed).

## Status
#1412 landed first (done, gate-green, independent review 0 findings, dual-read-safe, deploying to canary). codex's no-tail is mid-build (self-driving P0→P3 onto the target branch) and will pick this up on rebase. gaga's remaining auth-followups (#1405 fault-recovery upper layer, etc.) still in progress.
