> **Task:** hello-live-e2e-kanban-fusion
> **Branch:** `feat/hello-live-e2e-kanban-fusion`
> **PR:** https://github.com/ezagent42/ezagent/pull/1383
> **Dev:** zhaomato / Codex
> **returned_at:** 2026-07-14 15:35 +0800
> **deadline:** 2026-07-14 23:59 +0800
> **deadline_status:** deferred

## What's done

- Shipped the hello dispatcher role, canonical loose-coupled Kanban delegation,
  normalized source artifact, and dedicated read-only concierge boundary.
- Shipped signed, bounded, one-shot anonymous login continuation.
- Exposed the real anonymous hello task form on both external-feed and
  `/hello/:name` chat-feed product routes.
- Proved the real login continuation creates exactly one canonical Kanban node.
- Added LiveView/controller/product integration coverage and browser screenshots.
- Preserved World surface ownership: no `styles.css` edit; the only World source
  change is the latest-main URI helper gate fix.

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | Greeter entry and real prompt | met | `docs/e2e/2026-07-14/hello-live-e2e-kanban-fusion/01-anonymous-entry.png`; stable `#hello-prompt-form` route test |
| 2 | Real DeepSeek JSON-render generation -> `Spec.validate` -> live render | deferred | DeepSeek endpoint reached but the only local key returns HTTP 401. Open decision: supply a valid DeepSeek key and rerun the recorded browser flow. No stub is claimed. |
| 3 | Second prompt transforms/PATCHes the live page | deferred | Deterministic product integration is green; real-model proof depends on the same valid DeepSeek credential. |
| 4 | Concierge answers read-only without page mutation | met (deterministic) / live deferred | Product integration snapshots Surface before/after; live-model transcript depends on the same credential. |
| 5 | Anonymous `public_view` is visible | met | `01-anonymous-entry.png`, ChatFeed route test, real HTTP 200 public ingress |
| 6 | Catalog 36-component constraint holds live | met (contract) / live-generation deferred | Spec/catalog parity tests assert exactly 36; generated live spec awaits valid credential. |
| 7 | hello -> Kanban real product connection | met | live board `entity://demo/agent/hello-kanban`, node `n1`, `hello_source` artifact; screenshots and transcript companion |
| 8 | Agent-browser screenshots + transcript | met for available product flow | E2E directory above; DeepSeek failure is recorded honestly |
| 9 | Loose coupling explicitly not #1360 Layer B | met | README/transcript boundary statement |
| 10 | Static gates, regression, PR-head CI, rebase main | pending final head | Update below after the evidence/fix commit is pushed and CI completes. |

**Method friction:** The handoff assumed a valid DeepSeek credential and a
browser-ready Linux host. The local key was only proven present, not accepted by
the provider; Chrome also required unprivileged runtime libraries. Future live
E2E handoffs should preflight provider authentication and browser shared-library
availability before treating the six-point proof as closed-set deliverable.

## Gate and merge request

- Rebase base: `575225560` (`origin/main`, fetched 2026-07-14 15:45 +0800).
- PR-head CI: pending the final evidence/controller commit.
- Local `mix precommit`: rerun with an unprivileged PostgreSQL client extracted
  under `/tmp`, so HomeMigration now passes. The remaining failures are three
  session materialization cases whose `cc` role cannot resolve the broken local
  Claude Code credential source, plus the existing World PR-4 PTY push test
  timing out after 100 ms (reproduces unchanged against the branch's
  URI-equivalent helper call). None is on the hello/DeepSeek change path;
  PR-head deterministic CI is authoritative.
- Merge request: do not call the DeepSeek 6-point line fully met until a valid
  key reruns the live generation/PATCH steps. The completed hello entry,
  continuation, and loose-coupled Kanban connection are ready for review.
