# Codex Handoff — Socialware implementation (P1–P6, loose-audit model)

> **Mode:** loose-audit handoff (same as the 2026-06-06 credential-cascade handoff that
> delivered PR-0…PR-5). **Codex owns execution and self-merges PR-by-PR.** The author
> (Claude/Allen side) owns **PR review (codex adversarial + human), issue prompts, and E2E**,
> and periodically pulls `main` to audit. Codex does not wait for review to merge; the author
> files `socialware-audit` issues for anything found post-merge and Codex picks them up.

## 1. What to build

Socialware — fused backend-agent + real-time-render sessions on existing ezagent primitives.
Read these two documents IN FULL before starting; they are the source of truth:
- **Spec:** `docs/superpowers/specs/2026-06-07-socialware-design.md` (rev8, codex-approved-for-planning).
- **Plan:** `docs/superpowers/plans/2026-06-07-socialware-implementation.md` (P1–P6, task-by-task).

Do not re-litigate the locked contracts in the plan's "Locked contracts" section — they survived
six codex adversarial rounds.

## 2. Phase → PR mapping

Execute in order; each phase is one or more PRs. Later phases depend on earlier ones.
- **PR-SW1 (P1):** `ezagent_domain_socialware` app + `Behavior.Turn` + `:turns` slice + the
  state machine + `session.socialware` Kind + restart survival.
- **PR-SW2 (P2):** `:surface` slice (immutable versions + `approved` pointer) + operator HEEx
  `PageView`.
- **PR-SW3 (P3):** **core-schema PR** — `Message.visibility` + migration + visibility-aware
  `MessageStore` APIs + the settlement record (`:committed`-last) + the gated customer feed +
  the transactional outbox + customer-feed authorization + mode wiring (claim/copilot/takeover).
  *This is the leak-safety phase; its invariant tests are mandatory gates.*
- **PR-SW4 (P4):** customer frontend — streaming endpoint + React/json-render SPA + component
  registry + Sandpack `code` node + external/anon auth (port loom #480's rendering half).
- **PR-SW5 (P5):** first fused vertical plugin (`ezagent_plugin_<name>`) + SW-DEV + SW-USE E2E.
- **PR-SW6 (P6):** self-evolve — immutable config store + cascade pointer + repoint-rollback +
  SW-UPD E2E.

Split any PR further if it grows too large (e.g. P3 may be 2 PRs: core-schema + feed/auth). Keep
each PR independently testable.

## 3. Execution process (per PR)

1. `cd /Users/h2oslabs/Workspace/esr-ng && git fetch origin && git worktree add
   /private/tmp/sw-<phase> origin/main && cd /private/tmp/sw-<phase>` (a **fresh worktree off
   `origin/main` per PR** — never reuse a worktree across PRs; the per-worktree SQLite test DB
   drifts otherwise).
2. **Check open `socialware-audit` issues first** (`gh issue list --label socialware-audit
   --state open`) and fold any that apply to this phase into the work.
3. Implement task-by-task, **TDD** (Red → verify-fail → Green → verify-pass → Refactor →
   commit). Frequent commits.
4. Run the phase acceptance gate (the plan's "P<n> acceptance gate" + `MIX_ENV=test mix test`
   for the touched apps; full-umbrella before the core-schema PR-SW3 merges).
5. Open a PR, then `gh pr merge --admin --squash --delete-branch` (admin-merge is authorized in
   this repo; loose-audit = self-merge once your own gate is green).
6. `git worktree remove --force /private/tmp/sw-<phase>`.

## 4. Acceptance gate (the invariants that MUST hold — from spec §9 / plan)

A phase is not "done" until its invariant test passes (not on compile/merge alone):
- **P1:** state machine rejects every illegal transition; degenerate single-bot turn works; a
  turn survives cold restart (snapshot).
- **P2:** `:surface` versions immutable + retained; `approved` recoverable after a newer version
  + across cold restart; operator PageView renders latest.
- **P3 (leak-safety, mandatory):**
  - an `:operator_only` (takeover-assist) message **NEVER** reaches the customer feed via ANY
    path — live, history/snapshot, raw `MessageStore.recent_in_session`, session PubSub, raw
    `Publisher`, or an unfiltered `ExternalMirror` binding;
  - **crash matrix** — a crash after any single settle sub-write leaves the settlement
    `!= :committed`, so the customer sees neither chat nor page for that turn (no partial);
    replay re-drives to `:committed`;
  - customer-feed authz — a session-binding token scoped to (session A, workspace A) is **denied**
    session B, workspace B, and when expired/revoked; visibility-gating is applied AFTER the scope
    check, never instead of it;
  - backward-compat migration — legacy messages default `:customer_visible`.
- **P5 (SW-DEV + SW-USE):** a vertical author makes **zero core-code change**; **one settled turn
  drives both customer panes simultaneously in one viewport** (not separate tabs); in
  copilot/takeover the customer sees nothing until the operator approves; agent-browser
  screenshots ①②③ + restart + cross-scope denial.
- **P6 (SW-UPD):** config changes via the flow + observable in a later turn; rollback = repoint
  reverts deterministically, surviving restart.

## 5. Hard constraints

- **Test DB only** (`MIX_ENV=test`). **NEVER** `mix ecto.migrate` against dev/prod. **NEVER**
  touch running dev/prod docker containers or their data.
- Admin-merge authorized in this repo. Secrets never committed. Remote URLs use the Tailscale IP
  `100.64.0.27`, not localhost.
- **No silent defaults / shims / whitelists.** Let-it-crash; structural fixes.
- **PR-SW3 migration ordering** must be coordinated with the #17 cascade migrations (different
  tables, same `ezagent_core` migration sequence) to avoid a sequence conflict.
- Repo facts (don't trip on these): Chat domain is `ezagent_domain_instance_message` (NOT
  `ezagent_domain_chat`); new Behaviors `use Ezagent.Lifecycle` (handlers `/2`); dispatch via
  `Invocation.dispatch` (`?action=turn.<x>`); tests `EzagentCore.DataCase` +
  `Ezagent.LifecycleCase`. Full pattern index in the plan's "Repo facts" section.

## 6. Feedback loop (author side)

- The author periodically pulls `main`, runs the phase acceptance gates + the SW-USE/SW-UPD E2E
  (agent-browser), and files `gh issue create --label socialware-audit` for any regression or
  gap, pinging Allen on Feishu. A scheduled check watches socialware PRs/issues (mirrors the
  cascade-audit cron).
- If Codex orphans/stalls a PR, the author may finish it; bias toward bounded, verifiable
  sub-steps if a whole-phase job proves unreliable.
- **Codex companion review caveat:** any Elixir review run through the codex companion is in an
  isolated MIX_HOME with no deps — review **static only, skip mix/build/tests**, or the round
  yields nothing.
