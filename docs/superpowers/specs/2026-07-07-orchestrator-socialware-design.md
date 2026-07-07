# M2 -- orchestrator socialware design

**Status:** rev2 -- codex-reviewed 2026-07-07 (rev1 UNSOUND: 3 BLOCKER + 3 MAJOR + 1 MINOR),
all resolved. [B-1] `uses: ["cc"]` not `"orchestrator"`; [B-2] post-materialization hook for
scoped caps + MCP context; [B-3] Option A compat shim RECONCILED to adopt-in-place.
[M-1] `orchestrator_template_uri` MOOT claim softened -- it's still read for MCP rebuild.
[M-2] Tool catalog split (13 domain / 12 MCP) documented explicitly. [M-3] compat shim must
use `create_session`'s `:global` lock. [m-1] `requires: []` removed from YAML (M3 field).
**Authority:** `docs/superpowers/specs/2026-07-06-orchestration-as-socialware-design.md` SS2 + S9 M2
(on main). Lead decision (Allen, 2026-07-07): orchestrator IS a socialware -- it provides
team/routing/role management. M2 makes this formal: 13 MCP team/version tools become plugin
contributions, orchestrator Definition (views = Agent Console), default SessionTemplate installs
it, `Session.ensure_orchestrator` retires.

---

## 1. Problem (current state, every claim cites code)

Today the stock orchestrator is NOT a socialware. Three symptoms:

**(a) Hardcoded template -- you can't swap orchestrator personas.**

`Session.ensure_orchestrator/3` at
`apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator.ex:94` builds the
orchestrator template URI as `Ezagent.URI.template(:system, :agent, "cc-orchestrator")` --
a hardcoded string literal. The cc-orchestrator AgentTemplate is seeded by
`CcOrchestratorSeed.seed/0` at
`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/cc_orchestrator_seed.ex:107`,
writing hardcoded content (`flavor: "cc"`, line 416; `role: "orchestrator"`, line 430).
The orchestrator role recipe at
`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/orchestrator_recipe.ex:65` hardcodes
`skills: ["ezagent-session-orchestrator"]` and `prompt: persona()`. All three are
hardwired at boot -- there is no governance/publish path to change them.

**(b) 13 tools as Elixir domain-code -- not versionable through governance, and CATALOGS DRIFT.**

Two separate tool catalogs exist:

*Domain catalog* at
`apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/tool_catalog.ex:4-19`
declares 13 atoms: `:add_managed_member`, `:add_participant`, `:update_member_template`,
`:remove_member`, `:define_rule_set_rule`, `:define_prompt_template`, `:define_legend`,
`:update_template`, `:save_template_as`, `:migrate_session`, `:list_templates`,
`:kb_query`, `:kb_ingest`.

*CC MCP server catalog* at
`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server/tool_catalog.ex:8-289`
exposes 12 MCP `tools/list` schemas -- NO `add_participant`. The two catalogs already
DRIFT: the domain catalog is the canonical gate (`ToolCatalog.tool?/1` validates
atoms), but the MCP catalog is what the orchestrator's `claude` subprocess actually
SEES. `add_participant` is callable through `SessionManager` dispatch but never
appears in `tools/list`.

These are implemented in
`apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex` as Elixir functions
dispatched via `Ezagent.Invocation.dispatch/1` (e.g. `add_managed_member` at line 136,
`define_rule_set_rule` at line 559). The orchestrator's `claude` subprocess reaches
them through a stdio MCP bridge (`orchestrator_bridge.py`) that forwards `tools/call`
over WS to `McpServer` at
`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server.ex`. The tools live as
domain-code, not as plugin contributions declared in a recipe -- so tool changes require
a BEAM deploy, not a socialware publish.

[M-2 resolved]: The tool catalog split is now explicitly documented. Builder-verify note:
the two catalogs must be unified -- the recipe's contribution declaration is the SINGLE
source of truth, and both the domain gate and the MCP `tools/list` derive from it.

**(c) Special spawn path parallel to universal materialization.**

