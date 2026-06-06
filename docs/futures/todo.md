# Durable TODO — items deferred to future PRs

> Per `feedback_durable_todo_list` (Allen 2026-05-22): the in-memory
> TaskCreate is session-scoped; this file is the source of truth for
> in-flight + future work that crosses sessions.

## Active follow-ups (post-2026-05-24 batch)

### Capability struct lacks an action axis (codex PR #356 r1 CRIT)

- **Where:** `apps/ezagent_core/lib/ezagent/capability.ex:90` (struct
  has no `action` field; `cap/3` ignores its third arg);
  `apps/ezagent_core/lib/ezagent/capability.ex:192` (`matches?/2`
  checks kind+behavior+instance+workspace only).
- **Surfaced by:** PR #356 (HIGH-2 completion) codex r1 review of
  `Behavior.Workspace :create_user`. Folding the privileged
  `:create_user` into the same Behavior as `:add_member`/`:list_members`
  meant any holder of any Workspace cap could also create users.
  PR #356 worked around by carving `:create_user` into its OWN
  Behavior (`Ezagent.Behavior.WorkspaceUserAdmin`) — but the underlying
  cap-shape limitation persists for every multi-action Behavior in
  the codebase (Routing, ApiKeys, UserTokens, Feishu UserBinding, …
  PR #355 Feishu UserBinding has the same flaw at lower stakes).
- **Fix shape (TBD):** add `action :: atom() | :any` as a fifth
  match dimension. SPEC-level change — touches struct, parser,
  matches?/2, every grant site, every test. Two staging strategies:
  (a) add field default `:any` (backwards-compatible — existing caps
  match all actions), then progressively narrow grants; (b) refuse
  `action: :any` grants and force per-action specification.
- **Priority:** HIGH — every multi-action Behavior is a latent
  escalation surface. Workaround (Behavior-per-privileged-action)
  works but pollutes module count.
- **Until then:** new privileged actions get their own Behavior
  module per the PR #356 carve-out pattern. Document this in
  ezagent-developer skill as a current-state pattern.
- **PR #408 surface (2026-05-27):** `Behavior.Workspace :create_session`
  was added in PR #408 (SPEC `2026-05-26-session-create-orchestrator-unified`
  Gap C) and grants the cap to workspace members on `add_member`
  (codex round-2 MED-2 fix). Because the cap shape is identical to
  every other Workspace cap, a member granted this cap also satisfies
  the cap-check for `add_member`, `remove_member`, `set_routing_rules`,
  `create_agent`, etc. **Not a regression** — the same over-grant
  exists for every multi-action Behavior cap in the umbrella; codex
  round-1 of PR #408 didn't flag it, codex round-3 caught it after
  the round-2 fix moved the helper into the Behavior layer (visibility
  not severity changed). **Mitigation in this PR:** documentation only;
  the proper fix is either (a) add `action` to the Capability struct
  (the SPEC change at top of this entry) OR (b) carve `:create_session`
  into its own Behavior module (e.g. `Behavior.WorkspaceSessions`)
  per the PR #356 carve-out pattern. Allen's call which lands first.
  Inline comments at the grant sites cross-reference this note:
  `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex` (facade
  `grant_member_create_session_cap/2`); same name in
  `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex`
  (Behavior helper, lifted from the facade in PR #408 round-2 fix).

### Entity-caps LV grant form needs action-selector dropdown (post action-axis PR)

- **Trigger:** SPEC `2026-05-27-capability-action-axis.md` §3.6.1(b)
  runtime-check; r4 codex review HIGH-2; admin-role exemption is the
  bridge so the existing form (which silently defaults `action: :any`
  via `build_cap/2`) keeps working.
- **What's needed:** add an `<select>` populated from the target
  Behavior's `actions/0` (plus an `:any` option for admin-issued
  wildcard grants), wire it through `build_cap/2` so the grant
  carries the chosen action atom. Removes the admin-role exemption's
  necessity for narrow grants.
- **Where:** `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/entity_caps_live.ex:169-200`
- **Priority:** MED — admin-role exemption is fine in the short term;
  the proper fix is structural narrowing of admin-issued grants.

### Admin promotion cap-lifecycle cleanup (pre-existing, codex PR #408 review surface)

- **Trigger:** SPEC `2026-05-27-capability-action-axis.md` §7;
  PR #408 codex r3 HIGH-C.
- **What:** `users_live.ex "Promote to system"` adds workspace membership
  (`:224-229`); demotion (`:248-250`) removes membership but does NOT
  sweep caps that were granted DURING the promotion window. Wildcard
  caps survive demotion → durable authority leak.
- **Fix shape:** record granted_at timestamp + promotion-window marker
  on caps issued during promotion; on demotion, revoke any cap with
  granted_by indicating promotion + granted_at within the window.
  Alternative: scope all promotion-window grants to a
  `{:within_promotion, principal_uri, until: <demote_time>}` scope-
  tuple shape (extends existing scope-bounded delegation patterns).
- **Priority:** HIGH for production; LOW today (only Allen + seeded admin
  are persistently admin; no real temp-promotions yet).

### Codex PR #356 r1 HIGH/MED deferred

- **HIGH-1 (CLI scheme mismatch for non-bare URIs):** PR #356 fix
  partial — added a parsed-URI passthrough in
  `EzagentCli.Dispatch.build_target_uri/5` so callers can pass full
  `entity://...` URIs in `--user`. But CLI tests covering User-Kind
  ops (`grant_cap`, `set_password`, `mint_token`, etc.) don't exist
  yet — they would catch a regression. **Follow-up:** add a CLI
  integration test class for User-Kind actions (parallel to
  `cli_lv_same_server_invariant_test.exs` for Session).
- **HIGH-2 (UserTokens combined Behavior):** the same Behavior carries
  mint/list/revoke, so they share a cap subject (subsumed by the
  CRIT-1 axis issue above; cap split would require structural change).
  Until the action-axis SPEC lands, document the limitation in the
  Behavior moduledoc + audit cap grants accordingly.
- **HIGH-4 (LV bypass for create/set_password):** the GUI side
  (`EzagentPluginLiveview.UsersLive`) still calls
  `Ezagent.Users.create/3` + `set_password/2` directly. PR #356
  closed the CLI surface only. **Follow-up:** migrate the LV to
  dispatch via the same `Ezagent.Workspace.create_user/3` /
  `:set_password` dispatch paths CLI uses. Tracked separately
  because LV migration is a UX-touching change distinct from the
  CLI-side dispatch closure.



### AdapterRegistry / BindingRegistry `:public` ETS hardening (facade-audit r5 CRIT deferred)
- **Where:** `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_registry.ex` + `binding_registry.ex` (both `:public` ETS managed by `EzagentCore.EtsOwner`)
- **Surfaced by:** PR #334 (facade-audit IMPL) codex r5 — CRITICAL: in-VM caller can `:ets.insert(table, ...)` against either registry, spoofing an adapter/binding pair that the Plugin contract never validated → bypass Grill-5 + bypass `assert_required_callbacks!` + dispatch a fake `:bind` to a non-existent adapter module.
- **Fix shape (TBD):** convert `:public` → `:protected` (only GenServer owner writes); expose `register/1` API enforced by Plugin.boot only; update ~15 test sites that do direct `:ets.delete*` against these tables to use a sandbox-clear API instead.
- **Why deferred:** PR #334 was already at codex r5 + the fix touches PR-EM-1 + PR-EM-2 modules — out of facade-audit scope. Same systemic concern earlier flagged for OTHER `:public` ETS registries (Plugin/AgentFlavor/Behavior/Template) per docs/futures/todo "ETS-registries hardening" entry. Worth one combined SPEC + impl.
- **Priority:** MED — exploitable only by in-VM code (BEAM access already implies trust); production deployment posture treats BEAM access as trusted. Worth fixing pre-multi-tenant GA but not v1 blocker.

### Facade-auth-model security audit (deferred from PR-EM-3 codex iteration)

