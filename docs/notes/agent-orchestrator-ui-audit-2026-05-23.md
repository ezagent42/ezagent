# Agent + Orchestrator UI Audit — 2026-05-23

## §0 Audit context

- **Ask**: Allen Feishu 2026-05-23 — "Audit the existing UI for agent + orchestrator features. What exists? What's missing? Does the implementation follow ezagent's best-practice layering (3-tier rule, primitives-only-in-domain_ui, dispatch invariants)?"
- **Scope**: read-only investigation across `apps/ezagent_domain_ui/`, `apps/ezagent_plugin_liveview/`, `apps/ezagent_web/lib/ezagent_web/router.ex`, `apps/ezagent_domain_instance_message/lib/ezagent/orchestrator/`, and the Phase-7 Kinds (`Ezagent.Entity.AgentTemplate`, `Ezagent.Entity.SessionTemplate`, `Ezagent.Behavior.Template`). One docs commit only — no code changes.
- **Yardstick**: `ezagent-developer` SKILL.md "Design Principles" P1-P26 (consolidated authoritative set landed in PR #252), the **3-tier rule (P8/P9)**, **UI Contract** §"3-layer UI architecture" + §"Nested shell architecture" + DO/DON'T lists, and the dispatch/cap invariants P14/P15.

This doc is the §1 inventory, §2 gap table, §3 per-element layering verdict, §4 cross-layer violation list, §5 best-practices verdict, §6 V1-blocker vs V2-backlog recommendation.

## §1 Inventory — every LV / shell component with an agent/orchestrator angle

24 LiveView modules in `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/`; 13 of them touch agent / orchestrator / template surfaces. Tier-2 (`ezagent_domain_ui`) primitive components: 14 atoms + 4 shell components + 1 auto-derive + 3 SessionView surfaces. Tier-3 plugin-LV composites: 2 (`MemberPanel`, `SessionEditor`).

### Routes (cross-referenced from `apps/ezagent_web/lib/ezagent_web/router.ex`)

| URL | LV module | Shell perspective | Subject |
|---|---|---|---|
| `/sessions` | `EzagentPluginLiveview.AdminLive` | `:workspace` | Session activity (SessionEditor + MemberPanel + view-switcher) |
| `/admin` | `EzagentPluginLiveview.AdminDashboardLive` | `:admin` | KPI dashboard (links into sub-pages) |
| `/admin/logs` | `EzagentPluginLiveview.ObservabilityLive` | `:admin` | Audit stream, CC bridges list, kind_snapshots SQL |
| `/admin/registry` | `EzagentPluginLiveview.EntitiesLive` | `:admin` | KindRegistry browser (all schemes incl. `template://`) |
| `/admin/snapshots` | `EzagentPluginLiveview.SnapshotsLive` | `:admin` | `kind_snapshots` table dump + delete |
| `/admin/settings` | `EzagentPluginLiveview.SettingsLive` | `:admin` | Admin SMTP / registration domain config |
| `/workspaces` | `EzagentPluginLiveview.WorkspacesLive` | `:admin` | Workspace list |
| `/workspaces/:name` | `EzagentPluginLiveview.WorkspaceDetailLive` | `:admin` | Members, **legacy** workspace.session_templates map, routing |
| `/routing` | `EzagentPluginLiveview.RoutingLive` | `:workspace` | Routing rule editor (global default scope) |
| `/identities` (+ `/identities/users`, `/identities/agents`) | `EzagentPluginLiveview.IdentitiesLive` | `:workspace` | Address-book — users + agents |
| `/identities/agents/new` | `EzagentPluginLiveview.AgentNewLive` | `:workspace` | Create agent (flavor + name + caps + cwd + with-PTY) |
| `/identities/agents/:uri` | `EzagentPluginLiveview.AgentDetailLive` | `:workspace` | Per-agent status, lifecycle, bridge, inline `<details>` PTY |
| `/identities/agents/:uri/caps` | `EzagentPluginLiveview.EntityCapsLive` | `:workspace` | Per-entity cap grant/revoke |
| `/identities/agents/:uri/api-keys` | `EzagentPluginLiveview.UserApiKeysLive` | `:workspace` | API keys (for owner User of a curl agent) |
| `/identities/agents/:uri/terminal` | `EzagentPluginLiveview.TerminalLive` | `:workspace` | Standalone xterm window |
| `/plugins` | `EzagentPluginLiveview.PluginsLive` | `:workspace` | Registry-driven plugin cards |
| `/plugins/feishu/bindings` | `EzagentPluginLiveview.FeishuBindingsLive` | `:workspace` | Feishu chat-id ↔ session bindings |
| `/plugins/auto/:kind` / `:kind/:uri` | `EzagentPluginLiveview.AutoDeriveLive` | `:workspace` | Generic Kind browser (slice inspect dump) |
| `/profile` | `EzagentPluginLiveview.ProfileLive` | `:workspace` | Personal profile / display name / avatar |

### Tier-2 components (`ezagent_domain_ui`)

| Module | Tier | Role |
|---|---|---|
| `EzagentDomainUi.Components` (button/card/badge/page_header/breadcrumb/stat/plugin_card) | 1 (atoms) | Page-level atoms |
| `EzagentDomainUi.Primitives` (status_dot/avatar/tabs/modal/toast/tree_list/empty_state/form_field/uri_chip/uri_picker/toolbar/tooltip/icon) | 1 (atoms) | Low-level atoms |
| `EzagentDomainUi.IdeShell.ide_shell_outer` | 1 (chrome) | Outer shell — header + CmdK slot + body slot |
| `EzagentDomainUi.WorkspaceShell.workspace_shell` | 1 (chrome) | Inner workspace perspective (activity bar / resource panel / main / right sidebar / status bar) |
| `EzagentDomainUi.AdminShell.admin_shell` | 1 (chrome) | Inner admin perspective |
| `EzagentDomainUi.AutoDerive` | 2 (utility) | List/detail introspection of any live Kind |
| `EzagentDomainUi.SessionViewRegistry` + `SessionView` | 2 (registry) | Plugin-registered view registry for `:main_view` |
| `EzagentDomainUi.Pty.Terminal` / `TerminalSeam` / `TerminalView` | 2 (PTY) | xterm.js Phoenix hook + dispatch seam + SessionView impl |
| `EzagentDomainUi.Routing.RoutingView` | 2 (SessionView) | Routing as a SessionView (peer of Chat) |
| `EzagentDomainUi.UriOptions` | 2 (data) | Caller-authorized URI option lookup |
| `EzagentDomainUi.CommandSource` | 2 (data) | CmdK ranking pure fn |
| `EzagentDomainUi.Gettext` | 2 (i18n) | Tier-2 i18n backend |

### Tier-3 plugin-LV composites

| Module | Role |
|---|---|
| `EzagentPluginLiveview.AppShell.app_shell` | The single entry point — wires CmdK ONCE, accepts `perspective` |
| `EzagentPluginLiveview.CommandPaletteComponent` | Stateful CmdK LiveComponent |
| `EzagentPluginLiveview.Admin.SessionEditor` | Session-header + main-view slot + composer |
| `EzagentPluginLiveview.Admin.MemberPanel` | Unified member list + Invite modal |
| `EzagentPluginLiveview.Views.ConversationView` | SessionView impl for chat history stream |

## §2 Gaps — what's missing, with severity

For agent/orchestrator-related Phase-7 deliverables, the UI coverage is **partial**: agents are well-supported (create / list / detail / caps / terminal / kill via restart), but the entire **AgentTemplate / SessionTemplate / orchestrator working-copy / Generator** surface is invisible. Phase-7 introduced 8+ new operator-relevant concepts; the UI surfaces 1 (`/identities/agents/*`).

| # | Missing feature | Today's state | Severity | Owner | Sketch of fix |
|---|---|---|---|---|---|
| G-1 | **AgentTemplate CRUD LV** | Zero UI. `AgentTemplate` Kind exists (`Ezagent.Entity.AgentTemplate`, type_name `:agent_template`, snapshot `:on_change`); operators can only create one via `mix ezagent.agent_template.create` or by re-running `CcOrchestratorSeed.seed/0`. The `/admin/registry` filter chips don't even include `template://`'s type axis. | **V1 blocker** | `ezagent_plugin_liveview` | Add `/agent-templates` (list) + `/agent-templates/new` (form: name, flavor, cwd, claude_config_dir, settings_path, mcp_config_path) + `/agent-templates/:uri` (edit). Dispatches `?action=template.write` on `template://agent/<ws>/<name>` via `Invocation.dispatch`. Reuse `AutoDerive` for raw read-only first, then promote to form. |
| G-2 | **SessionTemplate CRUD + fork + instantiate LV** | Zero UI. `SessionTemplate` carries `agent_slots`, `routing_rules`, `orchestrator_template_uri`, `parent_template_uri`, `version_hash` — none surfaced. `Ezagent.Entity.SessionTemplate.fork/2` and `persist_version/2` have NO UI trigger. `Session.spawn_from_template/2` (the **Generator**) is only invoked by orchestrator MCP tool path. | **V1 blocker** | `ezagent_plugin_liveview` | Add `/session-templates` (list w/ version graph + fork count), `/session-templates/:uri` (read slot config + routing rules + parent lineage chip), `/session-templates/:uri@<hash>` (specific version), `[Fork]` button → dispatch `template.write` (new SessionTemplate URI with `parent_template_uri = source@hash`), `[Spawn Session]` button → dispatch `Session.spawn_from_template`. |
| G-3 | **Orchestrator + working-copy view** | Zero UI. The `template_working_copy` field on Session's `:chat` slice — the durable record showing "what slots are filled, with which AgentTemplate URIs, plus the orchestrator's pending edits" — is unread by any LV. No way to see "what is this session's orchestrator looking at right now?" outside `:sys.get_state` via `/admin/snapshots`. | **V1 blocker** | `ezagent_plugin_liveview` | In SessionEditor, add an `:orchestrator` SessionView (registered via `SessionViewRegistry.register`) that reads `Chat.template_working_copy/1` and renders agent_slots + orchestrator_template_uri + routing_rules. Show divergence vs `parent_template_uri@hash` so operator sees "what's pending". |
| G-4 | **Orchestrator MCP tool surface (the 7 tools)** | Zero UI. The 7 tools (`add_agent_slot` / `remove_agent_slot` / `update_agent_template` / `write_matcher` / `update_template` / `save_template_as` / `list_templates`) are only invokable via the LLM-driven MCP transport. Operator can't manually trigger any of them from UI to debug "did the orchestrator try this?" or "force this slot for me". | **V2 nice-to-have** | `ezagent_plugin_liveview` (or new admin/operator surface) | Add a per-session "Orchestrator Tools" panel (admin-only, gated by cross-workspace cap) that dispatches each tool against the bound session's orchestrator context. NOT a chat-replacement — a debug + override surface. |
| G-5 | **Generator-run observation (partial-state report)** | Zero UI. `Session.spawn_from_template/2` is multi-step (per `apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex:121-132`); failures leave the session partially-instantiated. The recent PR #248-#250 (Generator round 8-10) added cleanup, but no UI shows "this session was generated from `template://session/.../v1@<hash>`, slots [A,B,C], B failed, OS pid 4711 leaked". | **V1 blocker** | `ezagent_plugin_liveview` | Add a Generator-run report card on `/sessions/:uri` (when session has a `parent_template_uri`): source template + hash + slot-by-slot status (alive / dead / orphan-reaped). Source the data from `Chat.template_working_copy/1` + `KindRegistry.lookup` per slot URI + audit log of `Behavior.Lifecycle` events. |
| G-6 | **TemplateTags list/move** | Zero UI. `Ezagent.TemplateTags` (`apps/ezagent_core/lib/ezagent/template_tags.ex`) — workspace-scoped `name → tag → hash` resolver — has no operator surface. The orchestrator's `update_template` writes `stable`-tag bumps; operator can't see, move, or roll back a tag without `mix run` or SQL. | **V2 nice-to-have** | `ezagent_plugin_liveview` (subpage of /session-templates) | Per-template tags table + move-tag button (dispatch via new `template.move_tag` Behavior action on the same `template://session/...` URI — keep tool list at 7 by NOT adding a new tool; just expose the existing TemplateTags API behind the existing `Behavior.Template`). |
| G-7 | **AgentTemplate / SessionTemplate filter chip on `/admin/registry`** | The `EntitiesLive` filter chips include `template://` (line 121) but the LV cannot distinguish `template://agent/*` vs `template://session/*` — the chip just shows raw URIs. AutoDeriveLive at `/plugins/auto/:kind` accepts `agent_template` + `session_template` atoms but no nav from `/admin/registry`. | **V2 nice-to-have** | `ezagent_plugin_liveview` | Add row click → `/plugins/auto/agent_template/<encoded-uri>` (or `/plugins/auto/session_template/...`); split the `template://` chip into `template://agent` + `template://session`. |
| G-8 | **Flavor list is hardcoded in `agent_new_live`** | `AgentNewLive` has `@flavors ~w(cc echo curl)` (line ~62) — adding a Python agent flavor requires editing `ezagent_plugin_liveview`. `Ezagent.AgentFlavorRegistry` is the canonical SoT — the UI must read from there. | **V1 blocker** | `ezagent_plugin_liveview` | Replace `@flavors` with `Ezagent.AgentFlavorRegistry.list_flavors/0`. Per P1 + P11: a new agent flavor plugin should never require an edit to `ezagent_plugin_liveview`. |
| G-9 | **cc-orchestrator template surfacing** | The seeded `template://agent/default/cc-orchestrator` AgentTemplate (`CcOrchestratorSeed`) is invisible. There's no way to confirm via UI that it seeded, what its sandbox path is, or whether its MCP bridge install succeeded. | **V1 blocker** | `ezagent_plugin_liveview` (sub-case of G-1) | Show in the AgentTemplate list (G-1); add a "boot-seed status" badge if it's the singleton. Surface `CcOrchestratorSeed.InstallError` via flash + `/admin/logs`. |
| G-10 | **Agent restart is cc-only and hand-rolled** | `AgentDetailLive.handle_event("restart", ...)` calls `Ezagent.Domain.Pty.lookup/1` directly + `Process.exit/2` — no `Behavior.Lifecycle` dispatch, no audit, no cap check. The moduledoc itself acknowledges "Direct plugin reference here is the documented exception per invariant 8". | **V2 nice-to-have** (the underlying Behavior is missing — P22 says reliability primitives belong in core; this is the gap behind the UI) | `ezagent_domain_instance_message` (Behavior) + `ezagent_plugin_liveview` (UI) | Add a `Behavior.Lifecycle` `:restart` action on the Agent Kind that dispatches downward to the flavor's restart fn; replace the UI `Process.exit` with `Invocation.dispatch`. |
| G-11 | **Agent termination from UI** | No "Terminate" button on `/identities/agents/:uri`. Operator must kill via `mix` task or BEAM shell. `Behavior.Lifecycle` `:terminate` is invocable via dispatch + caps. | **V2 nice-to-have** | `ezagent_plugin_liveview` | Add danger-variant button on AgentDetailLive that dispatches `?action=lifecycle.terminate` (modal-confirmed). |
| G-12 | **Workspace.session_templates is legacy + duplicates Phase-7 Kinds** | `WorkspaceDetailLive` renders `@workspace.session_templates` — a Phase-4d freeform `%{name => %{"class" => ..., ...}}` map living in `Workspace.Store`. This is OLD (pre-Phase-7) and ORTHOGONAL to the AgentTemplate/SessionTemplate Kinds. Operators looking at "templates" today see only the Phase-4d records, NOT the real Kinds. Violates P3 (single source of truth — "templates" now lives in two places). | **V1 blocker** (data-architecture cleanup, but flagged here as a UI symptom) | `ezagent_domain_instance_message` (decide which is canonical) + `ezagent_plugin_liveview` | Either retire the legacy `workspace.session_templates` map and have `WorkspaceDetailLive` read from `KindSnapshot.list_in_workspace/1` filtered to `template://`, OR rename the legacy field to make clear it's "spawn-template registrations" (not SessionTemplate Kinds). Recommend the former. |

## §3 Layering verdict per agent/orchestrator-related element

Verdict abbreviations: ✓ = conforms, ⚠ = partially conforms (degraded but not actively broken), ✗ = violates.

| Element | Verdict | Principle | Notes |
|---|---|---|---|
| `AgentDetailLive` uses `<.button>` / `<.icon>` / `<.card>` (Tier-2 atoms) | ✓ | P8 / UI Contract DO list | Per the file's PR-H comment, inline styles were migrated to atoms. |
| `AgentDetailLive` reaches into `EzagentPluginCc.BridgeRegistry` directly (lines 102-103) | ⚠ | P1 / P11 / P24 | Soft-guarded by `Code.ensure_loaded?`. The contract is "no direct plugin imports from UI" — this is one of two documented exceptions (the moduledoc itself calls it out). Should migrate to a `Ezagent.Domain.Agent.bridge_status/1` facade (parallel to the existing `lifecycle_status/1` facade). |
| `AgentDetailLive.handle_event("restart")` calls `Ezagent.Domain.Pty.lookup/1` + `Process.exit/2` | ✗ | P14 (dispatch is the only path) + P15 (cap check) + P22 (audit) | Bypasses dispatch, caps, audit. The moduledoc acknowledges as "documented exception" pending V2 Lifecycle Behavior; that's a deferred-fix flag, not exoneration. |
| `AgentNewLive` hardcodes `@flavors ~w(cc echo curl)` | ✗ | P1 / P11 — plugin-isolation | New flavor plugin = edit ezagent_plugin_liveview. Must read `Ezagent.AgentFlavorRegistry`. |
| `AgentNewLive` uses `Ezagent.Workspace.add_template` for cc/echo flavors | ⚠ | P3 / G-12 | Calls into legacy `workspace.session_templates` map — the Phase-4d data model, not Phase-7's AgentTemplate Kind. Works today but bakes the legacy SoT in. |
| `AgentNewLive` uses `Invocation.dispatch` for cap grants (line 331) | ✓ | P14 / P15 | Correct — `identity.grant_cap` action. |
| `AdminLive` reaches into `EzagentPluginCc.BridgeRegistry` + `EzagentPluginFeishu.SessionBinding` (4+ call sites) | ⚠ | P1 / P11 | Same soft-guard pattern (`Code.ensure_loaded?`). Documented as exceptions; same V2 fix path. |
| `AdminLive` uses `<.button>`, `<.modal>`, `<.uri_picker>` for Invite flow | ✓ | UI Contract DO list | PR #178 + V1 spec §2C.3 migrated this. |
| `MemberPanel` is Tier-3 plugin composite using Tier-1 atoms | ✓ | UI Contract §3-layer | Moduledoc explicitly calls out "stateless — parent owns assigns + handlers." |
| `SessionEditor` is Tier-3 stateless composite, parent owns state | ✓ | UI Contract §3-layer | Same pattern. |
| `IdentitiesLive` reads `Ezagent.KindRegistry.list_all/0` directly (not via a facade) | ✓ | P9 (reads-Kind-data → belongs in plugin LV) | `KindRegistry` is a Tier-1 primitive; reading from it is allowed. |
| `EntitiesLive` renders `<h1 style="font-size: 22px;">`, `<p style="...">`, `<section style="...">`, `<table style="...">` | ✗ | UI Contract DON'T list | 16 `style="..."` occurrences in a file whose only acknowledged migration is "PR-F filter chips inlined." The header / paragraph / table are NOT migrated. |
| `SnapshotsLive` renders `<h1 style="font-size: 22px;">` + `<p style="...color: #666;">` (line 24 = 24 occurrences) | ✗ | UI Contract DON'T list | Same `<h1 style="font-size: 22px; font-weight: 600;">` pattern as EntitiesLive — copy-paste anti-pattern across admin-perspective pages. |
| `UserApiKeysLive` (30 inline style occurrences) | ✗ | UI Contract DON'T list | Same problem. Not directly an agent surface but is reachable from the `/identities/agents/:uri/api-keys` route. |
| `WorkspaceDetailLive` (2 inline style occurrences; mostly migrated per PR-H per moduledoc) | ⚠ | UI Contract DON'T list | Mostly OK — only 2 stragglers. |
| `RoutingLive` (30 inline style occurrences) | ✗ | UI Contract DON'T list | Routing is an orchestrator-adjacent surface (the orchestrator's `write_matcher` tool writes routing rules); the page that operators use to inspect those rules has 30 raw `style=` violations. |
| `AutoDeriveLive` for `template://*` Kinds | ⚠ | UI Contract — works but is read-only inspect-dump | `inspect(state, pretty: true)` is operator-grade, not user-grade. Suffices for V0 visibility, not V1. |
| All Tier-3 LVs wrap render in `<AppShell.app_shell>` over `<WorkspaceShell.workspace_shell>` or `<AdminShell.admin_shell>` | ✓ | Nested shell architecture | Verified across `admin_live`, `agent_detail_live`, `agent_new_live`, `entities_live`, `snapshots_live`, `terminal_live`, `routing_live`, `identities_live`. |
| All `require_entity` LVs benefit from `:put_locale` on_mount via `router.ex` `live_session :require_entity` | ✓ | i18n PR #224 | Confirmed in `router.ex` line 67 + `live_auth.ex` line 101. |
| `terminal_live`, `agent_detail_live` use `Ezagent.Domain.Agent.lifecycle_status/1` facade (NOT direct plugin import) | ✓ | P1 / P24 | The sanctioned facade exists; both LVs use it. Bridge status doesn't have a parallel facade — see ⚠ above. |
| Workspace plumbing (P12) on agent-related routes | ✓ | P12 — workspace_uri threading | `current_workspace_uri` flows in via on_mount; all LVs surface it correctly. |
| `agent_new_live` workspace assignment: hard-codes `@default_workspace_name` for template registration | ⚠ | P12 — workspace plumbing | Agents created from any workspace UI session land in `workspace://default` via the legacy template registration path. Probably wrong for multi-workspace; should use the caller's session workspace. |