`Session.ensure_orchestrator/3` (orchestrator.ex:78-148) calls
`spawn_orchestrator_via_template_content/5` (line 234) which reads the cc-orchestrator
AgentTemplate's content slice via `:sys.get_state` (line 286-299) and calls
`Agent.spawn_from_template_content/4` directly. This is a SEPARATE path from the
universal `materialize_template_team` path (`TemplateTeam` module at
`apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/template_team.ex`,
called by `SessionCreator.create_session/3` at
`apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex`).
Two ways to create session members: one universal (template-team materialization), one
special (hardcoded ensure_orchestrator). The orchestrator's `orchestrator_template_uri`
field on SessionTemplate (declared at
`apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex:60`) IS read during
materialization (`TemplateResolver.orchestrator_template_uri_of/1` at
`apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/template_resolver.ex:108`)
and written to the session's durable working copy (`Materializer.materialize_orchestrator_working_copy/4`
at `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/materializer.ex:10`),
so the field is NOT dead -- it is an active, hardcoded special-case in the create-session
chokepoint.

The default SessionTemplate (seeded at
`apps/ezagent_domain_session/lib/ezagent_domain_instance_message/application.ex:582-669`)
declares the orchestrator as a member with `role_name: "orchestrator"` and
`source_template_uri` pointing at the hardcoded cc-orchestrator AgentTemplate. But
the actual spawn of that member goes through `ensure_orchestrator`, not through the
normal member-materialization path -- the default template's `members` declaration is
treated as a member declaration to place in `template_working_copy.member_declarations`
(`Materializer.materialize_template_declaration/3` at line 29), while the orchestrator
itself is spawned by the special `ensure_orchestrator` call.

**(d) `orchestrator_template_uri` on socialware Definition is legacy.**

The `%Definition{}` struct at
`apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex:25` carries an
`orchestrator_template_uri: nil` field. Conformance validates it parses (conformance.ex:285).
But it is a direct URI-to-template pointer that predates the role-slot model --
P1--P3 role slots express template choice through `recipe` + `flavor`, not through a
bare `orchestrator_template_uri`. The `DefinitionEditor` at
`apps/ezagent_domain_session/lib/ezagent/socialware/definition_editor.ex:95-99`
reads this from either the template's legacy field or the socialware definition's
field (lines 391-402), merging them with the definition taking precedence. This is a
layering violation -- template choice belongs to the role slot, not a second URI
field on the definition.

---

## 2. Architecture (the layering guard from SS2)

Primitives stay framework FOREVER: session membership (`session.join`/leave),
role materialization (`materialize_template_team` and `session.assign_role`),
the routing table substrate (RuleStore/RoutingRegistry/Resolver/Matcher), the
socialware install machinery (Installation/DefinitionRegistry/governance).

The orchestrator socialware PACKAGES on top of those primitives:
- **Operator views** -- the Agent Console surfaces: the `sessions_table`, `conversation`
  (with team/role/routing management panels), and admin surfaces (`templates`,
  `routing`, `caps_admin`).
- **Agent-facing tools** -- the orchestrator MCP tools (13 domain-catalog tools, 12
  exposed to LLM via MCP `tools/list`), moved from Elixir domain-code to plugin
  contributions declared in the cc plugin's recipe.

**Why the guard is load-bearing:** Installing ANY socialware must not require the
orchestrator socialware's machinery, because installing the orchestrator itself needs
those framework primitives. If install depended on the orchestrator, the orchestrator
could never be installed. Install/routing/role must work bare (framework), and the
orchestrator socialware is "just another app" that makes them ergonomic.

---

## 3. Design -- three bounded moves

### M2-a: Tools to plugin contributions

**Current state (catalogued from both tool catalogs):**

| # | Tool name | Domain catalog? | MCP tools/list? | Category | What it does |
|---|---|---|---|---|---|
| 1 | `add_managed_member` | yes | yes | team | Spawn worker from AgentTemplate + join as member |
| 2 | `add_participant` | yes | **NO** | team | Add member by ref. NOT surfaced to LLM via MCP. |
| 3 | `update_member_template` | yes | yes | team | Swap member's source AgentTemplate + regenerate |
| 4 | `remove_member` | yes | yes | team | Terminate worker + prune routing + leave session |
| 5 | `define_rule_set_rule` | yes | yes | routing | Insert single-receiver routing rule into named rule-set |
| 6 | `define_prompt_template` | yes | yes | routing | Install named prompt template |
| 7 | `define_legend` | yes | yes | routing | Front rule-set with @legend handle |
| 8 | `update_template` | yes | yes | version | Snapshot session -> new version of parent SessionTemplate |
| 9 | `save_template_as` | yes | yes | version | Snapshot session -> first version of NEW SessionTemplate |
| 10 | `migrate_session` | yes | yes | version | Migrate session to immutable target SessionTemplate URI |
| 11 | `list_templates` | yes | yes | version | List visible AgentTemplate + SessionTemplate URIs |
| 12 | `kb_query` | yes | yes | kb | Retrieve top-k chunks from kb-agent |
| 13 | `kb_ingest` | yes | yes | kb | Ingest document into kb-agent |

