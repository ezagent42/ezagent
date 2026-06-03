# Plan — per-flavor config form surface (#18) + entrypoint-audit follow-up (#19)

Scope: ALL changes confined to `apps/ezagent_plugin_liveview/*`. Any change needed
outside the plugin is a STOP-and-report blocker (other in-flight PRs own those files).

## Track #19 — LV entrypoint audit follow-up (audit/checklist FIRST)

### Findings (verified against current source, not taken on faith)

`docs/notes/lv-entrypoint-audit.md` (landed as #500) is a **completed** audit, not
a live checklist. It has three answered questions:

- **Q1 reachability** — every runtime operator feature is LV-reachable; the only
  gaps (plugin install, host-migration/bootstrap/dev tooling) are deliberately
  CLI-only. Verified: `/identities/agents/new`, `/admin/routing`,
  `/plugins/feishu/bindings`, `/admin/snapshots`, `/workspaces[/:name]` all exist
  in `apps/ezagent_web/lib/ezagent_web/router.ex`. `LvCliParityTest` exists
  (`apps/ezagent_core/test/invariants/lv_cli_parity_test.exs`).
- **Q2 placement/styling** — confirmed GREEN in the doc's own "Q2 — visual
  validation (agent-browser, live :10042)" section (both flagged items closed).
- **Q3 decision procedure** — documented, routes verified.

There are **no unchecked checkbox items, no TODO/FIXME, no follow-up list** in the
doc (grep confirms). The single concrete defect the audit *text* surfaces is the
**misleading a11y label**: the workspace dropdown carries
`aria-label="Switch workspace"` (`切换工作区`) on BOTH perspectives, but on the
`:admin` perspective the rendered control shows the `system` context, not a
workspace switcher.

### Follow-up action taken (#19)

- The misleading-label fix lives in `apps/ezagent_domain_ui/lib/.../ide_shell.ex`
  (`workspace_dropdown/1`) — **OUTSIDE the plugin**. Per scope rule this is a
  **flagged blocker**, NOT changed here. Documented in the PR body + this plan.
- Audit doc updated with a "Closure (2026-06-03)" note recording that the doc has
  no open code items and the one residual a11y nit is owned by `ezagent_domain_ui`
  (cross-link), so the audit is not silently treated as "more to do."

No code follow-up is in-scope-and-actionable for #19; the value delivered is the
verification (claims confirmed non-stale) + the explicit closure/handoff note.

## Track #18 — per-flavor config form surface ("config_surface :form" V2)

### Current state

The V2 form mechanism is **already substantially built** and is the right one:

- `Ezagent.UI.Form` (core) — behaviour with `form_fields/0`, `form_to_args/1`,
  `implements?/1`, `list_form_classes/0`. Field shape:
  `%{name, type (:text|:path|:uri|:select), label, required?, placeholder?, options?, default?}`.
- All 5 flavors implement `form_fields/0` with DISTINCT fields:
  cc (2: agent_uri, cwd), codex (5: +model/approval_policy/sandbox selects),
  curl (4+: provider/api_url/model/...), np, echo.
- `workspace_detail_live.ex` (the "Add template" flow) already renders the
  per-flavor fields generically: class picker → `form_fields/0` → field-type-aware
  inputs (`:select`/`:path`/`:text`) + JSON escape hatch.

### Gap (the actual #18 work)

The field-rendering is **inlined** in `workspace_detail_live.ex` (~45 lines of HEEx
+ helpers `input_class_for/1`). It is a one-off, not a reusable surface. The 3-layer
UI contract + North Star (plugin isolation) say this belongs in a **Layer-2 plugin
composition component** so any LV (the add-template form today, future per-flavor
config-edit surfaces tomorrow) renders flavor config the same way without
re-inlining.

### Target

New Layer-2 component module `EzagentPluginLiveview.ConfigForm` inside the plugin:

- `config_fields/1` — stateless `Phoenix.Component`. `attr :fields` (the
  `form_fields/0` list), `attr :name_prefix` (form field namespace, e.g.
  `"add_template"`), `attr :values` (optional current values for edit mode, default
  `%{}`). Renders one row per field, type-aware (`:select`/`:path`/`:uri`/`:text`),
  dark-mode-paired, `font-mono` for path/uri — matching the existing inlined markup
  exactly so the add-template UI is unchanged.
- `flavor_config_fields/1` — thin wrapper that resolves a flavor's fields from
  `Ezagent.UI.Form` (via the template class) and delegates to `config_fields/1`.
  This is the "config_surface :form" entry: given a flavor/class, render its config.
- `workspace_detail_live.ex` refactored to call `<ConfigForm.config_fields .../>`
  instead of the inlined block — proving reuse + keeping behavior identical.

All inside the plugin. No core/template/flavor/sandbox edits. (The flavors already
expose `form_fields/0`; I consume it.)

### TDD

`test/config_form_test.exs` — `render_component/2` assertions:
- cc renders exactly its 2 fields (agent_uri, cwd), no model/sandbox.
- codex renders its selects (approval_policy options never/on-request/untrusted;
  sandbox read-only/workspace-write/danger-full-access) — proving per-flavor
  divergence.
- curl renders provider/api_url/model.
- `:path`/`:uri` fields get `font-mono`; `:select` renders `<option>`s.
- `name_prefix` namespaces the input `name=` attrs.
- `values` pre-fills inputs (edit mode).

Plus keep `workspace_add_template_live_test.exs` green (regression: refactor must
not change add-template behavior).

### Structural-fix discipline

No shims/defaults-as-fix. If a flavor doesn't implement `form_fields/0`, the JSON
escape hatch already covers it (existing behavior) — that's a real branch, not a
degrade-path bolted on for this change.
