# Phase 7 completion — the Generator + the live Orchestrator

> **Status**: DRAFT rev 3 — 2026-05-22. Author: Claude, per Allen
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
>   - **HIGH-1** — rev 2 dispatch-routed the 7 tools with the
>     orchestrator's two scope-bounded caps but never gave the
>     orchestrator any `template:*` cap; dispatch-routed
>     `update_template` / `save_template_as` / `list_templates` would
>     DENY on the happy path. rev 3 adds the **Generator-time
>     template-cap delegation contract** (§1.4) — explicit owner→
>     orchestrator template-cap grant, exact shapes, denial tests.
>   - **HIGH-2** — `Ezagent.PluginCc.Template.CcAgent` is not a
>     flavor-delegation target: `validate/1` requires
>     `{"class","agent_uri","cwd"}`, `instantiate/3` matches only
>     `%{"agent_uri"=>…}`, `build_claude_cmd/2` hardcodes one
>     `--settings` + one `--mcp-config`. rev 3 specifies the concrete
>     AgentTemplate→cc delegation contract (§1.1, §1.5).
>   - **HIGH-3** — working-copy normalization needs a durable
>     source-template field that does not exist (`Agent.spawn/4`
>     ignores `template_uri`, records only workspace + lineage).
>     rev 3 makes `source_agent_template_uri` a durable field and
>     defines it BEFORE the PR that relies on it (§1.6).
>   - **HIGH-4** — rev 2's "DB-backed SessionTemplate tables" conflict
>     with the actual Kind/`kind_snapshots` persistence model. rev 3
>     picks ONE source of truth: a SessionTemplate version IS a Kind
>     instance; persistence = snapshot; `list_templates` = catalog
>     query over `kind_snapshots` (§1.7).
>   - **MEDIUM-5** — the PR sequence asked earlier PRs to prove
>     later-PR behavior. rev 3 resequences into independently-testable
>     vertical slices (§2).

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
   are bare Kinds — no `Ezagent.Kind.Template` impl, slice schemas
   moduledoc-only, no slice-population code.
6. No `template:` cap is ever enforced.
7. ~7 V1-V5 gating tests missing.

## 1. Architectural decisions rev 3 locks

### 1.1 AgentTemplate is persistent CONFIG — it does NOT spawn