## §4 Cross-layer violations found (file:line)

### V-1: Hardcoded plugin flavor list in domain-adjacent UI
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/agent_new_live.ex:62` — `@flavors ~w(cc echo curl)`
- **Violates**: P1 (plugin isolation), P11 (plugin extends, doesn't require core edits), P24 (plugins don't write core).
- **Fix**: read from `Ezagent.AgentFlavorRegistry.list_flavors/0` (the canonical SoT registry already exists per `apps/ezagent_core/lib/ezagent/agent_flavor_registry.ex`).

### V-2: LV bypasses dispatch + caps + audit for "restart agent"
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/agent_detail_live.ex:138-160` — `Process.exit(pid, :shutdown)` on a PtyServer pid obtained via direct `Ezagent.Domain.Pty.lookup/1`.
- **Violates**: P14 (dispatch is the only path), P15 (cap check), P22 (audit telemetry).
- **Fix**: a `Behavior.Lifecycle` `:restart` action on Agent Kind + UI dispatches via `Invocation.dispatch/1`. Moduledoc already flags this as deferred to V2 Lifecycle Behavior — fine to defer, but flag in tracker.

### V-3: LV imports plugin modules directly (multiple call sites)
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/agent_detail_live.ex:102-103` — `EzagentPluginCc.BridgeRegistry.list_connected()`
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/observability_live.ex:35-36` — same
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex:477-478, 1281-1282, 1319-1320, 1418` — `EzagentPluginCc.BridgeRegistry`, `EzagentPluginFeishu.SessionBinding`
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/feishu_bindings_live.ex:52` — `alias EzagentPluginFeishu.{BindingPolicy, SessionBinding, UserBinding}` (no soft-guard)
- **Violates**: P1 (plugin isolation north star), P11 / P24 (plugin extends, never required by other tiers).
- **Mitigation today**: `Code.ensure_loaded?` soft-guard in 5 of 6 sites. `feishu_bindings_live.ex` is hard-coupled (alias at module top, no soft-guard) — that LV literally cannot exist without the Feishu plugin, so it's borderline acceptable as a "plugin's own LV in the wrong app" but is still a layering smell.
- **Fix**: hoist plugin-public APIs to facades (`Ezagent.Domain.Agent.bridge_status/1`, `Ezagent.Domain.Channel.bindings_for_session/1`). The Feishu admin LV should probably move into `apps/ezagent_plugin_feishu/lib/` and register its route from the plugin's `Application.start/2`.

