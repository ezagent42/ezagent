# Hello–Kanban Product Closeout Design

## Goal

Close the remaining product gaps after #1425 without implying that the Hello
delegation receipt is live. Preserve the current concierge-navigation and
tailnet-development fixes, add a tested cross-workspace receive boundary, prove
Kanban reflux in an isolated real stack, and dispose of stale PR #1134.

## Workspace isolation

- Work only in `/home/ning/ezagent-hello-closeout` on
  `feat/hello-kanban-product-closeout`, based on the latest `origin/main`.
- Do not stop, restart, edit, or reconfigure the running
  `/home/ning/ezagent-hello-intent-fix` worktree or its port-10042 service.
- Carry forward only the source/test/config changes currently present in that
  worktree. Never carry `node_modules` symlinks, database state, API keys, or
  generated runtime files.

## Product decision: honest snapshot plus live-board CTA

The Hello receipt remains a delegation-time snapshot. It must visibly say that
it is not the live task state and provide a primary action that opens the
corresponding World Kanban board. The action uses the real board/session URI;
it does not copy board data or claim that the receipt auto-refreshes.

The user flow is:

1. The owner delegates a task from Hello.
2. Hello renders a receipt labelled `委派快照 · 非实时状态`.
3. The receipt provides `在 World Kanban 查看实时进度`.
4. The action opens the World Kanban route for the mounted/original board.
5. World re-reads the live board actor, so later source changes appear there.

If the route cannot be produced, the receipt keeps the snapshot label and
shows no broken action. Delegation success must not be turned into failure by a
missing optional UI link.

## Authorization boundary

Receiving/mounting a shared board must remain same-workspace. A receiver from a
different workspace is rejected before a Mount row or capability is minted.
The regression test must prove all three outcomes:

- the operation returns the canonical cross-workspace denial;
- no durable Mount row exists for the attempted receipt;
- the foreign receiver cannot read or write the board afterward.

Existing same-workspace behavior remains unchanged: repeated receipt is
idempotent, `get_tree` reads the original live board, and write actions remain
denied for a read-only mount.

## Carried-forward fixes

The new PR also includes the current uncommitted fixes:

- Viewer navigation executes unseen server-whitelisted navigation messages
  independent of UUID agent names, with pure Node and ExUnit regression tests.
- Development World routes allow localhost and tailnet hosts.
- Development World loads Phoenix-hosted built JS/CSS rather than making a
  remote colleague's browser request its own `localhost:5173`.

These changes remain separate logical commits from the Kanban closeout.

## PR #1134 disposition

Close #1134 rather than rebase it. Its concierge, public read, website tabs,
publish-as-template, Surface seed, World durable listing, navigation, typing,
and unread behavior all have corresponding implementations on main or later
PRs. Its only absent module, `Ezagent.Entity.HelloConcierge`, is an obsolete
standalone Kind replaced by the current unified `Entity.Agent + role` model.

The closure comment must identify the covering implementation and state that
the UUID navigation regression is fixed in this new PR, so future readers do
not interpret closure as feature abandonment.

## Verification

Run focused tests first, then the affected app suites and repository gates:

- Viewer navigation Node/ExUnit contract tests.
- Hello delegation/published-read tests.
- Kanban board-forward and Mount authorization tests.
- World route/action tests for the live-board URL.
- `mix precommit`, with any unrelated baseline/environment failure reported
  exactly rather than represented as green.

The branch must be rebased on current main before the final PR-head CI run.

## Recording plan

Record against an isolated deployment profile and ports, never the colleague's
port-10042 service. Use a fresh disposable database/profile with the same
production application topology needed for World, Hello, Kanban, and the curl
LLM agent.

### Recording A: product path and live reflux

Target duration: 2–4 minutes, one continuous recording.

1. Open the seeded Hello website as the owner and briefly show the page.
2. Enter a real task request and delegate it to Kanban.
3. Hold on the Hello receipt long enough to show:
   - the created task summary;
   - `委派快照 · 非实时状态`;
   - `在 World Kanban 查看实时进度`.
4. Activate the CTA and land on the correct World Kanban board.
5. Show the delegated card and its initial status.
6. In the source/owner Kanban surface, change the card status or add a clearly
   named reflux marker node.
7. Return to the receiver/live board and trigger its normal re-read/refresh.
8. Show the new status/marker appearing without re-delegating or copying data.
9. Return briefly to the Hello receipt and show that it still presents itself
   honestly as a snapshot rather than pretending to have refreshed.

Capture companion screenshots for the receipt label/CTA, the initial World
board, and the post-change World board. Save the video, screenshots, and an
exact action transcript under
`docs/e2e/2026-07-16/hello-kanban-product-closeout/`.

### Recording B: carried concierge navigation fix

Target duration: 30–60 seconds. It may be appended to Recording A if the state
is stable.

1. On the Hello site, send a natural-language navigation request as owner.
2. Show the concierge reply.
3. Show the page actually switching tabs.
4. Keep DevTools closed unless needed; the visible product outcome is the
   evidence.

### Non-visual authorization evidence

Do not attempt to demonstrate cross-workspace denial by manipulating real team
workspaces on camera. Attach the focused test transcript to the E2E README,
including the denial result and assertions that no Mount/cap was created.

## Done condition

- Hello receipts cannot reasonably be mistaken for live status.
- The World CTA reaches the real live board and deployed-stack reflux is
  recorded.
- Cross-workspace receipt is denied with durable negative assertions.
- The current navigation and tailnet fixes are included and tested.
- #1134 is closed with an evidence-based disposition.
- The new PR is rebased, review-complete, and CI green.
