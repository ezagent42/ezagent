# Phase 7 completion — the Generator + the live Orchestrator

> **Status**: DRAFT rev 4 — 2026-05-22. Author: Claude, per Allen
> Feishu 2026-05-22 ("和 codex 配合完成 Phase 7 的工作 … v1 要求是
> 完整的生产可用性,不要留尾巴").
>
> - **rev 1**: initial 6-PR scope from the audit.
> - **rev 2**: first `codex adversarial-review` — 1 CRITICAL + 4 HIGH +
>   2 MEDIUM, all addressed. (a) CRITICAL — rev 1 copied the LOCKED
>   phase7 SPEC's URI shapes (`template://session/<name>@<hash>`)
>   verbatim, but the repo's Phase-9 URI migration moved to 3-segment
>   per-workspace URIs — rev 2 uses the CURRENT model everywhere.
>   (b) the working-copy must be normalized live→template BEFORE
>   persistence. (c) CapBAC lands per-path in the PR that introduces
>   the path. (d) PR-5 is a real privileged MCP surface. (e)
>   AgentTemplate is persistent CONFIG; instantiation delegated to
>   plugin Template Classes. (f) transactional persistence schema.
>   (g) tests per-PR.
> - **rev 3**: second `codex adversarial-review` — 4 HIGH + 1 MEDIUM,
>   all addressed against the REAL code (modules cited inline):
>   - **HIGH-1** — rev 2 never gave the orchestrator any `template:*`
>     cap; dispatch-routed template tools would DENY. rev 3 added the
>     Generator-time template-cap delegation contract (§1.4).
>   - **HIGH-2** — `Ezagent.PluginCc.Template.CcAgent` was not a
>     flavor-delegation target; rev 3 specified the concrete
>     AgentTemplate→cc delegation contract (§1.1, §1.5).
>   - **HIGH-3** — working-copy normalization needs a durable
>     source-template field; rev 3 put it in the working-copy slice
>     (§1.6).
>   - **HIGH-4** — rev 2's "DB-backed SessionTemplate tables"
>     conflicted with the Kind/`kind_snapshots` model; rev 3 picked
>     the Kind/snapshot model as the one source of truth (§1.7).
>   - **MEDIUM-5** — resequenced PRs into independently-testable
>     vertical slices (§2).
> - **rev 4**: third `codex adversarial-review` — 4 HIGH + 1 MEDIUM,
>   all addressed against the REAL code (modules cited inline):
>   - **HIGH-1+2 (unified)** — rev 3's persistence + dispatch plan
>     targeted **actions that do not exist**. It said persisting a
>     template version dispatches `identity.update_slice`, and PR-5's
>     table routed `add_agent_slot` to a bare `template.instantiate`
>     callback. But `Ezagent.Behavior.Identity` exposes ONLY
>     `list_caps`/`has_cap?`/`grant_cap`/`revoke_cap` (there is no
>     `update_slice`, and the `:identity` slice holds CAPS, not
>     template content); and `Ezagent.Kind.Template.instantiate/3` is
>     a callback-module contract, NOT a `BehaviorRegistry`-registered
>     action, so it is not dispatch-invocable. rev 4 defines a **real
>     `Ezagent.Behavior.Template`** carrying the template CONTENT
>     slice with dispatchable `:read`/`:write`/`:instantiate` actions,
>     registered on both Template Kinds (§1.0). Persistence and the
>     PR-5 dispatch table are rewritten to that real Behavior.
>   - **HIGH-3** — delegating worker spawn to `CcAgent.instantiate/3`
>     drops the `AgentLineage.record` + workspace bind that cap #2
>     (`{:spawned_by, orchestrator}`) needs — `CcAgent` only ensures
>     the Agent Kind + PtyServer. rev 4 makes the **Generator /
>     `add_agent_slot` wrapper own post-spawn obligations** (§1.6a).
>   - **HIGH-4** — owner→orchestrator template-cap delegation had no
>     real authority preflight: `Identity.grant_cap/3` dispatches with
>     `admin_caps()` and merely stamps `granted_by` — nothing checks
>     the owner actually holds the authority. rev 4 specifies the
>     exact **owner-cap preflight** the Generator performs before
>     delegating caps #3/#4 (§1.4).
>   - **MEDIUM-5** — `list_templates` returned a COMBINED catalog of
>     both AgentTemplate + SessionTemplate URIs gated on cap #3 OR #4
>     — cross-kind leak. rev 4 gates each result set by its OWN kind
>     cap (§2.1, §1.7 (b)).

This SPEC **completes** the LOCKED `docs/phase-specs/phase7/SPEC.md`
(v3). The phase7 SPEC's *design intent* (the Generator, the live
Orchestrator, the 7 tools, git-style versioning) is the design of
record; its concrete **URI shapes are superseded** by the Phase-9
3-segment-per-workspace URI migration (see §1.2). rev 3 scopes the
unbuilt ~40% the audit
(`docs/notes/phase-7-implementation-audit-2026-05-22.md`) found.

## 0. What this completes

Audit verdict: Phase 7 is ~55-60% real. **Solid — do not re-do**:
`Ezagent.WorkspaceRegistry`, `Ezagent.AgentLineage`,
`Ezagent.Entity.Agent.spawn/4`, the scope-bounded delegation caps
(`Ezagent.Capability.instance_match?/2`), `mix ezagent.bootstrap`.
**Unbuilt — this SPEC**:

1. The Orchestrator does not run — `Ezagent.Orchestrator.Tools` (444
   lines) is imported by nothing; no MCP exposure.
2. `update_template` / `save_template_as` compute a hash + URI and
   **persist no row** — `build_working_copy/4` returns a slice, the
   tool calls `SessionTemplate.compute_version_hash/1` +
   `SessionTemplate.build_uri/3`, returns the URI, persists nothing.
3. The Generator (`Ezagent.Entity.Session.spawn_from_template/2`) is
   the "minimal PR-41" stub — spawns only the orchestrator.
4. `SessionTemplate.fork/2`, `.create/2`, the `template_tags` registry
   — absent.
5. `Ezagent.Entity.AgentTemplate` / `Ezagent.Entity.SessionTemplate`
   are bare Kinds — they carry only `Ezagent.Behavior.Identity`
   (caps), the template-CONTENT slice schemas are moduledoc-only,
   there is no dispatchable `read`/`write`/`instantiate` action, and
   no slice-population code. rev 4 adds a real
   `Ezagent.Behavior.Template` (§1.0) to fix this.
6. No `template:` cap is ever enforced; the would-be grant path has
   no owner-authority preflight (§1.4).
7. ~7 V1-V5 gating tests missing.

## 1. Architectural decisions rev 4 locks

### 1.0 `Ezagent.Behavior.Template` — the dispatchable template Behavior (codex rev-4 HIGH-1+2)

**The bug rev 3 left.** rev 3's persistence plan said "persisting a
template version dispatches `identity.update_slice`", and PR-5's
dispatch table routed `add_agent_slot` to
`template://agent/...?action=template.instantiate`. Both target
**non-existent dispatch actions**:

- `Ezagent.Behavior.Identity` (verified —
  `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex`)
  declares `actions/0 == [:list_caps, :has_cap?, :grant_cap,
  :revoke_cap]`. There is **no `update_slice` action**, and its
  `state_slice/0 == :identity` holds `%{caps: MapSet.t()}` — CAPS,
  not template content. Routing template content through it is
  category-wrong.
- `Ezagent.Kind.Template` (verified —
  `apps/ezagent_core/lib/ezagent/kind/template.ex`) is a
  **callback-module contract** (`template_name/0`, `validate/1`,
  `instantiate/3`). It is NOT registered in `BehaviorRegistry`.
  Dispatch resolves an action via
  `Ezagent.BehaviorRegistry.lookup(kind_module, action)` → a
  `Ezagent.Behavior` module (verified — `Ezagent.Capability.cap_for_action/3`
  + `BehaviorRegistry.lookup/2`). A bare callback is never
  dispatch-invocable; `?action=template.instantiate` resolves to
  `:error` → DLQ-unroutable.

**The fix — a real `Ezagent.Behavior.Template`.** rev 4 defines a
new Behavior in `ezagent_domain_chat`
(`apps/ezagent_domain_chat/lib/ezagent/behavior/template.ex`) that
follows the house pattern of `Ezagent.Behavior.Identity` /
`Ezagent.Behavior.Chat` (verified — both implement
`@behaviour Ezagent.Behavior` with `actions/0`, `state_slice/0`,
`init_slice/1`, `invoke/4`, `interface/0`):

