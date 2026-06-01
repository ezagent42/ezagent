# Minimal PoC — AutoService customer-service on ezagent — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the minimal PoC that proves AutoService's customer-service capabilities (web chat, soul-edit, operator takeover) migrate onto ezagent, packaged as small reviewable PRs, with a Gaps & Blocks findings doc and 3 demos.

**Architecture:** The `customer_chat` (A) plugin already exists and is largely wired (routes, SoulStore→cc spawn, operator console). This plan is **verify existing + fix the one real gap (takeover→Mode shape) + package into reviewable PRs + document findings + demo** — NOT greenfield. Spec: `poc/phase-2/15-corrected-minimal-poc-plan-2026-06-01.md`.

**Tech Stack:** Elixir umbrella (Phoenix LiveView, Ecto/SQLite), `gh` CLI on `ezagent42/ezagent`, claude-in-chrome for demo capture.

**Global invariants (every task):**
- `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps` on every `mix` call. **NEVER `mix deps.get`.**
- `gh` always with `--repo ezagent42/ezagent`.
- Branch base: `poc/phase-2-customer-service` (HEAD has A + bridge fix).
- Don't lose others' work (verified: our PRs are 100% ours; hjj's are in `feat/autoservice-cinnox`).

---

## Phase 0 — Baseline (prove the starting state is green)

### Task 0.1: Compile + run A's existing tests
**Files:** none (verification)

- [ ] **Step 1: Compile the umbrella**

Run: `cd /Users/daiming/workspace/ezagent42/ezagent-poc-phase-2 && MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix compile`
Expected: exit 0 (warnings in unrelated apps OK; none in `ezagent_plugin_customer_chat`).

- [ ] **Step 2: Ensure DBs migrated (post bridge-fix merge)**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix ecto.migrate && MIX_ENV=test MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix ecto.migrate`
Expected: "Migrations already up" or applies pending; exit 0.

- [ ] **Step 3: Run A's existing test suite**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_plugin_customer_chat/test`
Expected: all pass (bootstrap, components, config_auth, ephemeral_gc, soul_store, theme).

- [ ] **Step 4: Run Mode (#511) tests (takeover primitive)**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_domain_chat/test/ezagent/behavior/mode_test.exs`
Expected: all pass.

- [ ] **Step 5: Record baseline** — note any failures in `poc/phase-2/16-gaps-and-blocks.md` (created in Phase 4) under "baseline". If green, no commit (verification only).

### Task 0.2: Close the superseded autoservice split PRs
**Files:** none (PR admin)

- [ ] **Step 1: Close #525 (autoservice CS)**

Run: `gh pr close 525 --repo ezagent42/ezagent --comment "Superseded by the corrected minimal PoC (poc/phase-2/15-corrected-minimal-poc-plan). Re-anchored on customer_chat (A); the autoservice/curl path is out of scope. All commits here are ours — nothing lost."`
Expected: "Closed pull request #525".

- [ ] **Step 2: Close #526 (autoservice operator)**

Run: `gh pr close 526 --repo ezagent42/ezagent --comment "Superseded — see #525 close note + poc/phase-2/15-corrected-minimal-poc-plan."`
Expected: "Closed pull request #526".

- [ ] **Step 3: (no commit — PR admin only)**

---

## Phase 1 — Fix the one real code gap: takeover → real Mode (#511)

`session_view_live.dispatch_takeover/1` dispatches `mode.set` with `args: %{mode: :takeover, set_by: ...}`, but Mode #511's `:set` action schema is `%{mode: :atom}`. Drop the extra key; remove the pre-2.6 "expected to fail" placeholder.

### Task 1.1: Wire A's Take-over button to the real Mode

**Files:**
- Modify: `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/session_view_live.ex` (`dispatch_takeover/1` ~line 285-291 + moduledoc ~line 11-26)
- Test: `apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/session_view_live_takeover_test.exs` (create)

- [ ] **Step 1: Write the failing test** (dispatching takeover flips the session mode via the real Mode)

```elixir
# apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/session_view_live_takeover_test.exs
defmodule EzagentPluginCustomerChat.SessionViewLiveTakeoverTest do
  use ExUnit.Case, async: false
  alias Ezagent.Behavior.Mode

  # Reuse the same dispatch shape the LiveView uses, asserting it matches the
  # real Mode.set arg schema (%{mode: :atom}) — i.e. NO extra keys.
  test "takeover dispatch args match Mode.set schema (mode only, no set_by)" do
    args = EzagentPluginCustomerChat.SessionViewLive.takeover_args()
    assert args == %{mode: :takeover}
    # schema sanity: Mode.set declares args %{mode: :atom}
    assert %{mode: :atom} = Mode.__action_args__(:set)
  end
end
```

- [ ] **Step 2: Run it — verify it fails**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/session_view_live_takeover_test.exs`
Expected: FAIL — `takeover_args/0` undefined (and/or `__action_args__` helper name differs).

> If `Mode.__action_args__/1` doesn't exist, replace that assertion with a literal `assert args == %{mode: :takeover}` only, and verify the schema by reading `mode.ex` `action :set, args: %{mode: :atom}` manually. Keep the test to the arg-shape contract.

- [ ] **Step 3: Implement — extract `takeover_args/0` + fix the dispatch shape**

In `session_view_live.ex`, replace the `dispatch_takeover/1` body's args and add a public helper:

```elixir
@doc false
def takeover_args, do: %{mode: :takeover}

defp dispatch_takeover(socket) do
  target = URI.new!("#{socket.assigns.session_uri_str}?action=mode.set")

  inv = %Ezagent.Invocation{
    target: target,
    mode: :call,
    args: takeover_args(),
    ctx: %{
      caller: socket.assigns.current_entity_uri,
      caps: socket.assigns.caller_caps,
      reply: {:caller_inbox, self()}
    }
  }

  Ezagent.Invocation.dispatch(inv)
end
```

Also update the moduledoc: delete the `PHASE_2.6_INTEGRATION`/"expected to fail" block (lines ~11-26) and replace with: `## Take-over wires to Ezagent.Behavior.Mode (#511): dispatches mode.set %{mode: :takeover} on the session; Chat.handle_send then suppresses agent-sender messages.`

- [ ] **Step 4: Run the test — verify it passes**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/session_view_live_takeover_test.exs`
Expected: PASS.

- [ ] **Step 5: Recompile + full customer_chat suite (no regressions)**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_plugin_customer_chat/test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/session_view_live.ex \
        apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/session_view_live_takeover_test.exs
git commit -m "fix(customer-chat): wire Take-over button to real Behavior.Mode (#511) — drop pre-2.6 set_by key"
```

---

## Phase 2 — Verify soul-edit end-to-end (no code expected; confirm wiring)

SoulStore→cc spawn is already wired (`bootstrap.cc_soul_path_for_workspace → SoulStore.effective_path`); `/plugins/customer-chat/:tenant/config` (ConfigLive) is routed; SoulStore + ConfigAuth are unit-tested.

### Task 2.1: Confirm the effective-soul resolution feeds cc spawn
**Files:** none (verification); if a gap is found, fix in this task.

- [ ] **Step 1: Re-read the wiring**

Run: `grep -n "effective_path\|cc_soul_path\|soul_path" apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/bootstrap.ex`
Expected: `cc_soul_path_for_workspace → SoulStore.effective_path(workspace, role)` and `soul_path` threaded into `create_agent` args.

- [ ] **Step 2: Confirm cc consumes `soul_path` as `--append-system-prompt-file`**

Run: `grep -n "append-system-prompt-file\|soul_path\|build_soul_args" apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex`
Expected: `build_soul_args` emits `["--append-system-prompt-file", path]`.

- [ ] **Step 3: Run the SoulStore + ConfigAuth unit tests (already green in 0.1, re-confirm in isolation)**

Run: `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/soul_store_test.exs apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/config_auth_test.exs`
Expected: all pass.

- [ ] **Step 4: Record result.** If wiring is intact (expected), no code change — note "soul-edit migrates natively (no gap)" for the Gaps doc. If a wiring gap is found, fix it minimally here + add a regression test + commit.

---

## Phase 3 — Package into small reviewable PRs

A (`customer_chat`, ~1.9k LOC) is much smaller than the old #446 monster. Split into 3 capability PRs (matching spec §8), each on `origin/main` so they're independently reviewable. Use a temp worktree per branch (see autoservice precedent); compile-verify each before pushing. The cc-agent bring-up changes are a 4th, separate PR coordinated with hjj.

> Carving guidance: `bootstrap.ex` is shared. Put the base plugin + `bootstrap` (with the `SoulStore` call **stubbed to fixture-only**) in PR-1; PR-2 adds `SoulStore`/`ConfigLive`/`ConfigAuth` + flips `cc_soul_path_for_workspace` to `SoulStore.effective_path` + the `/config` route; PR-3 adds `DashboardLive`/`SessionViewLive` + `/operator` routes + the Mode wiring.

### Task 3.1: PR-1 — customer web chat (base plugin)
**Files (into a temp worktree branch `feat/cs-chat` off `origin/main`):**
- `apps/ezagent_plugin_customer_chat/` minus `{soul_store,config_live,config_auth,dashboard_live,session_view_live}.ex` and minus their tests
- `bootstrap.ex` with `cc_soul_path_for_workspace/2` returning the fixture path only (no `SoulStore` dep yet)
- `apps/ezagent_web` router: `/chat/:tenant`, widget, SSE only
- the chat/theme/components/ephemeral_gc tests

- [ ] **Step 1: Create the worktree + branch**

```bash
WT=/tmp/wt-cs-chat
git worktree add -q "$WT" origin/main -b feat/cs-chat
```

- [ ] **Step 2: Bring the base files from our branch, excluding soul-edit/operator**

```bash
cd "$WT"
git checkout poc/phase-2-customer-service -- apps/ezagent_plugin_customer_chat apps/ezagent_web/lib/ezagent_web/router.ex apps/ezagent_web/mix.exs
git rm -q apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/{soul_store,config_live,config_auth,dashboard_live,session_view_live}.ex
git rm -q apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/{config_auth,soul_store}_test.exs
```

- [ ] **Step 3: Stub `cc_soul_path_for_workspace/2` to fixture-only** (remove the `SoulStore` dependency from the base)

In `$WT/.../bootstrap.ex`, replace the body of `cc_soul_path_for_workspace/2` with the fixture-path computation inlined (copy the `fixture_path` logic from `soul_store.ex`: `Path.join([soul_root(), tenant, "souls", "#{role}.md"])`, return it if `File.exists?`, else `nil`), so PR-1 has no soul-edit code.

- [ ] **Step 4: Trim the router** — remove the `/operator*` + `/config` + ConfigLive/DashboardLive/SessionViewLive lines (keep `/chat/:tenant`, widget, SSE).

- [ ] **Step 5: Compile**

Run: `cd "$WT" && MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix compile`
Expected: exit 0, no dangling refs to removed modules. (Fix any reference the trim missed.)

- [ ] **Step 6: Test + commit + push + PR**

```bash
cd "$WT" && MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_plugin_customer_chat/test
git add -A && git commit -m "feat(customer-chat): AI customer web chat on ezagent (base plugin)"
git push -u origin feat/cs-chat
gh pr create --repo ezagent42/ezagent --base main --head feat/cs-chat \
  --title "PoC PR-1 — AI customer web chat (customer_chat plugin)" \
  --body "Minimal PoC, base plugin: ChatLive /chat/:tenant + widget + SSE + per-conv cc agent (EagerBridge) + theme. Soul-edit = PR-2, operator takeover = PR-3. See poc/phase-2/15-corrected-minimal-poc-plan. NOTE for Allen: none (no core change in this PR)."
```

- [ ] **Step 7: Clean up worktree**

```bash
cd /Users/daiming/workspace/ezagent42/ezagent-poc-phase-2 && git worktree remove --force /tmp/wt-cs-chat && git branch -D feat/cs-chat 2>/dev/null || true
```

### Task 3.2: PR-2 — soul-edit (stacked on PR-1)
**Files (branch `feat/cs-soul-edit` off `feat/cs-chat`):**
- Add `soul_store.ex`, `config_live.ex`, `config_auth.ex` + their tests
- Flip `bootstrap.cc_soul_path_for_workspace/2` to `SoulStore.effective_path/2`
- Add the `/plugins/customer-chat/:tenant/config` route

- [ ] **Step 1: Worktree off PR-1**

```bash
WT=/tmp/wt-cs-soul
git worktree add -q "$WT" origin/feat/cs-chat -b feat/cs-soul-edit
cd "$WT"
git checkout poc/phase-2-customer-service -- \
  apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/{soul_store,config_live,config_auth}.ex \
  apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/{soul_store,config_auth}_test.exs
```

- [ ] **Step 2: Restore the `SoulStore` call in bootstrap + add the config route**

In `$WT/.../bootstrap.ex`, change `cc_soul_path_for_workspace/2` back to `EzagentPluginCustomerChat.SoulStore.effective_path(workspace, role)`. In `$WT/.../router.ex`, add `live "/plugins/customer-chat/:tenant/config", ConfigLive` inside the operator/admin `EzagentPluginCustomerChat` scope (create the scope if PR-1 removed it; it needs `RequireEntity`).

- [ ] **Step 3: Compile + test**

Run: `cd "$WT" && MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix compile && MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_plugin_customer_chat/test`
Expected: exit 0; soul_store + config_auth tests pass.

- [ ] **Step 4: Commit + push + PR (base = feat/cs-chat)**

```bash
git add -A && git commit -m "feat(customer-chat): editable soul (SoulStore file model + ConfigLive + ConfigAuth cap gate)"
git push -u origin feat/cs-soul-edit
gh pr create --repo ezagent42/ezagent --base feat/cs-chat --head feat/cs-soul-edit \
  --title "PoC PR-2 — editable soul (file model, stacked on PR-1)" \
  --body "Admin edits the tenant soul (edited→fixture→prev, undo/reset) gated by the workspace-admin cap; cc reads the effective soul at spawn via --append-system-prompt-file. New conversations reflect the edit. No core change. Spec: poc/phase-2/11-admin-edit-soul-design + 15-corrected-minimal-poc-plan."
git -C /Users/daiming/workspace/ezagent42/ezagent-poc-phase-2 worktree remove --force "$WT"
```

### Task 3.3: PR-3 — operator console + takeover (stacked on PR-1, needs Mode #511)
**Files (branch `feat/cs-operator` off `feat/cs-chat`):**
- Add `dashboard_live.ex`, `session_view_live.ex` (with the Phase-1 Mode fix) + the `/operator*` routes
- Depends on Mode #511 — note in the PR body that it stacks logically on #511

- [ ] **Step 1: Worktree + bring files (including the Phase-1 takeover fix)**

```bash
WT=/tmp/wt-cs-op
git worktree add -q "$WT" origin/feat/cs-chat -b feat/cs-operator
cd "$WT"
git checkout poc/phase-2-customer-service -- \
  apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/{dashboard_live,session_view_live}.ex \
  apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/session_view_live_takeover_test.exs
```

- [ ] **Step 2: Add `/operator*` routes** — in `$WT/.../router.ex` add `live "/operator", DashboardLive`, `live "/operator/:tenant", DashboardLive`, `live "/operator/:tenant/:conv", SessionViewLive` in the `EzagentPluginCustomerChat` operator scope.

- [ ] **Step 3: Bring Mode (#511) into this branch so it compiles** (Mode isn't in `main` yet)

```bash
git checkout origin/feat/takeover-mode -- \
  apps/ezagent_domain_chat/lib/ezagent/behavior/mode.ex \
  apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex \
  apps/ezagent_domain_chat/lib/ezagent/entity/session.ex \
  apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex
```

- [ ] **Step 4: Compile + test**

Run: `cd "$WT" && MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix compile && MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps mix test apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/session_view_live_takeover_test.exs`
Expected: exit 0; takeover test passes.

- [ ] **Step 5: Commit + push + PR**

```bash
git add -A && git commit -m "feat(customer-chat): operator console + takeover wired to Behavior.Mode (#511)"
git push -u origin feat/cs-operator
gh pr create --repo ezagent42/ezagent --base feat/cs-chat --head feat/cs-operator \
  --title "PoC PR-3 — operator console + takeover (Mode #511)" \
  --body "Operator dashboard lists live customer sessions; SessionView Take-over flips session mode via Behavior.Mode (#511); Chat.handle_send suppresses agent-sender msgs. @Allen — DECISION: takeover here uses a core Chat.handle_send suppression hook (Mode). A zero-core-change alternative (pure routing) is documented in poc/phase-2/14-takeover-routing-evolution. Which direction should ezagent standardize on, and is the Chat hook acceptable? This PR stacks logically on #511 (Mode)."
git -C /Users/daiming/workspace/ezagent42/ezagent-poc-phase-2 worktree remove --force "$WT"
```

### Task 3.4: Consolidate the cc-agent bring-up PR (coordinate with hjj)
**Files:** none here — a coordination + packaging task.

- [ ] **Step 1: Comment on #512 proposing the consolidation**

Run: `gh pr comment 512 --repo ezagent42/ezagent --body "Proposal: fold this (EagerBridge + repeat-prompt fix) together with the theme-picker PTY change + the OAuth/dialog-gate fix (b03cb4da/65a0732f, now in poc) into ONE 'claude 2.1.92 headless cc-agent bring-up' PR, matching #510's 4-track plan + #524's close note. @hjj — who owns that consolidated PR, you or us? Either way the code is the same; just avoid a duplicate."`
Expected: comment posted.

- [ ] **Step 2: (no commit — coordination)** Await ownership decision; do not duplicate.

---

## Phase 4 — Gaps & Blocks findings doc (the PoC deliverable)

### Task 4.1: Write `poc/phase-2/16-gaps-and-blocks.md`
**Files:** Create `poc/phase-2/16-gaps-and-blocks.md`

- [ ] **Step 1: Write the findings doc** — promote the G1–G5 table from spec §3 into a standalone findings report, each with: what was tried, what's native vs custom, status, and (for G3) the explicit Allen decision. Include the baseline result from Task 0.1 and the soul-edit verdict from Task 2.1. Pull verbatim from `15-corrected-minimal-poc-plan` §3 + cite `12-orchestrator-vs-our-capabilities` (G4) and `14-takeover-routing-evolution` (G3).

- [ ] **Step 2: Commit + push**

```bash
cd /Users/daiming/workspace/ezagent42/ezagent-poc-phase-2
git add poc/phase-2/16-gaps-and-blocks.md
git commit -m "docs(phase-2): Gaps & Blocks findings (PoC deliverable, G1-G5)"
git push origin poc/phase-2-customer-service
```

---

## Phase 5 — Demos (after PR-1/2/3 land or on the integrated branch)

Record on `acme`. Run on the integrated `poc/phase-2-customer-service` branch (has all three capabilities + bridge fix).

**CRITICAL recording prereq — avoid the claude 2.1.92 OAuth screen** (from the bridge-fix session): a fresh per-agent `CLAUDE_CONFIG_DIR` triggers the OAuth login screen in 2.1.92 → `EagerBridge` returns `{:error, :oauth_required}` and the cc agent never binds. Before recording, ensure the cc agent **either** uses `~/.claude` directly (do **not** set `claude_config_dir` in the agent template) **or** has an `api_key_helper` configured (see `docs/runbook/cc-agent-config.md`).

**Verify the bridge is actually connected before recording** (server log):
- `grep 'CONNECTED TO Ezagent.AgentBridge.Socket' <server.log>` — the esr-bridge MCP reached the bridge.
- `grep 'JOINED agent_bridge' <server.log>` — the agent JOINed its channel.
Both must appear, and a customer message must produce a real cc reply, before capturing.

### Task 5.1: Record the 3 demos
**Files:** `docs/assets/demo*` (re-created)

- [ ] **Step 1: Start the server** (see `poc/phase-2/cc-agent-slow-bind-findings` appendix for the exact distributed command).

- [ ] **Step 2: Record chat / operator / soul**

```bash
DEMO_MODE=chat     DEMO_TENANT=acme DEMO_OUTDIR=docs/assets/demo          scripts/demo/record-clean.sh
DEMO_MODE=operator DEMO_TENANT=acme DEMO_OUTDIR=docs/assets/demo-operator scripts/demo/record-clean.sh
DEMO_MODE=soul     DEMO_TENANT=acme DEMO_OUTDIR=docs/assets/demo-soul     scripts/demo/record-clean.sh
```
Expected: each produces an `.mp4`/`.gif` + screenshots; verify the chat gets a real cc reply, takeover suppresses the AI, soul edit changes the next conversation.

- [ ] **Step 3: Commit the demos + a short README linking them**

```bash
git add docs/assets && git commit -m "docs(phase-2): re-record chat/operator/soul demos on acme (post bridge-fix)"
git push origin poc/phase-2-customer-service
```

---

## Out of scope (do NOT implement)
Curl fast-agent + `configure`; soul hot-update of live sessions; copilot; the long-lived/template lifecycle refactor (G2 — documented only); merging `feat/autoservice-cinnox`.

## Self-review notes
- Spec coverage: §2 base (Phase 3), §3 gaps (Phase 4), §4 lifecycle G2 (documented in Phase 4, not built — correct), §5/§6 takeover core hook (Phase 1 + PR-3 Allen flag), §8 PR split (Phase 3 + 0.2), §9 tests/demos (Phases 0/1/2/5). Covered.
- The only behavioral code change is Task 1.1 (takeover arg shape). Everything else is verify/package/document — matches the "A is already built" reality.
