# Hello–Kanban Product Closeout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Hello→Kanban receipt honest and actionable, enforce same-workspace board receipt, preserve today's local product fixes, prove live reflux in an isolated stack, and close stale PR #1134.

**Architecture:** Keep the Hello receipt as a delegation snapshot, but carry a separate World Kanban route in its whitelisted nav payload and render a clear live-board CTA. Enforce workspace equality in `BoardProvision.forward_board/5` before resolving the receiver or calling `Mount.mount/6`, so no cap or Mount row can be created cross-workspace. Use the existing board actor as the live data source; no polling or copy layer is introduced.

**Tech Stack:** Elixir 1.19, Phoenix 1.8, Ecto/PostgreSQL, React 19, plain ESM asset tests, ExUnit, agent-browser/ffmpeg recording, GitHub CLI.

## Global Constraints

- Never modify, stop, restart, or reconfigure `/home/ning/ezagent-hello-intent-fix` or its port-10042 service.
- Work only in `/home/ning/ezagent-hello-closeout` on `feat/hello-kanban-product-closeout`.
- Never copy or commit API keys, databases, generated build artifacts, or `node_modules` links.
- Preserve the current CapBAC mint chokepoint; `Mount.mount/6` remains generic and trusted-caller oriented.
- The Hello receipt must say it is a snapshot and must not claim live refresh.
- The recording stack uses different ports and a disposable database/profile.

---

### Task 1: Carry forward the current navigation and tailnet fixes

**Files:**
- Create: `apps/ezagent_domain_socialware/assets/js/viewer_nav.mjs`
- Modify: `apps/ezagent_domain_socialware/assets/js/viewer_app.js`
- Create: `apps/ezagent_domain_socialware/assets/test/viewer_nav_test.mjs`
- Create: `apps/ezagent_domain_socialware/test/assets/viewer_nav_test.exs`
- Modify: `config/dev.exs`

**Interfaces:**
- Produces: `latestUnseenNavMessage(messages, seenIds) :: message | null`
- Preserves: server-whitelisted `nav.type` values `switch_tab`, `scroll_to`, and `open_url`

- [ ] **Step 1: Apply only the tracked/untracked source changes from the frozen worktree**

Transfer the five source/test/config files from `/home/ning/ezagent-hello-intent-fix` without copying either `node_modules` symlink.

- [ ] **Step 2: Run the focused navigation tests**

Run:

```bash
mix test apps/ezagent_domain_socialware/test/assets/viewer_nav_test.exs \
  apps/ezagent_domain_socialware/test/assets/viewer_renderer_test.exs \
  apps/ezagent_domain_socialware/test/assets/catalog_normalize_test.exs
node apps/ezagent_plugin_hello/assets/test/hello_delegation_surface_test.mjs
```

Expected: all tests exit 0; the Node contracts print their `ok` lines.

- [ ] **Step 3: Commit the carried fixes**

```bash
git add apps/ezagent_domain_socialware/assets/js/viewer_app.js \
  apps/ezagent_domain_socialware/assets/js/viewer_nav.mjs \
  apps/ezagent_domain_socialware/assets/test/viewer_nav_test.mjs \
  apps/ezagent_domain_socialware/test/assets/viewer_nav_test.exs \
  config/dev.exs
git commit -m "fix(socialware): execute UUID-agent navigation actions"
```

### Task 2: Make the Hello Kanban receipt an honest snapshot with a World CTA

**Files:**
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/kanban_delegation.ex`
- Modify: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/kanban_delegation_test.exs`
- Modify: `apps/ezagent_domain_socialware/assets/js/viewer_app.js`
- Modify: `apps/ezagent_plugin_hello/assets/test/hello_delegation_surface_test.mjs`

**Interfaces:**
- Produces in the receipt nav payload:
  - `"kind" => "hello_kanban_receipt"`
  - `"value" => receive_ref` for the existing public read receipt
  - `"live_board_url" => "/plugins/kanban/<encoded board URI>"`
  - `"snapshot" => true`