13 tools in the domain catalog (tool_catalog.ex:4-19); 12 in the MCP surface
(mcp_server/tool_catalog.ex:8-289). `add_participant` is an internal
`SessionManager` invoke path, not an LLM-facing MCP tool. The recipe's contribution
declaration must unify these two catalogs into a single source of truth.

**What changes:** These tools move from Elixir code in
`apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex` to contributor
declarations in the cc plugin's orchestrator recipe. The orchestrator role's recipe
(already registered in `RecipeRegistry` as `"orchestrator"` at
`orchestrator_recipe.ex:48`) loads them through the existing `Recipe.Compose` path
(`apps/ezagent_core/lib/ezagent/agent/recipe/compose.ex:56`).

**Interface:** The recipe declares `contributions: [tool_catalog]` (or an equivalent
key -- the exact recipe field TBD), and `Recipe.Compose.materialize/2` folds them
into the `sandbox_content`. The cc `Template.OrchestratorBootstrap` at
`apps/ezagent_plugin_cc/lib/ezagent/template/orchestrator_bootstrap.ex` (which
currently copies the hardcoded `ezagent-session-orchestrator` skill into the spawned
agent's config_dir) instead reads the recipe's compiled contribution set and installs
them. The MCP tool surface the orchestrator's `claude` sees is exactly what the
recipe declares, versioned through the socialware governance chain.

**B-2: Post-materialization orchestrator hooks.** The standard `materialize_template_team`
path at `template_team.ex:29` materializes role agents and recipe caps but does NOT
perform two orchestrator-specific side effects currently done by `ensure_orchestrator`:

1. **Scoped delegation caps** (`Orchestrator.Caps.grant_orchestrator_scoped_caps/3`
   at orchestrator.ex:548-550) -- grants the orchestrator `{:within_session, S}` and
   `{:spawned_by, orchestrator}` caps that authorize its MCP tool dispatches.
2. **MCP context registration** (`register_orchestrator_mcp_context/5` at
   orchestrator.ex:578-591) -- populates the `OrchestratorReadinessPort` cache so the
   MCP bridge can resolve `orchestrator_uri -> {session_uri, workspace_uri, ...}`.

The Definition-based spawn must perform both. Design: the orchestrator role's materialization
step includes a **post-materialization callback** registered by the cc plugin. The callback
name TBD (`post_spawn_orchestrator/3` or equivalent). The recipe's `requested_caps`
already covers Template authority (orchestrator_recipe.ex:71-76); the scoped delegation
caps and MCP context are session-level ops the callback handles, not agent-level capability
requests.

**No rewrite of tool implementations:** The existing dispatch calls inside
`Ezagent.Orchestrator.Tools` stay as Elixir domain-code -- the tools are server-side
operations on the live session. What changes is the DECLARATION surface: the recipe
controls which tools the orchestrator role offers, and the recipe is publishable
through the socialware governance chain. A future orchestrator variant could declare
a subset or superset of tools through its own recipe.

### M2-b: Orchestrator Definition

The orchestrator gets a socialware `%Definition{}`:

```yaml
name: orchestrator
version: "0.1.0"
title: "Session Orchestrator"
description: "Team, routing, and role management for multi-agent sessions."
uses: ["cc"]             # B-1: the cc plugin (slug "cc") hosts the orchestrator
                         # recipe + orchestrator bootstrap. It DECLARES the tool
                         # contributions via its recipe (orchestrator_recipe.ex).
                         # Plugin identity: plugin_info/0 at
                         # apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/application.ex:77
                         # returns slug: "cc". There is NO separate "orchestrator" plugin.
roles:
  - role_name: orchestrator
    fill: agent
    recipe: orchestrator
    flavor: cc
routing_rules: []       # empty -- orchestrator provides tools, doesn't route messages
views: []               # see below
prompt_templates: {}
legends: {}
visibility_policy:
  publish_policy: auto
  scope: public
  web_anon_access: false
owner_policy:
  type: installer
```

**The views field:** The orchestrator socialware DOES NOT declare its own views module
in the `views` field. The Agent Console surfaces (team wizard, role assignment, routing
editor) are already registered as world layout slots in
`apps/ezagent_plugin_world/lib/ezagent/world/slot_registry.ex:40-87` and rendered by
the world plugin's `ConversationView` / `AdminActions`. These are application-level
surfaces, not socialware views. The socialware `views` mechanism
(`SessionViewRegistry` at `apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view_registry.ex:54-58`)
registers per-session view modules keyed by atom id (e.g. `hello_render`). The
orchestrator needs no custom per-session views -- its operator surfaces are the
existing world layout slots. However, the orchestrator socialware COULD declare a
future `orchestrator_console` view if a dedicated management surface is needed.

**Design decision:** The `views: []` field is intentionally empty. The orchestrator
socialware's "console" IS the existing world Agent Console -- no new view module is
needed. `routing_rules: []` is also intentional -- the orchestrator provides tools
to MANAGE routing, but does not participate in message routing itself. Its tools are
invoked by the LLM through MCP `tools/call`, not by the routing table.

### M2-c: Default install + `ensure_orchestrator` retirement

**Default SessionTemplate gains `installs: [orchestrator]`.**

The current default SessionTemplate seed at
`apps/ezagent_domain_session/lib/ezagent_domain_instance_message/application.ex:631`
writes `installs: ["chat"]`. This changes to `installs: ["chat", "orchestrator"]`.

When `SessionCreator.create_session/3` materializes a session from this template,
the socialware install machinery (`Installation.resolved_template_installs/2` at
conformance.ex:312) resolves `"orchestrator"` through `DefinitionRegistry.lookup/2`.
The orchestrator role (`role_name: "orchestrator"`, recipe `"orchestrator"`, flavor
`"cc"`) is materialized through the STANDARD `materialize_template_team` path --
the same path that materializes hello's `builder` and `responser` roles.

**`Session.ensure_orchestrator` becomes transitional (Option A semantics).**

The entire function at orchestrator.ex:78-148 becomes a thin compat shim. **B-3
resolved: the shim ADOPTS existing orchestrators into Definition-based membership**
(consistent with S4 Option A), rather than returning `:already_present` without
adoption.

```
def ensure_orchestrator(session_uri, workspace_uri, owner_uri) do
  # MUST acquire the same :global lock create_session/3 uses
  # (session_creator.ex:167, session_creator.ex:230 -- M-3 resolved)
  # so adoption and concurrent create_session serialize.
  # 1. Check if an orchestrator member already exists.
  # 2a. If yes AND it is NOT under Definition membership:
  #     ADOPT it: record member join with role_name "orchestrator",
  #     register Definition install record, return {:ok, uri, :already_present}.
  # 2b. If yes AND already under Definition membership:
  #     return {:ok, uri, :already_present} -- already adopted.
  # 3. If no orchestrator exists: install "orchestrator" socialware
  #    via standard Installation path, spawning from Definition's recipe+flavor.
  ...
end
```

The compat shim's behavior (B-3, M-3 resolved):
1. **Lock:** Acquire the same `:global` per-session lock that
   `SessionCreator.create_session/3` uses at session_creator.ex:167. Without it,
   concurrent `create_session` + compat-shim interleave on working-copy writes,
   install records, and MCP context re-registration.
2. Check if an orchestrator member already exists in the session.
3. If yes AND unadopted: **adopt it** -- record it as a session member with
   `role_name: "orchestrator"` under the Definition-based install record, so the
   session's socialware install machinery sees it as managed. The agent's process
   stays running (zero downtime). Return `{:ok, uri, :already_present}`.
4. If yes AND already adopted: return `{:ok, uri, :already_present}` (idempotent).
5. If no: install the `"orchestrator"` socialware via the standard `Installation`
   path, spawning an orchestrator agent from the Definition's role recipe+flavor.

**Retirement condition:** `ensure_orchestrator` is DELETED (not just deprecated)
when ALL of:
- Every new session created through `create_session/3` gets its orchestrator via
  the standard `materialize_template_team` path (the `installs: ["orchestrator"]`
  default template covers this).
- Every EXISTING session has either: (a) already had its orchestrator adopted into
  Definition-based membership via the compat shim (step 3 above), OR (b) naturally
  churned (session deleted/ended).
- The compat shim's adoption path (step 3 above) is exercised in CI against
  existing-session fixtures and passes.

**M-1: `orchestrator_template_uri` is still READ for MCP rebuild, though no longer DECISIVE for spawn.**

The `McpServer.orchestrator_working_copy/1` at
`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server.ex:267-273` reads
`template_working_copy.orchestrator_template_uri` to determine if a session is
orchestrator-bearing. This is a COMPAT read during the transitional period: the
session's working copy still carries the legacy field (written by
`Materializer.materialize_orchestrator_working_copy/4`), and `McpServer` uses
it to decide whether to rebuild the MCP context. Once Definition-based membership
is the sole mechanism, `McpServer` should check for an orchestrator role member
instead. Until then: the field is read-for-compat but the DECISIVE spawn value
comes from the Definition's role recipe+flavor. The working copy write of
`orchestrator_template_uri` in `materialize_orchestrator_working_copy/4`
continues to populate the compat field alongside the role materialization.