- **`state_slice/0 → :template`.** A NEW slice, separate from
  `:identity`. The Template Kinds (AgentTemplate / SessionTemplate)
  already carry `Ezagent.Behavior.Identity` in their `behaviors/0`
  for the cap policy; rev 4 ADDS `Ezagent.Behavior.Template` to both
  Kinds' `behaviors/0`, so each Kind now has two slices: `:identity`
  (the cap policy — `default_caps`, owner-grant caps) and
  `:template` (the template CONTENT).
- **`init_slice/1`.** Reads `args[:content]` (default `nil` — an
  unpopulated template Kind). The content map is the per-Kind
  schema:
  - **AgentTemplate `:template` slice content** — the
    moduledoc-only schema from `agent_template.ex` made real:
    `name`, `description`, `flavor`, `working_directory`,
    `claude_config_dir`, `settings_path`, `mcp_config_path`,
    `api_key_helper`, `default_caps`, `created_by`, `created_at`.
  - **SessionTemplate `:template` slice content** — the
    moduledoc-only schema from `session_template.ex` made real:
    `name`, `description`, `agent_slots`,
    `orchestrator_template_uri`, `routing_rules`,
    `default_workspace_uri`, `parent_template_uri`, `version_hash`,
    `version_tag`, `created_by`, `created_at`.
- **`actions/0 → [:read, :write, :instantiate]`** — the
  dispatchable action set:
  - **`:read`** (`:call` mode) — `{:ok, slice, %{content: map}}`.
    Returns the `:template` slice content. The cap-gated catalog
    read for `list_templates` and the per-template fetch
    `add_agent_slot` / the Generator do when resolving a template
    URI.
  - **`:write`** (`:call` mode) — args `%{content: map}` → replaces
    the `:template` slice content, returns `{:ok, new_slice,
    %{content: map}}`. Because both Template Kinds are
    `{:snapshot, :on_change}` (verified — `persistence/0` in both
    Kind modules), a `:write` slice mutation triggers a
    `kind_snapshots` row write. **This is the persistence
    primitive** — "persist a template version" = spawn the
    Template Kind + dispatch `Behavior.Template` `:write`.
  - **`:instantiate`** (`:call` mode) — args `%{instance_name,
    workspace_uri, ...}`. For an **AgentTemplate** Kind: reads its
    own `:template` slice `flavor`, resolves the plugin Template
    Class via `Ezagent.AgentFlavorRegistry.lookup(flavor)`
    (verified — returns `{:ok, %{kind: _, template_class: tc}}`),
    builds the Class data map via `AgentTemplate.to_template_data/2`
    (§1.5), and delegates the actual spawn to the wrapper described
    in §1.6a. For a **SessionTemplate** Kind: returns
    `{:error, :use_generator}` (SessionTemplate instantiation IS
    the Generator — §1.7 (d) / PR-4; the Behavior does not
    duplicate it).
- **`interface/0`** — the `description`/`args`/`returns`/`modes`
  map per `Ezagent.Behavior` contract, all three actions `:call`.
- **Registration.** `EzagentDomainChat.Application.start/2` extends
  `register_chat_behaviors/0` (verified — that fn already does
  `BehaviorRegistry.register(Session, :send, Chat)` etc.):

      Enum.each(Ezagent.Behavior.Template.actions(), fn action ->
        :ok = BehaviorRegistry.register(AgentTemplate, action, Ezagent.Behavior.Template)
        :ok = BehaviorRegistry.register(SessionTemplate, action, Ezagent.Behavior.Template)
      end)

  After this, `?action=template.read` / `template.write` /
  `template.instantiate` resolve through `BehaviorRegistry` on
  either Template Kind and are dispatch-invocable — and CapBAC
  step 5.5 derives the `needed` cap via `cap_for_action/3` with
  `behavior == Ezagent.Behavior.Template`, `kind == :agent_template`
  or `:session_template`.