- Consumes: World's canonical detail route `/plugins/kanban/:uri`.

- [ ] **Step 1: Write failing Elixir assertions for the live World route**

Add a delegation test assertion equivalent to:

```elixir
assert result.live_board_url ==
         "/plugins/kanban/" <> URI.encode_www_form(URI.to_string(result.kanban_uri))
```

Run:

```bash
mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/kanban_delegation_test.exs
```

Expected: FAIL because `live_board_url` is absent.

- [ ] **Step 2: Add the canonical World URL to delegation results**

Add a private helper:

```elixir
defp world_kanban_url(%URI{} = kanban_uri) do
  "/plugins/kanban/" <> URI.encode_www_form(URI.to_string(kanban_uri))
end
```

Return `live_board_url` from `delegate/3` and include it in the receipt nav map.

- [ ] **Step 3: Write failing product-surface assertions**

Extend `hello_delegation_surface_test.mjs` to require:

```js
assert.match(viewer, /委派快照 · 非实时状态/)
assert.match(viewer, /在 World Kanban 查看实时进度/)
assert.match(viewer, /live_board_url/)
```

Run the Node test and confirm it fails on missing copy/CTA.

- [ ] **Step 4: Render the honest receipt and CTA**

Update the receipt rendering so it includes:

```js
React.createElement("span", {className: "hello-kanban-result-snapshot"}, "委派快照 · 非实时状态")
React.createElement(
  "a",
  {href: receipt.live_board_url, target: "_blank", rel: "noreferrer"},
  "在 World Kanban 查看实时进度 →",
)
```

Keep the existing public receive link as a secondary action labelled
`接收只读看板`. Do not execute `receipt.value` automatically as the World CTA.

- [ ] **Step 5: Run focused tests and commit**

```bash
mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/kanban_delegation_test.exs
node apps/ezagent_plugin_hello/assets/test/hello_delegation_surface_test.mjs
git add apps/ezagent_plugin_hello apps/ezagent_domain_socialware/assets/js/viewer_app.js
git commit -m "fix(hello): link delegation snapshots to live kanban"
```

### Task 3: Reject cross-workspace board forwarding before Mount/cap creation

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/socialware/board_provision.ex`
- Modify: `apps/ezagent_plugin_kanban/test/e2e/board_forward_test.exs`

**Interfaces:**
- Produces: `BoardProvision.forward_board/5 -> {:error, :cross_workspace_denied}` when board, source session, and target session are not all in one workspace.
- Guarantees: no call to `Mount.mount/6`, no Mount row, no receiver cap.

- [ ] **Step 1: Add the failing cross-workspace test**

Create a second workspace and target session/assistant. Attempt to forward the
source workspace board into that target and assert:

```elixir
assert {:error, :cross_workspace_denied} =
         BoardProvision.forward_board(board, from_session, foreign_session, Kanban, bob_ctx)

assert MountRow.get(foreign_session, board, foreign_assistant, Kanban) == nil
assert {:error, reason} = dispatch_as(foreign_assistant, board, :get_tree, %{})
assert reason in [:unauthorized, :cross_workspace_denied]
```

Run the focused test and confirm it fails because forwarding currently reaches
the existing access/mount path.

- [ ] **Step 2: Add the pre-mint workspace guard**

At the start of `forward_board/5`, require the workspace URI of `board_uri`,
`from_session_uri`, and `to_session_uri` to match. Return
`{:error, :cross_workspace_denied}` before `assert_forward_access/5` and before
target assistant resolution.

- [ ] **Step 3: Run the forward and Mount suites**

```bash
mix test apps/ezagent_plugin_kanban/test/e2e/board_forward_test.exs
mix test apps/ezagent_domain_session/test/ezagent/socialware/mount_test.exs \
  apps/ezagent_domain_session/test/ezagent/socialware/mount_reconcile_test.exs
