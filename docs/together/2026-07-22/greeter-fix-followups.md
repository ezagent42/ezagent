# greeter-relay fix (#1507) — non-blocking follow-ups

Merged 2026-07-22 (`cce24e97b`). Adversarial-review gate verdict: **SOUND / merge-safe**
(6 surfaces held; crash reproduced on main, non-vacuous end-to-end pass on the branch;
cap invariants 396/0). Two non-blocking findings from the review, tracked here:

## 1. should-fix — strengthen the repro test (guard the full issue→verify→handler invariant)
`apps/ezagent_plugin_hello/test/integration/hello_greeter_relay_repro_test.exs` currently
`refute`s two crash strings + asserts `Process.alive?`. It is a **valid** regression test
for THIS bug (proven fail-on-main), but a *future* issue↔verify resolver misalignment would
surface as a **silent** `:missing_cap` on the deferred cast — the front-desk wouldn't crash,
neither refuted string would appear — so the test would pass **vacuously**.
**Fix:** assert the relay actually reached the handler — e.g. the concierge/router dispatch
fired, or a resulting session message / receipt exists. Cheap; fold in when next touching
this area (or a tiny standalone PR).

## 2. nit — latent lifecycle-scope gap (no current caller)
A *future* flavor self-issuing a **recipe-only** action from `on_ready` / `handle_continue` /
`handle_signal` (outside the dispatch scope where `Kind.Runtime.do_handle_dispatch/4` installs
`Cap.RuntimeView`) would silently fall back to the global `BehaviorRegistry` → `:unknown_action`
→ crash — the same class the fix just repaired for the dispatch path. **No current caller**;
any such path was already broken pre-fix. If a flavor ever needs this, extend the RuntimeView
install to those lifecycle scopes (or resolve via the instance set there too).

Neither blocks anything. The merged fix is correct, secure, and gate-green.
