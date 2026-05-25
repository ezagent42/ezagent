# Durable TODO — items deferred to future PRs

> Per `feedback_durable_todo_list` (Allen 2026-05-22): the in-memory
> TaskCreate is session-scoped; this file is the source of truth for
> in-flight + future work that crosses sessions.

## Active follow-ups (post-2026-05-24 batch)

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
  migration template, hold an invariant test that `mix esr` is the
  ONLY task allowed to call domain modules outside of bootstrap.

  **Sweep progress (this PR — triage commit on
  `cli-sweep/deprecate-bypass-tasks`):**

  - ✅ `routing.add_rule` — already deprecated in PR #302 (Behavior
    `Ezagent.Behavior.Routing` exists; `mix esr routing add_rule`
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
    `mix esr` will then auto-derive the CLI from the Behavior's
    `interface/0`. Wiring a FacadeRegistry shortcut "to ship it
    faster" is the wrong fix — it would close HIGH-2 by closing
    the wrong problem.

    | Legacy task | Proposed `mix esr` | Behavior + action to add FIRST |
    |---|---|---|
    | `mix ezagent.user.create` | `mix esr user create --uri … --password … --caps …` | `Ezagent.Entity.User` Behavior action `:create` + cap subject; existing `Ezagent.Users.create/3` becomes its `invoke/4` body |
    | `mix ezagent.user.set_password` | `mix esr user set_password --uri … --password …` | `Ezagent.Entity.User` `:set_password` action + cap (`:user, :set_password, …`); body wraps existing `Ezagent.Users.set_password/2` |
    | `mix ezagent.agent.create` | `mix esr agent create --uri … --caps …` | `Ezagent.Entity.Agent` `:create` action + cap; body matches LV path (audit Finding 4) — `add_template + invoke_template_now` |
    | `mix ezagent.user.token mint` | `mix esr user token mint --for … --label …` | `Ezagent.Entity.User` `:mint_token` action + cap. **Codex PR #304 MED carve-out:** `user.token` is NOT pure bootstrap (also lists + revokes for arbitrary users); only the FIRST-admin-bootstrap mint stays in the legacy task |
    | `mix ezagent.user.token list` | `mix esr user token list` | `Ezagent.Entity.User` `:list_tokens` action + cap |
    | `mix ezagent.user.token revoke` | `mix esr user token revoke --token-id …` | `Ezagent.Entity.User` `:revoke_token` action + cap |
    | `mix ezagent.feishu.bind` | `mix esr feishu bind --open-id … --user-uri … [--admin …]` | new `EzagentPluginFeishu.Behavior.UserBinding` on `Workspace` Kind with `:bind` action + cap; body uses `UserBinding.bind/3 + BindingPolicy.apply/2` |
    | `mix ezagent.feishu.unbind` | `mix esr feishu unbind --open-id …` | same Behavior, `:unbind` action |
    | `mix ezagent.feishu.list` | `mix esr feishu list` | same Behavior, `:list` (read-only cap subject) |
    | `mix ezagent.feishu.chat.bind` | `mix esr feishu chat_bind --chat-id … --session-uri …` | new `EzagentPluginFeishu.Behavior.SessionBinding` on `Session` Kind with `:bind` action + cap |
    | `mix ezagent.feishu.chat.unbind` | `mix esr feishu chat_unbind --chat-id …` | same Behavior, `:unbind` action |

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
- **HIGH-3** (~12 LV handle_events have no CLI equivalent): need
  facade-ops for `create_session`, `add_member`, `promote_to_system`,
  `grant_cap`, `revoke_cap`, `save_smtp`, `save_registration_domains`
  [now removed per PR #299], `delete_rule`, `disable_rule`,
  `enable_rule`. Per `feedback_completion_requires_invariant_test`,
  add an enumerating invariant that fails when an LV event has no
  CLI counterpart.

### `/admin/uploads/:filename` controller route — scope mismatch
Codex PR #305 round-4 HIGH (2026-05-24): the chat-compose-upload
download endpoint sits under the `/admin/*` URL prefix but is a
plain controller route, so the centralized `live_session
:require_admin` (PR #305) does NOT gate it. The controller is
misnamed — chat uploads are user-scope, not admin-scope.

**Fix sequence:**
1. Move route from `get "/admin/uploads/:filename", UploadsController, :show`
   to `get "/files/:filename", UploadsController, :show` (or
   similar non-admin prefix)
2. In `UploadsController.show/2`, verify the caller is either
   (a) the uploading user, OR (b) a member of any session the
   file is attached to with read-cap. Reject otherwise.
3. Add regression test: non-admin caller cannot fetch files
   uploaded by another user/workspace via `/files/:filename`
   guessing.
4. After the move, ALL remaining routes under `/admin/*` are
   pure LiveView, so the `live_session :require_admin` gate is
   complete by inspection.

PR #305 cannot land this fix (out of scope for the audit-LOW
batch + would touch the chat upload pipeline which has its own
LV tests to update). Tracked here as the gating follow-up
before the admin-gate invariant can be claimed complete.

### `Workspace.Registry.default_workspace_uri/0` legacy fallback
Still returns `"workspace://default"` for the NOT NULL `workspace_uri`
on audit/snapshot rows fired by system events. After PR-C #295 +
PR-F #297 deleted the `default` workspace from boot, this fallback
points at a non-existent row. Re-routing requires a ~100-fixture
migration; flagged in `apps/ezagent_domain_workspace/lib/ezagent/workspace_registry.ex`
docstring as legacy.

### Notifications consumer coverage
PR #300 wired AdminLive as the operator subscriber + added notify
calls to `Workspace.add/remove_member` and `Identity.grant/revoke_cap`.
Additional producers still silent:
- `Chat.join` — should notify the joinee
- `agent.terminate` — should notify spawning principal
- `agent_template.fork` — should notify the fork-owner

Add to relevant Behavior `:action` clauses, gated by `user_uri?/1`.

### PR5: `Agent.duplicate/clone` (cross-user agent copy)
Per `feedback_agent_clone_not_via_template` — direct agent-to-agent
copy via a new `Ezagent.Entity.Agent.clone/3` primitive (NOT through
Template Registry). Reads source agent's `:sandbox.config_dir_path`,
copies to a new agent-private location, reuses same `template_class`,
spawns new Agent Kind. Cross-workspace caps via a separate cap-bridge
mechanism (TBD).

### Audit gaps from notification-log audit
Still open after PR #300 + the batch fix that includes this todo:
- **LOW** — `EzagentWeb.Telemetry.metrics/0` defines 16 metrics but
  no reporter is attached in prod. Either attach a `TelemetryMetricsPrometheus`
  reporter at boot OR delete the unused metrics decl.
- **LOW** — write a SPEC for the notifications system at
  `docs/superpowers/specs/notifications.md` (currently only moduledoc).
- **LOW** — `ObservabilityLive` reads audit rows without
  `workspace_uri` filter; Phase 9 PR-6 added the column but the
  READ-side never landed. Add the filter + a per-workspace caps check.

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
1. **DONE** (this PR) — `Capability.cross_workspace?/2` `apply/3` →
   `Workspace.Store` is documented in `feedback_let_it_crash_no_workarounds`-
   compliant style; layer_purity_test explicit allowlist update
   pending.
2. **DONE** (this PR) — marketplace toggle deferred record (see top).
3. **TBD** — `AgentExtensionsLive.authorized_to_toggle?/1` rebuilds
   cap shape by hand; should call `Capability.cap_for_action/3`.
4. **TBD** — workspace SoT (`list_visible` vs `list_persisted`) is
   enforced by convention only; needs an invariant test (e.g. grep
   that no operator LV calls `list_persisted/0`).
5. **DONE** (PR-F #297) — `Registration.create_principal/3` "default"
   default arg removed.