The `orchestrator_template_uri` field on SessionTemplate
(session_template.ex:60) and on Definition (definition.ex:25) stays for
back-compat. The `DefinitionEditor.orchestrator_template_uri_for_template/2`
merge at definition_editor.ex:391-402 remains operational but the role slot's
recipe+flavor is the authoritative spawn path.

---

## 4. Transition from current state

**Problem:** Existing sessions have a live orchestrator spawned by
`ensure_orchestrator`'s hardcoded path. Those orchestrator agents were created
from `template://system/agent/cc-orchestrator` with ownership recorded in
`AgentLineage` + `WorkspaceRegistry`, and they carry scoped delegation caps
(granted at orchestrator.ex:549 via `Orchestrator.Caps`). The Definition-based
orchestrator would be a DIFFERENT agent URI (spawned through the standard
materialization path), so it would not be the same process.

**Option A (adopt-in-place):** Detect the existing `ensure_orchestrator`-spawned
agent, record it as the session's orchestrator member with role_name `"orchestrator"`
under the Definition-based membership. The agent's URI and caps stay unchanged;
it now participates in the socialware install machinery (can be re-installed/
upgraded through repoint). Tradeoff: the agent's `source_template_uri` in member
facets would point at the cc-orchestrator AgentTemplate (which is correct --
that IS its spawn source), and the Definition's role specifies recipe+flavor
(which describe what an orchestrator IS, not how THIS specific one was spawned).
The adoption is a metadata-only operation (no process restart).

