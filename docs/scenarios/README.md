# E2E scenarios — master catalog

> **Status**: draft — 2026-05-28. Author: Claude, per Allen Feishu 12:32
> directive *"请先整理 e2e scenarios 的文档，说明应该有哪些 E2E 场景"*.
>
> Bilingual lockstep mirror: [`README.zh_cn.md`](./README.zh_cn.md).
>
> **What this is**: the master catalogue of every E2E scenario ezagent
> needs to validate end-to-end — across UI, CLI, Feishu, agent flavors,
> persistence, recovery, and plugin authoring. Each scenario is one
> sub-directory `<NN>-<slug>/scenario.md` (+ ZH mirror).
>
> **What this is NOT**: an implementation plan. Scenarios that are
> "not-implemented" mean we don't have a runnable E2E harness for them
> *yet* — many of the underlying actions DO work in production (Allen
> exercises them manually), but the codified scenario does not exist
> as a runbook + invariant test combination.

---

## 0. Purpose

Per Allen 2026-05-28: as Phase 2 (per-domain Behavior migrations on
top of PR #451 Router/Behavior/Kind primitives) begins, the test
matrix has fragmented across:

- Integration tests (`apps/*/test/integration/*`) — 57 files, but the
  catalogue of *what they collectively assert* is unmapped.
- Operator runbooks (`docs/runbook/*`) — 4 files; cc-agent + 4-agent
  comprehensive only.
- Manual smokes recorded as PR evidence (`docs/notes/evidence/*`) — ad
  hoc, no master index.
- Phase-specs `docs/phase-specs/phaseN/VERIFICATION.md` — bounded to
  each phase, no cross-phase rollup.

This file is the **single rollup**. Every Phase 2+ PR's `VERIFICATION`
section should be answerable as "scenarios NN, MM" in this catalog.

---

## 1. How to run a scenario

Each `<NN>-<slug>/scenario.md` declares:

- **Pre-conditions** — boot state, login state, env vars, seed data.
- **Actors** — `entity://user/...`, `entity://agent/...` URIs in play.
- **Steps** — concrete UI clicks / CLI commands / Feishu inputs.
- **Expected outcomes** — final state assertions + audit-trail rows.
- **Failure modes** — what to deliberately break to verify graceful
  degradation.
- **Cross-references** — PRs / SPECs / tests / open bugs.

### 1.1 Standard preconditions

Most scenarios assume:

| Resource | Value |
|---|---|
| Phx server | `http://100.64.0.27:10042` (Tailscale IP, Allen is remote) |
| Local-only URL | `http://127.0.0.1:10042` (operator-local; LV will load but Feishu webhooks need the public sidecar) |
| Allen's Feishu chat_id (DM) | `oc_d9b47511b085e9d5b66c4595b3ef9bb9` |
| Dev / smoke Feishu chat_id | `oc_83a4f1ff0bf627ffe26aa60647e5b04a` |
| System admin | `entity://system/user/admin` (workspace-first per PR #131 — NOT `entity://user/system/admin`). **A FRESH stack has NO admin password** — the entrypoint does not set one, so first login fails until you set it: `mix ezagent.user.set_password entity://system/user/admin --password <pw>`. (The shared dev stack had `e2e-admin-2026` set manually 2026-05-30; a disposable/fresh stack does not.) **Log in with the admin's EMAIL + password** (the seeded admin email is `admin@ezagent.chat`) — login is email+password since #87 (URI/username login was retired); the login form has no URI field. |
| Self-serve creds (no asking Allen) | Bootstrap an admin token: `mix ezagent.user.token entity://system/user/admin --mint` → use `EZAGENT_USER_TOKEN=<tok> EZAGENT_ENTITY_URI=entity://system/user/admin mix ezagent user set_password --user <uri> --password <pw>` to set a login password, or `mix ezagent user create` + `set_password` to mint a throwaway test user. Never block on asking Allen for a password (his directive 2026-05-30). |
| Default workspace | `workspace://system` (post-#398 rename; `workspace://default` is forbidden alias per PR #399) |

### 1.2 Tooling

| Tool | Use |
|---|---|
| `mix ezagent.bootstrap` | idempotent DB-migrate + plugin install. Run once after `mix ecto.create`. |
| `mix phx.server` | umbrella boot. Allen runs this in tmux session `esrd`. |
| `mix ezagent <behavior> <action>` | CLI dispatch (post-PR #386 rename from `mix esr`). |
| `mix ezagent.demo.seed_cc_sandbox` | seed credentials into a sandboxed `.claude/` per cc-agent. |
| `agent-browser` | the **mandatory** verification surface for any UI scenario per `feedback_agent_browser_debug`. |
| Feishu Sidecar | external mirror sender for outbound; webhook receiver for inbound. |
| `codex_app_server_thread_repro.py` | the codex bridge UDS WS regression smoke (PR #441). |

### 1.3 Verification surface — hard rule

Per `feedback_esr_e2e_standards`: every E2E scenario that touches UI
or Feishu **MUST** include an agent-browser screenshot (LV) + a
Feishu chat capture (when applicable). Log-only verification is
**not** sufficient for sign-off. cc-openclaw Feishu DMs (the
operator's own channel) DO NOT count — only the ezagent Feishu
sidecar replying counts.

---

## 2. Status taxonomy

| Symbol | Status | Meaning |
|---|---|---|
| ✅ | `implemented-and-tested` | Runbook exists + automated test covers the happy path + at least one failure mode. Allen has signed off on the manual smoke. |
| ⚠️ | `implemented-with-gaps` | Production code path works but the scenario lacks one of: codified runbook / automated test / failure-mode coverage / cross-reference index. |
| ❌ | `not-implemented` | The user-visible action does not work end-to-end. May be a known gap (e.g. `/admin/agents` 404 today) or future scope. |
| ⏳ | `partially-implemented` | Production code exists but is gated behind a flag, requires unmerged PRs, or only covers a subset of flavors / cases. |

A scenario is **only** ✅ if its `scenario.md` cites an `apps/.../test/...`
test path + a runbook path + at least one PR-evidence screenshot. The
2026-05-04 `feedback_esr_e2e_standards` rule.

---

## 3. The 18 categories

| # | Category | Scenarios | Primary surface |
|---|---|---|---|
| 1 | [Auth / Identity](#category-1--auth--identity) | 01-04 | LV `/login`, `/admin/users` |
| 2 | [Agent lifecycle](#category-2--agent-lifecycle) | 05-08 | LV `/admin/agents`, CLI `ezagent agent`, PTY |
| 3 | [Session flows](#category-3--session-flows) | 09-11 | LV `/admin/sessions/:uri`, Feishu bind |
| 4 | [Feishu integration](#category-4--feishu-integration) | 12-13 | Sidecar webhooks + outbound |
| 5 | [Capability management](#category-5--capability-management-capbac) | 14-15 | LV `/admin/caps`, CLI `ezagent capability` |
| 6 | [Cross-workspace](#category-6--cross-workspace) | 16-17 | LV workspace dropdown, multi-WS user |
| 7 | [PTY interaction](#category-7--pty-interaction) | 18-19 | LV `/admin/agents/:uri/terminal` |
| 8 | [Workspace management](#category-8--workspace-management) | 20 | LV `/admin/workspaces`, CLI `ezagent workspace` |
| 9 | [Template + version tags](#category-9--template--version-tags) | 21 | LV `/admin/templates`, CLI `ezagent template` |
| 10 | [Routing](#category-10--routing) | 22 | LV `/admin/routing`, `RoutingRegistry` |
| 11 | [External mirror bindings](#category-11--external-mirror-bindings) | 23 | `ExternalMirrorWorker`, Feishu sidecar |
| 12 | [Destroy + cleanup cascade](#category-12--destroy--cleanup-cascade) | 24 | Saga-style facade-level cascades |
| 13 | [Recovery + boot](#category-13--recovery--boot) | 25 | `phx restart`, `StateRebuilder`, `BootReconciler` |
| 14 | [Codex bridge](#category-14--codex-bridge) | 26 | `codex_app_server_thread_repro.py`, UDS WS |
| 15 | [Resource management](#category-15--resource-management) | 27 | Sandboxed `.claude/`, api-keys, write_path |
| 16 | [Audit + observability](#category-16--audit--observability) | 28 | `EventLog`, telemetry, `/admin/events` |
| 17 | [Admin LV pages](#category-17--admin-lv-pages) | 29 | All `/admin/*` LVs + cmdK |
| 18 | [Plugin author DX](#category-18--plugin-author-dx) | 30 | `use Ezagent.Behavior`, effects, LegacyAdapter |

---

## 4. Scenario index — flat list

> Cluster overview: [`homesite-journey.md`](./homesite-journey.md) maps the homesite
> user journey (stages 0–5) across scenarios 36–39. Task split:
> [`homesite-handoff.md`](./homesite-handoff.md) (官网/hello → zyli, world → zyli).

| # | Title | Cat | Status | Test path |
|---|---|---|---|---|
| 01 | [Magic-link email login](./01-magic-link-login/scenario.md) | 1 | ⚠️ | `magic_link_invariants_test.exs` |
| 02 | [Password login (admin)](./02-password-login-admin/scenario.md) | 1 | ✅ | `magic_link_invariants_test.exs` + Allen 2026-05-21 sign-off |
| 03 | [Token-based CLI auth (mint / list / revoke)](./03-cli-token-auth/scenario.md) | 1 | ⚠️ | `cli_dispatch_test.exs` (no User-Kind tests yet — todo #1 HIGH-1) |
| 05 | [cc agent — spawn → first-run → message → reply](./05-cc-agent-roundtrip/scenario.md) | 2 | ✅ | `cc_agent_admin_reply_e2e_test.exs` |
| 06 | [codex agent — spawn → bridge → reply](./06-codex-agent-roundtrip/scenario.md) | 2 | ⚠️ | `orchestrator_mcp_e2e_test.exs` + `codex_app_server_thread_repro.py` |
| 07 | [curl agent — spawn → DeepSeek round-trip](./07-curl-agent-deepseek/scenario.md) | 2 | ✅ | PR #126 evidence + `curl-agent-walkthrough.md` |
| 08 | [4-agent comprehensive (cc → curl → np → user)](./08-4agent-comprehensive/scenario.md) | 2 | ✅ | `comprehensive_4agent_e2e_test.exs` + `docs/runbook/4-agent-comprehensive-e2e.md` |
| 09 | [Create session via LV + add member](./09-session-create-lv/scenario.md) | 3 | ✅ | `session_create_orchestrator_unified_test.exs` |
| 10 | [@-mention dispatch — mention-gated routing](./10-mention-gated-routing/scenario.md) | 3 | ✅ | `mention_gated_routing_test.exs` + `mention_failed_notification` PR #406 |
| 11 | [Cross-session @-mention is rejected](./11-cross-session-mention-rejected/scenario.md) | 3 | ✅ | `category_10_scenarios_10_11_mention_routing_test.exs` "Scenario 11" (4 tests) + PR #406 `mention_failed_notification` |
| 12 | [Feishu chat ↔ session bind + outbound](./12-feishu-bind-outbound/scenario.md) | 4 | ✅ | PR #420 + `external_mirror/facade_test.exs` |
| 13 | [Feishu inbound message → routed to agent](./13-feishu-inbound-routing/scenario.md) | 4 | ✅ | `feishu_chat_binding_test.exs` + `inbound_chat_lookup_test.exs` |
| 14 | [Grant cap via LV (action-axis)](./14-grant-cap-action-axis/scenario.md) | 5 | ✅ | `cap_action_axis_invariant_test.exs` + PR #410 |
| 15 | [Revoke cap + non-admin denial](./15-revoke-cap-non-admin-denial/scenario.md) | 5 | ✅ | `caps_denial_e2e_test.exs` + `non_admin_grant_flow_e2e_test.exs` |
| 16 | [Switch workspace + visibility filter](./16-workspace-switch-visibility/scenario.md) | 6 | ✅ | `workspace_isolation_test.exs` + PR #434 |
| 17 | [User with caps in multiple workspaces](./17-multi-workspace-user/scenario.md) | 6 | ✅ | `scenario_17_multi_workspace_user_test.exs` (4 tests) + visibility/membership invariants + `session_principal_test.exs:147` (default-WS) |
| 18 | [PTY first-run theme dialog handling](./18-pty-first-run/scenario.md) | 7 | ✅ | `cc_agent_admin_reply_e2e_test.exs` + PR #385 |
| 19 | [PTY restart preserves cwd + orphan reap](./19-pty-restart-orphan/scenario.md) | 7 | ✅ | PR #385 + #388 + `sandbox_destroy_test.exs` |
| 20 | [Workspace create + add member + destroy](./20-workspace-lifecycle/scenario.md) | 8 | ⚠️ | `add_member_spawn_then_grant_test.exs` + PR #417 (no destroy E2E) |
| 21 | [Template version tag + instantiate](./21-template-version-tag/scenario.md) | 9 | ⏳ | `add_template_invokes_test.exs` — version tags NOT YET shipped |
| 22 | [Routing rule CRUD + precedence](./22-routing-crud/scenario.md) | 10 | ✅ | `routing_consolidation_invariant_test.exs` + `routing_boot_test.exs` |
| 23 | [ExternalMirrorWorker re-subscribe on cold-spawn](./23-external-mirror-resubscribe/scenario.md) | 11 | ✅ | PR #420 fix for task #49 |
| 24 | [Destroy cascade — agent / session / workspace](./24-destroy-cascade/scenario.md) | 12 | ⚠️ | `scenario_24_destroy_cascade_test.exs` (10 tests: saga cascade + compensation) — full workspace-level 3-level cascade E2E still the gap |
| 25 | [Phx restart — snapshot rebuild + ExternalMirror](./25-phx-restart-rebuild/scenario.md) | 13 | ✅ | `snapshot_restart_test.exs` + `session_survives_restart_test.exs` + `cap_action_axis_snapshot_restore_test.exs` |
| 26 | [Codex bridge UDS WS thread continuity (PR #441 regression)](./26-codex-bridge-uds-ws/scenario.md) | 14 | ✅ | `orchestrator_mcp_bridge_test.exs` + `scripts/codex_app_server_thread_repro.py` |
| 27 | [Per-agent api-keys + sandbox isolation](./27-api-keys-sandbox/scenario.md) | 15 | ⚠️ | `cc_agent_sandbox_credentials_test.exs` — Bug A (config_dir atomic setup) deferred |
| 28 | [Dispatch audit row (invocations → EventLog)](./28-dispatch-audit/scenario.md) | 16 | ⏳ | `Audit.@events` covered; EventLog migration is Phase 2+ |
| 29 | [Admin LV smoke — registry / snapshots / templates / routing / cmdK](./29-admin-lv-smoke/scenario.md) | 17 | ⚠️ | per-LV manual smoke; `/admin/agents` returns 404 (gap) |
| 30 | [Plugin author DX — write a new Behavior with effects](./30-plugin-author-behavior/scenario.md) | 18 | ✅ | Phase 1-4 migration complete (PRs #451-#469); E2E test #468 exercises greenfield Behavior writes against the new contract |
| 31 | [Home backup / restore / migration](./31-home-backup-restore-migration/scenario.md) | 13 | 🚧 | see scenario doc |
| 32 | [Feishu @-mention → orchestrator dispatch](./32-feishu-mention-orchestrator-dispatch/scenario.md) | 3 | 🚧 | `scenario_32_mention_orchestrator_dispatch_test.exs` (deterministic) + live runbook |
| 33 | [Full-star — orchestrator dispatches ALL flavors (cc + codex + curl)](./33-full-star-orchestrator-all-flavors/scenario.md) | 3 | 🚧 | `scenario_33_full_star_test.exs` (deterministic) + live runbook |
| 34 | [Sender-locked relay (传话游戏) — legend + rule-set + prompt-template, no baton](./34-sender-locked-relay/scenario.md) | 3 | 🚧 | `scenario_34_sender_locked_relay_test.exs` (deterministic, 8 tests green) + `scenario_34_*_live_test.exs` (live runbook, `@tag :live`) |
| 35 | [External-user anonymous access (membership-only)](./35-external-user-anon-access/scenario.md) | 1 | 🚧 | deterministic tier PARTIAL + live agent-browser runbook — see scenario doc (issue #51) |
| 36 | [Homesite visitor journey — browse → login-gate → gated CTAs](./36-homesite-browse/scenario.md) | 1 | 🚧 | design spec — recordable vs `docs/website-demo/v1` mock; live recorder + test pending |
| 37 | [Homesite dialog ↔ world session (bidirectional sync)](./37-homesite-dialog-world-sync/scenario.md) | 3 | 🚧 | design spec (journey stage 3) — backend dialog wiring not connected; world→page via placeholder |
| 38 | [Share / deploy — invite others into the SAME session (group chat)](./38-share-deploy-same-session/scenario.md) | 3 | 🚧 | design spec (journey stage 4) — deploy = same session, member, history kept |
| 39 | [Try world → re-create the homesite session as a new owned session](./39-redeploy-publish-fork-session/scenario.md) | 3 | 🚧 | design spec (journey stage 5) — enter world, re-create a new owned session, no history |

---

## 5. Category notes

### Category 1 — Auth / Identity

Production paths: magic-link via `Ezagent.Web.MagicLinkController`,
password via `Ezagent.Behavior.Identity` (User Kind), CLI tokens via
`Ezagent.Behavior.UserTokens` (`mint` / `list` / `revoke`).

Open gaps:
- `feedback_uuid_is_canonical_identifier` (2026-05-12) — username is
  mutable display-only; cap-key resolves username → UUID. Need a
  scenario for "user renames + caps still hold".
- Token revoke + active-CLI-session: token revoke does not currently
  invalidate an in-flight CLI dispatch.

### Category 2 — Agent lifecycle

Five flavors today: `cc`, `codex`, `curl`, `np`, `echo`. Each
declared via `agent_flavors/0` in its plugin (Decision Log #133-#134).
Flavor → Template Class resolution lives in `AgentFlavorRegistry`.

The 4-agent comprehensive (scenario 08) is the cross-flavor integration
test. cc + curl + np + echo + codex each have a `plugin_contract_test.exs`
proving they declare their flavors correctly.

### Category 3 — Session flows

Unified create path lands in PR #408 (`Behavior.Workspace :create_session`).
Member operations route through workspace caps. Mention-gated routing
(PR #422 + SPEC `mention-gated-routing`) is the default; explicit
routing rules override.

Cross-session leak prevention is enforced by `RoutingResolver` via
the `$session_members` magic receptor token (Decision #120).

### Category 4 — Feishu integration

Sidecar architecture (separate process, JSON-RPC bridge). Two
modes:
1. **Inbound**: Feishu webhook → sidecar → `FeishuAdapter.receive/1`
   → routing rule → agent action.
2. **Outbound**: agent emit → `ExternalMirrorWorker` → sidecar →
   Feishu app send_message.

Per `feedback_register_lookup_key_parity` (2026-04 lesson), inbound
chat lookup tests cover the `chat_id → session_uri` mapping (PR-EM-1).

### Category 5 — Capability management (CapBAC)

Cap shape post-PR #410 (action-axis SPEC `capability-action-axis`):
`{kind, behavior, action, instance, workspace_uri}` — 5 dimensions.
`matches?/2` enforces all 5. `cap_for_action/3` per-Kind authoritative.

Admin holds `%{kind: :any, behavior: :any, action: :any, instance:
:any, workspace_uri: :any}` (decision #99). The
`feedback_let_it_crash_no_workarounds` rule forbade a wildcard
fallback in `:any`; the admin cap is structural, not a default.

Open gap: action-selector dropdown on `/admin/caps` LV grant form
(todo entry "Entity-caps LV grant form needs action-selector dropdown");
admin-role exemption is the current bridge.

### Category 6 — Cross-workspace

Cap-based visibility replaces the old `visible` field (PR #434, SPEC
`workspace-cap-based-visibility`). A user sees a workspace iff they
hold ANY cap with `workspace_uri: <ws_uri>` (or `:any`).

Workspace prefix invariant (PR #417): every entity URI carries its
owning workspace as a path segment, e.g.
`entity://agent/<workspace>/<agent_name>`. `add_member` validator
enforces this.

### Category 7 — PTY interaction

cc agent + np agent + python agent (codex too via the new bridge)
all spawn PTY children. Orphan reap (PR #385) uses pid-files (PR #388
replaced the `ps`-walk). State machine for PTY phase (PR #390): boot
→ first-run → ready → working → idle.

cc agent first-run theme dialog: the spawned `claude` shows a TUI
theme picker on first launch; ezagent's PTY handler types
`<Enter>` blindly to dismiss it (PR #390).

### Category 8 — Workspace management

CRUD + member ops. Destroy with active sessions is currently NOT
exercised end-to-end — see `lifecycle_terminate_test.exs` for the
terminate action body but no full cascade test.

Default workspace is `workspace://system` post-PR #398 (Allen 2026-05-26
correction from the earlier `default` alias).

### Category 9 — Template + version tags

Templates are Kind today (per-template snapshot strategy `{:snapshot,
:on_change}`). Version tags are NOT YET shipped — the closest is
template_class registration via `AgentFlavorRegistry`. A future SPEC
will add tags + rollback.

### Category 10 — Routing

`RoutingRegistry` is a third Registry family (Decision #95) with
owner-pid checks (runtime writes from admin). 5-leaf Matcher AST
(`mention` / `from` / `text_contains` / `text_matches` / `always`)
+ 3 combinators (and / or / not, PR #118 in Decision #118).

Routing rule precedence: in-DB order + `enabled` flag (PR #120,
Decision #120). System-default `always() → ["$session_members"]`
rule is admin-disable-only, never deletable.

### Category 11 — External mirror bindings

`ExternalMirrorWorker` per-binding GenServer. PR #420 fixed the cold-spawn
re-subscribe gap (task #49) — when a Session re-spawns from snapshot,
the corresponding worker must re-subscribe to the session publisher.

Multi-app-id support: same `chat_id` can be bound to multiple bots; the
worker registry keys on `{chat_id, app_id}`.

### Category 12 — Destroy + cleanup cascade

Saga-style cascades land with PR #451's `SagaRunner`. Phase 2 will
exercise this end-to-end. Today: facade-level destroy is mostly
single-step (no compensation on partial failure).

### Category 13 — Recovery + boot

`StateRebuilder` (PR #451) replays `EventLog` rows to reconstitute
Kind state on boot. `BootReconciler` (in `ExternalMirror`) sweeps
`bindings` rows + ensures every active binding has a live worker.

`session_survives_restart_test.exs` covers session-side; analogous
test for ExternalMirrorWorker landed in PR #420; cc agent
orchestrator respawn-from-snapshot covered in
`orchestrator_mcp_e2e_test.exs`.

### Category 14 — Codex bridge

Bridge sidecar runs as a separate process; ezagent + bridge share
`thread_id` via JSON-RPC over a UDS WebSocket (PR #441 fix). The TUI
resume path was fixed in PR #437. Operator smoke:
`scripts/codex_app_server_thread_repro.py` + `scripts/codex_bridge_thread_smoke.py`.

### Category 15 — Resource management

Per-agent api-keys (PR #389 flipped from User to Agent Kind).
Per-agent `claude_config_dir` (sandboxed `.claude/`). Bug A
("config_dir atomic setup") is deferred — when a cc agent restarts
mid-setup, the partially-populated config_dir is left dangling.
SPEC #445 §3.3 lifts these to first-class `resource://` URIs in
Phase 2 PR 8.

### Category 16 — Audit + observability

Today: every `Invocation.dispatch/1` emits telemetry
`[:ezagent, :authz, granted | denied]` + writes an `invocations`
row. Phase 1 PR #451 adds `EventLog` as the canonical events table
(Phase 2 migrates `invocations` → `EventLog`).

`/admin/events` LV does not exist yet — observation is via SQLite
queries or telemetry dashboards.

### Category 17 — Admin LV pages

| Path | Coverage |
|---|---|
| `/admin` | ✅ workspace dropdown + chat + dispatch UI |
| `/admin/users` | ✅ create / set_password / mint_token (CLI parity gap — todo HIGH-4) |
| `/admin/caps` | ✅ list + grant + revoke (action-selector form gap — todo) |
| `/admin/workspaces` | ✅ create / add_member / destroy (last untested E2E) |
| `/admin/templates` | ✅ list + create + form (auto-derived from Template Class) |
| `/admin/routing` | ✅ rules CRUD + precedence + enable/disable |
| `/admin/registry` | ✅ live KindRegistry snapshot |
| `/admin/snapshots` | ✅ kind_snapshots browse + dump + clear |
| `/admin/agents` | ❌ returns 404 today — gap, scenario 29 flags it |
| `/admin/sessions/:uri` | ✅ chat + member roster + dispatch |
| `/admin/sessions/:uri/routing` | ✅ per-session routing rules (PR #418 fix) |
| `/admin/agents/:uri/terminal` | ✅ live PTY mirror |
| cmdK search | ⚠️ shipped (SPEC `v1-uri-pickers-and-cmdk`) — coverage of all action verbs not tested |

### Category 18 — Plugin author DX (Router/Behavior/Kind — Phase 1-4 complete)

Per SPEC #445 §4 (Phase 1-4 migration PRs #451 / #453 / #454 / #462 / #463 / #464 / #469 all merged 2026-05-28), plugin authors write `use Ezagent.Behavior` modules with `action :foo, args: ..., returns: ..., caps: [...]` macros + `def handle_foo(args, ctx)` returning effects. Phase 1 (PR #451) shipped the primitives + `LegacyBehaviorAdapter` as a transitional bridge; Phase 2 (PR #462 + #463) migrated all 34+ Behaviors to new contract; **Phase 3 (PR #464) deleted `LegacyBehaviorAdapter` and retired `Behavior.invoke/4` to `@optional_callbacks`**; Phase 4 (PR #469) polished Kind.Server metadata + audit fix. 165 E2E tests passing (#465-#468).

Scenarios for this category target:
1. Writing a new Behavior (greenfield) — exercises the action macro, effects vocabulary, cap declaration, EventLog emission. Scenario #30 is the canonical exercise.
2. (HISTORICAL — Phase 1-2 only) Migrating an existing `Behavior.invoke/4` via LegacyAdapter — proves the adapter was transparent to callers. After Phase 3 (PR #464) deleted the adapter, this scenario is no longer runnable; it remains in the catalog as git archaeology.
3. Saga compensation pattern — declare a multi-step saga, verify compensation order on partial failure (note: compensation is best-effort partial restore, NOT atomic rollback — codex r2 HIGH-5 closure; SPEC §5.4).

---

## 6. Prioritization — top 5 (historical: Phase 2 test infra investment)

**Status update (2026-05-28)**: All Phase 1-4 migration PRs (#451 / #453 / #454 / #462 / #463 / #464 / #469) merged + 165 E2E tests pass (#465-#468). The list below was the prioritization rationale BEFORE Phase 2 implementation; preserved for archival reasons. Top scenarios remain the canonical exercises for any future Behavior contract change.

| Rank | Scenario | Why (historical, pre-Phase-2) |
|---|---|---|
| **1** | **30 — Plugin author DX (greenfield Behavior)** | Phase 2's done-gate is plugin authors writing new Behaviors without core knowledge. Status: shipped in PR #468. |
| **2** | **25 — Phx restart rebuild** | Snapshot-based recovery is the safety net for the 34+ Behavior migration. If StateRebuilder regresses, every retrofitted Behavior is at risk. Status: shipped in PR #466. |
| **3** | **24 — Destroy cascade w/ Saga** | PR #451's `SagaRunner` is untested in production. Phase 2 will use it for multi-step Behavior migrations; need a baseline scenario before that. Status: shipped in PR #466. |
| **4** | **05 + 06 + 07 — cross-flavor agent roundtrip** | The 3 most-used agent flavors. Any Phase 2 Behavior touching `chat.send` / `chat.receive` must regression-pass these. Status: shipped in PR #468. |
| **5** | **14 — cap action-axis grant** | Cap-axis is THE invariant for plugin isolation (a wildcard cap defeats the model). Any Phase 2 Behavior migration must preserve action-narrow grants. Status: shipped in PR #465. |

Secondary investments (post-top-5):
- **17 — Multi-workspace user** — ✅ done (2026-06-14): scenario-level e2e +
  visibility/membership invariants; default-workspace-at-login resolved (Phase 9 PR-5).
- **21 — Template version tags** — SPEC pending; not blocking Phase 2
  but blocking Phase 3.

> Scenario 04 (cross-workspace delegated token) was **removed 2026-06-14** (YAGNI, Allen):
> no current use case, no implementation, and "system controls other workspaces" already works
> via system-membership cross-workspace authority (`Capability.cross_workspace?/2`) — no token
> delegation. If codex-v2 ever needs delegated "acting-as" dispatch, it starts as a fresh
> brainstorm + SPEC, not a resurrected scenario stub.

---

## 7. References

### Top-level architecture

- [`ARCHITECTURE.md`](../../ARCHITECTURE.md) — v0.4 final, Decision Log #1-#137
- [`IMPLEMENTATION_ROADMAP.md`](../../IMPLEMENTATION_ROADMAP.md) — 7-phase plan
- [`GLOSSARY.md`](../../GLOSSARY.md) — disambiguation reference
- [`CLAUDE.md`](../../CLAUDE.md) — project-level Claude instructions

### Phase 1 (Router/Behavior/Kind) — merged 2026-05-28

- SPEC PR — `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md`
- Integration PR #451 — feat/router-behavior-kind-phase-1-v2
- Sub-PRs #447 (EventLog), #448 (SnapshotStore), #449 (SagaRunner), #450 (Router + Behavior + Kind + LegacyAdapter)

### Existing scenario sources (rolled up here)

- [`docs/runbook/4-agent-comprehensive-e2e.md`](../runbook/4-agent-comprehensive-e2e.md) — scenario 08
- [`docs/runbook/cc-agent-e2e.md`](../runbook/cc-agent-e2e.md) — scenarios 05, 18, 19
- [`docs/runbook/cc-agent-config.md`](../runbook/cc-agent-config.md) — scenario 27
- [`docs/notes/curl-agent-walkthrough.md`](../notes/curl-agent-walkthrough.md) — scenario 07
- [`docs/notes/caps-e2e-design.md`](../notes/caps-e2e-design.md) — scenarios 14, 15
- [`docs/notes/demo-followup-walkthrough.md`](../notes/demo-followup-walkthrough.md) — scenarios 09, 12
- [`docs/futures/todo.md`](../futures/todo.md) — open gaps cross-referenced from scenario "Notes" sections

### SPECs that define expected behavior

- `2026-05-22-plugin-authoring-contract.md` — Category 18 contract
- `2026-05-22-mention-gated-routing.md` — Scenario 10
- `2026-05-23-capability-registry.md` — Scenarios 14, 15
- `2026-05-24-caps-data-ownership-v2.md` — Scenario 16
- `2026-05-24-external-mirror-domain.md` — Scenarios 12, 13, 23
- `2026-05-25-agent-create-cli-gui-parity.md` — Scenarios 03, 05-08
- `2026-05-26-session-create-orchestrator-unified.md` — Scenario 09
- `2026-05-27-capability-action-axis.md` — Scenario 14
- `2026-05-27-workspace-cap-based-visibility.md` — Scenario 16
- `2026-05-28-router-behavior-kind-architecture.md` — Scenario 30

### Open feedback rules cited by scenarios

- `feedback_esr_e2e_standards` — verification surface hard rule
- `feedback_agent_browser_debug` — UI verification mandate
- `feedback_open_terminal_first_when_debugging` — debugging discipline
- `feedback_bilingual_docs_convention` — ZH lockstep convention this catalogue follows

---

## 8. How to add a new scenario

1. Pick the next free `NN` (zero-pad to 2 digits).
2. Pick a Kebab-case slug.
3. Create `docs/scenarios/<NN>-<slug>/scenario.md` (EN) +
   `scenario.zh_cn.md` (ZH lockstep).
4. Use the template in `docs/scenarios/template/scenario.md` (TODO —
   not yet shipped; copy from an existing scenario meanwhile).
5. Update §4 above + §3 category-count.
6. Update §6 if priority changes.

Honest status reporting is the rule (`feedback_completion_requires_invariant_test`):
a scenario is only ✅ when both `scenario.md` and an `apps/.../test/...`
file exist + Allen has signed off.

---

## 9. Changelog

| Date | Change | Author |
|---|---|---|
| 2026-05-28 | Initial catalogue — 30 scenarios across 18 categories | Claude (subagent dispatched by Allen 12:32 directive) |