**Relationship to `Ezagent.Kind.Template`.** The callback contract
`Ezagent.Kind.Template` (`template_name/0` + `validate/1` +
`instantiate/3`) **keeps its existing role** — it is the
**Template-CLASS** contract that plugin Template Classes implement
(`Ezagent.PluginCc.Template.CcAgent` implements it; `Ezagent.Workspace.Loader`
invokes it). It is the *flavor plugin's* spawn contract, registered
in `Ezagent.TemplateRegistry`. The new `Ezagent.Behavior.Template`
is a different thing: a **Behavior on the Template KIND** that holds
+ serves the persistent template-content slice and routes
dispatchable actions. They do not collide — different namespaces
(`Ezagent.Kind.Template` = the plugin Class behaviour;
`Ezagent.Behavior.Template` = the core Behavior contract), different
roles (Class = "how to spawn a flavor of agent"; Behavior = "how to
read/write/instantiate the template config record"). The
AgentTemplate Kind's `Behavior.Template` `:instantiate` action
*delegates to* a `Ezagent.Kind.Template` Class — it does not replace
it. rev 4 keeps both; the SPEC text is precise about which is which
at every call site.

**Tests (PR-1):** `Behavior.Template.actions/0` returns the 3
actions; `:write` then `:read` round-trips the content slice;
`:write` on a `{:snapshot, :on_change}` Template Kind produces a
`kind_snapshots` row; both Template Kinds resolve `template.read` /
`template.write` / `template.instantiate` through `BehaviorRegistry`;
`cap_for_action(AgentTemplate, :write, uri)` yields `behavior ==
Ezagent.Behavior.Template` and `kind == :agent_template`;
SessionTemplate `:instantiate` returns `{:error, :use_generator}`.

### 1.1 AgentTemplate is persistent CONFIG — it does NOT spawn

`Ezagent.Entity.AgentTemplate` is a Kind-snapshot-backed **config
record**: a pointer to a sandbox + a cap policy. It does NOT itself
launch a `claude` PTY. **Instantiation is delegated** — the
AgentTemplate Kind's `Ezagent.Behavior.Template` `:instantiate`
action (§1.0) reads its own `:template` slice `flavor`, resolves the
plugin Template Class via `Ezagent.AgentFlavorRegistry.lookup(flavor)`,
builds a Template-Class data map from the AgentTemplate slice
(§1.5 adapter), and hands off to the **§1.6a wrapper** which calls
`Class.instantiate/3` and then records lineage + binds the workspace.
The plugin owns the *launch*; the wrapper owns the *post-spawn
obligations* (§1.6a). The concrete `flavor → Template Class`
resolution and the AgentTemplate-slice→cc-agent-data adapter are
specified in §1.5.

AgentTemplate's `flavor` field lives in its `:template` slice
content (§1.0 — `"cc"` etc.) so the delegation target is explicit.
Non-cc flavors are supported the day their plugin Template Class
accepts the adapter's data map.

### 1.2 URIs — the CURRENT 3-segment per-workspace model

The phase7 SPEC predates Phase 9. The model in force NOW (verified:
`SessionTemplate.build_uri/3`, `cc_agent.ex` `check_agent_uri/1`):

- AgentTemplate — `template://agent/<workspace>/<name>`
- SessionTemplate — `template://session/<workspace>/<name>@<hash>`
- Tag-addressed — `template://session/<workspace>/<name>:<tag>`
- Agent instance — `entity://agent/<workspace>/<flavor>_<name>`

`Ezagent.TemplateTags` is keyed by **`(workspace, name, tag)`** — a
`stable` tag in workspace A and in workspace B are distinct rows and
must never resolve to each other. Every cap `instance` and every URI
parse/build in this SPEC uses the 3-segment model. The cross-workspace
non-collision is an invariant test (PR-1).

### 1.3 The canonical `template_working_copy` schema

The current `Tools.build_working_copy/4` derives a slice from LIVE
runtime — `agent_slots` as `{slot_name, entity://agent/...}` (a live
*instance* URI), routing receivers as live agent URIs, and it would
hash `session_uri` in. That slice is **not a reusable template** and
two identical teams in two sessions hash differently.

rev 3 defines `template_working_copy` as a **template-shaped** Session
slice (a new field on the Chat slice — see §1.6 for how it is durably
populated), and a **normalization** function `live → template`:

- `agent_slots :: [{slot_name, template://agent/<ws>/<name>}]` — each
  live worker carries the AgentTemplate URI it was spawned from. That
  URI comes from the **durable `source_agent_template_uri` field**
  defined in §1.6 (NOT from a guess off the live instance URI).
- `routing_rules :: [{matcher_ast, [slot_name]}]` — receivers are slot
  NAMES, not live URIs (resolved to URIs on instantiate).
- The version hash is computed by `SessionTemplate.compute_version_hash/1`
  over `{agent_slots, routing_rules, orchestrator_template_uri,
  default_workspace_uri, description}` ONLY — `session_uri`,
  timestamps, `created_by`, live pids EXCLUDED (the function already
  `Map.drop`s `created_at`/`created_by`; rev 3 also excludes
  `session_uri` and `name` from the *hash input* by structuring
  `build_working_copy/4` to emit a hash-input map without them).

### 1.4 Generator-time template-cap delegation contract + owner-cap preflight (codex HIGH-1 / rev-4 HIGH-4)

**The bug rev 2 left:** PR-5 dispatch-routes the 7 MCP tools with the
orchestrator's caps; PR-2 gates `update_template`/`save_template_as`/
`list_templates` on `template:*` caps. But the Generator
(`Session.spawn_from_template/2` → `grant_scoped_caps/3`) grants the
orchestrator exactly TWO caps: `{:within_session, S}` on `:session`
and `{:spawned_by, orch}` on `:agent`. Neither matches a
`template://` target. So a dispatch-routed `list_templates` /
`update_template` / `save_template_as` would return
`{:error, :unauthorized}` on the happy path. No `admin_caps` fallback
is permitted (skill anti-pattern + Decision #137).

**The fix — explicit template-cap delegation at Generator boot.**
`grant_scoped_caps/3` is extended to grant the orchestrator a THIRD
and FOURTH cap. The grants:

| # | kind | behavior | instance | workspace_uri | meaning |
|---|------|----------|----------|---------------|---------|
| 3 | `:session_template` | `Ezagent.Behavior.Template` | `{:within_workspace, ws}` (see below) | session's workspace | read + write + instantiate SessionTemplates in the orchestrator's workspace |
| 4 | `:agent_template`   | `Ezagent.Behavior.Template` | `{:within_workspace, ws}` | session's workspace | read + instantiate AgentTemplates in the orchestrator's workspace (needed by `add_agent_slot`/`list_templates`) |

`behavior` is the **module reference** `Ezagent.Behavior.Template`
(invariant 2 — caps carry module refs, never atom shorthand). Now
that §1.0 makes `Ezagent.Behavior.Template` a real registered
Behavior, `cap_for_action/3` derives `behavior ==
Ezagent.Behavior.Template` for every `template.read`/`write`/
`instantiate` dispatch — so the delegated caps and the `needed` caps
match on `behavior` exactly.

`{:within_workspace, workspace_uri}` is a new scope-tuple `instance`
shape, narrower than `:any`, MORE specific than a URI cap — symmetric
with `{:within_session, _}` (Decision #137 / invariant 5). It is added
to `Ezagent.Capability.instance_match?/2` in **PR-1** (it is a
contract, lands before any code relies on it). Match semantics: a
needed action on `template://<type>/<ws>/<name>` matches a
`{:within_workspace, W}` cap iff the URI's workspace segment == `W`.
Cross-workspace template access (`template://…/other-ws/…`) is denied
— two-tenant isolation holds.

**Parent-template scoping note.** `update_template` produces a *new
version of the parent* SessionTemplate. The parent always lives in the
orchestrator's own workspace (the Generator instantiated the session
*from* that parent into that workspace). So cap #3's
`{:within_workspace, ws}` covers `update_template`,
`save_template_as`, and `list_templates` without a per-name cap. A
per-name `template:write` cap is NOT delegated to the orchestrator —
the orchestrator's authority is workspace-bounded, not name-bounded;
finer-grained name caps remain an operator/LV concern.

**Delegation source + the owner-cap preflight (rev-4 HIGH-4).** Caps
#3/#4 are `granted_by: owner_uri` — the human owner who triggered the
Generator. **The bug rev 3 left:** rev 3 said the owner "must itself
hold a template cap covering that workspace; the Generator does not
fabricate authority", and "fails closed if the owner lacks it" — but
specified NO code that actually checks. The real grant path
(`Ezagent.Identity.grant_cap/3` — verified,
`apps/ezagent_domain_identity/lib/ezagent/identity.ex`) dispatches
`identity.grant_cap` with `ctx.caps = Ezagent.Entity.User.admin_caps()`
and merely stamps `granted_by` on the new cap. It runs the CapBAC
check against `admin_caps`, not the owner's. An implementer extending
`grant_scoped_caps/3` the obvious way would **silently mint
workspace-wide template authority for an owner who has none** —
fail-open, the exact opposite of the SPEC's intent.

rev 4 specifies the exact **preflight** the Generator performs,
*before* delegating caps #3/#4, for EACH of #3 and #4 independently:

1. **Load the owner's ACTUAL caps.** Call
   `Ezagent.Identity.list_caps_for(owner_uri)` (verified — returns a
   `MapSet.t(Capability.t())`, dispatches `identity.list_caps` on the
   owner's User Kind; `MapSet.new()` if the Kind is not spawned). This
   is the owner's real authority — NOT `admin_caps()`.
2. **Verify it covers the delegated scope.** Build the `needed` map
   for the cap being delegated:
   `%{kind: :session_template (or :agent_template), behavior:
   Ezagent.Behavior.Template, instance: <a representative
   template://<type>/<ws>/<name> URI in the session's workspace>,
   workspace_uri: <session workspace>}`, and check
   `Enum.any?(owner_caps, &Ezagent.Capability.matches?(&1,
   needed))`. The owner passes iff at least one of their real caps
   authorizes a `Behavior.Template` action on that kind in that
   workspace (e.g. the owner holds `:any` admin, or a
   `{:within_workspace, ws}` template cap, or a broader template
   cap). Because `instance_match?/2` honors `{:within_workspace, _}`,
   an owner whose own template cap is workspace-bounded still passes
   for their own workspace and fails for any other.
3. **Only then perform the grant.** If the owner passes, dispatch the
   `identity.grant_cap` for that cap. The grant dispatch itself still
   uses a **system context** (the Generator is a privileged
   bootstrap program — it runs `grant_cap` as `system://bootstrap`,
   consistent with `grant_scoped_caps/3`'s existing privileged grant
   of caps #1/#2). The preflight — NOT the grant's `ctx.caps` — is
   what enforces "no authority is fabricated". The privileged grant
   context is legitimate *because* the preflight gated it.
4. **If the owner fails — grant nothing for THAT cap.** The Generator
   skips delegating that one cap (#3 or #4). It does NOT raise, does
   NOT abort the whole session — the orchestrator simply comes up
   without that cap and the corresponding tools (template-write tools
   if #3 missing; `add_agent_slot`/`list_templates`-agent-rows if #4
   missing) DENY at dispatch when the orchestrator later tries them.
   **Fail closed, not fail open**: a missing delegated cap silently
   removes a tool's authority; it never silently grants it. Caps
   #1/#2 (the scope-bounded session/agent caps) are unconditional —
   they are structural to any orchestrator and not template
   authority, so the preflight does not gate them.

**Tests (PR-1 for the shape, PR-4/PR-5 for the e2e):**
- PR-1: `{:within_workspace, W}` matches same-workspace template URI,
  denies other-workspace template URI, denies non-template kind.
- PR-4: **owner-cap preflight denial test** — run the Generator with
  an `owner_uri` whose User Kind holds NO template cap (and is not
  admin); assert the spawned orchestrator's cap set contains caps
  #1/#2 but NOT cap #3 and NOT cap #4. A second variant: owner holds
  ONLY cap #3-equivalent → orchestrator receives #3 but not #4.
- PR-5: dispatch-routed `list_templates` with ONLY the four delegated
  caps SUCCEEDS; the same call with caps #3/#4 *omitted* returns
  `{:error, :unauthorized}` — proving no `admin_caps` fallback. And:
  an orchestrator whose owner failed the cap-#3 preflight, calling
  `update_template`, returns `{:error, :unauthorized}` (the missing
  cap fails closed end-to-end).
- PR-5: an out-of-workspace `add_agent_slot` (AgentTemplate URI in a
  different workspace) returns `{:error, :unauthorized}`.

### 1.5 The AgentTemplate→cc concrete delegation interface (codex HIGH-2)

**What the real code shows** (`apps/ezagent_plugin_cc/lib/ezagent/
template/cc_agent.ex`):
- `validate/1` requires keys `{"class","agent_uri","cwd"}`.
- `instantiate/3` matches only `%{"agent_uri" => uri_str}` and reads
  `Map.fetch!(tmpl, "cwd")`.
- `build_claude_cmd/2` hardcodes ONE plugin-shipped `--settings`
  (`priv/claude-pty-settings.json` forcing `remoteControlAtStartup:
  false`) and ONE generated `--mcp-config` (`McpConfigWriter.write!`).
- There is no `flavor` key, no AgentTemplate-slice consumer, no
  operator-`settings_path`/`mcp_config_path` handling.

So "delegate to `CcAgent`" is not yet a real interface. rev 3 makes it
one:

**(a) `flavor → Template Class` resolution.** `Ezagent.Entity.AgentTemplate`
gains a `flavor` slice field. The resolver is:
`Ezagent.AgentFlavorRegistry.lookup(flavor)` → `%{template_class: tc}`
→ `tc` is the Template Class module. (`AgentFlavorRegistry` already
exists and already carries `template_class` per the chat app's
`kind_module_from_class/1` — rev 3 reuses it; no new registry.) For
`flavor: "cc"`, `tc == Ezagent.PluginCc.Template.CcAgent`.

**(b) The AgentTemplate-slice → cc-agent-data adapter.** A new pure
function `Ezagent.Entity.AgentTemplate.to_template_data/2(slice,
instance_agent_uri)` produces the `CcAgent`-shaped map. It maps:

| AgentTemplate slice field | cc.agent template-data key | rule |
|---------------------------|----------------------------|------|
| (constant `"cc.agent"`)   | `"class"`                  | from `flavor` via the registry's `template_name/0` |
| `instance_agent_uri`      | `"agent_uri"`              | the per-instance URI the Generator built |
| `working_directory`       | `"cwd"`                    | required; adapter errors if nil |
| `settings_path`           | `"operator_settings_path"` | new optional cc.agent key (§ (c)) |
| `mcp_config_path`         | `"operator_mcp_config_path"` | new optional cc.agent key (§ (c)) |
| `claude_config_dir`       | `"claude_config_dir"`      | new optional cc.agent key → `CLAUDE_CONFIG_DIR` env |
| `api_key_helper`          | `"api_key_helper"`         | new optional cc.agent key (macOS Keychain — §4) |

**(c) `CcAgent` schema changes.** `validate/1` and `instantiate/3` are
extended to accept the four new optional keys above (absent ⇒ current
behavior, no regression). `build_claude_cmd/2` is extended to:
1. ALWAYS emit the mandatory safety `--settings
   priv/claude-pty-settings.json` and the trusted `--mcp-config
   <McpConfigWriter output>` — unchanged, non-negotiable.
2. If `operator_settings_path` is present, emit it as an *additional*
   `--settings <operator>` AFTER the mandatory one. claude's
   `--settings` is last-wins per file but the mandatory file is
   listed first and the operator file second — so the operator file
   can layer non-conflicting keys but **`remoteControlAtStartup`
   resolves to the operator's value if they set it true.** That is
   the wrong order. rev 3 therefore mandates the **mandatory file is
   emitted LAST** so its `remoteControlAtStartup: false` wins; the
   operator file is emitted FIRST. (Verified intent: the safety
   override must be non-bypassable — last-wins ⇒ safety last.)
3. `operator_mcp_config_path` is emitted as an *additional*
   `--mcp-config` but **never replaces** the trusted
   `McpConfigWriter` output (the esr-bridge MCP server is required
   for the agent to talk back to ESR). Both are passed; claude merges
   MCP configs additively, so an operator config adds servers but
   cannot delete the bridge.
4. `claude_config_dir`, if present, is set as `CLAUDE_CONFIG_DIR` in
   the erlexec env of the spawned process (sandbox isolation).

**Tests (PR-1):** `to_template_data/2` round-trip; `CcAgent.validate/1`
accepts the extended map and still accepts the legacy 3-key map;
**hostile-path test** — an `operator_settings_path` whose JSON sets
`remoteControlAtStartup: true` MUST still yield `false` at runtime
(assert the mandatory file is positioned last in the `--settings`
arg sequence); an `operator_mcp_config_path` MUST NOT remove the
esr-bridge server from the effective config.

### 1.6 `source_agent_template_uri` is a durable field (codex HIGH-3)

**The bug rev 2 left:** working-copy normalization (§1.3) needs each
live worker to know which AgentTemplate it was spawned from. But
`Ezagent.Entity.Agent.spawn/4` IGNORES its first arg
(`%URI{} = _template_uri`) — it builds the instance URI, calls
`SpawnRegistry.spawn`, `WorkspaceRegistry.bind`, `AgentLineage.record`.
There is NO durable record of the source AgentTemplate. So
`build_working_copy/4` cannot honestly produce `agent_slots ::
[{slot_name, template://agent/...}]`.

**Decision — where it lives.** Two candidates were investigated:

- **`AgentLineage` metadata.** `Ezagent.AgentLineage` is an ETS table
  `agent_uri → spawned_by_uri` owned by `EzagentCore.EtsOwner`. ETS is
  in-memory — it does NOT survive a phx restart. The working copy must
  survive restart (Session is `{:snapshot, :on_change}`; the whole
  point of §1.3). Putting `source_agent_template_uri` in `AgentLineage`
  would mean after a restart the normalization loses every worker's
  source template. Rejected.
- **An Agent slice field.** `Ezagent.Entity.Agent` carries the
  `Ezagent.Behavior.Identity` slice and has `persistence/0 ==
  :on_terminate`. A field there persists on graceful shutdown but not
  on crash.

**rev 3 picks: a field on the live Session's `template_working_copy`,
populated at spawn time by the Generator — NOT a per-Agent field.**
Rationale: the working copy IS the durable record of "which templates
compose this team", it already lives on the Session
(`{:snapshot, :on_change}` — survives crash), and the orchestrator's
`add_agent_slot`/`remove_agent_slot`/`update_agent_template` already
mutate team composition. Storing the slot→source-template mapping
inside the working copy means there is ONE durable structure and no
divergence between a per-Agent field and the working copy.

Concretely, `template_working_copy.agent_slots` is the durable list of
`{slot_name, source_agent_template_uri}` itself. The Generator (PR-4)
initializes it; the three orchestrator agent-slot tools (PR-5)
maintain it:
- `add_agent_slot(slot, agent_template_uri, …)` — appends
  `{slot, agent_template_uri}` to `agent_slots`.
- `update_agent_template(slot, new_uri, …)` — replaces the tuple for
  `slot`.
- `remove_agent_slot(slot, …)` — drops the tuple for `slot`.

`build_working_copy/4` then reads `agent_slots` straight from the
working-copy slice — no guessing from live instance URIs, no
`AgentLineage` walk. A worker that died and was respawned keeps its
slot's source template because the slot tuple is the truth, not the
process.

The Generator and `add_agent_slot` know the AgentTemplate URI; they
record `{slot, agent_template_uri}` into the slice in the same step
as the worker spawn. The worker spawn itself goes through the §1.6a
wrapper (NOT `Agent.spawn/4` directly), and the wrapper is also where
lineage + workspace binding happen.

**Tests (PR-4 for init, PR-5 for maintenance):**
- Generator initializes `agent_slots` with the right
  `{slot, template://agent/...}` tuples; the slice survives a Session
  restart (snapshot reload).
- `add_agent_slot` / `update_agent_template` / `remove_agent_slot`
  each leave `agent_slots` consistent; after a restart the working
  copy round-trips.

### 1.6a The delegated-spawn wrapper owns lineage + workspace binding (codex rev-4 HIGH-3)

**The bug rev 3 left.** rev 3 (§1.1, §1.5, PR-4, PR-5) moves worker
creation from `Ezagent.Entity.Agent.spawn/4` to the flavor Template
Class's `instantiate/3` (delegation — the plugin owns the launch).
But the lineage + workspace recording that cap #2
(`{:spawned_by, orchestrator}`) depends on lives in `Agent.spawn/4`,
NOT in the plugin Template Class. Verified:

- `Ezagent.Entity.Agent.spawn/4`
  (`apps/ezagent_domain_chat/lib/ezagent/entity/agent.ex:132`) does
  `spawn_or_resume` → `Ezagent.WorkspaceRegistry.bind(agent_uri,
  workspace_uri)` → `Ezagent.AgentLineage.record(agent_uri,
  granted_by)`. The lineage record is what makes
  `Ezagent.AgentLineage.spawned_in_lineage?/3` (called by
  `Capability.instance_match?({:spawned_by, P}, _)` — verified,
  `capability.ex:122-130`) return true.
- `Ezagent.PluginCc.Template.CcAgent.instantiate/3`
  (`apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex:131`)
  does ONLY `ensure_agent_kind` (`SpawnRegistry.spawn`) +
  `ensure_pty_server`. It does **NOT** call
  `WorkspaceRegistry.bind` and does **NOT** call
  `AgentLineage.record`. (`Ezagent.Workspace.Loader.invoke_template`
  binds the workspace *after* `Class.instantiate/3` returns — but it
  too never records lineage, and the orchestrator path does not go
  through `Workspace.Loader`.)

**Consequence:** a worker spawned by delegating straight to
`Class.instantiate/3` is **never recorded in `AgentLineage` under the
orchestrator**. The orchestrator's cap #2 (`{:spawned_by,
orchestrator}`) then matches nothing for that worker. So
`remove_agent_slot` (dispatch target `lifecycle.terminate`, cap #2)
and `update_agent_template` (caps #2 + #4) — which the orchestrator
must call on its own workers on the *happy path* — return
`{:error, :unauthorized}`. The orchestrator could create workers it
can never manage. Fail-broken.

**The fix — a wrapper owns the post-spawn obligations.** The plugin
Template Class is correctly plugin-isolated (`feedback_north_star_plugin_isolation`)
— it must NOT know about ESR's lineage/workspace registries. So the
*caller* of `Class.instantiate/3` owns the obligations. rev 4
specifies a **delegated-spawn wrapper** —
`Ezagent.Entity.Agent.spawn_from_agent_template/4` (a NEW function
in `agent.ex`, replacing the role of the old `spawn/4` for the
delegated path; the old `spawn/4` may be kept or folded — see
below). The wrapper contract:

1. **Resolve.** Given an `agent_template_uri`, dispatch
   `Behavior.Template` `:read` on it (§1.0) to get the AgentTemplate
   `:template` slice content; read its `flavor`.
2. **Look up the Class.** `Ezagent.AgentFlavorRegistry.lookup(flavor)`
   → `%{template_class: tc}`.
3. **Build the Class data map.** `AgentTemplate.to_template_data/2`
   (§1.5 adapter) from the slice + the per-instance agent URI the
   wrapper builds.
4. **Delegate the launch.** `tc.instantiate(tc.template_name(),
   data, workspace_uri)` → `{:ok, [worker_uri]}` (the plugin owns
   exactly this — the Agent Kind + PTY).
5. **Record lineage (wrapper-owned).** For each returned
   `worker_uri`: `Ezagent.AgentLineage.record(worker_uri,
   orchestrator_uri)` — `orchestrator_uri` is the principal passed
   in by the caller (the Generator passes the owner for the
   orchestrator agent; `add_agent_slot` passes the orchestrator's
   own URI for workers, so cap #2's `{:spawned_by, orchestrator}`
   resolves).
6. **Bind workspace (wrapper-owned).** For each `worker_uri`:
   `Ezagent.WorkspaceRegistry.bind(worker_uri, workspace_uri)`
   (invariant 4 — workspace-scoped routing rules must fire).

Steps 5 + 6 are the obligations that USED to live inside
`Agent.spawn/4` and that `Class.instantiate/3` does NOT do. The
wrapper re-establishes them after delegation. This is stated as the
**wrapper contract**: any code path that creates a worker through
the delegated Template-Class path MUST run steps 5 + 6, in that
order, against the returned worker URI(s), before returning. The
Generator (PR-4) and `add_agent_slot` (PR-5) both call this single
wrapper — they do not call `Class.instantiate/3` directly and do not
re-implement lineage/binding.

**Relationship to `Agent.spawn/4`.** The old `Agent.spawn/4` already
does steps 5 + 6 but does NOT delegate to a flavor Class (its
moduledoc admits it "does NOT instantiate the underlying claude
process"). rev 4 supersedes it for the orchestrator/Generator path
with `spawn_from_agent_template/4`, which delegates AND keeps the
obligations. The old `spawn/4` is retired from the orchestrator path
(its remaining call sites, if any non-template, are audited in PR-4;
if none, it is deleted — no dead code, per `feedback_let_it_crash_no_workarounds`).

**Tests (PR-4 + PR-5):**
- PR-4: a worker spawned through `spawn_from_agent_template/4` IS
  recorded in `AgentLineage` under the orchestrator —
  `AgentLineage.spawned_in_lineage?(worker_uri, orchestrator_uri)`
  returns true; and `WorkspaceRegistry.lookup(worker_uri)` returns
  the session's workspace.
- PR-5: **cap-#2 happy-path test** — after `add_agent_slot` spawns a
  worker via the delegated path, the orchestrator (holding cap #2)
  successfully dispatches `remove_agent_slot`
  (`lifecycle.terminate`) and `update_agent_template` on that
  worker; both SUCCEED (proving lineage was recorded). A control:
  the same dispatch against a worker spawned by a *different*
  orchestrator returns `{:error, :unauthorized}`.

### 1.7 Persistence model — a SessionTemplate version IS a Kind instance (codex HIGH-4)

**The bug rev 2 left:** rev 2 said "DB-backed SessionTemplate tables /
`template_tags` table / `Repo.transaction` around row-insert". But the
real persistence model has no such tables:

- `Ezagent.Entity.SessionTemplate` and `Ezagent.Entity.AgentTemplate`
  are **Kinds** with `persistence/0 == {:snapshot, :on_change}`.
- A Kind instance persists via `Ezagent.Kind.Snapshot` →
  `Ezagent.Ecto.KindSnapshot` → the single `kind_snapshots` table
  (`uri` PK, `kind_type`, `state_binary`, `workspace_uri`). There is
  one row per Kind URI.
- `Orchestrator.Tools.list_templates/2` reads `KindRegistry.list_all()`
  — but `KindRegistry` is a stdlib `Registry` of **live pids only**.
  It does NOT show snapshotted-but-not-spawned templates.
- A SessionTemplate "row" in rev 2's language is exactly a
  SessionTemplate **Kind instance** at a hash-addressed URI.

**rev 3 picks ONE source of truth: the existing Kind/snapshot model.**
No new tables. Concretely:

**(a) "Persist a new SessionTemplate version" = spawn the Template
Kind + dispatch `Behavior.Template` `:write` (rev-4 HIGH-1+2 fix).**
rev 3 said this dispatches `identity.update_slice` to populate the
`:identity` slice — but `Ezagent.Behavior.Identity` has no
`update_slice` action and the `:identity` slice holds CAPS, not
template content (§1.0). rev 4 corrects it: persisting a version is

1. `Ezagent.Kind.spawn(SessionTemplate, %{uri:
   template://session/<ws>/<name>@<hash>})` — bring the Template
   Kind up (or find it already alive). The `:template` slice starts
   empty (`Behavior.Template.init_slice/1` with no `content`).
2. Dispatch `?action=template.write` on that URI with
   `args: %{content: <the template content map>}` — the
   `Ezagent.Behavior.Template` `:write` action (§1.0) replaces the
   `:template` slice content. Because SessionTemplate is
   `{:snapshot, :on_change}`, this slice mutation writes a
   `kind_snapshots` row keyed by the hash URI.

   (Equivalently the content MAY be passed via the spawn `params` so
   `Behavior.Template.init_slice/1` reads `args[:content]` — but
   the dispatch-`:write` path is canonical because it goes through
   CapBAC and audit. The persistence helper `persist_version/2`
   (PR-3) uses the dispatch path.)

Content-addressing gives idempotency for free: the same content ⇒
the same hash ⇒ the same URI ⇒ `Ezagent.Kind.spawn` /
`SpawnRegistry.spawn` returns `{:error, {:already_started, _}}` (the
snapshot row already exists with the same content) ⇒ no duplicate,
no error — treat as success (the boot-seed idempotency convention).
The `template.write` is harmlessly re-applied (writes the identical
content) or skipped when the Kind is already alive with that hash.

**(b) "List templates" = a catalog query, not a live-registry scan —
gated PER KIND (rev-4 MEDIUM-5 fix).** `list_templates` is rewritten
to query persisted templates:
`Ezagent.Ecto.KindSnapshot.list_in_workspace(workspace_uri)` (verified
— exists, the standard workspace-scoped read path per SPEC v3 §7.2),
then partitioned by `kind_type`:

- the `kind_type == "agent_template"` rows form the **AgentTemplate
  result set**;
- the `kind_type == "session_template"` rows form the
  **SessionTemplate result set**.

**Each result set is gated by its OWN kind cap.** rev 3 returned a
COMBINED `%{agent_templates, session_templates}` catalog gated on cap
#3 OR cap #4 — so a caller with only `:agent_template` authority
would still learn every SessionTemplate name (and vice versa). That
is a cross-kind information leak. rev 4 gates independently:

- the AgentTemplate rows are included ONLY if the caller holds a
  `Behavior.Template` cap matching `kind == :agent_template` for the
  workspace (cap #4);
- the SessionTemplate rows are included ONLY if the caller holds a
  `Behavior.Template` cap matching `kind == :session_template` for
  the workspace (cap #3).

A caller with only cap #4 sees `agent_templates: [...]` and
`session_templates: []`; a caller with only cap #3 sees the inverse;
a caller with neither gets `{:error, :unauthorized}`. The catalog is
never cross-contaminated. The per-kind check uses
`Ezagent.Capability.matches?/2` against a `needed` map per kind
(`%{kind: :agent_template (or :session_template), behavior:
Ezagent.Behavior.Template, instance: <representative workspace
template URI>, workspace_uri: <ws>}`) — the same matcher dispatch
CapBAC uses, so the two stay structurally aligned. Live-only
templates spawned but not yet snapshotted are a non-issue — a
`{:snapshot, :on_change}` Kind snapshots on its first slice
mutation, and `template.write` population IS a slice mutation.

**(c) `template_tags` is a small persisted registry — same pattern as
`routing_rules`.** `Ezagent.Routing.RuleStore` is the reference: an
Ecto schema over a SQLite table, hydrated into ETS at boot, read from
ETS at runtime. `Ezagent.TemplateTags` follows it exactly:
- Ecto schema `template_tags` — columns: `id` PK, `workspace_uri`
  TEXT NOT NULL (per invariant 14 — it is per-tenant), `name` TEXT,
  `tag` TEXT, `version_hash` TEXT, `created_by`, timestamps.
- UNIQUE constraint `(workspace_uri, name, tag)` — a tag is unique
  per (workspace, template-name); workspace A's `stable` and
  workspace B's `stable` are distinct rows (§1.2 non-collision).
- API: `put(workspace, name, tag, hash, created_by)`,
  `resolve(workspace, name, tag) :: {:ok, hash} | :error`,
  `list(workspace)`.
- Tag moves are **CAS**: `move(workspace, name, tag, expected_hash,
  new_hash)` updates only if the current row still points at
  `expected_hash` — concurrent re-point loses deterministically.

**(d) Restart hydration.** A SessionTemplate Kind is **lazily
demand-spawned** on reference: `EzagentDomainChat.Application`'s
`"template"` `SpawnRegistry` fn switches on `uri.host` and calls
`Ezagent.Kind.spawn(SessionTemplate, %{uri: uri})`;
`Ezagent.Kind.Snapshot.load_or_init/3` rehydrates the slice from the
`kind_snapshots` row. So `fork/2` and `spawn_from_template/2` find a
template after a restart by referencing its hash URI — the existing
`ensure_template_alive/1` path
(`Session.spawn_from_template/2` — `KindRegistry.lookup` then
`SpawnRegistry.spawn`) already does exactly this and works because the
snapshot row exists.

**(e) Owner-cap grant stays consistent with template creation.** When
`save_template_as` / `fork` / `create` persists a new SessionTemplate,
the owner must hold the cap that lets `spawn_from_template` later
instantiate it. The grant goes through `Ezagent.Identity.grant_cap/3`
(verified path: `apps/ezagent_domain_identity/lib/ezagent/identity.ex`
— dispatches `identity.grant_cap` on the OWNER's User Kind; the
`Ezagent.Behavior.Identity` `invoke(:grant_cap, …)` adds the cap to
the owner's `:identity` slice; the owner's User Kind snapshots that
mutation). The new-template creation and the owner-cap grant are
sequenced: **create the SessionTemplate Kind first** (its
`kind_snapshots` row appears via the `template.write`), **then**
`grant_cap` the owner a cap with `kind: :session_template, behavior:
Ezagent.Behavior.Template, instance: {:within_workspace, ws}` (the
workspace the template was created in) — i.e. a `Behavior.Template`
authority covering `:read`/`:write`/`:instantiate` on
SessionTemplates in `ws`, which is what `spawn_from_template/2`'s
preflight (§1.4 / PR-4) will check. There is no `Repo.transaction`
because there is no shared SQL transaction across two Kind snapshots
— instead the ordering is: template-Kind-first, cap-second; if the
cap grant fails the template still exists (harmless — a template
nobody can yet instantiate, fixable by re-granting) but the function
returns `{:error, _}` so the caller knows. (This is the
let-it-crash-honest trade-off: no fake atomicity over two
independent snapshot writes.)

**(f) No silent divergence.** The invariant rev 3 protects: persisted
templates (`kind_snapshots` — the `:template` slice per §1.0), tags
(`template_tags`), caps (`:identity` slices), and the live
`KindRegistry` never disagree. Tests:
- **Restart test**: persist a SessionTemplate, simulate a restart
  (stop the Kind, re-reference the hash URI), assert the rehydrated
  slice equals the persisted content and `list_templates` still shows
  it.
- **Concurrent-create test**: two `save_template_as` calls with
  *identical* content race → both resolve to the same hash URI → one
  spawn wins, the other gets `{:error, {:already_started, _}}` →
  treated as success → exactly one snapshot row.
- **CAS-tag test**: two `move` calls with the same `expected_hash`
  race → exactly one succeeds, the other returns
  `{:error, :tag_moved}`.

## 2. PR sequence — independently-testable vertical slices (codex MEDIUM-5)

rev 2's sequence asked PR-1's `SessionTemplate.instantiate/3` to
delegate to a not-yet-built Generator, and PR-2 to prove "persisted
row is re-instantiable" before PR-4 built worker-spawning. rev 3
resequences so **each PR's tests pass honestly on that PR's own code**
— no stub satisfying a callback, no test deferred to a later PR.

Every PR carries its own tests. The rule: a PR claims only what its
code does.

### PR-1 — contracts only: the `Behavior.Template`, the cap shape, the adapter

Pure contract + schema. No persistence claim, no re-instantiation
claim.

- **`Ezagent.Behavior.Template`** — the NEW Behavior (§1.0):
  `state_slice/0 → :template`, `actions/0 → [:read, :write,
  :instantiate]`, `init_slice/1`, `invoke/4`, `interface/0`. Follows
  the `Ezagent.Behavior.Identity` / `Ezagent.Behavior.Chat` house
  pattern.
- `Ezagent.Entity.AgentTemplate` and `Ezagent.Entity.SessionTemplate`
  gain `Ezagent.Behavior.Template` in their `behaviors/0` (alongside
  the existing `Ezagent.Behavior.Identity`), so each Kind boots a
  `:template` slice. The real slice schemas (phase7 SPEC, currently
  moduledoc-only) become the `Behavior.Template` content shape
  (§1.0); AgentTemplate's content carries `flavor`. URIs 3-segment
  per §1.2.
- `EzagentDomainChat.Application.register_chat_behaviors/0` registers
  `Behavior.Template`'s 3 actions on both Template Kinds via
  `BehaviorRegistry.register/3` (§1.0) — so `template.read` /
  `template.write` / `template.instantiate` are dispatch-invocable.
- AgentTemplate Kind's `Behavior.Template` `:instantiate` action
  resolves `flavor` → `AgentFlavorRegistry` Template Class; the
  actual worker spawn is delegated to the §1.6a wrapper. SessionTemplate
  Kind's `:instantiate` returns `{:error, :use_generator}` — honest:
  SessionTemplate instantiation IS the Generator (PR-4).
- `Ezagent.Kind.Template` (the plugin Template-CLASS callback
  contract) is UNCHANGED — PR-1 keeps it; §1.0 spells out the
  relationship.
- `Ezagent.Capability.instance_match?/2` gains the
  `{:within_workspace, workspace_uri}` shape (§1.4).
- `Ezagent.Entity.AgentTemplate.to_template_data/2` adapter (§1.5).
- `Ezagent.PluginCc.Template.CcAgent` extended: `validate/1` +
  `instantiate/3` accept the 4 new optional keys; `build_claude_cmd/2`
  emits operator `--settings`/`--mcp-config` with the **mandatory
  safety file LAST** and the trusted bridge config non-removable
  (§1.5 (c)).
- **Tests**: `Behavior.Template` — `actions/0` returns the 3
  actions; `:write` then `:read` round-trip; `:write` on a
  `{:snapshot, :on_change}` Template Kind writes a `kind_snapshots`
  row; both Template Kinds resolve all 3 actions via
  `BehaviorRegistry`; `cap_for_action(AgentTemplate, :write, uri)`
  yields `behavior == Ezagent.Behavior.Template`; SessionTemplate
  `:instantiate` → `{:error, :use_generator}`. Plus: the 3-segment
  URI round-trip; cross-workspace name non-collision;
  `{:within_workspace, W}` matches/denies (§1.4); `to_template_data/2`
  round-trip; `CcAgent` legacy-3-key + extended-7-key both validate;
  **hostile-path** — operator `settings_path` cannot flip
  `remoteControlAtStartup` true, operator `mcp_config_path` cannot
  drop the esr-bridge server.

### PR-2 — durable source-template metadata + the working-copy slice schema

The data shapes the Generator and the persistence both depend on —
landed before either.

- `template_working_copy` field added to the Chat slice
  (`Ezagent.Behavior.Chat` `state_slice`), shape per §1.3 + §1.6
  (`agent_slots :: [{slot_name, template://agent/...}]`,
  `routing_rules :: [{matcher_ast, [slot_name]}]`, plus
  `orchestrator_template_uri`, `default_workspace_uri`,
  `description`). Session is already `{:snapshot, :on_change}` —
  the slice persists.
- `Ezagent.Orchestrator.Tools.build_working_copy/4` rewritten to emit
  the template-shaped slice: `agent_slots` read straight from the
  working-copy slice (§1.6) — NOT from `WorkspaceRegistry`/live
  instance URIs; routing receivers as slot names; `session_uri` /
  `name` excluded from the hash-input map.
- **Tests**: the working-copy slice round-trips through a Session
  snapshot/restore; `build_working_copy/4` emits AgentTemplate URIs +
  slot-name routing; identical team config in two different sessions
  → `compute_version_hash/1` returns the SAME hash (proves
  `session_uri` excluded). No re-instantiation claim here.

### PR-3 — `Ezagent.TemplateTags` registry + the persistence helpers

The persistence layer, standing on its own.

- `Ezagent.TemplateTags` — Ecto schema `template_tags` +
  ETS-hydrated registry, `routing_rules`/`RuleStore` pattern (§1.7
  (c)): `put/5`, `resolve/3`, `list/1`, CAS `move/5`. `workspace_uri`
  NOT NULL (invariant 14). Migration uses the SQLite
  CREATE-NEW/INSERT-SELECT pattern (invariant 14).
- `Ezagent.Entity.SessionTemplate.persist_version/2` — the helper
  that spawns a SessionTemplate Kind at the hash URI and populates
  its slice (§1.7 (a)). Idempotent on duplicate hash.
- **Tests**: `put`/`resolve` round-trip; cross-workspace tag
  non-collision; CAS `move` — concurrent move, one wins; idempotent
  duplicate-hash `persist_version` (same content → one row, no
  error); `template_tags` rows carry non-nil `workspace_uri`.

### PR-4 — the Generator, fully (+ the delegated-spawn wrapper + the owner-cap preflight)

`Session.spawn_from_template/2` performs all 8 phase7-SPEC steps
(currently 4).

- **`Ezagent.Entity.Agent.spawn_from_agent_template/4`** — the NEW
  delegated-spawn wrapper (§1.6a). Resolves the AgentTemplate's
  `:template` slice (`Behavior.Template` `:read`), looks up the
  flavor Class, builds the Class data via `to_template_data/2`,
  calls `Class.instantiate/3`, then — **wrapper-owned** —
  `AgentLineage.record(worker_uri, principal_uri)` and
  `WorkspaceRegistry.bind(worker_uri, workspace_uri)` for every
  returned worker URI. The old `Agent.spawn/4` is retired from this
  path (deleted if it has no other call sites).
- Resolve `agent_slots` → for each slot, spawn via
  `spawn_from_agent_template/4` (NOT `Class.instantiate/3` directly —
  so lineage is recorded; §1.6a).
- Record each slot's `{slot_name, source_agent_template_uri}` into the
  Session's `template_working_copy.agent_slots` slice (§1.6).
- Resolve `routing_rules` slot-names → per-instance agent URIs →
  install via `RuleStore.add`.
- `grant_scoped_caps/3` extended (§1.4): grants the orchestrator the
  two template caps #3/#4 (`behavior == Ezagent.Behavior.Template`)
  alongside the existing two scope-bounded caps — but **only after
  the owner-cap preflight passes** for each (§1.4 steps 1-4). The
  preflight loads the owner's ACTUAL caps via
  `Ezagent.Identity.list_caps_for/1` (NOT `admin_caps()`) and
  `Capability.matches?/2`-checks them against the delegated scope; a
  failing preflight skips ONLY that cap (fail closed). Caps #1/#2 are
  unconditional.
- `spawn_from_template/2` itself preflights the OWNER too — checks
  `owner_uri` holds a `Behavior.Template` cap for `:session_template`
  covering the SessionTemplate's workspace before instantiating
  (otherwise the owner cannot create the session at all).
- **Tests**: a multi-slot template instantiates all workers + routing;
  each worker IS in `AgentLineage` under the orchestrator and bound
  to the session workspace (§1.6a wrapper test);
  `agent_slots` slice populated with the right source-template URIs;
  the slice survives a restart; re-instantiation of the same template
  produces an identical team; **owner-cap preflight denial test** —
  owner without a SessionTemplate `Behavior.Template` cap → Generator
  denied; owner without cap-#3/#4 authority → orchestrator spawns but
  its cap set omits #3 and/or #4 (§1.4 PR-4 test).

### PR-5 — the Orchestrator runs: the privileged MCP surface

The decisive PR. Standing on PR-1..4: the caps exist (§1.4), the
working-copy slice exists (PR-2), persistence exists (PR-3), the
Generator populates the slice (PR-4) — so PR-5's tests prove only
PR-5's behavior.

- **Dispatch-routing the 7 tools.** `Orchestrator.Tools` today calls
  `Agent.spawn/4` / `RuleStore.add/5` / `terminate_child` DIRECTLY,
  bypassing dispatch + CapBAC. Each tool is refactored to go through
  `Ezagent.Invocation.dispatch/1` (or, for the agent-slot tools,
  through the §1.6a wrapper which itself dispatches `template.read`)
  so the orchestrator's four delegated caps (§1.4) are enforced on
  every tool action. The per-tool dispatch table is §2.1 below — it
  targets the real `Ezagent.Behavior.Template` actions, NOT
  `identity.*` and NOT bare callbacks.
- **`update_template` / `save_template_as` now persist** — via
  `SessionTemplate.persist_version/2` (PR-3), which spawns the
  SessionTemplate Kind + dispatches `Behavior.Template` `:write`
  (§1.7 (a)). They write a real `kind_snapshots` row;
  `update_template` produces a new hash version of the parent;
  `save_template_as` produces the first version of a new name and
  (§1.7 (e)) grants the owner a `Behavior.Template` SessionTemplate
  cap on it.
- **The orchestrator MCP server** — a new component in
  `ezagent_domain_chat`:
  - Tool JSON schemas — one per the 7 tools (§2.1 has the brief
    schema per tool).
  - Caller context — the MCP server runs per-orchestrator-agent; the
    calling orchestrator's URI + its four delegated caps form the
    `ctx` for every dispatched action. No tool runs with ambient
    `admin_caps`.
  - Session context — the orchestrator's session URI is bound at
    MCP-server start; tools read it from there, never from tool args.
  - Error propagation — `{:error, :unauthorized}` /
    `{:error, :cross_workspace_denied}` / `{:error, _}` becomes a
    structured MCP tool error the orchestrator LLM sees and can
    surface in chat.
- **The `cc-orchestrator` AgentTemplate config** — `seed_cc_orchestrator_template`
  populates a real slice: `flavor: "cc"`, a `claude_config_dir`, a
  `settings.json` enabling the orchestrator pattern, an
  `mcp_config_path` pointing at the orchestrator MCP server, a system
  prompt.
- **The chat path** — mentioning the orchestrator routes (via
  mention-gated routing #226) `chat.receive` to it; the live `claude`
  processes it and may call the 7 MCP tools.
- **Tests IN THIS PR**: a deterministic fake-LLM / fake-MCP e2e that
  drives the 7 tools through the MCP server + asserts CapBAC holds —
  including:
  - the **no-`admin_caps`-fallback denial test** — `list_templates`
    with caps #3/#4 omitted → `:unauthorized`;
  - the **cap-#2 happy-path test** (§1.6a) — `remove_agent_slot` /
    `update_agent_template` on a worker the orchestrator spawned via
    the delegated path SUCCEED (proving the wrapper recorded
    lineage); the control against another orchestrator's worker
    DENIES;
  - the **MEDIUM-5 per-kind list test** — a cap-#3-only caller sees
    `session_templates: [...], agent_templates: []`; a cap-#4-only
    caller sees the inverse; neither leaks the other kind's URIs;
  - per-tool effect tests; the agent-slot tools maintain
    `template_working_copy.agent_slots` (§1.6).
  The human agent-browser demo is supplemental release evidence, not
  the CI gate.

### PR-6 — the 3 session-creation entry points + closeout

- `SessionTemplate.fork/2` — `persist_version/2` a new SessionTemplate
  with `parent_template_uri` set; grant the owner a `Behavior.Template`
  SessionTemplate cap (§1.7 (e)).
- `SessionTemplate.create/2` — `persist_version/2` a new root
  template (no parent); grant the owner cap.
- Both, plus `spawn_from_template`, require the SessionTemplate
  `Behavior.Template` cap (preflight per §1.4) before they act.
- Any V1-V5 gating test not already landed (`bootstrap_to_serving`,
  `plugin_hot_install` if still missing).
- Correct `docs/notes/phase-7-handoff.md` (it falsely declares "v1
  release, code-complete") + the stale `phase-7-resume-state.md`.
- The supplemental human agent-browser e2e (phase7 SPEC §"e2e demo").
- **Tests**: fork lineage (`parent_template_uri` correct, parent row
  unchanged); create produces a root; cap denial on each path.

### 2.1 PR-5 per-tool dispatch table (codex explicit ask — rev 4: real `Behavior.Template` actions)

All 7 `Orchestrator.Tools` functions, refactored to dispatch. `ctx`
for every row = `%{caller: orchestrator_uri, caps: <the 4 delegated
caps>, reply: …}`. Every cap's `behavior` field is the **module
reference** shown (invariant 2 — never an atom shorthand). Every
template action resolves through `BehaviorRegistry` to the real
`Ezagent.Behavior.Template` Behavior registered in PR-1 (§1.0) — so
`cap_for_action/3` derives the same `behavior` and CapBAC matches.
"Workspace derived from" describes how the target workspace segment
is obtained.

| Tool | Dispatch target URI | Behavior.action | Args (JSON schema, brief) | Required cap shape | Workspace derived from | Error mapping |
|------|---------------------|-----------------|---------------------------|--------------------|------------------------|---------------|
| `add_agent_slot` | `template://agent/<ws>/<name>?action=template.instantiate` — the `Behavior.Template` `:instantiate` action on the AgentTemplate Kind (§1.0). The action resolves the flavor Class and hands off to the §1.6a wrapper, which runs `Class.instantiate/3` + records lineage + binds workspace. | `template.instantiate` (`Ezagent.Behavior.Template`) | `{slot_name: string, agent_template_uri: string(uri), prompt_override?: string}` | `{kind: :agent_template, behavior: Ezagent.Behavior.Template, instance: {:within_workspace, ws}}` (cap #4) | `agent_template_uri`'s workspace segment; must equal the orchestrator's session workspace | `:unauthorized` → MCP error "slot template outside your workspace"; `:cross_workspace_denied` likewise; `{:error, _}` → "spawn failed: …" |
| `remove_agent_slot` | `entity://agent/<ws>/<flavor>_<slot>?action=lifecycle.terminate` (terminate Behavior on the Agent Kind; replaces the direct `DynamicSupervisor.terminate_child`) | `lifecycle.terminate` | `{slot_name: string}` | `{kind: :agent, behavior: :any, instance: {:spawned_by, orch}}` (cap #2 — resolves because the §1.6a wrapper recorded the worker under the orchestrator) | the orchestrator's session workspace (the slot's instance URI is built in it) | `:unauthorized` → "not your agent"; absent slot → `{:ok, :removed}` (idempotent) |
| `update_agent_template` | sequential `remove_agent_slot` then `add_agent_slot` dispatches | (as the two above) | `{slot_name: string, new_agent_template_uri: string(uri)}` | caps #2 + #4 | as the two above | first failing dispatch's mapping |
| `write_matcher` | `session://<template>/<ws>/<name>?action=routing.add_rule` (the rule's scope-owning Kind is the orchestrator's Session — invariant 12, no `routing-admin://` singleton) | `routing.add_rule` | `{matcher_ast: object, receiver_slot_names: [string]}` | `{kind: :session, behavior: :any, instance: {:within_session, S}}` (cap #1) | the orchestrator's session URI workspace segment | `:unauthorized` → "cannot write rules outside your session"; matcher parse error → "invalid matcher" |
| `update_template` | `template://session/<ws>/<parent_name>@<new_hash>?action=template.write` — spawn the new-hash SessionTemplate Kind, then dispatch `Behavior.Template` `:write` to populate its `:template` content slice (§1.7 (a)). NOT `identity.update_slice` (no such action). | `template.write` (`Ezagent.Behavior.Template`) | `{content: object}` — the normalized template content map (built from session context; the MCP tool itself takes no args) | `{kind: :session_template, behavior: Ezagent.Behavior.Template, instance: {:within_workspace, ws}}` (cap #3) | the orchestrator's session workspace (parent template lives there) | `:parent_template_deleted` → "parent gone, use save_template_as"; `:unauthorized` → "no template-write authority here" |
| `save_template_as` | `template://session/<ws>/<new_name>@<hash>?action=template.write` (new family; same spawn-then-`:write` persist path) | `template.write` (`Ezagent.Behavior.Template`) | `{new_name: string}` (content from session context) | `{kind: :session_template, behavior: Ezagent.Behavior.Template, instance: {:within_workspace, ws}}` (cap #3) | the orchestrator's session workspace | `:unauthorized` → "no template-create authority here"; duplicate hash → success (idempotent) |
| `list_templates` | a per-kind cap-gated read of `Ezagent.Ecto.KindSnapshot.list_in_workspace(ws)` (§1.7 (b)), partitioned by `kind_type`. NOT a single dispatch — but each kind's result set is gated by its OWN `Behavior.Template` cap before inclusion (§1.7 (b) / rev-4 MEDIUM-5) | (cap-gated read, no dispatch — see note) | `{name_filter?: string}` | AgentTemplate rows gated by cap #4 (`kind: :agent_template`); SessionTemplate rows gated by cap #3 (`kind: :session_template`); each via `Capability.matches?/2` | the orchestrator's session workspace | neither cap → `:unauthorized` "no template-read authority"; only one cap → that kind's rows returned, the other kind's list empty (no cross-kind leak) |

Note on `list_templates`: it is the one tool that is a pure read of
`kind_snapshots` (§1.7 (b)), not an actor-to-actor message — so it is
not a dispatch. The MCP server enforces CapBAC explicitly and **per
kind**: it checks cap #4 (`:agent_template`, `behavior ==
Ezagent.Behavior.Template`) before including the AgentTemplate rows
and cap #3 (`:session_template`) before including the SessionTemplate
rows. A caller authorized for only one kind never learns the other
kind's template names. This is documented as a deliberate trade-off,
not an idiom: reads of the snapshot catalog are not dispatches, but
they are still cap-gated — per result set — at the MCP-server
boundary.

## 3. cc-agent-config reconciliation (audit §"Overlap")

The drafted `2026-05-22-cc-agent-config.md` (branch
`docs/cc-agent-config-spec`, unmerged) and Phase-7 AgentTemplate
design the same `CLAUDE_CONFIG_DIR` sandbox. **AgentTemplate is the
design of record** (§1.1, §1.5 — it owns `claude_config_dir`,
`settings_path`, `mcp_config_path`, `api_key_helper`; §1.5 (c)
specifies exactly how the cc Template Class consumes them). After
PR-1, cc-agent-config shrinks to ~nothing.

**Decision flagged for Allen**: recommend **retiring the standalone
cc-agent-config SPEC** and folding cc agent configurability into
AgentTemplate (Phase 7). Allen confirms when back. Until then, the
cc-config branch stays unmerged and is NOT implemented.

## 4. macOS Keychain caveat (carry-forward)

`CLAUDE_CONFIG_DIR` isolates everything except macOS Keychain
credentials. The cc-config rev 2 spike confirmed file-based
credentials DO isolate. The `api_key_helper` AgentTemplate field
(threaded to `CcAgent` via the §1.5 adapter as the
`api_key_helper` cc.agent key) exists for the macOS multi-agent case;
PR-1's cc Template Class delegation + the runbook document it.

## 5. Scale, risk, user-assist

- PR-1..4 are bounded — fixing broken/incomplete shipped code against
  now-correct contracts.
- **PR-5 is highest-risk** — a new privileged command surface. It
  gets the most codex scrutiny + a deterministic CI e2e (including
  the HIGH-1 no-`admin_caps`-fallback denial test).
- **User-assist (flag per memory `feedback_flag_user_assist_steps`)**:
  PR-5/PR-6's live demo needs a human to drive an orchestration chat;
  the orchestrator's `claude` needs working credentials in its
  `claude_config_dir` — the same credential-seeding question as
  cc-config Q4. Allen needed for the live demo.

## 6. Verification

Each phase7 `VERIFICATION.md` row the audit marked NOT MET / PARTIAL
ends MET, with the gating test in the PR that delivers the behavior
(not batched): V2.1 (PR-5), V2.3/V2.5 (PR-5 — persistence now lands
via `Behavior.Template` `:write` with the running orchestrator), V2.4
(PR-4), V2.6 (PR-2 working-copy restart + PR-4 Generator restart),
V5.1's 7 tests distributed PR-1..6. The Generator instantiates
workers+routing (PR-4); the owner-cap preflight denies a Generator
call whose owner lacks SessionTemplate `Behavior.Template` authority
(PR-4); a worker spawned through the delegated path IS in the
orchestrator's lineage so cap #2 permits managing it (PR-4 wrapper
test); the orchestrator's dispatch-routed tools enforce the four
delegated caps — targeting the real `Ezagent.Behavior.Template`
actions — with no `admin_caps` fallback (PR-5); `list_templates`
leaks no cross-kind URIs (PR-5 MEDIUM-5 test); `phase-7-handoff.md`
no longer claims a false "code-complete" (PR-6).