**Option B (reshuffle):** Terminate the old orchestrator, spawn a fresh one through
the Definition-based path. Tradeoff: all existing sessions experience an
orchestrator restart -- the orchestrator's PTY and `claude` subprocess are killed
and re-created. Session state (chat history, rules, members) survives in the
Session Kind's snapshot, but the orchestrator's in-flight operations are lost.
The MCP context (`OrchestratorReadinessPort`) must be re-registered.

**Option C (leave running, let natural churn retire):** The `ensure_orchestrator`
compat shim returns `:already_present` for all existing sessions. New sessions
get Definition-based orchestrators. Old sessions keep their hardcoded-spawn
orchestrators until the session ends (user deletes it, or workspace cleanup).
Tradeoff: two types of orchestrators coexist indefinitely. The compat shim
can never be deleted while any old session is alive. Old sessions can't benefit
from orchestrator upgrades (repoint) because their orchestrator isn't managed
through the socialware install machinery.

**Chosen: Option A (adopt-in-place).** Rationale:
1. Zero downtime -- no orchestrator restart for existing sessions.
2. The adoption is metadata-only: record the existing agent URI as a member with
   `role_name: "orchestrator"` and register it under the Definition's install record.
3. Once adopted, the session has one install record for `orchestrator`, and the
   compat shim's "already present" check sees it as managed. The hardcoded spawn
   path is never invoked again for that session.
4. The `orchestrator_template_uri` field on the session's working copy becomes
   irrelevant -- the Definition's role recipe+flavor IS the source of truth for
   what an orchestrator is. The existing agent's `source_template_uri` facet
   pointing at `template://system/agent/cc-orchestrator` is historically accurate
   and harmless.