`Ezagent.Entity.AgentTemplate` is a Kind-snapshot-backed **config
record**: a pointer to a sandbox + a cap policy. It does NOT itself
launch a `claude` PTY. **Instantiation is delegated** — the Generator
(and the orchestrator's `add_agent_slot`) resolves an AgentTemplate,
reads its `flavor`, looks up the plugin Template Class via
`Ezagent.TemplateRegistry`, builds a Template-Class data map from the
AgentTemplate slice, and calls `Class.instantiate/3`. The plugin owns
the launch. The concrete `flavor → Template Class` resolution and the
AgentTemplate-slice→cc-agent-data adapter are specified in §1.5.

AgentTemplate gains a `flavor` slice field (`"cc"` etc.) so the
delegation target is explicit. Non-cc flavors are supported the day
their plugin Template Class accepts the adapter's data map.

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

### 1.4 Generator-time template-cap delegation contract (codex HIGH-1)

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
and FOURTH cap, in the SAME `Repo`-free dispatch-of-`identity.grant_cap`
loop that already grants the two scope-bounded caps. The grants:

| # | kind | behavior | instance | workspace_uri | meaning |
|---|------|----------|----------|---------------|---------|
| 3 | `:session_template` | `:any` | `{:within_workspace, ws}` (see below) | session's workspace | read + create + instantiate SessionTemplates in the orchestrator's workspace |
| 4 | `:agent_template`   | `:any` | `{:within_workspace, ws}` | session's workspace | read AgentTemplates in the orchestrator's workspace (needed by `add_agent_slot`/`list_templates`) |

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

**Delegation source.** Caps #3/#4 are `granted_by: owner_uri` — the
human owner who triggered the Generator. The owner must itself hold a
template cap covering that workspace; the Generator does **not**
fabricate authority. If the owner lacks it, `grant_scoped_caps/3`
surfaces `{:error, {:scoped_cap_grant_failed, _}}` (the existing
return path) and the Generator fails closed — no orchestrator with
half its caps.

**Tests (PR-1 for the shape, PR-5 for the e2e):**
- PR-1: `{:within_workspace, W}` matches same-workspace template URI,
  denies other-workspace template URI, denies non-template kind.
- PR-5: dispatch-routed `list_templates` with ONLY the four delegated
  caps SUCCEEDS; the same call with caps #3/#4 *omitted* returns
  `{:error, :unauthorized}` — proving no `admin_caps` fallback.
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

This makes `Agent.spawn/4`'s ignored `template_uri` arg honest: the
Generator and `add_agent_slot` pass the AgentTemplate URI; `spawn/4`
does not need to store it (the working copy does), but the Generator
records `{slot, agent_template_uri}` into the slice in the same step.

**Tests (PR-4 for init, PR-5 for maintenance):**
- Generator initializes `agent_slots` with the right
  `{slot, template://agent/...}` tuples; the slice survives a Session
  restart (snapshot reload).
- `add_agent_slot` / `update_agent_template` / `remove_agent_slot`
  each leave `agent_slots` consistent; after a restart the working
  copy round-trips.

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

**(a) "Persist a new SessionTemplate version" =** spawn a
SessionTemplate Kind at `template://session/<ws>/<name>@<hash>` and
dispatch `identity.update_slice` (or grant the slice via the spawn
`init_slice` args) to populate its `:identity` slice with the
template content map. Because SessionTemplate is `{:snapshot,
:on_change}`, the spawn + slice population writes a `kind_snapshots`
row keyed by the hash URI. Content-addressing gives idempotency for
free: the same content ⇒ the same hash ⇒ the same URI ⇒
`SpawnRegistry.spawn` returns `{:error, {:already_started, _}}` (or
the snapshot row already exists) ⇒ no duplicate, no error — treat as
success (the boot-seed idempotency convention).

**(b) "List templates" = a catalog query, not a live-registry scan.**
`list_templates` is rewritten to query persisted templates:
`Ezagent.Ecto.KindSnapshot.list_in_workspace(workspace_uri)` filtered
to `kind_type in ["session_template", "agent_template"]`, mapped to
their `uri`. This returns the durable catalog regardless of which
templates are currently spawned. (`list_in_workspace/1` already
exists and is the standard workspace-scoped read path per SPEC v3
§7.2.) Live-only templates that happen to be spawned but not yet
snapshotted are a non-issue — a `{:snapshot, :on_change}` Kind
snapshots on its first slice mutation, and template population IS a
slice mutation.

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
— dispatches `identity.grant_cap` on the target Kind; the
`Ezagent.Behavior.Identity` `invoke(:grant_cap, …)` adds the cap to
the `:identity` slice; for a `{:snapshot, :on_change}` target that
mutation snapshots). The new-template creation and the owner-cap grant
are sequenced: **create the SessionTemplate Kind first** (its snapshot
row appears), **then** `grant_cap` the owner a `template:instantiate`
cap whose `instance` is `{:within_workspace, ws}` (the workspace the
template was created in). There is no `Repo.transaction` because there
is no shared SQL transaction across two Kind snapshots — instead the
ordering is: template-Kind-first, cap-second; if the cap grant fails
the template still exists (harmless — a template nobody can yet
instantiate, fixable by re-granting) but the function returns
`{:error, _}` so the caller knows. (This is the let-it-crash-honest
trade-off: no fake atomicity over two independent snapshot writes.)

**(f) No silent divergence.** The invariant rev 3 protects: persisted
templates (`kind_snapshots`), tags (`template_tags`), caps (`:identity`
slices), and the live `KindRegistry` never disagree. Tests:
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

### PR-1 — contracts only: Template Classes, the 4 cap shapes, the adapter

Pure contract + schema. No persistence claim, no re-instantiation
claim.

- `Ezagent.Entity.AgentTemplate` and `Ezagent.Entity.SessionTemplate`
  implement `Ezagent.Kind.Template` (`template_name/0`, `validate/1`,
  `instantiate/3`) with real slice fields (phase7 SPEC schemas;
  AgentTemplate gains `flavor`; both 3-segment URIs per §1.2).
- `AgentTemplate.instantiate/3` resolves `flavor` →
  `AgentFlavorRegistry` Template Class and delegates via the
  `to_template_data/2` adapter (§1.5). It does NOT spawn workers
  itself.
- `SessionTemplate.instantiate/3` returns `{:error,
  :use_generator}` — honest: SessionTemplate instantiation IS the
  Generator (PR-4); PR-1 does not pretend otherwise. (No stub
  delegating to a non-existent function.)
- `Ezagent.Capability.instance_match?/2` gains the
  `{:within_workspace, workspace_uri}` shape (§1.4).