- **Where:** `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror.ex` (facade) + `behavior/external_mirror.ex` (action body)
- **Pattern observed (2026-05-25):** PR-EM-3 hit 5 rounds of codex review (r1-r5);
  each round surfaced 2-3 new HIGH/CRIT findings related to the bind/unbind
  facade's auth-model enforcement: flag forgery (r3 CRIT), read-side cap
  bypass (r2 HIGH), spawn-error swallowing (r4 HIGH), ordering of cap-check
  vs target-ownership-check (r4 MED), and BootReconciler ordering (r4 HIGH).
  The pattern suggests structural under-specification in SPEC §4.2 not
  fully addressed by point fixes.
- **Recommendation:** post-Stream-2 standalone audit PR that
  (a) defines a single comprehensive invariant test exercising all 4
  enforcement gates (cap-1 / cap-2 / target-check / workspace-iso) +
  forgery resistance + ordering + failure modes;
  (b) reviews the facade vs action-body split per `feedback_let_it_crash_no_workarounds`;
  (c) adds a security-focused doc to `docs/superpowers/specs/` capturing
  the auth model formally.
- **Priority:** post-Stream-2 (PR-EM-FINAL or first follow-up). Each
  individual PR-EM-3 finding is fixed; the META-finding is the
  pattern of finding-them.
- **Concrete r5 starting points** (2026-05-25 codex r5 — `needs-attention`,
  2 HIGH on PRE-EXISTING code, NOT in r4 scope; both architectural per
  ship discipline so escalated rather than in-place-fixed):
  1. **AdapterInstall ordering vs BindingRegistry atomicity**
     (`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_registry.ex:92-101`):
     `AdapterRegistry.register/1` triggers `AdapterInstall.install/1`
     (worker reconciliation) before the matching
     `BindingRegistry.register_module/2` runs in the normal plugin boot
     path. If the binding-registry insert later fails and rollback
     deletes the adapter row, already-spawned workers stay alive against
     a missing binding module → supervisor churn. Recommendation: split
     cap-subject registration from worker reconciliation; gate worker
     spawn on BOTH registries succeeding.
  2. **bind spawn-before-persist split-brain**
     (`apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex:333-340`):
     `:bind` action body spawns the worker FIRST, then
     `persist_binding_row/2`. If `Repo.insert/1` raises (DB outage,
     schema drift), the worker is alive but no row + no slice mutation.
     Also: changeset errors are mapped to `:ok` blanket — non-unique
     validation failures would silently drop the row while leaving
     slice + worker. Recommendation: make bind atomic — either persist
     first + terminate worker on failure, OR only treat
     verified-unique-constraint collisions as idempotent (return/raise
     all other Repo failures).

### `Ezagent.Invocation.dispatch/1` ReadyGate ↔ PendingDelivery TOCTOU
- **Where:** `apps/ezagent_core/lib/ezagent/invocation.ex` `dispatch/1`
  reads `Ezagent.Kind.ReadyGate.status/1` then
  `Ezagent.Kind.PendingDelivery.buffer/...` as two non-atomic
  operations. A Kind that flips `not_ready → ready` between the two
  reads can have an invocation neither buffered nor delivered.
