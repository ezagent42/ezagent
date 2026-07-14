> **Task:** hello-live-e2e-kanban-fusion
> **Branch:** `feat/hello-recording-ready`
> **PR:** pending follow-up PR (the original #1383 is already merged)
> **Dev:** zhaomato / Codex
> **returned_at:** 2026-07-14 19:56 +0800
> **deadline:** 2026-07-14 23:59 +0800
> **deadline_status:** deferred

## What's done

- Shipped the hello dispatcher role, canonical loose-coupled Kanban delegation,
  normalized source artifact, and dedicated read-only concierge boundary.
- Shipped signed, bounded, one-shot anonymous login continuation.
- Exposed the real anonymous hello task form on both external-feed and
  `/hello/:name` product routes.
- Corrected `/hello/:name` to consume the committed external Surface feed; the
  previous chat-only feed could show narration but not the generated page.
- Materialized the promised stable product affordance IDs in the real renderer:
  `#hello-product-entry`, `#hello-task-cta`, and
  `#hello-coupling-boundary`.
- Proved the real login continuation creates exactly one canonical Kanban node.
- Added controller/product coverage and recording-ready browser screenshots,
  including the truthful receipt and real World Kanban node.
- Preserved World surface ownership: no `styles.css` edit; the only World source
  change is the latest-main URI helper gate fix.

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | Greeter entry and real prompt | met | `01-anonymous-entry.png`; real browser found the product IDs and single `#hello-prompt-form` |
| 2 | Real DeepSeek JSON-render generation -> `Spec.validate` -> live render | deferred | DeepSeek endpoint reached but the only local key returns HTTP 401. Open decision: supply a valid DeepSeek key and rerun the recorded browser flow. No stub is claimed. |
| 3 | Second prompt transforms/PATCHes the live page | deferred | Deterministic product integration is green; real-model proof depends on the same valid DeepSeek credential. |
| 4 | Concierge answers read-only without page mutation | met (deterministic) / live deferred | Product integration snapshots Surface before/after; live-model transcript depends on the same credential. |
| 5 | Anonymous `public_view` is visible | met | `01-anonymous-entry.png`, external-Surface short-link route test, real HTTP 200 public ingress |
| 6 | Catalog 36-component constraint holds live | met (contract) / live-generation deferred | Spec/catalog parity tests assert exactly 36; generated live spec awaits valid credential. |
| 7 | hello -> Kanban real product connection | met | live board `entity://system/agent/hello-kanban`, node `n1`, raw `unassigned` -> `待派`, `hello_source` artifact; screenshots 04/05 |
| 8 | Browser screenshots + transcript | met for recording-ready product flow | five screenshots + redacted transcript; DeepSeek credential failure is recorded honestly |
| 9 | Loose coupling explicitly not #1360 Layer B | met | README/transcript boundary statement |
| 10 | Static gates, regression, PR-head CI, rebase main | local met / PR CI pending | rebased on `origin/main@b29f0fc93`; final `mix precommit` exited 0; PR-head CI starts after push |

**Method friction:** The handoff assumed a valid DeepSeek credential and a
browser-ready Linux host. The local key was only proven present, not accepted by
the provider; Chrome also required unprivileged runtime libraries. Future live
E2E handoffs should preflight provider authentication and browser shared-library
availability before treating the six-point proof as closed-set deliverable.

## Gate and merge request

- Rebase base: `origin/main@b29f0fc93`; feature head before this ledger-only
  update: `ef84180dc`.
- PR-head CI: pending the follow-up PR.
- Local PostgreSQL was restored as the repository-declared Docker service after
  the previous container disappeared mid-`precommit`; PostgreSQL client tooling
  was restored for the home-migration backup/restore tests.
- Targeted Hello/continuation/receipt tests, renderer JS contract, assets build,
  the World PTY authorization regression (5 consecutive runs), the manifest
  installer regression, the CC credential fixture suite, and final
  clean-process `mix precommit` all pass locally.
- PR-head CI remains the final machine return gate before this return is
  accepted.
- Merge request: do not call the DeepSeek 6-point line fully met until a valid
  key reruns the live generation/PATCH steps. The completed hello entry,
  continuation, and loose-coupled Kanban connection are ready for review.
