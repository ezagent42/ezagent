# HANDOFF — hello-A de-hardcode (PR-1..4) + socialware MARKET surface (PR-5)

**Date:** 2026-07-22 · **From:** kimi (K3) · **To:** next implementer agent
**Spec (authoritative):** `docs/together/2026-07-22/plans/hello-A-impl-spec.md` on branch
`origin/spec/hello-A-de-hardcode`; a verbatim copy sits UNTRACKED at
`impl-spec-local-copy.md` in each worktree root (scratch — **do NOT commit it**).
**Base:** both branches cut from `origin/main@1ed5c739a` (includes main-red fixes #1519/#1520).

| Deliverable | Branch | Worktree |
|---|---|---|
| A: hello-A de-hardcode (PR-1..3; PR-4 describe-only) | `feat/hello-A-de-hardcode` | `/Users/h2oslabs/Workspace/esr-ng/.worktrees/hello-A-de-hardcode` |
| B: socialware market surface (PR-5) | `feat/socialware-market-surface` | `/Users/h2oslabs/Workspace/esr-ng/.worktrees/socialware-market-surface` |

---

## Environment gotchas (read FIRST — they cost hours)

1. **Shared test Postgres:** `127.0.0.1:55432` (user/pass `ezagent_pg_compat`), `max_connections=100`.
   Another concurrent suite (db `ezagent_pg_compat_testp195`) idles ~40 connections; each `mix test`
   boot grabs `pool_size: 40`. Two concurrent suites + anything else → `FATAL 53300
   too_many_connections`, which surfaces downstream as `:not_found` / `:invalid_cap_signature` /
   `absorb_not_committed` in cap/credential tests. **If you see those, check DB pressure first**
   (`PGPASSWORD=ezagent_pg_compat psql -h 127.0.0.1 -p 55432 -U ezagent_pg_compat -d postgres -c
   "select datname,state,count(*) from pg_stat_activity group by 1,2;"`) and rerun serially.
2. **Worktree A assets:** `apps/ezagent_web/assets/node_modules` is SYMLINKED to the main
   checkout's (needed or `mix test` in ezagent_web fails on tailwind build). Worktree B does NOT
   have this symlink yet — create it before running ezagent_web tests there:
   `ln -s /Users/h2oslabs/Workspace/esr-ng/apps/ezagent_web/assets/node_modules apps/ezagent_web/assets/node_modules`
3. `mix deps.get` already ran in both worktrees. `uv run` (never bare `python`); `pnpm` not `npm`;
   `mix format` ONLY touched files; never `cat >>` a `.ex` (use Edit); no back-compat shims.
4. **Skills are mandatory** before editing: read
   `/Users/h2oslabs/Workspace/esr-ng/.claude/skills/ezagent-developer/SKILL.md` (+ `references/capbac.md`,
   `references/ui-contract.md` for UI), `ezagent-socialware/SKILL.md`, `elixir-phoenix-helper/SKILL.md`.
5. **`lin_yilun` does not exist as seeded data anywhere in the repo** — it is deploy state (Allen's
   named fallback 官网 owner). Tests that exercise the owner path MUST create the row:
   `Ezagent.Users.create(uri, nil, [], email_verified: false)` AND make the owner a workspace
   MEMBER (`Workspace.add_member/2`) — an owner who is only a URI with a users row still fails
   `identity.absorb_cap` with `:no_such_actor` at materialize time (cap-grant needs a live actor;
   add_member pre-spawns the user Kind).

---

## Deliverable A — status

### PR-1 — COMMITTED `a3b973fc5` ✅
`feat(hello): single-source home workspace + credential bridge off system (hello-A PR-1)`
- New `EzagentPluginHello.home_workspace/0` (`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello.ex`)
  reading `:ezagent_plugin_hello, :home_workspace` (default `"ezagent"`, set in `config/config.exs`).
- Deleted `:ezagent_web, :hello_workspace` (config.exs) + its `"demo"` code fallback;
  `ChatFeedController.show_by_name/2` now reads the one key; router.ex comment updated.
- `CredentialBridge` destination = the accessor at RUNTIME (`destination_workspace/0` public reader),
  compile-time `@system_workspace "system"` attr deleted; zero-arity preserved (#185); moduledoc
  rewritten per spec §6.2 framing (Option B visibly rejected).
- Respec'd `hello_credential_source_test.exs` prod-entry to the configured home ws (kept
  `refute function_exported?(ensure_deepseek_source, 1)`); updated
  `chat_feed_controller_test.exs` to override the new key (with restore).
- New `HomeWorkspaceTest` split-brain invariant (accessor == bridge destination == "ezagent",
  one override moves both).
- **Gates at commit time:** `mix compile --warnings-as-errors` clean; tests 9 (hello) + 11
  (controller) green.

### PR-2 — IMPLEMENTED, UNCOMMITTED, tests ~90% green ⚠️
Uncommitted diff (8 files, +257/−85) in worktree A. What it does:
- `app.ex`: `create_app/3` honors `opts[:owner]` (default admin for legacy callers); owner flows
  through `Installation.owner_uri_for_template` (def's `owner_policy: :installer` ⇒ owner ==
  caller verbatim) into `spawn_kind(Session, owner_uri:)`; stale ":fixed to system admin" comment
  fixed. **Resolved ambiguity:** `install_template_installs` + `seed_hello_definition` actors STAY
  `User.admin_uri()` per spec §2.1 impl-constraint ("internal install/materialize actor may stay a
  trusted boot authority") — only the session OWNER + page-drive author became the ezagent
  principal; flagged in code comments.
- `fusion_seed.ex`: `@default_workspace "system"` deleted — reads `home_workspace()` inline;
  `run/1` + `apply_to/2` accept `:owner` (default admin); page turn + shell driven AS the owner;
  `ensure_workspace/2` creates with `created_by: owner` and — on FRESH create only —
  `Workspace.add_member(workspace, owner)` (the production-critical discovery above).
- `official_site_seed.ex`: full rewrite per §4/Addendum — `site_uri()` = `session://<home>/hello/
  ezagent-official`; `ensure/0` resolves owner FIRST (before the credential bridge can create the
  home ws admin-owned); `resolve_owner/0` = home ws `created_by`, falling back to
  `entity://<home>/user/lin_yilun` when absent OR == system-admin (NEVER admin); moduledoc rewritten.
- `template/hello_session.ex`: new `instantiate/4` threading `opts[:caller]` →
  `App.create_app(..., owner: caller)` (the any-user generalization).
- `behavior/workspace.ex` (domain): `create_session_via_class` calls `instantiate/4` with
  `caller: caller` when exported, else `/3` (unchanged for other classes).
- `application.ex`: boot comments/log → `/hello/ezagent-official`.
- Tests: `official_site_seed_test.exs` respec'd (ezagent/ezagent-official + owner assertions +
  split-brain leg; creates lin_yilun row in setup); NEW
  `test/integration/hello_workspace_isolation_test.exs` (§8 fail-before/pass-after):
  - FAIL-BEFORE (✅ passing): `system`-pinned 官网, ezagent member WITH explicitly-issued caps →
    genuine cast `session.send` fires `[:ezagent, :workspace, :denied]` telemetry
    (caller_ws=ezagent, target_ws=system) + call-mode `session.join` returns
    `{:error, :cross_workspace_denied}`.
  - PASS-AFTER (❌ last red): anon path — mint via `AnonUser.mint_for_public_session`, join, relay
    via `Delivery.dispatch_receive_call/3`, keyless stop acceptable.

**Exact current test state (last runs):**
- `official_site_seed_test.exs` — 2/2 GREEN (in the 4-test batch).
- `hello_workspace_isolation_test.exs` — FAIL-BEFORE green; PASS-AFTER red: my
  `ensure_workspace` helper called `Workspace.add_member` on an already-existing "ezagent"
  workspace left over from a sibling test whose store row was sandbox-rolled-back →
  `RuntimeError: workspace self-cap issuance failed: :not_found` (workspace.ex:642
  `workspace_self_ctx`). **Fix ALREADY EDITED but NOT YET RERUN:** the helper now only
  `add_member`s on a FRESH `Workspace.create` (`{:ok, _}` branch). Rerun:
  `mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/official_site_seed_test.exs
  apps/ezagent_plugin_hello/test/integration/hello_workspace_isolation_test.exs`
  If still red from stale-process/rolled-back-row interference: terminate the home-ws + lin_yilun
  Kinds at test start (see `terminate/1` helper in `hello_credential_source_test.exs`) before
  creating.
- `hello_credential_source_test.exs` — prod-entry intermittently `{:error, :not_found}`; PROVEN
  order-independent cause was the DB connection storm (green standalone on seed 7, red under
  53300 pressure). Re-verify when DB is quiet; if it persists, trace which bridge step returns
  bare `:not_found` (suspect `Cap.issue_for_action` → `LocalRuntime.ensure_started(workspace://ezagent)`
  when the ws process outlives its rolled-back row — same stale-process class as above).

**Remaining for A:**
1. Rerun PR-2 tests (above), then FULL hello suite `mix test apps/ezagent_plugin_hello/test`
   (was 95 tests / 4 failures mid-debug — expect 0 now, verify).
2. Commit PR-2 (suggested: `feat(hello): seed 官网 as ezagent-member session ezagent-official
   (hello-A PR-2)`).
3. Gates: `mix compile --warnings-as-errors`; `mix test apps/ezagent_core/test/invariants/` +
   `mix ezagent.check_invariants` — `behavior/workspace.ex` line shifts WILL trip line-anchored
   baselines; REGENERATE the affected baseline to match the tree (do not weaken). Also run
   `apps/ezagent_domain_workspace` + `apps/ezagent_web` suites touched by the diff.
4. **PR-3** (not started): fresh/isolated stack (docker fresh seed) — boot self-heals
   `ezagent-official` in `ezagent`, greeter relays (anon path), page renders at
   `/hello/ezagent-official`; agent-browser screenshot = sign-off bar (skill at
   `~/.agents/skills/agent-browser/SKILL.md`; remote URLs use 100.64.0.27). Harness precondition
   (Addendum should-fix #1c): seed the home workspace + a real non-admin founder user FIRST.
5. **PR-4: DESCRIBE-ONLY — do NOT execute.** `scripts/refresh_hello_site.exs` intentionally left
   on `system/hello/web` (§7 assigns it to coordinator-gated PR-4). Rename parity audit for code:
   only historical mentions remain (official_site_seed.ex moduledoc) — diff == ∅ for live literals.

---

## Deliverable B (PR-5) — status: implemented, UNVERIFIED ⚠️

A subagent implemented per spec §15 then died on provider quota before running ANY gate.
Uncommitted diff in worktree B (15 modified + 3 new files):
- NEW `lib/ezagent/world/market_actions.ex` (193 lines) — publish/retract/install actions.
- NEW `assets/src/components/Market.tsx` (170) + world wiring (`main.tsx`, `slots.manifest.json`,
  `world_ia.js`, `SessionsTable.tsx`), `world/routes.ex`, `navigation.ex`, `slot_registry.ex`,
  `state_contract.ex`, `dispatch_contract.ex`, `workspace_plugin_data.ex`, `world_live.ex`,
  `ezagent_web/router.ex` (market route).
- NEW `test/ezagent/world/market_surface_test.exs` (323) + e2e fixture additions.
- `docs/futures/todo.md` updated (out-of-scope list).

**Verify BEFORE trusting anything:**
1. Read `market_actions.ex` against the §15.3 HARD rules: browse list MUST come from
   `DefinitionRegistry.list/1` / `socialware_rows` (never raw `ConfigStore.list_current_objects`);
   install MUST go through `SocialwareInstall.prepare_create_template` with `{config_id,
   content_hash}`; 上架 MUST thread the REAL `current_entity_uri` as actor_uri + REAL
   `PresenterCaps.load(socket)` caps through `DefinitionEditor.save_authored_definition` (a
   system/service actor_uri bypasses the #165 gate — the single highest-risk check);
   下架 MUST use `ConfigGovernance.Socialware.retract/2` / `restore/2` (NEVER
   `DefinitionRegistry.set_retracted/4`).
2. Create the node_modules symlink (gotcha #2), `mix compile --warnings-as-errors`, build world
   assets if the world test setup needs it.
3. Run `mix test apps/ezagent_plugin_world/test` (esp. `market_surface_test.exs` — §15.5
   non-vacuous: non-admin DENIED publish end-to-end on a TENANT ws; admin allowed; retract →
   `:socialware_revision_retracted`; private foreign def invisible + non-installable).
4. `mix test apps/ezagent_core/test/invariants/` + `mix ezagent.check_invariants` (regenerate
   baselines if the world diff trips line anchors).
5. Agent-browser screenshot of the market page → `evidence/market-surface/` (create dir), then
   ONE commit `feat(socialware): add market browse/install + publish/retract surface (PR-5)`.
   Do NOT commit `impl-spec-local-copy.md`.

---

## Final report the coordinator expects (both deliverables)
Branch · commit hashes + one-liners · every gate run with pass/fail counts · spec ambiguities
resolved (so far: install/seed actors stay admin-trusted per §2.1 impl-constraint; owner-fallback
user must exist AND be a member — seed now ensures membership on fresh create;
`hello_credential_source_test` flakiness traced to shared-DB connection storms, not code) ·
screenshot paths for PR-3 + PR-5.