- **Surfaced by:** PR-EM-CORE (#312, 2026-05-24 / merged 2026-05-25) —
  widening the not-ready window during the new post-init continuation
  queue made the race more visible. Codex r4 of PR-EM-CORE flagged it.
- **Pre-existing:** YES — the race exists on `main` independent of
  PR-EM-CORE; PR-EM-CORE merged with the race documented as a
  framework-wide separate concern (per Allen's "round-2 cap" rule +
  autonomous merge authorization).
- **Fix shape (TBD):** likely either (a) atomic
  `ReadyGate.status_and_buffer/1` returning {:ready | {:buffered, _}}
  in one ETS read+write, or (b) buffer-then-check + drain on
  ready-flip. Needs a SPEC; not a quick patch.
- **Priority:** MED — race window is microseconds in practice and the
  drain-on-ready path picks up dropped invocations; no observed
  message loss in the test suite. Worth fixing before ExternalMirror
  GA but not blocking individual PR-EM-* merges.

### Marketplace install-from-source (PR3 cc.toggle_extension toggle-ON)
- **Where:** `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` —
  `toggle_extension/3` returns `:install_from_source_not_implemented`
  for `enabled? = true`. Toggle-OFF works (`rm -rf` the bundle dir).
- **Why deferred:** needs a marketplace contract (source URL,
  signature, version pin, cache layout). Out of scope for PR3
  scaffolding.
- **Workaround for operators:** manually `cp -r` a Claude Code plugin
  bundle (with `.claude-plugin/plugin.json` manifest) into
  `<config_dir>/.claude/plugins/<name>/`. The LV picks it up on next
  refresh + can toggle-OFF.
- **Next step:** SPEC the marketplace registry. Likely a new Kind
  (`marketplace://<name>`) with `:install` / `:uninstall` /
  `:list_available` actions, dispatched by the cc plugin from
  `toggle_extension`.

### CLI ↔ GUI parity (audit findings #137 still partial)
From `docs/notes/2026-05-24-cli-gui-parity-audit.md` — 2 HIGH still
open after HIGH-1 (admin fallback hole) closed in PR #298:

- **HIGH-2** (16 of 17 legacy `mix ezagent.*` tasks bypass dispatch):
  needs a per-task migration sweep. Tasks call domain modules
  directly → no CapBAC, no audit, no cross-workspace check. Worst
  example: `mix ezagent.routing.add_rule`. Approach: write a
  migration template, hold an invariant test that `mix ezagent` is the
  ONLY task allowed to call domain modules outside of bootstrap.

  **Sweep progress (this PR — triage commit on
  `cli-sweep/deprecate-bypass-tasks`):**

  - ✅ `routing.add_rule` — already deprecated in PR #302 (Behavior
    `Ezagent.Behavior.Routing` exists; `mix ezagent routing add_rule`
    dispatches against `system://routing/default`).
  - ⏳ **deferred to follow-up PRs** — each below needs a real
    `Behavior` action reached via `Ezagent.Invocation.dispatch/1`
    (NOT a bare FacadeRegistry op) BEFORE its legacy task can be
    deprecated. **Codex PR #304 pre-merge review HIGH finding:** a
    FacadeRegistry op that calls a domain function directly
    reproduces the exact bypass HIGH-2 is supposed to retire —
    `EzagentCli.Dispatch.run_facade/3` invokes `fun.(parsed)` with
    no Invocation, no caller/caps, no audit. Each row below MUST
    land its corresponding Behavior action + cap subject FIRST;
    `mix ezagent` will then auto-derive the CLI from the Behavior's
    `interface/0`. Wiring a FacadeRegistry shortcut "to ship it
    faster" is the wrong fix — it would close HIGH-2 by closing
    the wrong problem.

    | Legacy task | Proposed `mix ezagent` | Status |
    |---|---|---|
    | `mix ezagent.feishu.bind` | `mix ezagent workspace bind --workspace <name> --open-id … --user-uri …` | ✅ **DONE in cli-lv-parity-high-2-3 branch.** `EzagentPluginFeishu.Behavior.UserBinding` registered on Workspace Kind with `:bind` action + cap. Legacy task kept as-is pending muscle-memory transition. |
    | `mix ezagent.feishu.unbind` | `mix ezagent workspace unbind --workspace <name> --open-id …` | ✅ **DONE.** Same Behavior, `:unbind` action. |
    | `mix ezagent.feishu.list` | `mix ezagent workspace list_feishu_bindings --workspace <name>` | ✅ **DONE.** Same Behavior, `:list_feishu_bindings` (read-only). |
    | ~~`mix ezagent.feishu.chat.bind`~~ | ~~`mix ezagent feishu chat_bind`~~ | **OBSOLETE.** Removed in PR-EM-6; chat→session bindings now go via `mix ezagent.external_mirror.bind <session-uri> feishu <chat_id>` (generic ExternalMirror Domain). |
    | ~~`mix ezagent.feishu.chat.unbind`~~ | ~~`mix ezagent feishu chat_unbind`~~ | **OBSOLETE.** Same as above; use `mix ezagent.external_mirror.unbind`. |
    | `mix ezagent.user.create` | `mix ezagent workspace create_user --workspace <name> --user-uri … --password … --caps …` | ✅ **DONE (2026-05-26).** `Ezagent.Behavior.WorkspaceUserAdmin :create_user` registered on Workspace Kind. Body wraps `Ezagent.Users.create/3` + opportunistic `SpawnRegistry.spawn`. Adds a structural cross-workspace check on the new user URI that the legacy direct-call had no analog for. Facade `Ezagent.Workspace.create_user/3`. Legacy task retained for muscle memory with deprecation notice. **NOTE:** codex PR #356 r1 CRIT showed that co-locating `:create_user` with `Behavior.Workspace`'s 10 member/template/routing actions would share a cap subject (no action axis in Capability struct), so this carved out into its own Behavior. Underlying cap-action-axis limitation tracked above. |
    | `mix ezagent.user.set_password` | `mix ezagent user set_password --user <uri> --password …` | ✅ **DONE (2026-05-26).** New `Ezagent.Behavior.UserCredentials :set_password` registered on User Kind. Separate from Identity per cap-shape carve-out (avoids conflating self-mutation rights with admin reset). Legacy task retained as admin-bootstrap carve-out (chicken-and-egg: first password must be set BEFORE admin has a token to authenticate `mix ezagent`). |
    | `mix ezagent.agent.create` | `mix ezagent workspace create_agent --workspace <name> --flavor … --name …` | ✅ **ACTION EXISTS** (PR #344 / `Behavior.Workspace :create_agent`); legacy task still calls the action body directly (single-path invariant test enforces). Auto-derived `mix ezagent workspace create_agent` already wired. |
    | `mix ezagent.user.token mint` | `mix ezagent user mint_token --user <uri> --label …` | ✅ **DONE (2026-05-26).** New `Ezagent.Behavior.UserTokens :mint_token` registered on User Kind. Body wraps `Ezagent.Entity.Token.mint/2`. **Carve-out preserved:** the first-admin-bootstrap mint stays in the legacy task per codex PR #304 MED — the deprecation notice for `--mint` is gentler than for `--list`/`--revoke` to reflect this. |
    | `mix ezagent.user.token list` | `mix ezagent user list_tokens --user <uri>` | ✅ **DONE (2026-05-26).** Same Behavior, `:list_tokens` action. Returns id / label / timestamps only — NEVER plain (regression test asserts the response shape has no `:plain` or `:token_hash` keys). |
    | `mix ezagent.user.token revoke` | `mix ezagent user revoke_token --user <uri> --token-id …` | ✅ **DONE (2026-05-26).** Same Behavior, `:revoke_token` action. Idempotent (legacy `Token.revoke/1` returns `:ok` for unknown ids). |

    Rule of thumb for the implementer: if you're about to add a
    `FacadeRegistry.register/3` for one of these without a matching
    `Behavior` + cap subject + `Ezagent.Invocation.dispatch/1` call
    path, STOP — you're recreating HIGH-2.

  - ✅ **CLI-only by design (will NOT be migrated, audit-confirmed
    carve-outs):** `bootstrap`, `check_invariants`, `db.reset`,
    `home.adopt_db`, `home.init`, `plugin.install`, `snapshot.list`,
    `snapshot.dump`, `stress`, `user.token` (**bootstrap mint ONLY**
    — `list` + `revoke` move to deferred table above per codex MED
    finding; the legacy task keeps a narrow first-admin mint mode),
    `auth.magic_link` (operator-debug mirror of HTTP path),
    `demo.seed_cc_agent` / `demo.seed_cc_sandbox` (demo seeders,
    not operator ops). Each file now carries a "Category A" audit
    comment in its moduledoc.
  - ⚠️ **partial-dispatch carve-out:** `snapshot.clear` — destructive
    DB op that audit Finding 5 flags as "should arguably be a
    Behavior so caps gate it". Tracked separately; the wider
    `system://snapshots` Kind needs designing first.
- **HIGH-3** (~12 LV handle_events have no CLI equivalent):
  ✅ **enumerating invariant landed** as
  `apps/ezagent_core/test/invariants/lv_cli_parity_test.exs` in
  cli-lv-parity-high-2-3 branch. Walks every LV file, categorises every
  `handle_event/3` clause into `:cli | :ui_only | :pty_stream | :deferred`
  with explicit per-event row + reason. Currently 61 events tracked
  (27 CLI / 26 UI-only / 2 PTY-stream / 6 deferred).

  **Re-mapping after the invariant landed** (audit notes from
  2026-05-24 now stale; this is the current state):

  | Event | Status |
  |---|---|
  | `add_member`, `remove_member`, `add_template`, `remove_template`, `create_workspace` | ✅ `mix ezagent workspace ...` / `mix ezagent.workspace.*` (PR #344) |
  | `promote_to_system`, `revoke_system` | ✅ aliased to `workspace.add_member/remove_member system <uri>` |
  | `grant`, `revoke` (entity_caps) | ✅ auto-derived `mix ezagent user grant_cap/revoke_cap` via `Behavior.IdentityAdmin` |
  | `delete_rule`, `disable_rule`, `enable_rule` | ✅ auto-derived `mix ezagent workspace delete_rule/...` via `Behavior.Routing` |
  | `add_rule` | ✅ auto-derived `mix ezagent workspace add_rule` |
  | `routing_rule_add_session` | ✅ auto-derived `mix ezagent session add_rule` (Routing registered on Session Kind) |
  | `routing_rule_toggle` | ✅ aliased to `mix ezagent workspace enable_rule/disable_rule` per toggle direction |
  | `restart` (agent) | ✅ auto-derived `mix ezagent agent terminate` |
  | `toggle` (agent extensions) | ✅ auto-derived `mix ezagent template toggle_extension` |
  | `bind`, `unbind` (feishu) | ✅ auto-derived `mix ezagent workspace bind/unbind` (this PR — Behavior.UserBinding) |
  | `put`, `delete` (api_keys) | ✅ auto-derived `mix ezagent user put_api_key/delete_api_key` |
  | `dump`, `clear` (snapshots) | ✅ `mix ezagent.snapshot.*` |
  | `add_binding`, `unbind` (ext mirror) | ✅ `mix ezagent.external_mirror.*` |
  | `send_test_email` | ⚠️ semi-covered by `mix ezagent.auth.magic_link` (different intent — operator-debug) |
  | **`create_session`** | ✅ **DONE (PR-5 / 2026-06-04).** `Behavior.Workspace :create_session` is the user/operator entry; LV and E2E setup now call `Ezagent.Workspace.create_session/3`, while lower-level instance-message materialization is internal-only. |
  | **`create_user`** | ✅ **DONE (2026-05-26).** `Behavior.Workspace :create_user` (see HIGH-2 table). Auto-derived `mix ezagent workspace create_user`. |
  | **`set_password`** | ✅ **DONE (2026-05-26).** New `Behavior.UserCredentials :set_password` on User Kind (see HIGH-2 table). Auto-derived `mix ezagent user set_password`. |
  | **`save_display_name`** | ⏳ DEFERRED. Needs Behavior on User Kind for `:set_display_name` (Profile slice); LV uses `Ezagent.Entity.Profile.upsert/1` directly. |
  | **`save_smtp`** | ⏳ DEFERRED. Needs Behavior on App/SystemSettings Kind for `:save_smtp_config`; LV uses `Ezagent.AppSettings.put/2` directly. |
  | **`chat_compose`** | ⏳ DEFERRED. CLI is partial — text-only via `mix ezagent session send`; file attachments need a `resource://` upload primitive that doesn't exist yet (audit Finding row 1). |

  The remaining ⏳ DEFERRED rows are the residual gaps. Each is
  enumerated in the invariant test's `@event_to_cli` table with
  category `:deferred` and a `docs/futures/todo.md` citation.
  Post-2026-05-26 HIGH-2 completion: `create_user` + `set_password`
  closed; 3 deferred rows remain (`chat_compose`, `save_display_name`,
  `save_smtp`).

### ~~`/admin/uploads/:filename` controller route — scope mismatch~~ — RESOLVED 2026-05-25
Codex PR #305 round-4 HIGH (2026-05-24): the chat-compose-upload
download endpoint sat under the `/admin/*` URL prefix but was a
plain controller route, so the centralized `live_session
:require_admin` (PR #305) did NOT gate it. The controller was
misnamed — chat uploads are user-scope, not admin-scope.

**Fix landed (2026-05-25, PR fix/uploads-route-per-user-authz):**
1. ~~Move route from `/admin/uploads/:filename` →
   `/files/:filename`~~ — done in `router.ex`.
2. ~~`UploadsController.show/2` verifies caller is admin OR
   uploading-user OR session-participant; otherwise 403.~~ — done
   in `uploads_controller.ex`.
3. ~~Regression test pinning cross-user isolation.~~ — done in
   `apps/ezagent_web/test/ezagent_web/controllers/uploads_controller_test.exs`
   (9 tests, including the cross-user-guessing-yields-403 case).
4. ~~All remaining `/admin/*` routes are pure LiveView, gated by
   `live_session :require_admin` by inspection.~~ — comment added
   in `router.ex` near the admin scope documenting the
   invariant + an explicit anti-regression note.

### ~~Silent default workspace fallbacks (runtime form)~~ — RESOLVED 2026-05-26 (PR #362)

Allen 2026-05-26 09:31: "如果没有提供 workspace name，应该直接 crash. 现在
已经没有了默认 workspace 这个概念". PR #335 deleted the literal/static
default workspace; PR #362 closed the remaining 14 runtime-fallback
sites of shape `workspace_uri.host || "default"` + the residual
`workspace_name_from_caller(_), do: "system"` in `dispatch.ex`.

Sites fixed: `session.ex × 4`, `agent.ex × 1`, `behavior/template.ex × 2`,
`session_template.ex × 1`, `orchestrator/tools.ex × 2`, `cc_agent.ex × 2`,
`dispatch.ex × 1`. New invariant test
`no_silent_default_workspace_test.exs` locks the bug class out.

NB: `dispatch.ex` 144/147/150 `fill_caller_workspace("default", ...)`
intentionally NOT touched — `"default"` is the template-class segment
of `session://<class>/<workspace>/<name>`, not a workspace fallback.

### ~~Notifications consumer coverage~~ — RESOLVED 2026-05-26 (med-batch)
PR #300 wired AdminLive as the operator subscriber + added notify
calls to `Workspace.add/remove_member` and `Identity.grant/revoke_cap`.
~~Additional producers still silent~~ — all 3 wired in med-batch:
- ✅ `Chat.join` notifies joinee (`apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex` `invoke(:join, …)` — `:session_member_joined`)
- ✅ `agent.terminate` notifies spawning principal via `AgentLineage.lookup/1` (`apps/ezagent_core/lib/ezagent/behavior/lifecycle.ex` `invoke(:terminate, …)` — `:agent_terminated`)
- ✅ `agent_template.fork` notifies fork-owner (`apps/ezagent_domain_instance_message/lib/ezagent/behavior/template.ex` `fork_agent_template/3` — `:agent_template_forked`)

All gated by `user_uri?/1`. Tests added to `chat_test.exs`,
`lifecycle_terminate_test.exs`, `template_fork_lineage_test.exs`.

### ~~PR5: `Agent.duplicate/clone` (cross-user agent copy)~~ — RESOLVED 2026-05-26 (via PR #338)

Per `feedback_agent_clone_not_via_template`: direct agent-to-agent
copy. **Landed in PR #338 (`9120952`)** via `--from <source-uri>` arg
on `Ezagent.Workspace.create_agent/3`. The clone primitive is
`Behavior.Workspace.:create_agent` with `from:` arg:

- **Source resolution** — `resolve_source_config_dir/2` in
  `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex:469`
  dispatches `sandbox.read` against the source agent URI WITH THE
  CALLER'S CAPS (standard CapBAC, no parallel auth path), returns
  the source's `config_dir_path` from its `:sandbox` slice.

- **Copy + spawn** — `do_create_agent("cc", …)` at
  `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex:526`
  builds a cc Template with `claude_config_dir` = source's per-agent
  dir; the cc Template Class's existing `create_agent_config_dir/2`
  does the `File.cp_r/2` deep copy at spawn (Allen 2026-05-24 PR3).
  Result: new agent has same `template_class` + own
  config_dir path (deep-copy independent from source).

- **CLI** — `mix ezagent.agent.create <uri> --from <source-uri>`
  already wires through the action (no separate `mix ezagent agent
  clone` subcommand; the operator surface uses
  `mix ezagent.agent.create` with the source as a flag).

- **Cross-workspace cap-bridge** — still deferred to v1.5. The
  current path requires the caller to hold `sandbox.read` on source
  AND `Behavior.Workspace.:create_agent` on destination workspace —
  same-workspace works structurally; cross-workspace caps need the
  bridge SPEC.

**Architectural rationale for NOT adding `Ezagent.Entity.Agent.clone/3`:**
Adding a parallel primitive on the Agent module would create dual
SoT (P3 violation) — the action body already lives on
`Behavior.Workspace.:create_agent` per Allen's 2026-05-25
simplification (closes #332). `feedback_agent_clone_not_via_template`'s
intent was "not via Template Registry" — Workspace IS the natural
parent Kind (per the `:create_agent` precedent), not a Template
Registry concern. Status documented per `feedback_dont_defer_what_is_solvable_now`:
v1.5 cross-workspace cap-bridge tracked separately when it lands.

### Audit gaps from notification-log audit
Still open after PR #300 + the batch fix that includes this todo:
- **DONE (low-doc-batch 2026-05-26)** — `EzagentWeb.Telemetry.metrics/0`
  defines 16 metrics; the original report claimed "no reporter attached"
  but `Phoenix.LiveDashboard` at `/dashboard` consumes `metrics:
  EzagentWeb.Telemetry` (verified at `apps/ezagent_web/lib/ezagent_web/
  router.ex:250` — `live_dashboard "/dashboard", metrics: EzagentWeb.
  Telemetry`). The moduledoc already documents this correction in the
  2026-05-24 cleanup batch. Single-node-ops setup needs no separate
  Prometheus reporter; adding `{TelemetryMetricsPrometheus, ...}` to
  `EzagentWeb.Telemetry.init/1`'s children is a one-line future change
  if multi-node alerting becomes a requirement (LiveDashboard would
  keep working in parallel because both reporters subscribe to the
  same telemetry events).
- **DONE (low-doc-batch 2026-05-26)** — SPEC for the notifications
  system at `docs/superpowers/specs/notifications.md` is the stable-
  contract index pointing at the canonical v2 SPEC
  (`2026-05-24-notification-architecture-v2.md`). Expanded in this
  batch to include §1-§9 (Context / Goals / Architecture / Cap model /
  Producer list / Consumer LVs / Failure modes / Invariant tests /
  Out-of-scope). Bilingual `notifications.zh_cn.md` added.
- **DONE (low-doc-batch 2026-05-26)** — `ObservabilityLive` workspace
  filter landed earlier (see `apps/ezagent_plugin_liveview/lib/
  ezagent_plugin_liveview/observability_live.ex:30-65` —
  `workspace_filter_for/1` + scoped queries). This batch added the
  regression test
  (`apps/ezagent_plugin_liveview/test/observability_live_test.exs`)
  that fails when the filter is removed.

### ETS-registries hardening (deferred from PR-EM-1 codex r2 HIGH-1)

**Tracked**: PR #315 (PR-EM-1) added Ezagent.ExternalMirror.AdapterRegistry
+ BindingRegistry as `:public` ETS tables, matching the existing
EtsOwner pattern (PluginRegistry, AgentFlavorRegistry, BehaviorRegistry,
etc. are all `:public`). Codex round-2 HIGH-1 flagged that
any in-VM code can call `:ets.insert/2` against these registries
and bypass the validation in `register/1`.

This applies to the **entire EtsOwner pattern**, not just the new
ExternalMirror tables. Only `Ezagent.NotificationSubscriptions`
uses `:protected` + GenServer-serialised writes (per its PR-N1
codex round-2 HIGH-1), and that's because it gates cap-checked
writes specifically.

**SPEC question**: should every contract-enforced registry move
to `:protected` + owning GenServer write API? Or is the current
trust model (plugin code is treated as trusted; the
`:ezagent_plugin_check` compile-time gate prevents accidental
direct calls; the registry API enforces validation when called
properly) the right one?

**Owner**: TBD. Not blocking PR-EM-1; PR-EM-2 dispatch reads
the same tables. If the answer is "yes, harden", the migration
is SPEC + a sweep PR across every registry — out of scope for
the ExternalMirror PR sequence.

### Architecture audit follow-ups
From `docs/notes/2026-05-24-architecture-audit-v1.md` (5 LOW):
1. **DONE** — `Capability.cross_workspace?/2` `apply/3` →
   `Workspace.Store` is documented in `feedback_let_it_crash_no_workarounds`-
   compliant style; layer_purity_test explicit allowlist update
   pending.
2. **DONE** — marketplace toggle deferred record (see top).
3. **DONE (med-batch 2026-05-26)** — `AgentExtensionsLive.authorized_to_toggle?/1`
   uses `Capability.cap_for_action/3` (file:line
   `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/agent_extensions_live.ex:265-279`).
   Audit-time grep across operator scope finds zero remaining
   `%Capability{kind:` hand-constructed structs (one `needed`-map
   site in `session_external_mirror_live.ex:486` uses an
   adapter-supplied `behavior_module`, not `BehaviorRegistry.lookup` —
   different code shape, not a drift risk).
4. **DONE (med-batch 2026-05-26)** — `workspace_sot_test.exs`
   added at `apps/ezagent_core/test/invariants/workspace_sot_test.exs`.
   Greps `apps/ezagent_plugin_liveview/lib` + `apps/ezagent_web/lib`
   for `Workspace.list_persisted/0` / `Workspace.Store.list_all/0` —
   fails with zero allowlist entries.
5. **DONE** (PR-F #297) — `Registration.create_principal/3` "default"
   default arg removed.

### ✅ ExternalMirrorWorker dedupe drops retry-send with reused msg.id — RESOLVED 2026-06-01 (PR #516)

> Dedupe key changed to composite `{msg.id, send_cursor}`; codex also caught
> (HIGH) that the production Lifecycle `%{state: ...}` slice wasn't unwrapped —
> fixed so dedupe works in the real path, with a wrapped-slice regression test.

- **Where:** `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror_worker.ex:469-486`
  (`invoke(:publish)` dedupes by `event_msg_id == slice.last_published_message_id`).
- **Surfaced by:** PR #420 (task #49) codex r4 review of the r3 catchup
  fix. Adversarial check #2 ("can a replayed event share msg id with
  a fresh event?") uncovered a pre-existing dedupe bug ORTHOGONAL to
  CHECK C catchup.
- **Bug shape:** `Chat.invoke(:send)` deliberately bumps `:send_cursor`
  even when `msg.id` is reused (see `chat.ex:394` + `chat.ex:406-412`
  — MessageStore is idempotent on `(id, session_uri)`; the cursor
  delta is what makes `new_slice != slice` for retried sends). The
  Feishu adapter treats every send_cursor delta as a real publish
  (`feishu_adapter.ex:304,321`). But the worker's `event_msg_id ==
  last_published_message_id` short-circuit silently skips the retry
  send as a "duplicate" — even though the adapter contract says it
  should publish. End result: a legitimate retry-send to Feishu is
  dropped.
- **Why NOT fixed in PR #420:** out-of-scope for CHECK C (an
  empty-fanout WINDOW bug). The fix changes dedupe semantics from
  `msg.id` to composite key `(msg.id, send_cursor)` — touches the
  `last_published_message_id` slice field shape + every test that
  asserts on `:duplicate_skip` (currently `worker_publish_test.exs`
  exercises this code path with msg.id-only equality). Deserves its
  own PR with explicit dedupe-contract regression tests.
- **Fix shape (TBD):** rename `last_published_message_id` →
  `last_published_send_key` storing `{msg.id, send_cursor}` (or a
  hashed pair); update the cond at line 472 to compare composites.
  Reachable through replay too — same dedupe path. Need to confirm
  no chat-side flow re-emits the SAME `(msg.id, send_cursor)` pair
  legitimately (it shouldn't — send_cursor is monotonic per
  `Chat.invoke(:send)` invocation, and replay re-delivers the SAME
  event so the pair matches the prior publish exactly).
- **Priority:** MED — limited to chat-send retry path; default Feishu
  send is not retried at the chat layer in V1. Surfaces if/when a
  user clicks "resend" in LV chat UI or an upstream binding/adapter
  call retries on a transient failure.
- **Bonus follow-up (codex r4 LOW):** the regression test in
  `worker_resubscribe_catchup_test.exs` uses `chat.join` (slice-level
  mutation, no `msg.id` in payload), so `extract_event_message_id/1`
  returns nil and the dedupe never fires. Once dedupe is fixed,
  augment the catchup test (or write a sibling) to drive an actual
  `chat.send` through the window so the catchup + dedupe interact
  end-to-end.

---

## Post-lifecycle-migration full E2E findings (2026-05-30, Allen "e2e全量重跑")

> **RESOLVED 2026-05-31** — the migration-introduced (B) findings + the
> highest-stakes pre-existing (A) finding were closed by the remediation batch
> merged 2026-05-30/31, verified on `origin/main`:
> - `:not_ready` readiness regression (B, PRIMARY) → **#493** (`kind/server.ex`
>   `ReadyGate` + `PendingDelivery.flush` buffering present; full umbrella 169→0).
> - `Jason.Encoder not implemented for Ezagent.Capability` silently dropping
>   `cap_granted` from EventLog (A, HIGH) → **#493** (`defimpl Jason.Encoder,
>   for: Ezagent.Capability` in `capability.ex`).
> - destroy-gate + AgentLineage durability (B/C) → **#493** (+ prod migration
>   `20260616000000_agent_lineage_durable_backing`, see `pending-prod-migrations`).
> - cold-restart P6 determinism → **#498**; URI silent-address hardening → **#496**;
>   router facade `Invocation.dispatch`→`Router.dispatch` (#112) → **#494**;
>   home backup/restore CLI (#120) → **#497**.
> - Sandbox-isolation full-run flakiness (A) is **pre-existing test-infra**, NOT
>   migration-caused (deterministic-0 on fresh worktrees; double-digit counts
>   come from concurrent-suite contention / a bisect-churned worktree's drifted
>   test DB — see memory `feedback_fresh_worktree_for_test_measurement`).
>
> Still OPEN from below: the home-portability **durable** profile-relative path
> fix (CLI shipped in #497; structural fix deferred — see
> `docs/notes/home-portability-audit.md`). Findings retained verbatim below.

Methodology: phx restarted on complete `d46bd2d2`; live agent-browser + full
umbrella `mix test` (407 files) + isolated chat re-runs + **pre-lifecycle
baseline worktree (`54df56c9`) chat run for apples-to-apples diff**.

### Verdict
- **Live product migration: VALIDATED.** phx boots clean; cold-restart rebuild
  works (7 cc agents respawn from snapshot, ExternalMirror BootReconciler
  reconciles, KindRegistry repopulated — agent-browser screenshot captured);
  `snapshot_restart_test` GATE 3/3 from umbrella root.
- **Automated suite: ~131 raw failures full-run, triaged:**

#### A. PRE-EXISTING (confirmed via baseline diff — NOT migration's fault)
- **Sandbox-isolation flakiness**: chat baseline = 23 failures, ~39
  `DBConnection.ConnectionError` (`owner exited / Client still using
  connection` — spawned Kind.Servers outlive the test that owns the sandbox
  connection). Present pre-lifecycle. Run files isolated/serial to confirm green.
- **`Jason.Encoder not implemented for Ezagent.Capability`** (HIGH, pre-existing):
  baseline 337 / migrated 332 raised `:emit` of `:cap_granted` EventLog rows
  (`identity.ex:361`). The emit is caught ("continuing") so cap_granted events
  are **silently dropped from EventLog**. Fix: `@derive {Jason.Encoder, ...}` on
  `Ezagent.Capability` (+ nested URI/MapSet/DateTime encoders) OR emit a plain
  map payload instead of the struct.
- URI fixture artifacts (`host: {:not,:a,:string}`, `String.Chars.URI`),
  feishu BindingPolicy retired-API, etc. — documented earlier.

#### B. MIGRATION-INTRODUCED (chat: baseline 23 → migrated 43 failures, +20)
- **`:not_ready` readiness regression (PRIMARY, ~6 direct + cascade)**:
  `join`/`subscribe_from` called synchronously right after a Session (re)spawn
  returns `{:error, :not_ready}` instead of buffering. Engine
  `kind/server.ex` ReadyGate/PendingDelivery path was touched by Phase A
  (#478); the documented contract ("dispatch during post-init buffers via
  PendingDelivery and runs after :ready") is NOT covered for the synchronous
  call path now that `activate/2` runs in post-init `handle_continue`,
  widening the not-ready window. Failing: `SessionSurvivesRestartTest — THE
  GATE`, `WorkspaceRegistry rebind on rehydrate`, `PublisherSessionTest
  no-ambient-caps`, etc. **These tests encode a real production invariant**
  (join-right-after-(re)spawn must not be rejected — exactly the cold-restart
  message-loss class the migration was meant to kill). FIX DIRECTION: restore
  buffering for synchronous dispatch during `:not_ready` at the engine level —
  do NOT paper over by making tests await-ready (would mask the regression).
  *Needs Allen's architectural steer (core-engine + behavior change).*
- **destroy-gate semantics change (SandboxDestroyTest, 2)**: after `:destroy`,
  `read`/`write_path` return `{:ok, %{...: nil}}` (empty two-container state)
  instead of `{:error, :destroyed}`. The process-dict `destroyed?` gate was
  intentionally removed in the Sandbox→Lifecycle conversion ("destroyed =
  absence of state"). Either re-add a destroyed sentinel or update the 2 tests
  — decision pending (is read-after-destroy-returns-empty acceptable?).
- two-container parity test-debt (Kind.SnapshotTest etc., few): tests assert
  old flat slice shape `%{identity: %{caps:}}`; product correctly returns
  `%{identity: %{state: %{caps:}}}`. Update the test assertions.
- **home portability (#120) — relativize Sandbox `config_dir_path`**: SHIPPED a
  working `mix ezagent.home.backup` + `ezagent.home.restore` (VACUUM-INTO
  consistent DB copy + rewrite-on-restore of the absolute `config_dir_path` /
  `respawn_template_data` paths buried in `kind_snapshots.state_binary`, e2e in
  `apps/ezagent_core/test/integration/home_migration_test.exs`). DEFERRED the
  durable structural fix: store the Sandbox slice path **profile-relative**
  (`cc-agents/<ws>/<name>`) and resolve against `Ezagent.Home` at read time in
  `activate/2`, so restore needs no rewrite at all. Invasive — touches the
  Sandbox slice contract, the cc Template Class, `:write_path` callers,
  `reconcile_after_load`, + a data migration of existing rows. See
  `docs/notes/home-portability-audit.md` §"Conclusion" approach 2.

- **cc-agent claude credential durability (2026-06-01)**: cc agents
  (orchestrators + workers) authenticate to Anthropic via the Claude Max
  OAuth token in `<CLAUDE_CONFIG_DIR>/.claude/.credentials.json`, which
  EXPIRES ~daily. When it expires, claude receives channel messages but
  every reply fails `401 Invalid authentication credentials · Please run
  /login` — the agent looks alive (bridge joined, mentions delivered) but
  silently never replies. Found while debugging the orchestrator-chain
  (`[[project_cc_channel_reply_unverified]]`): orch's token had expired
  ~8h prior; refreshed operationally by copying the operator's valid
  `~/.claude/.credentials.json`. DURABLE FIX options: (a) configure an
  `api_key_helper` / long-lived API key for spawned agents instead of the
  expiring OAuth token; (b) ensure the headless claude auto-refreshes via
  its refresh token on launch (it has one — confirm why it didn't); (c)
  a spawn-time credential-freshness preflight that fails loud (or
  refreshes) rather than letting the agent run with a dead token. Until
  fixed, long-lived agents go mute a day after the last login.

- **✅ RESOLVED (PR #517) — inbound feishu: disambiguate multi-session chat binding by @-mention (2026-06-01,
  Allen Q "为什么不能绑定多session")**: the `external_mirror_bindings` data model ALLOWS a
  chat→N-sessions (intended for OUTBOUND fan-out). But INBOUND
  (`InboundChatLookup.resolve/1`) fails closed with `:ambiguous_chat_binding` when a
  chat has 2+ bindings, because it can't decide which session an inbound message
  targets. Improvement: when the inbound message @-mentions a specific agent (e.g.
  `@cc_orchestrator-e2e-orch14`), route to the SESSION that agent is a member of —
  letting one Feishu group host multiple orchestrator sessions, disambiguated by who
  is @-mentioned. Until then, keep one binding per chat (delete stale rows when a
  bound session is destroyed — destroying a session should cascade-delete its
  `external_mirror_bindings` rows; today it doesn't, which is how the orch5/orch14
  ambiguity arose).

- **✅ RESOLVED (PR #508) — AgentTemplate.to_template_data/2 is cc-centric — blocks orchestrator-spawned
  curl/codex workers (2026-06-01, scenario 33 live)**: the mapping only propagates
  `class`/`agent_uri`/`cwd` + the cc-specific optional set
  (`claude_config_dir`/`operator_settings_path`/`operator_mcp_config_path`/
  `api_key_helper`/`role`). It does NOT carry curl's `provider`/`api_url`/`model`
  or codex's `model`/`approval_policy`/`sandbox`. So when the orchestrator's
  `add_agent_slot` spawns a curl/codex worker, the worker's flavor slice gets those
  fields as `nil` — verified live: an orch-spawned curl worker had `provider`/
  `api_url`/`model` all nil (DeepSeek key WAS set on its `:api_keys` slice and
  readable, but it couldn't call the API — didn't know the URL/model). cc workers
  work only because their needed field (`claude_config_dir`) happens to be in the cc
  allowlist. FIX (needs brainstorm + codex spec): make `to_template_data`
  flavor-generic — e.g. the flavor's Template Class declares which content keys to
  thread, or thread all non-reserved content keys. This is THE blocker for live
  multi-flavor full-star (scenario 33 live tier); the deterministic scenario_33 test
  uses synthetic no-PTY flavors so it doesn't exercise this mapping.
- **✅ RESOLVED (PR #509 — root cause: app-server unix socket path exceeded SUN_LEN) — codex worker bridge fails to connect (2026-06-01)**: an orch-spawned codex
  worker spawns + the codex `app-server` procs start, but `codex_bridge.py` logs
  `bridge connection fail` / `codex_thread_id_file_timeout` — the worker never
  becomes reachable. codex CLI 0.134.0 + `~/.codex/auth.json` present. Separate from
  the to_template_data gap; a codex-plugin bridge bug to debug (thread_id file
  handshake / timeout).
- **✅ RESOLVED (PR #518) — add_agent_slot is a synchronous 5s GenServer.call — too short for slow-spawning
  flavors (2026-06-01)**: spawning a codex worker (cold app-server start >5s) made
  `add_agent_slot` return `{:exit, {:timeout, GenServer.call}}` to the caller, even
  though the spawn continued async and the worker Kind was created. The slot-spawn
  should tolerate slow flavors (async spawn + readiness poll, or a longer/ configurable
  timeout) rather than surfacing a spurious timeout.

- **⚠️ PARTIALLY RESOLVED (PR #519 — observability landed) — remove_agent_slot silently drops routing rules that point only to that slot —
  no error, no recovery on re-add (2026-06-01, relay 传话游戏 debug; Allen flagged
  as "又是静默失败")**: `Orchestrator.Tools.remove_agent_slot` GC's every routing rule
  whose ONLY receiver is the removed slot (`RuleStore.delete(rule.id, force: true)`,
  tools.ex ~1095). Defensible as GC, BUT: (a) re-adding the SAME slot name does NOT
  recreate the rules, and nothing warns — so "remove + add" (the intuitive "restart
  this worker") silently loses all routing to it; (b) a subsequent message that then
  matches NO worker rule just falls through to the session default fan-out
  (`$session_users`/`$mentions`) and goes nowhere — no "unroutable to any worker"
  signal. Symptom seen: re-spawned a cc relay worker via remove+add, its `BATON->cc`
  rule was gone, kickoff messages silently went unanswered (looked like the cc worker
  was mute — it wasn't; it never received anything). Structural fixes (no workaround):
  re-add restores the slot's rules, OR remove emits a warning naming the rules it
  cascade-deletes, OR give "message matched no worker receiver" an observable signal
  instead of a silent default fan-out. Also: prefer a non-destructive worker-restart
  primitive (update_agent_template / PTY restart) over remove+add when only swapping
  creds/config.
  > **PR #519 landed the observability half**: each cascade force-delete now emits a
  > `Logger.warning` (rule id + matcher + worker) AFTER the txn commits, and
  > `remove_agent_slot` returns `{deleted_rules, repointed_rules}`. STILL OPEN:
  > (a) re-add restoring a slot's dropped rules, (b) the "message matched no worker
  > receiver" observable signal (the silent default-fan-out half), (c) the
  > disable-not-delete GC option. Confirmed live 2026-06-01: an @-mention to a
  > non-member slot worker silently goes nowhere — that's the (b) gap.
  >
  > **Update 2026-06-05 (verified vs origin/main):** `remove_agent_slot` was
  > RETIRED → replaced by member-model `remove_member` (tools.ex §3.8), which
  > SUBSUMES the #519 observability half — its result reports
  > `deleted_rules` (cascade-deleted, routing LOST + Logger.warning'd) vs
  > `repointed_rules`. So the remove-side observability (a-partial) is done.
  > **Genuine residual = (b)**: the "message matched no worker receiver →
  > silent default fan-out" signal lives in the ROUTING layer, not remove.
  > `Ezagent.Routing.Resolver.resolve_with_ctx/4`
  > (`apps/ezagent_core/lib/ezagent/routing/resolver.ex:190`) treats
  > `system_default` (`$session_users`/`$mentions`) as just another matched
  > rule; there is no signal distinguishing "matched a real worker/member
  > rule" from "only matched system_default" when a message carried
  > `@mentions` that resolved to no member. (b) is a NEW observability
  > feature needing design (signal shape + false-positive guard for
  > legitimate broadcasts) — NOT a quick patch. Recommend a small
  > brainstorm/spec before implementing.
  >
  > **CLOSED 2026-06-06 (Allen).** The remove-side cleanup/observability is
  > done (remove_member: deleted_rules/repointed_rules + cascade-delete
  > warnings). The (b) "no worker matched → silent fan-out" case is NOT a bug:
  > an `@mention` to a non-member is silently dropped by the Resolver's
  > `valid_member?/2` filter (resolver.ex:336) — IM-consistent (@nonexistent =
  > no-op) AND a load-bearing SECURITY boundary (chat.receive runs under
  > `system://chat-router`; delivering to an unvalidated target = privilege
  > escalation). Allen declined the optional UX hint. **Task closed — no
  > remaining work.**

- **✅ `domain.agent` — DONE (verified against origin/main 2026-06-05).** Content
  audit (not SHA — the stale local `domain-agent-foundation` branch's commits are on
  main under different SHAs via #539 + unify-uri-query reshaping): PR-1/PR-DR/PR-4 +
  codex merged via **PR #539**; PR-2 (split `working_directory`→`project_cwd`+`config_dir`)
  done (only comments reference the old name, no live reads); PR-6 `update_member_template`
  on main; the 2026-06-03 config_dir promotion (`claude_config_dir`→`config_dir`,
  fail-loud) merged; PR-3's domain-owns/plugin-materializes architecture landed
  (domain threads `config_dir`, core `Kind.Template` does `allocated_config_dir`,
  `Behavior.Sandbox` owns FS lifecycle + invokes `template_class.destroy_config_dir/2`,
  plugins only materialize). scenario-34 deterministic **8/0** in dev docker; live
  passed 2026-06-03 (old node). ONLY residual = move per-agent config_dir PATH
  COMPUTATION (cc_agent/codex_agent `agent_config_dir/1`) fully into the domain — a
  marginal structural refinement the spec flagged needs compat shims + Allen review;
  NON-blocking. The scenario-34 live re-run in the NEW #21 docker dev env needs Allen's
  dev Feishu app (cli_a97ae) event-subscription config. See [[project_domain_agent_spec]].

- **`domain.agent` abstraction — own per-agent identity + filesystem isolation as a
  structural invariant (Allen 2026-06-02, after E2E acceptance)** [SUPERSEDED by the ✅
  entry above — kept for the original problem statement]: the scenario-34
  live tier surfaced that per-agent resource isolation (cwd / config_dir / `.mcp.json`
  / bridge token) is currently SCATTERED — partly from template data
  (`working_directory`, which a mis-seeded template set to the SHARED
  `~/.ezagent/cc-orchestrator`, so all cc workers clobbered one `.mcp.json` → wrong
  bridge identity → `:no_bridge` silent drop), partly computed ad-hoc per flavor in
  the plugin Template Class. A `domain.agent` would make "an agent is a first-class
  entity with a UNIQUE identity + UNIQUE filesystem sandbox" a domain INVARIANT: the
  domain assigns per-agent working dir / config_dir / token and guarantees uniqueness,
  so no flavor's Template Class (or mis-set template field) can collapse two agents
  onto a shared path. Plugin Template Classes keep only flavor-specific bits (which
  binary, which flags). This makes the whole "shared-path leak" class structurally
  impossible. Ties into: creation-unification (domain.agent IS the agent-creation
  chokepoint), agent-clone-as-domain-primitive, per-agent-config_dir contract, and the
  plugin-isolation north star. The 2026-06-02 cc_agent.ex cwd fix (force per-agent cwd
  in `spawn_for_local_pty`) is the TACTICAL patch; domain.agent is the STRATEGIC home.
  Sequencing per Allen: do AFTER E2E acceptance.

- **Session snapshot WIPED on cold-start (e2e-orch15) — `{:snapshot,:on_change}` +
  empty `activate` overwrites good state (seen repeatedly 2026-06-02)**: the
  `session://default/system/e2e-orch15` snapshot (≈300KB: members/legends/
  prompt_templates/template_working_copy) gets overwritten with a 91-byte empty
  `%{state: %{}}` whenever the Session Kind cold-starts via a path whose `activate`
  returns empty (observed on boot-Loader respawn AND on a misused
  `SpawnRegistry.spawn/1`). Because the Session is `{:snapshot,:on_change}`, the empty
  activate immediately persists, destroying the durable state — and then
  `McpServer.rebuild_from_durable` can't find `template_working_copy.orchestrator_
  template_uri` → orchestrator registration fails (`:orchestrator_not_registered`) →
  orchestrator + tools dead. This is the `lifecycle_case.ex` "activate/2 didn't run or
  returned empty — cold-restart bug class". It BLOCKED the scenario-34 live round-trip
  (kept having to restore the snapshot from a DB backup; it re-wiped on the next cold
  start). Fix: make the Session's `activate` rebuild from the durable snapshot before
  any on_change persist (or guard on_change from writing an empty/partial slice over a
  non-empty one). Lesson recorded: NEVER `SpawnRegistry.spawn/1` an existing entity
  (fresh-spawns empty); revive via dispatch (`lazy_spawn_from_snapshot`).

## domain.agent — config/credential lifecycle gaps (Allen review 2026-06-03)

Surfaced answering Allen's two architecture questions after the scenario-34
cc→codex→curl live E2E passed. Both are NEXT-phase domain.agent scope, NOT in
the domain-agent-foundation PR (that PR is deliverability: PR-DR self-heal,
PR-4 snapshot guard, codex `--last`, table-rename).

- **Per-agent credential lifecycle (NOT implemented; test fixture only).**
  `CcAgent.create_agent_config_dir/2` (cc_agent.ex:1669) cleanly copies a
  template's `claude_config_dir` reference dir → per-agent private dir (cp_r +
  chmod creds + completion marker). But what POPULATES the reference dir with
  credentials is only test plumbing: the demo mix task
  `ezagent.demo.seed_cc_sandbox` (copies `~/.claude/.credentials.json` to
  "avoid re-login") and, during the live E2E, a MANUAL `cp` (not in code at
  all). The real flow Allen wants — **user creates a new agent → logs in
  themselves (claude `/login` inside the agent's sandbox) → credentials are
  saved and reused on future spawns** — does not exist. Proxy config has no
  code path either. domain.agent should own this lifecycle (login → persist →
  reuse) + runtime config (proxy), with a CLEAN separation between the test
  fixture (copy host creds) and the production config interface.

- **Per-flavor config UI (partial + generic; plugin `:form` surface unbuilt).**
  Create is a generic form (`agent_new_live`: flavor dropdown + name/cwd/pty);
  post-create config is spread across generic screens (`agent_detail` /
  `agent_extensions` / `agent_api_keys`). Flavors do NOT provide their own
  config UI: `config_surface/0` is `:route | :flavor | nil` (V1); the `:form`
  surface (plugin-provided config form, store V2 — SPEC §6.1) is noted but not
  built. No UI for cc/claude login or proxy. Decision needed: each flavor
  inherits one generic UI vs provides its own via the `:form` config_surface
  contract — then build it. Ties to the credential-lifecycle item (login UI).

## domain-agent-handoff parked work ledger (2026-06-04)

Source: `/tmp/handoff-esr-docker-pivot-2026-06-04.md` §4. Scope for the
parallel handoff branch is all parked work EXCEPT #21 Dockerize. #21 remains in
the separate cc-openclaw session; this ledger exists so non-#21 work is either
merged into `domain-agent-handoff` or left with a concrete blocker/decision.

- **#27 ComposerMention/AdminLive default session template seed — DONE.**
  Allen chose option B: seed a per-workspace `default` SessionTemplate. Merged
  to `domain-agent-handoff` as PR #559 (`66105e2c`). Targeted tests passed:
  `default_session_template_seed_test.exs`, `composer_mention_test.exs`, and
  the affected Admin/Agent LV suites.

- **PR-A2 codex CODEX_HOME per-agent isolation — DONE.** `CodexAgent` now uses
  ConfigDir namespace `codex`, materializes `auth.json`/`config.toml`, and
  passes `CODEX_HOME` through app-server, bridge sidecar, and PTY launch
  parameters. Merged to `domain-agent-handoff` as PR #560 (`4940f33f`).

- **#17 remaining gap: production auto-refresh-on-spawn — DECISION-BLOCKED,
  do not wire PR-E into production spawn by default.** The current spec
  (`docs/superpowers/specs/2026-06-03-agent-credential-lifecycle.md`) locks D3
  as "credential source resolved + cap-checked at agent CREATE time (human
  caller present), not spawn" and lists "Production runtime auto-refresh (users
  re-login)" under non-goals. `EzagentPluginCc.CredentialRefresh` is also
  documented as "#17 PR-E (TEST/E2E ONLY)" and "NOT for production runtime".
  Therefore the safe handoff status is:
  - production keeps the explicit `/login` + PR-C owner notification flow;
  - PR-E remains a non-prod/E2E provisioner;
  - any spawn-time production refresh/copy needs Allen to approve a new
    cap-checked credential-source model, not a direct call to the test
    provisioner from `ensure_subprocess_alive`.

- **#11 / #533 single authorized create path + manage-cap grant — IN PROGRESS
  IN PR-5 (2026-06-04).** The approved direction is to route user/operator
  session creation through `Ezagent.Workspace.create_session/3`, keep
  instance-message materialization as an internal implementation detail, and
  grant creator Manage caps through the shared create-time grant policy.
  Relevant docs:
  `docs/superpowers/specs/2026-06-02-domain-agent-design.md` §3.3/§4 and
  `docs/superpowers/specs/2026-06-01-unified-kind-creation-via-templates.md`.

- **#24 narrow default user session cap (§3.11) — PROD/#21 ADJACENT BLOCKER.**
  This gates a production Docker image because `Ezagent.Behavior.Manage` makes
  session management depend on narrowing the current broad default session cap.
  Keep it visible for the #21 prod-image review, but do not fold it into
  Dockerize or merge to `main` from this handoff branch without explicit scope.

- **#20 consolidate test-only snapshot writers — DONE.** Cleanup PR #565 makes
  ordinary tests seed snapshot rows through `Ezagent.Test.SnapshotFixtures`,
  with `test_snapshot_fixture_access_test.exs` preventing new direct fixture
  writes to `Ezagent.Kind.Snapshot.save_now/3` and
  `Ezagent.Ecto.KindSnapshot.upsert/5`. Low-level lifecycle/snapshot invariant
  tests remain explicitly allowlisted because they exercise the primitive
  persistence boundary itself.

- **ExternalMirror flaky tests x3 — RESOLVED.** The flaky publish/rehydration
  failures were isolated from #21 and fixed as ExternalMirror reliability PRs.
  Merged to `domain-agent-handoff` as PR #563 (`017b8d2f`) and follow-up PR
  #566. The fixes make Worker publish tests use unique sessions, wait for the
  Worker's deferred Publisher subscription before asserting publish delivery,
  and wait for cold-spawn re-subscription via the Session publisher subscriber
  map instead of a fixed sleep.

- **#22 harden node RPC/distribution console — GATED SECURITY SCOPE.** Needs
  Allen to choose the deployment posture (dev node convenience vs production
  distribution hardening). Naturally relevant to #21 prod image lockdown, but
  should be a security-scoped PR/spec rather than an incidental Docker change.

- **#25 architecture discussion — PENDING DISCUSSION DELIVERABLE.** The
  `improve-codebase-architecture` skill was installed in the cc-openclaw
  environment; the remaining work is a discussion/proposal deliverable, not a
  code patch in this handoff branch unless Allen asks for a written spec.

## Architecture clarity (Allen 2026-06-03)

- **Install + run `improve-codebase-architecture` skill to clarify the ESR
  architecture.** Skill installed at `.claude/skills/improve-codebase-architecture/`
  (cc-openclaw). Use it (informed by `UBIQUITOUS_LANGUAGE.md` + the `GLOSSARY.md`
  decisions log) to surface "deepening opportunities" — shallow modules, leaky
  seams, RBK / Kind / Behavior / Template / domain.agent layering friction — and
  discuss how to make the codebase deeper, more testable, more AI-navigable. The
  discussion + proposals are the deliverable.