```

Expected: same-workspace reflux/read-only/idempotency remains green; the new
foreign receive test passes.

- [ ] **Step 4: Commit the authorization fix**

```bash
git add apps/ezagent_domain_session/lib/ezagent/socialware/board_provision.ex \
  apps/ezagent_plugin_kanban/test/e2e/board_forward_test.exs
git commit -m "fix(kanban): deny cross-workspace board forwarding"
```

### Task 4: Record isolated real-stack product proof

**Files:**
- Create: `docs/e2e/2026-07-16/hello-kanban-product-closeout/README.md`
- Create: `docs/e2e/2026-07-16/hello-kanban-product-closeout/transcript.txt`
- Create: `docs/e2e/2026-07-16/hello-kanban-product-closeout/*.png`
- Create: `docs/e2e/2026-07-16/hello-kanban-product-closeout/*.webm`

**Interfaces:**
- Uses ports/profile distinct from 10042 and the colleague-facing database.
- Demonstrates the recording sequence from the approved design.

- [ ] **Step 1: Create an isolated profile/database and build assets**

Use a dedicated `EZAGENT_HOME`, PostgreSQL database, Phoenix port, and Vite port.
Record the exact environment variable names and ports in the E2E README, but
never record secret values.

- [ ] **Step 2: Seed Hello Fusion and prepare source/receiver Kanban state**

Run the Fusion seed, configure the disposable curl LLM credential locally, and
verify the isolated `/hello/fusion`, `/sessions`, and World Kanban routes return
200 after authentication.

- [ ] **Step 3: Record product path and reflux**

Follow Recording A in the design exactly: delegate, show snapshot label/CTA,
open World, mutate source, re-read receiver, show new state, return to snapshot.

- [ ] **Step 4: Record concierge navigation**

Follow Recording B: natural-language request, concierge response, actual tab
switch. This proves the carried UUID-agent fix in the same PR.

- [ ] **Step 5: Write transcript and evidence README**

Document timestamps, URLs with secrets removed, expected/observed results, and
the focused cross-workspace test command/output summary.

- [ ] **Step 6: Commit E2E evidence**

```bash
git add docs/e2e/2026-07-16/hello-kanban-product-closeout
git commit -m "test(e2e): prove hello kanban live-board reflux"
```

### Task 5: Dispose of PR #1134

**Files:**
- Modify: PR #1134 state/comment on GitHub only after code/tests are ready.

- [ ] **Step 1: Post the evidence-based closure comment**

State that main/later PRs cover public read, concierge, navigation, publish as
template, Surface seed, and World durable listings. State that the absent
standalone `Ezagent.Entity.HelloConcierge` is obsolete under unified
`Entity.Agent + role`, and link the new PR for the UUID-navigation regression.

- [ ] **Step 2: Close #1134**

Use `gh pr close 1134 --comment <message>` only after the new branch has a PR URL
to reference.

### Task 6: Full verification, review, rebase, PR, and CI

**Files:**
- Modify only files required by review or rebase conflict resolution.

- [ ] **Step 1: Run affected app suites**

```bash
mix test apps/ezagent_plugin_hello/test
mix test apps/ezagent_plugin_kanban/test
mix test apps/ezagent_domain_socialware/test
mix test apps/ezagent_domain_session/test/ezagent/socialware
```

- [ ] **Step 2: Run repository gate**

```bash
mix precommit
```

Report unrelated environment/baseline failures exactly and fix all failures
caused by this branch.

- [ ] **Step 3: Request code review and resolve findings**

Review the complete diff against the design, with special focus on CapBAC,
cross-workspace denial ordering, URL encoding, and viewer nav safety.

- [ ] **Step 4: Rebase current main and rerun focused tests**

```bash
git fetch origin main
git rebase origin/main
```

- [ ] **Step 5: Push and open the PR**

Push `feat/hello-kanban-product-closeout`, open a PR to `main`, and include the
recording/evidence links, #1425 closeout context, and #1134 disposition.

- [ ] **Step 6: Wait for PR-head CI**

Monitor required checks, fix branch-caused failures, and report only when the
required CI is green.
