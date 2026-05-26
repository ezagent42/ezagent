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
  | **`create_session`** | ⏳ DEFERRED. Needs a `:create_session` action on `Behavior.Workspace` (parallels `:create_agent` from PR #344). LV currently calls `EzagentDomainChat.create_session/3` directly — bypasses dispatch in BOTH surfaces. |
  | **`create_user`** | ✅ **DONE (2026-05-26).** `Behavior.Workspace :create_user` (see HIGH-2 table). Auto-derived `mix ezagent workspace create_user`. |
  | **`set_password`** | ✅ **DONE (2026-05-26).** New `Behavior.UserCredentials :set_password` on User Kind (see HIGH-2 table). Auto-derived `mix ezagent user set_password`. |
  | **`save_display_name`** | ⏳ DEFERRED. Needs Behavior on User Kind for `:set_display_name` (Profile slice); LV uses `Ezagent.Entity.Profile.upsert/1` directly. |
  | **`save_smtp`** | ⏳ DEFERRED. Needs Behavior on App/SystemSettings Kind for `:save_smtp_config`; LV uses `Ezagent.AppSettings.put/2` directly. |
  | **`chat_compose`** | ⏳ DEFERRED. CLI is partial — text-only via `mix ezagent session send`; file attachments need a `resource://` upload primitive that doesn't exist yet (audit Finding row 1). |

  The remaining ⏳ DEFERRED rows are the residual gaps. Each is
  enumerated in the invariant test's `@event_to_cli` table with
  category `:deferred` and a `docs/futures/todo.md` citation.
  Post-2026-05-26 HIGH-2 completion: `create_user` + `set_password`
  closed; 4 deferred rows remain (`chat_compose`, `create_session`,
  `save_display_name`, `save_smtp`).

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
- ✅ `Chat.join` notifies joinee (`apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex` `invoke(:join, …)` — `:session_member_joined`)
- ✅ `agent.terminate` notifies spawning principal via `AgentLineage.lookup/1` (`apps/ezagent_core/lib/ezagent/behavior/lifecycle.ex` `invoke(:terminate, …)` — `:agent_terminated`)
- ✅ `agent_template.fork` notifies fork-owner (`apps/ezagent_domain_chat/lib/ezagent/behavior/template.ex` `fork_agent_template/3` — `:agent_template_forked`)

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
