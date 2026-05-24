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
- **HIGH-3** (~12 LV handle_events have no CLI equivalent): need
  facade-ops for `create_session`, `add_member`, `promote_to_system`,
  `grant_cap`, `revoke_cap`, `save_smtp`, `save_registration_domains`
  [now removed per PR #299], `delete_rule`, `disable_rule`,
  `enable_rule`. Per `feedback_completion_requires_invariant_test`,
  add an enumerating invariant that fails when an LV event has no
  CLI counterpart.

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
