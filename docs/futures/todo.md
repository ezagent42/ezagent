# Durable TODO — items deferred to future PRs

> Per `feedback_durable_todo_list` (Allen 2026-05-22): the in-memory
> TaskCreate is session-scoped; this file is the source of truth for
> in-flight + future work that crosses sessions.

## Active follow-ups (post-2026-05-24 batch)

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
  - ⏳ **deferred to follow-up PRs** — each below needs a
    FacadeRegistry op (or Behavior action) BEFORE its legacy task
    can be deprecated. Without that, deprecation would lose operator
    capability.

    | Legacy task | Proposed `mix esr` | Wire-through |
    |---|---|---|
    | `mix ezagent.user.create` | `mix esr user create --uri … --password … --caps …` | New FacadeRegistry op `(:user, :create)` → `Ezagent.Users.create/3` |
    | `mix ezagent.user.set_password` | `mix esr user set_password --uri … --password …` | New FacadeRegistry op `(:user, :set_password)` → `Ezagent.Users.set_password/2` |
    | `mix ezagent.agent.create` | `mix esr agent create --uri … --caps …` | New FacadeRegistry op `(:agent, :create)` → `Ezagent.Workspace.add_template + invoke_template_now` (matching LV — audit Finding 4) |
    | `mix ezagent.feishu.bind` | `mix esr feishu bind --open-id … --user-uri … [--admin …]` | New FacadeRegistry op `(:feishu, :bind)` → `UserBinding.bind/3 + BindingPolicy.apply/2` |
    | `mix ezagent.feishu.unbind` | `mix esr feishu unbind --open-id …` | New FacadeRegistry op `(:feishu, :unbind)` → `UserBinding.unbind/1` |
    | `mix ezagent.feishu.list` | `mix esr feishu list` | New FacadeRegistry op `(:feishu, :list)` → `UserBinding.list_all/0` |
    | `mix ezagent.feishu.chat.bind` | `mix esr feishu chat_bind --chat-id … --session-uri …` | New FacadeRegistry op `(:feishu, :chat_bind)` → `SessionBinding.bind/2` |
    | `mix ezagent.feishu.chat.unbind` | `mix esr feishu chat_unbind --chat-id …` | New FacadeRegistry op `(:feishu, :chat_unbind)` → `SessionBinding.unbind/1` |

  - ✅ **CLI-only by design (will NOT be migrated, audit-confirmed
    carve-outs):** `bootstrap`, `check_invariants`, `db.reset`,
    `home.adopt_db`, `home.init`, `plugin.install`, `snapshot.list`,
    `snapshot.dump`, `stress`, `user.token` (bootstrap-token
    primitive; chicken-and-egg with `mix esr`), `auth.magic_link`
    (operator-debug mirror of HTTP path), `demo.seed_cc_agent` /
    `demo.seed_cc_sandbox` (demo seeders, not operator ops). Each
    file now carries a "Category A" audit comment in its moduledoc.
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