5. Cons: the adopted agent's `source_template_uri` facet does not match the
   Definition's recipe resolution (which would produce a different template).
   This is acceptable because the facet records HOW the agent was spawned, not
   what recipe it fulfills. If the session later repoints the orchestrator
   socialware to a new revision, the member-regenerate path
   (`update_member_template`) would replace it with an agent matching the new
   recipe.

**Migration sequence:**
1. Boot: DefinitionRegistry seeds the `orchestrator` Definition (M2-b).
   Must run BEFORE `seed_default_session_template` (application.ex:452)
   because the template's `installs: ["orchestrator"]` references it.
2. `SessionCreator.create_session/3`: new sessions install `orchestrator`
   through the standard `materialize_template_team` path (M2-c).
3. `ensure_orchestrator` compat shim: on first call for an existing session,
   acquire the `:global` per-session lock (M-3), detect the old-spawned
   orchestrator, adopt it into Definition-based membership, release the lock.
   Subsequent calls return `:already_present`.
4. When all sessions have adopted (or churned), delete `ensure_orchestrator`.

---

## 5. What the orchestrator socialware unlocks

- **G7 "mute composite" resolved:** Every session has a receive-capable member by
  default. The orchestrator role is materialized as a member with a stable
  `role_name` (prefixing "orchestrator:" per the A-2 namespace rule from
  SS6 of the reference design once M3 lands; in M2 the name stays `"orchestrator"`
  until M3's auto-prefix is available). Routing rules can target it by role_name,
  and it can receive messages -- so a session is never "mute" (no member to
  receive a direct message).

- **`orchestrator_template_uri` superseded for SPAWN, retained for compat READ**: The
  role's `recipe` + `flavor` IS the authoritative template choice for spawning.
  The field stays in structs because `McpServer.orchestrator_working_copy/1`
  (mcp_server.ex:267-273) still reads it for MCP context rebuild. Once
  `McpServer` is updated to detect orchestrator membership from role membership
  rather than the working-copy field, the field becomes entirely moot. Until
  then: read-for-compat, not decisive-for-spawn.

- **Future M3 `requires: [orchestrator]`:** Any socialware that needs team
  management declares `requires: [orchestrator]`. The orchestrator socialware
  is installed in the session first (recursively), its roles materialize, and
  its tools become available to the requiring socialware's roles. This is the
  G9 dependency mechanism from the reference design SS6 -- M3 work, but M2
  is the prerequisite (the orchestrator must EXIST as a socialware before
  anything can depend on it).

- **Orchestrator versioning through governance:** The orchestrator socialware
  can be published, pinned, and repointed through the same governance chain
  as any other socialware. A workspace admin can fork the orchestrator
  Definition, change the recipe (different skills, different flavor), and
  publish it as a custom orchestrator variant. Sessions install that variant
  instead of the stock orchestrator.

---

## 6. Out of scope

- **M3 `requires` mechanism:** The `requires: [orchestrator]` dependency
  field, install composition, merged conflict analysis, and pin/repoint
  semantics are M3.
- **Auto-prefix (A-2):** The `orchestrator:coordinator` namespace prefixing
  rule from the reference design SS6 lands in M3 with `requires`.
- **`from_role` runtime matcher (A-3):** M1 work.
- **Changing the orchestrator's flavor from `cc`:** The orchestrator stays
  flavor `cc` for all of M2. A non-cc orchestrator is future work.
- **Removing `orchestrator_template_uri` from structs:** The field stays
  for back-compat. Removal is a follow-up cleanup after the transitional
  period.
- **Per-workload orchestrator roles:** One orchestrator role per session
  is the M2 scope. Multiple orchestrator roles (e.g. a separate "kb-manager"
  orchestrator) is a later concern.
- **Agent Console refactoring:** The world plugin's layout slots are not
  restructured in M2. The "orchestrator socialware's views = Agent Console"
  claim is a conceptual mapping, not a code relocation.

---

## 7. Builder-verify notes

1. **B-1 -- `uses: ["cc"]` plugin resolution.** The orchestrator Definition
   declares `uses: ["cc"]`. Conformance assertion `uses_plugins_installed`
   (conformance.ex:136) checks `PluginRegistry.info("cc")`. Verify this
   passes with the installed cc plugin (plugin_info returns slug `"cc"` at
   application.ex:77). No new "orchestrator" plugin is created.

2. **B-2 -- Post-materialization orchestrator hooks.** The standard
   `materialize_template_team` path at template_team.ex:29 does NOT grant
   scoped delegation caps or register MCP context. The orchestrator role
   materialization must include a post-spawn callback that:
   - Grants `{:within_session, S}` + `{:spawned_by, orchestrator}` caps
     (mirroring `grant_orchestrator_scoped_caps` at orchestrator.ex:548-550).
   - Registers the MCP context (mirroring `register_orchestrator_mcp_context`
     at orchestrator.ex:578-591).
   Verify the callback name and invocation point in the materialization sequence.

3. **B-3/M-3 -- Compat shim lock + adoption.** The compat shim MUST acquire
   the same `:global` per-session lock that `create_session/3` uses at
   session_creator.ex:167 and session_creator.ex:230. Adoption writes
   (member join, install record, working copy) interleave with session-create
   writes and must be serialized. Idempotent member join alone is not enough.
   Verify lock acquisition and release at both entry points.

4. **M-1 -- `McpServer` compat read of `orchestrator_template_uri`.**
   `McpServer.orchestrator_working_copy/1` at mcp_server.ex:267-273 reads
   `template_working_copy.orchestrator_template_uri` for MCP context rebuild.
   Continue populating this compat field during the transitional period.
   Add a builder-verify TODO to migrate `McpServer` to detect orchestrator
   membership from session role members rather than the working-copy field.

5. **M-2 -- Tool catalog unification.** Two catalogs currently exist:
   domain `tool_catalog.ex:4-19` (13 atoms, gate for `ToolCatalog.tool?/1`)
   and cc MCP `mcp_server/tool_catalog.ex:8-289` (12 schemas, the LLM's
   `tools/list`). The recipe's contribution declaration must unify them
   into a SINGLE source of truth. Add CI gate: when the recipe's contribution
   set changes, both `tool_names()` and `tool_schemas()` MUST derive from it
   and fail if they drift.

6. **SessionTemplate `installs` field.** The existing install machinery
   (`Installation.resolved_template_installs/2`) resolves install names
   through `DefinitionRegistry`. The `"orchestrator"` name must be registered
   before any session creation that references it. Boot ordering is
   `seed_builtin_socialware_definitions` (line 470) before
   `seed_default_session_template` (line 452) -- verify this is maintained.

7. **Existing sessions without orchestrator.** Some sessions may have been
   created with `orchestrator_template_uri: nil` (cc-less builds). The
   compat shim's install path must handle this -- attempting to install the
   orchestrator socialware into a session that predates socialware machinery
   may fail if the session Kind lacks the socialware install slice.

8. **Cap migration.** The `ensure_orchestrator` path grants scoped delegation
   caps (`Orchestrator.Caps.grant_orchestrator_scoped_caps/3` at
   orchestrator.ex:549). The Definition-based spawn path must grant the
   same caps. Verify that the orchestrator role's recipe `requested_caps`
   (orchestrator_recipe.ex:71-76) plus the post-materialization callback
   together cover the same authority surface.

9. **Conformance assertion for orchestrator.** The `check_install_resolves`
   assertion (conformance.ex:301) verifies the orchestrator Definition is
   resolvable. The `check_agent_recipes` assertion (line 201) verifies the
   orchestrator recipe is registered. Both must pass for a green CI.

10. **`orchestrator_template_uri` in Definition and SessionTemplate.** For the
    orchestrator Definition, `orchestrator_template_uri: nil` is correct --
    the role's recipe+flavor REPLACES the direct URI pointer. Conformance's
    `check_orchestrator_uri` (line 287) already handles `nil` as `:ok`.
    The SessionTemplate field stays populated for compat reads by `McpServer`
    (see item 4 above). `DefinitionEditor.orchestrator_template_uri_for_template/2`
    at definition_editor.ex:391-402 must be audited: the role slot's
    recipe+flavor takes precedence over the legacy field when both are present.

11. **`add_participant` tool status.** `add_participant` is in the domain
    catalog but NOT in the MCP `tools/list` surface. It is callable through
    `SessionManager.invoke_tool` dispatch (session_manager.ex:398). Decide
    whether it should be an LLM-facing MCP tool or remain an internal-only
    invoke path. Document the decision in the recipe's contribution declaration.