- `Ezagent.Entity.AgentTemplate.to_template_data/2` adapter (§1.5).
- `Ezagent.PluginCc.Template.CcAgent` extended: `validate/1` +
  `instantiate/3` accept the 4 new optional keys; `build_claude_cmd/2`
  emits operator `--settings`/`--mcp-config` with the **mandatory
  safety file LAST** and the trusted bridge config non-removable
  (§1.5 (c)).
- **Tests**: `validate/1` accept/reject for both Template Kinds; the
  3-segment URI round-trip; cross-workspace name non-collision;
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

### PR-4 — the Generator, fully (+ `template:instantiate` cap)

`Session.spawn_from_template/2` performs all 8 phase7-SPEC steps
(currently 4).

- Resolve `agent_slots` → for each slot, resolve its AgentTemplate →
  delegate spawn via the flavor Template Class (§1.1, §1.5).
- Record each slot's `{slot_name, source_agent_template_uri}` into the
  Session's `template_working_copy.agent_slots` slice (§1.6).
- Resolve `routing_rules` slot-names → per-instance agent URIs →
  install via `RuleStore.add`.
- `grant_scoped_caps/3` extended to grant the orchestrator the TWO
  template caps #3/#4 (§1.4) alongside the existing two
  scope-bounded caps.
- `template:instantiate` cap is enforced at the Generator's caller
  surface — `spawn_from_template/2` checks `owner_uri` holds a
  `template:instantiate` cap (`{:within_workspace, ws}` shape)
  covering the SessionTemplate's workspace, before instantiating.
- **Tests**: a multi-slot template instantiates all workers + routing;
  `agent_slots` slice populated with the right source-template URIs;
  the slice survives a restart; re-instantiation of the same template
  produces an identical team; a caller without `template:instantiate`
  is denied.

### PR-5 — the Orchestrator runs: the privileged MCP surface

The decisive PR. Standing on PR-1..4: the caps exist (§1.4), the
working-copy slice exists (PR-2), persistence exists (PR-3), the
Generator populates the slice (PR-4) — so PR-5's tests prove only
PR-5's behavior.

- **Dispatch-routing the 7 tools.** `Orchestrator.Tools` today calls
  `Agent.spawn/4` / `RuleStore.add/5` / `terminate_child` DIRECTLY,
  bypassing dispatch + CapBAC. Each tool is refactored to go through
  `Ezagent.Invocation.dispatch/1` so the orchestrator's four
  delegated caps (§1.4) are enforced on every tool action. The
  per-tool dispatch table is §2.1 below.