### V-4: Inline `style=""` violations on UI Contract DON'T list
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/entities_live.ex` — 16 occurrences (`<h1 style="font-size: 22px; font-weight: 600;">`, `<p style="font-size: 13px; color: #666;">`, `<section style="margin-top: 16px;">`, `<table style="width: 100%; ...">`, etc.)
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/snapshots_live.ex` — 24 occurrences
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/user_api_keys_live.ex` — 30 occurrences
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/routing_live.ex` — 30 occurrences
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/workspace_detail_live.ex` — 2 occurrences (mostly migrated)
- **Violates**: UI Contract §DON'T list ("DON'T write `<h1 style="font-size: 22px; font-weight: 600;">` — use `<.page_header>` or Tailwind tokens"). Also breaks dark-mode toggle infrastructure (no `dark:` pair on hardcoded hex).
- **Fix**: PR-H pattern was applied to `agent_detail_live` + `workspace_detail_live`; repeat for these 4 files. ~100 lines of mechanical migration.

### V-5: Two parallel "templates" stores
- Legacy `Workspace.Store.session_templates` (Phase-4d freeform map) rendered in `WorkspaceDetailLive`
- Phase-7 `Ezagent.Entity.SessionTemplate` Kind — not rendered anywhere
- **Violates**: P3 (single source of truth for any datum).
- **Fix**: G-12 in §2. Decide which is canonical and migrate.

### V-6: Workspace assignment hardcoded in cc/echo create path
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/agent_new_live.ex:231, 257` — `Ezagent.Workspace.add_template(@default_workspace_name, ...)`
- **Violates**: P12 / P17 (workspace plumbing — multi-workspace operators can't create agents in non-default workspaces).
- **Fix**: derive workspace from the caller's session workspace (already on socket as `@current_workspace_uri`).

## §5 Best-practices verdict + concrete actionable items

The UI substantially follows the 3-layer / Nested-shell pattern. The Tier-2 primitives library is rich. New LVs added in PR-O / PR-N consistently use atoms + `<AppShell.app_shell>` wrap. But there are clear pockets of drift:

1. **Plugin-isolation north star (P1) is weakened** by 6 direct plugin imports in LV code. The pattern of `Code.ensure_loaded?` is a hack that hides the contract violation from CI. Three of the violations (`EzagentPluginCc.BridgeRegistry` reads) should become a `Ezagent.Domain.Agent.bridge_status/1` facade — the precedent (`lifecycle_status/1`) is already there. **Action**: write the facade, replace the 4 call sites, delete the `Code.ensure_loaded?` guards.

2. **Hardcoded plugin enumeration (V-1)** is the cleanest violation to fix — one-line change in `agent_new_live.ex` reading from the already-existing `Ezagent.AgentFlavorRegistry`. **Action**: do it.

3. **Inline `style=""` debt (V-4)** is mechanical but real — 100+ violations across 4 LV files. The DO/DON'T list in the SKILL is explicit. **Action**: a single mechanical PR migrating the 4 files using the patterns from `<.page_header>`, `<.card>`, `<.button>`, `<.badge>`, plus `dark:` pairs per the substitution table.

4. **Phase-7 invisibility (G-1 / G-2 / G-3 / G-5 / G-9 / G-12)** is the biggest finding. Phase-7 shipped 7 PRs of orchestrator + AgentTemplate + SessionTemplate + Generator infrastructure in May, and 0 PRs of operator UI for them. Operators can't see what the orchestrator does, can't audit the working-copy, can't browse the templates the orchestrator chooses from, can't see Generator run outcomes. The system is feature-complete but operationally opaque. **Action**: V1-blocker UI scope is G-1 + G-2 + G-3 + G-5 + G-8 + G-9 + G-12; that's 5-6 new LVs + 1 SessionView + 1 small refactor.

5. **AutoDerive (`/plugins/auto/:kind`) is the existing escape hatch** — it works today for `agent_template` and `session_template` (the Kinds expose `type_name/0` correctly per `agent_template.ex:102` and `session_template.ex:120`). A V0 stop-gap would simply add `/plugins/auto/agent_template` + `/plugins/auto/session_template` links from `/admin/registry` and call the Phase-7 UI "shipped at operator grade". This is faster than building purpose-specific LVs and matches Allen's "production-usability" P4 — operators get visibility immediately, polish lands later.

6. **Orchestrator tools surface (G-4) and TemplateTags (G-6)** are V2 — these are debug + override surfaces, not blockers for normal operation.

## §6 Recommendation — V1-blocker scope vs V2-backlog

### V1 blockers (must address before claiming the orchestrator UI is "shipped")

| Priority | Item | Reason | Approx effort |
|---|---|---|---|
| **1** | **G-8 / V-1** — `AgentFlavorRegistry`-driven flavor list in `AgentNewLive` | Smallest change, biggest plugin-isolation win. Unblocks Python flavor PR. | 30 min |
| **2** | **V0 stop-gap for G-1 + G-2** — link `/admin/registry` → `/plugins/auto/agent_template` + `/plugins/auto/session_template`; split the `template://` filter chip in `EntitiesLive` into agent/session | Gives operators *some* Phase-7 visibility this week without 2-week LV builds. | 2 hrs |
| **3** | **G-9** — surface cc-orchestrator seed status (boot pass/fail badge) in the V0 stop-gap or in `/admin/dashboard` | The orchestrator IS the system's marquee Phase-7 feature; a silent install failure is the worst-case bug. | 2 hrs |
| **4** | **G-12 / V-5** — decide canonical templates store; migrate `WorkspaceDetailLive` to read from `KindSnapshot.list_in_workspace/1` | Two parallel "templates" stores is the kind of P3 violation that grows silently. | 1 day (decision + migration) |
| **5** | **V-4** — migrate the 100 inline `style=""` occurrences in 4 LVs | One mechanical PR per the SKILL DO/DON'T list. | 4 hrs |
| **6** | **G-3 (lite)** — `:orchestrator` SessionView showing read-only `template_working_copy` for a session that has one | Operators need to answer "what is the orchestrator looking at?" — a read-only view is enough for V1. | 1 day |
| **7** | **G-5 (lite)** — Generator-run banner on Sessions with a `parent_template_uri` — source template chip + slot status list | Phase-7 round-8/9/10 (PRs #248-#250) closed cleanup loopholes; UI should confirm those work end-to-end. | 1 day |

### V2 backlog (post-V1)

| Item | Why deferred |
|---|---|
| G-1 / G-2 promotion from AutoDerive to purpose-built LVs (form-driven create/edit; fork button; version graph) | V0 stop-gap suffices for the first few weeks of Phase-7 production use; operator feedback will tell us which fields they actually edit. |
| G-4 — Orchestrator tools admin panel | Debug + override surface. Real operators will work via the orchestrator chat; only ezagent dev team needs the override surface. |
| G-6 — TemplateTags list/move UI | Tag-bumping is currently the orchestrator's job. Operator override is a future-when-we-need-it feature. |
| G-7 — `template://agent` vs `template://session` chip split | Cosmetic if G-1 + G-2 land. |
| G-10 / G-11 — Lifecycle Behavior for restart + terminate | The Behavior itself is missing (a P22 reliability primitive gap). When core adds it, UI follows in a small PR. |
| V-3 — `Ezagent.Domain.Agent.bridge_status/1` facade + remove plugin imports from LVs | Cleanup PR. Run after V1 lands. |
| V-6 — workspace derivation in agent create from caller's workspace | Multi-workspace operator path isn't pressured yet. Document as known limitation. |

### Cross-cutting recommendation: invariant tests

Per P6 — "completion claim requires invariant test." When V1 work above lands, add at minimum:

- `agent_new_live_flavor_registry_test.exs` — assert the flavor dropdown options match `AgentFlavorRegistry.list_flavors/0` (so a new flavor plugin causes the test to refuse a hardcoded list).
- `ui_no_inline_styles_test.exs` — `grep -rn 'style="' apps/ezagent_plugin_liveview/lib/` returns zero matches (with documented exemptions if any). Stops regression.
- `phase_7_kinds_have_ui_test.exs` — for every `kind_module` registered with `type_name in [:agent_template, :session_template]`, assert there's a route (via the router introspection) leading to a render path. Stops the "shipped backend without UI" pattern.

---

End of audit.