- **`update_template` / `save_template_as` now persist** — via
  `SessionTemplate.persist_version/2` (PR-3). They write a real
  `kind_snapshots` row; `update_template` produces a new hash version
  of the parent; `save_template_as` produces the first version of a
  new name and (§1.7 (e)) grants the owner a `template:instantiate`
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
  including the **HIGH-1 denial test** (`list_templates` with caps
  #3/#4 omitted → `:unauthorized`, proving no `admin_caps` fallback);
  per-tool effect tests; the agent-slot tools maintain
  `template_working_copy.agent_slots` (§1.6). The human agent-browser
  demo is supplemental release evidence, not the CI gate.

### PR-6 — the 3 session-creation entry points + closeout

- `SessionTemplate.fork/2` — `persist_version/2` a new SessionTemplate
  with `parent_template_uri` set; grant the owner a
  `template:instantiate` cap (§1.7 (e)).
- `SessionTemplate.create/2` — `persist_version/2` a new root
  template (no parent); grant the owner cap.
- Both, plus `spawn_from_template`, require the template-create /
  `template:instantiate` cap before they act.
- Any V1-V5 gating test not already landed (`bootstrap_to_serving`,
  `plugin_hot_install` if still missing).
- Correct `docs/notes/phase-7-handoff.md` (it falsely declares "v1
  release, code-complete") + the stale `phase-7-resume-state.md`.
- The supplemental human agent-browser e2e (phase7 SPEC §"e2e demo").
- **Tests**: fork lineage (`parent_template_uri` correct, parent row
  unchanged); create produces a root; cap denial on each path.

### 2.1 PR-5 per-tool dispatch table (codex explicit ask)

All 7 `Orchestrator.Tools` functions, refactored to dispatch. `ctx`
for every row = `%{caller: orchestrator_uri, caps: <the 4 delegated
caps>, reply: …}`. "Workspace derived from" describes how the target
workspace segment is obtained.

| Tool | Dispatch target URI | Behavior.action | Args (JSON schema, brief) | Required cap shape | Workspace derived from | Error mapping |
|------|---------------------|-----------------|---------------------------|--------------------|------------------------|---------------|
| `add_agent_slot` | `entity://agent/<ws>/<flavor>_<slot>?action=identity.grant_cap` is NOT it — spawn is via the flavor Template Class. Dispatch target = `template://agent/<ws>/<name>?action=template.instantiate` | `template.instantiate` (Template Class delegated) | `{slot_name: string, agent_template_uri: string(uri), prompt_override?: string}` | `{kind: :agent_template, behavior: :any, instance: {:within_workspace, ws}}` (cap #4) | `agent_template_uri`'s workspace segment; must equal the orchestrator's session workspace | `:unauthorized` → MCP error "slot template outside your workspace"; `:cross_workspace_denied` likewise; `{:error, _}` → "spawn failed: …" |
| `remove_agent_slot` | `entity://agent/<ws>/<flavor>_<slot>?action=lifecycle.terminate` (terminate Behavior on Agent Kind; replaces the direct `DynamicSupervisor.terminate_child`) | `lifecycle.terminate` | `{slot_name: string}` | `{kind: :agent, behavior: :any, instance: {:spawned_by, orch}}` (cap #2) | the orchestrator's session workspace (the slot's instance URI is built in it) | `:unauthorized` → "not your agent"; absent slot → `{:ok, :removed}` (idempotent) |
| `update_agent_template` | sequential `remove_agent_slot` then `add_agent_slot` dispatches | (as the two above) | `{slot_name: string, new_agent_template_uri: string(uri)}` | caps #2 + #4 | as the two above | first failing dispatch's mapping |
| `write_matcher` | `session://<template>/<ws>/<name>?action=routing.add_rule` (the rule's scope-owning Kind is the orchestrator's Session — invariant 12, no `routing-admin://` singleton) | `routing.add_rule` | `{matcher_ast: object, receiver_slot_names: [string]}` | `{kind: :session, behavior: :any, instance: {:within_session, S}}` (cap #1) | the orchestrator's session URI workspace segment | `:unauthorized` → "cannot write rules outside your session"; matcher parse error → "invalid matcher" |
| `update_template` | `template://session/<ws>/<parent_name>@<new_hash>?action=identity.update_slice` (spawn-then-populate via `persist_version/2`; the dispatched action populates the new Kind's slice) | `identity.update_slice` (slice population on the new SessionTemplate Kind) | `{}` (no args — session context supplies everything) | `{kind: :session_template, behavior: :any, instance: {:within_workspace, ws}}` (cap #3) | the orchestrator's session workspace (parent template lives there) | `:parent_template_deleted` → "parent gone, use save_template_as"; `:unauthorized` → "no template-write authority here" |
| `save_template_as` | `template://session/<ws>/<new_name>@<hash>?action=identity.update_slice` (new family; same persist path) | `identity.update_slice` | `{new_name: string}` | `{kind: :session_template, behavior: :any, instance: {:within_workspace, ws}}` (cap #3) | the orchestrator's session workspace | `:unauthorized` → "no template-create authority here"; duplicate hash → success (idempotent) |
| `list_templates` | `Ezagent.Ecto.KindSnapshot.list_in_workspace(ws)` is a read — but to keep CapBAC honest it is wrapped as a dispatch to `system://routing/default` is wrong; instead it is a **cap-gated read**: the MCP server checks the orchestrator holds cap #3 OR #4 for `ws` before calling `list_in_workspace/1`, then filters results to that workspace | (cap-gated read, no Behavior — the catalog is a query, §1.7 (b)) | `{name_filter?: string}` | cap #3 OR cap #4 (read intent) for the orchestrator's workspace | the orchestrator's session workspace | missing both caps → `:unauthorized` "no template-read authority" |

Note on `list_templates`: it is the one tool that is a pure read of
`kind_snapshots` (§1.7 (b)), not an actor-to-actor message — so it is
not a dispatch. The MCP server still enforces CapBAC explicitly
(checks cap #3/#4 before the query) so the "no `admin_caps`,
caps-enforced-everywhere" property holds. This is documented as a
deliberate trade-off, not an idiom: reads of the snapshot catalog are
not dispatches, but they are still cap-gated at the MCP-server
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
with the running orchestrator), V2.4 (PR-4), V2.6 (PR-2 working-copy
restart + PR-4 Generator restart), V5.1's 7 tests distributed
PR-1..6. The Generator instantiates workers+routing (PR-4); a
`template:instantiate`-less caller is denied (PR-4); the
orchestrator's dispatch-routed tools enforce the four delegated caps
with no `admin_caps` fallback (PR-5); `phase-7-handoff.md` no longer
claims a false "code-complete" (PR-6).
