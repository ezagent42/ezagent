---
name: ezagent-developer
description: >-
  Use whenever working on the ezagent codebase — touching any .ex file under
  apps/, modifying ARCHITECTURE.md/GLOSSARY.md/IMPLEMENTATION_ROADMAP.md/
  docs/notes/uri-design.md, reviewing PRs, or answering questions about
  Ezagent patterns. Ezagent is a multi-agent platform with three-tier
  architecture (core / domain / plugin), strict dispatch model, capability-
  based access control (CapBAC), Behavior+Kind+URI primitives following
  SPEC v2 (6 schemes, 2-segment authority, query-string actions), and
  ~12 cross-PR architectural invariants captured in CI gates. This skill
  loads the invariants the dev team must respect, the anti-patterns to
  refuse, the how-to recipes for common contributor tasks, and pointer
  index to forensic notes. Trigger on any Ezagent contribution because
  the invariants are silent landmines.
---

# ezagent-developer

You are working in the **ezagent** repo. The architectural rules below were locked across 7 phases of brainstorm with Allen, then re-shaped in PRs #140–#149 (URI SPEC v2 migration, 2026-05-19). Allen is no longer hand-walking each PR — your job is to keep the system honest without breaking the invariants he encoded as CI gates + Decision Log entries + the normative SPEC v2 doc.

Read the relevant sections before writing code. **The most expensive bugs in this codebase are invariant violations that pass type-check + tests-pass and only surface as silent drops in production.**

## How to use this skill

For every task:

1. Read **Architecture invariants** below — what must stay true regardless of feature work.
2. Read **Three-tier project structure** — every contribution lives in one of `core / domain / plugin`. Pick the right one before writing a line of code.
3. Check **Anti-patterns the skill refuses** — if the task description matches one, push back BEFORE writing code.
4. Use **How-to recipes** for common contributor tasks (add plugin, Kind, Behavior, Template Class, routing rule, invariant test).
5. When debugging, jump to **Debug recipes** — symptom-first.
6. Cross-reference **Pointer index** for the durable record (Decision Log, forensic notes, SPEC).

For larger changes, also load `docs/phase-specs/phase7/SPEC.md` and `docs/phase-specs/phase7/VERIFICATION.md` directly — they have the V1-V5 acceptance criteria the system was built against, and `docs/notes/uri-design.md` §5 — the URI SPEC v2 normative spec.

---

## Architecture invariants (NON-NEGOTIABLE — CI gates each one)

### 1. **Dispatch is the only path** (Decision #3, #43, #127, SPEC v2 §5.8)

Every actor-to-actor message goes through `Ezagent.Invocation.dispatch/1`. **Never** `PubSub.broadcast` from one Kind to another, write directly to an external system from inside a `handle_info`, or call another Kind's GenServer.call directly.

If you think you need to, you're describing a Behavior on an existing core Kind — NOT a new top-level scheme. Per SPEC v2 §5.8, plugins do NOT own top-level schemes (`feishu://` was deleted in PR #143). Pattern: register a new Behavior on the existing User or Session Kind via `BehaviorRegistry.register/3`, store the external identifier (feishu_open_id, slack_user_id, etc.) as metadata in the entity slice or a side join table, and receive/send through the core Kind's dispatch path.

CI gate: any module that `import`s `Phoenix.PubSub` AND writes to an external API without going through dispatch fails `receiver_kind_pattern_test.exs`.

### 2. **Capabilities are module references, not atoms** (Decision #137, plus the AtomShorthand trap)

`Ezagent.Capability.behavior` field is a `module()` (e.g. `Ezagent.Behavior.Chat`), NOT an atom shorthand (`:chat`). Atom mismatch silently denies because `Capability.matches?/2` requires exact equality on `behavior`. The parser converts string "chat" → `Ezagent.Behavior.Chat` at parse time; programmatic cap construction MUST use the module reference.

If your code path can't import the module reference (circular dep), use `:any` and scope by `:kind` instead — but document this as a trade-off, NOT an idiom (see forensic note `docs/notes/phase-7-handoff.md` §"Three trade-offs not to cargo-cult").

### 3. **Channel `meta` is `Record<string, string>`** (Decision #132)

For `notifications/claude/channel` payloads (per Anthropic channels-reference spec), every meta value MUST be a string. List/map/nested-object values cause claude TUI to silently drop the entire notification — no error to either side. Structured data goes in `content` as text breadcrumbs, or via a `tools/call` round-trip. The optional `meta.file_path` string (mirroring cc-openclaw convention) is the only way to surface a single file path through meta.

CI gate: `apps/ezagent_domain_chat/test/esr/behavior/chat_test.exs` "to_claude payload meta values are all strings".

### 4. **Workspace scoping is enforced via Ezagent.WorkspaceRegistry** (Decision #135)

`Ezagent.Behavior.Chat.invoke(:send, ...)` calls `Ezagent.Routing.Resolver.resolve/4` with `workspace_uri:` opt derived from `Ezagent.WorkspaceRegistry.lookup(session_uri)`. Without this plumbing, workspace-scoped routing rules silently never fire. New plugin Template Classes that spawn sessions MUST call `Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)` after `SpawnRegistry.spawn`.

CI gate: `apps/ezagent_domain_chat/test/integration/workspace_isolation_test.exs`.

### 5. **Scope-bounded delegation cap shapes narrow, never broaden** (Decision #137)

`{:within_session, session_uri}` and `{:spawned_by, principal_uri}` on `cap.instance` are first-class shapes for orchestrator-style bounded delegation. They are MORE specific than a URI cap, not less. A cap holder with `{:within_session, A}` can only act within session A, never extending to session B. `:any` remains the only true wildcard.

CI gate: `apps/ezagent_core/test/esr/capability_test.exs` "scope-bounded instance tuples" describe block.

### 6. **User Kind structural baseline cap** (Decision #133)

Every user created via `Ezagent.Domain.Identity.Users.create/3` inherits `Ezagent.Entity.User.default_caps()` (currently `kind=:session, behavior=:any, instance=:any`). This is a STRUCTURAL invariant — without it, users can't send chat messages even from LV. The `:any` here is a circular-dep workaround (see invariant 2), NOT an idiom to copy into new plugin defaults.

CI gate: `apps/ezagent_domain_identity/test/esr/entity/user_test.exs` `describe "default_caps/0 (PR 27)"`.

### 7. **Dispatch mode is a transport choice, NOT a hard contract** (Decision #134)

`Behavior.@interface[:action] = :cast | :call | ...` declares the DEFAULT transport behavior. Callers (transports) can override (e.g. Feishu `InboundDispatcher` dispatches `Chat.send` as `:call` for error feedback). This is legitimate. Silent-drop on cap denial is the bug we avoid by using `:call` for inbound user surfaces.

When adding a new transport (Slack, Discord, email), the inbound path should use `:call` mode + decompose result + send error message back through the originating channel on `:unauthorized`.

### 8. **Plugin authoring contract** (Decision #88, Phase 6 Restructure, SPEC v2 §5.6 + §5.8)

Plugins register at `Application.start/2` via:
- `Ezagent.BehaviorRegistry.register(kind_module, action, behavior_module)`
- `Ezagent.SpawnRegistry.register(scheme, spawn_fn)` — co-registers with `Ezagent.URI.SchemeRegistry` per SPEC v2 §5.6 + PR #147. URI-only single arg per Decision #65.
- `Ezagent.TemplateRegistry.register(class_module)` (single arg; reads `template_name/0`)
- `Ezagent.RoutingRegistry.declare_table(name, opts)`

**Plugins MUST NOT introduce a new top-level scheme** (SPEC v2 §5.8). Only six schemes exist: `entity, workspace, session, template, resource, system`. A plugin contributes Kinds either by (a) extending an existing scheme's type axis via a free-form name prefix (e.g. `entity://agent/cc_<name>` — cc plugin's flavor lives in the name prefix), or (b) registering a Behavior on an existing core Kind (e.g. Feishu plugin registers `FeishuReceive` on the User Kind, NOT a `feishu://` scheme).

`Mix.env()` in `Application.start/2` returns BUILD-time env (NOT runtime) when hot-installed via `mix ezagent.plugin.install`. Use `System.get_env("MIX_ENV")` if env-dependent boot logic is needed.

### 9. **No silent drops at user-facing surfaces** (Decision #134)

When an inbound message from a human-facing transport (Feishu, future Slack/Discord/email) fails dispatch (`:unauthorized` or otherwise), the transport MUST surface the error back to the human via the original channel + a reaction emoji. Silent drop is the bug `feedback_explicit_stop_signal_after_feishu` + Decision #134 were created to prevent.

### 10. **SessionTemplate fork = config only** (Decision #141)

SessionTemplate stores agent_slots + routing_rules + orchestrator_template_uri + workspace + parent_template_uri + version_hash. It does NOT store message history. Forking copies config only; instantiated sessions start with empty chat. Three-way merge of running sessions' working-copies is explicitly out of scope.

### 11. **URI shape — 3-segment authority for per-tenant schemes + query-string action + 6-scheme allowlist** (SPEC v3 §5.15 — Phase 9 PRs #159, #167; SPEC v2 §5.1, §5.2, §5.6 — PRs #140, #145, #146)

**Updated by Phase 9 (SPEC v3).** Per-tenant URIs (entity/session/template/resource) are 3-segment authority. `workspace://` and `system://` stay 2-segment.

**Per-tenant schemes** (3-segment):

    <scheme>://<type>/<workspace>/<name>[?action=<behavior>.<action>]

| Scheme | Shape | Example |
|--------|-------|---------|
| `entity://` | `entity://<user|agent>/<workspace>/<name>` | `entity://user/default/admin`, `entity://agent/team-alpha/cc_demo` |
| `session://` | `session://<template>/<workspace>/<name>` | `session://default/default/main` |
| `template://` | `template://<type>/<workspace>/<name>` | `template://agent/default/cc-orch` |
| `resource://` | `resource://<type>/<workspace>/<name>` | `resource://uploads/default/file-abc` |

**Workspace + system schemes** (2-segment, unchanged):

| Scheme | Shape | Example |
|--------|-------|---------|
| `workspace://` | `workspace://<name>` | `workspace://default`, `workspace://system` |
| `system://` | `system://<type>/<name>` | `system://routing/default`, `system://bootstrap/default` |

**Rules**:
- `<scheme>` is one of exactly six values: `entity, workspace, session, template, resource, system`. Enforced at parse time by `Ezagent.URI.SchemeRegistry` (PR #145). Plugin-owned top-level schemes are forbidden (§5.8); plugins extend existing schemes via type segment or register Behaviors on core Kinds.
- `<workspace>` MUST match `^[a-z][a-z0-9_-]*$` (workspace creation enforces; URI parser cross-checks).
- Actions are query-string: `?action=chat.send`, `?action=routing.add_rule`, `?action=pty.write` (PR #146). The previous `/behavior/<kind>/<action>` path syntax is removed — no transitional shim.
- 2-segment forms for per-tenant schemes (`entity://user/admin`, `session://default/main`) RAISE at parse time: `ArgumentError: <scheme> URI must include workspace segment` (Phase 9 PRs #159 + #167).

Deleted schemes (do NOT reintroduce): `user://`, `agent://`, `message://`, `feishu://`, `routing-admin://`, `pty-input://`. They were merged or dissolved in PRs #141 (entity://), #143 (feishu plugin re-shape), #144 (synthetic singletons), #149 (Message.uri → Message.id).

**Helper for extracting workspace from any per-tenant URI**: `Ezagent.URI.entity_workspace_uri/1` (entity scheme) or `Ezagent.Capability.workspace_of/1` (any scheme; raises on per-tenant URI with bad shape).

CI gates: `Ezagent.URI.parse!/1` test suite + `Ezagent.URI.SchemeRegistry` ETS lockdown; new Phase 9 invariants `entities_have_workspace_test.exs` + `all_per_tenant_uris_have_workspace_test.exs` reject 2-segment forms.

### 12. **Synthetic singletons are dissolved — Behaviors live on the actual scope-owning Kind** (SPEC v2 §5.7, PR #144)

There is no longer a singleton "admin" Kind for cross-cutting actions. Instead:
- Routing rule mutation dispatches to the rule's actual scope-owning Kind: `workspace://default/X?action=routing.add_rule`, `session://<template>/Y?action=routing.add_rule`, or `system://routing/default?action=add_rule`.
- PTY input dispatches to the target agent: `entity://agent/cc_X?action=pty.write`.

When adding a new "global" action, find the Kind whose scope the action naturally belongs to and add a Behavior there. Do NOT introduce a new `*-admin://default` singleton.

### 13. **Cross-workspace dispatch requires structural authority** (SPEC v3 §5 + §13, Phase 9 PRs #162 + #169)

Phase 9's dispatch step 5.6 (in `Ezagent.Kind.Runtime.handle_dispatch/4`, inserted between CapBAC step 5.5 and target-resolution) enforces workspace isolation. A dispatch is allowed when:
1. **Intra-workspace**: caller workspace == target workspace, OR
2. **System target**: target is `:any` workspace (template/system/resource schemes are cross-cutting), OR
3. **System caller**: caller is `:system` (bootstrap operations), OR
4. **Cross-workspace cap**: caller holds a cap with `workspace_uri: :any` (`Ezagent.Capability.cross_workspace?(cap)` returns true), OR
5. **System workspace member**: caller's workspace is `workspace://system` (Keycloak realm-admin model — `Ezagent.Capability.cross_workspace?(cap, caller_uri)` arity-2)

Otherwise: returns `{:error, :cross_workspace_denied}` (distinct error atom from `:unauthorized`).

**Inbound transports MUST surface `:cross_workspace_denied` distinctly** (invariant 9). Feishu plugin uses `NO` reaction (vs `THUMBSDOWN` for `:unauthorized`); LV flash messages and CLI exit codes differ.

**`workspace://system` is the structural sink for cross-workspace authority** (SPEC §13.1): it's a real workspace with `visible: false`. Its members hold cross-workspace authority by membership, not via explicit cap grant. The bootstrap admin (`entity://user/system/admin`) is the canonical system member.

**Workspace switcher UX is permission-gated** (SPEC §6.4 amendment 3):
- System members → context swap (no logout); `:current_workspace_uri` updates while `:current_entity_uri` stays
- Regular users → denial page with "Sign in to <ws>" prompt; user explicitly chooses to logout + re-auth (no silent session loss)

CI gates: `cross_workspace_isolation_test.exs` (PR-4) + `system_workspace_membership_test.exs` (PR-8). Gate-verified by temporarily disabling step 5.6 → 2/6 invariant tests fail.

### 14. **Per-tenant DB tables MUST carry `workspace_uri` NOT NULL column** (SPEC v3 §7, Phase 9 PR #164)

Every per-tenant table has a `workspace_uri TEXT NOT NULL` column (with index). Read paths scope via `Ezagent.Persistence.scope_by_workspace/2`. Write paths derive workspace from the entity URI's workspace segment (or session URI via WorkspaceRegistry — though that registry is now a consistency cache per §5.15).

**Per-tenant tables** (6 physical tables; the SPEC §7.1 logical list of 8 collapsed because caps live in `users.caps_json` and sessions/agents/templates multiplex on `kind_snapshots`):

- `messages` — message store
- `invocations` — audit log
- `users` — User Kind base
- `kind_snapshots` — per-Kind on-change snapshots (sessions/agents/templates multiplexed)
- `entity_tokens` — agent bearer tokens
- `entity_profiles` — display name + avatar metadata

**Exempt tables** (documented in migration + invariant test): `workspaces` (workspace IS tenant root), `routing_rules` (had `workspace_uri` since PR #146), `message_routings`, `dlq`, `app_settings`, `magic_link_tokens`, `feishu_user_bindings`, `feishu_session_bindings`.

**Migration pattern for SQLite**: CREATE-NEW/INSERT-SELECT/DROP/RENAME (SQLite doesn't support ALTER COLUMN). See `phase9_pr6_workspace_uri_columns.exs` for the canonical template.

**Read-path enforcement**: `Ezagent.Persistence.scope_by_workspace/2` wraps Ecto queryables. Audit any new query against per-tenant tables for the call — grep gate enforces.

**Write-path enforcement**: Changeset `validate_required([:workspace_uri])` + grep gate against `Repo.insert(... %{workspace_uri: nil})` patterns.

**System-scope reads** (admin listing all users across workspaces): intentional bypass; documented in function moduledoc + exemption list in `per_tenant_tables_have_workspace_column_test.exs`.

CI gates: `per_tenant_tables_have_workspace_column_test.exs` + `no_nil_workspace_writes_test.exs` + `no_nil_workspace_writes_identity_test.exs`.

---

## Three-tier project structure

Every contribution lives in one of three tiers. Knowing which tier you're in tells you what dependencies you may take, what abstractions you may reach for, and what reviewers will look for.

### Tier 1 — `core` (`apps/ezagent_core/`)

**Primitives only.** No domain logic, no Kinds with business semantics. Modules here are reused by every domain + plugin. The `Ezagent.*` namespace owner.

Includes:
- URI parser + `Ezagent.URI.SchemeRegistry` (`apps/ezagent_core/lib/ezagent/uri.ex`, `apps/ezagent_core/lib/ezagent/uri/scheme_registry.ex`)
- Registries: `KindRegistry`, `BehaviorRegistry`, `SpawnRegistry`, `TemplateRegistry`, `RoutingRegistry`, `WorkspaceRegistry`
- Dispatch: `Ezagent.Invocation`, `Ezagent.Kind.Runtime`, `Ezagent.Kind`, `Ezagent.Behavior`
- Capability: `Ezagent.Capability`, `Ezagent.Capability.*`
- Persistence infra: `Ezagent.EtsOwner` (`apps/ezagent_core/lib/ezagent_core/ets_owner.ex`), `Ezagent.Audit`, `Ezagent.MessageStore`, `Ezagent.Message`, `Ezagent.ReadyGate`, `Ezagent.PendingDelivery`, `Ezagent.Snapshot.*`
- Routing infra: `Ezagent.Routing.Resolver`, `Ezagent.Routing.RuleStore`, `Ezagent.Routing.Matcher`
- Workspace primitive: `Ezagent.Workspace.*` (Kind contract + Loader; no plugin-specific behavior)

**Rules**:
- `core` may NOT depend on any `domain_*` or `plugin_*` app.
- Adds new abstractions ONLY when shared by ≥2 downstream tiers.

### Tier 2 — `domain` (`apps/ezagent_domain_*/`)

**First-class domain Kinds + Behaviors.** Load-bearing — you cannot uninstall a domain app without breaking the system. The vocabulary that ezagent is FOR.

Apps:
- `ezagent_domain_chat` — Session Kind, Agent Kind, Chat Behavior, SessionTemplate, AgentTemplate, GenericSession Template Class, orchestrator tools, FeishuOutbound Behavior (moved here in PR #143, see invariant 8)
- `ezagent_domain_identity` — User Kind, Identity Behavior, ApiKeys Behavior, Entity facade (`Ezagent.Entity.authenticate/2`), Users provisioning, Token + ApiKey tables
- `ezagent_domain_workspace` — Workspace Kind, Workspace Loader, DefaultRules
- `ezagent_domain_python` — Python sidecar runner (PyProcess wrapper around erlexec)
- `ezagent_domain_ui` — UI primitives library (`Ezagent.UI.IdeShell`, button/card/badge/status_dot/uri_chip/modal/...); shadcn-inspired; consumed by `ezagent_plugin_liveview` + `ezagent_web`

**Rules**:
- `domain_*` MAY depend on `core` and on other `domain_*` apps as needed (with care to avoid cycles — `domain_identity` cannot depend on `domain_chat`, see invariant 6).
- Adds first-class Kinds/Behaviors only.

### Tier 3 — `plugin` (`apps/ezagent_plugin_*/`)

**Optional features.** Each plugin is a separate OTP app and can be added or removed without core/domain changes. The north-star property: "future devs work on different plugins without coordination" (per Allen's `feedback_north_star_plugin_isolation`).

Apps:
- `ezagent_plugin_cc` — Claude Code agents (cc.agent Template Class, PtyServer, BridgeRegistry, MCP config writer, CC channel). The cc-flavored agents register under `entity://agent/cc_<name>` (PR #141 + #149 — AgentTypeRegistry deleted; flavor is name-prefix, kind_module wiring lives on the Template per SPEC v2 §5.14).
- `ezagent_plugin_curl_agent` — HTTP-API agents (curl-flavored, `entity://agent/curl_<name>`)
- `ezagent_plugin_echo` — test/reference stub plugin (`entity://agent/echo_<name>`)
- `ezagent_plugin_feishu` — Lark integration (FeishuReceive Behavior on User Kind per SPEC v2 §5.8; no `feishu://` scheme; outbound dispatches to `entity://user/<name>?action=chat.send` with `feishu_id` in invocation args)
- `ezagent_plugin_liveview` — admin web UI LiveViews

**Rules**:
- `plugin_*` MAY depend on `core` and any `domain_*`.
- Plugins EXTEND `core` registries (BehaviorRegistry / SpawnRegistry / TemplateRegistry / RoutingRegistry) at `Application.start/2`. They do NOT write new core or domain primitives.
- Plugins do NOT introduce new top-level URI schemes (SPEC v2 §5.8 / invariant 11).

### Boundary rules summary

| From → To | core | domain | plugin |
|---|---|---|---|
| **core** | ✓ (intra) | ✗ | ✗ |
| **domain** | ✓ | ✓ (siblings, no cycles) | ✗ |
| **plugin** | ✓ | ✓ | ✓ (siblings rare) |

When in doubt: "could two unrelated plugin authors ship in parallel without merge conflict?" If no, the abstraction is in the wrong tier or the boundary is wrong.

---

## Anti-patterns the skill refuses

If a contributor (or your own draft) attempts any of these, push back BEFORE writing code. Each refusal cites the violated Decision Log entry / SPEC v2 section + the CI gate that will fail.

### Anti-pattern: "I'll PubSub.broadcast from this plugin to that one"

Refuse. Bypasses dispatch → bypasses CapBAC → bypasses audit → bypasses idempotency. Per SPEC v2 §5.8 + invariant 1 + 8: register a Behavior on the existing core Kind (User for per-user channels, Session for per-room channels) and dispatch through it. Reference impl: `apps/ezagent_plugin_feishu/lib/ezagent/behavior/feishu_receive.ex`.

### Anti-pattern: "I'll add a new top-level scheme for my plugin's domain (slack://, discord://, etc.)"

Refuse. SPEC v2 §5.6 + §5.8: exactly six schemes ever. Extend via type segment (only sometimes — agent flavor is free-form per §5.14) or register a Behavior on an existing core Kind. The Feishu plugin's `feishu://` scheme was DELETED in PR #143 — your new plugin does not get to reintroduce the anti-pattern. CI gate: `Ezagent.URI.SchemeRegistry` ETS lockdown.

### Anti-pattern: "I'll dispatch via path-style `/behavior/X/Y`"

Refuse. SPEC v2 §5.2 + PR #146: action invocation uses query string, never path. `?action=chat.send`, `?action=routing.add_rule`, `?action=pty.write`. The old `/behavior/<kind>/<action>` syntax is removed entirely — no transitional shim. Update audit logs, route tables, doctests at the same time as code.

### Anti-pattern: "I'll add `user://X` or `agent://X` back as an alias"

Refuse. SPEC v2 §5.12 + PR #141: `user://` and `agent://` merged into `entity://`. Canonical forms: `entity://user/<name>`, `entity://agent/<flavor>_<name>`. No 1-segment fallback, no legacy URI form accepted, no `default`-injection logic. `Ezagent.URI.parse!/1` rejects un-canonical input.

### Anti-pattern: "I'll use Message.uri"

Refuse. SPEC v2 §5.13 + PR #149: `Ezagent.Message.uri` field is renamed to `id` and stores a plain UUID string (no `message://` prefix). Reply-to references store the message id directly. LV stream `dom_id` uses the message id.

### Anti-pattern: "I'll resurrect routing-admin:// or pty-input:// as a singleton"

Refuse. SPEC v2 §5.7 + PR #144: synthetic singleton Kinds dissolved. Routing rule mutation dispatches to the rule's actual scope-owning Kind (`workspace://`, `session://`, or `system://routing/default`); PTY input dispatches to the target agent (`entity://agent/cc_X?action=pty.write`). Find the Kind whose scope the action naturally owns and add a Behavior there.

### Anti-pattern: "I'll bypass the cap check with admin_caps()"

Refuse. `admin_caps()` is the bootstrap principal's structural cap, NOT a goto for "make this work right now." If your code needs to act on behalf of a system component, use a scope-bounded delegation cap (`{:within_session, _}` or `{:spawned_by, _}` per Decision #137) — narrow, named, auditable.

### Anti-pattern: "I'll write the behavior as :chat in the cap struct"

Refuse. `Capability.behavior` is a module reference; the atom `:chat` is structurally different from `Ezagent.Behavior.Chat` and `matches?/2` will return false. Use the module reference. If a circular dep prevents that, use `:any` + narrow `:kind` (invariant 2 / forensic note).

### Anti-pattern: "I'll put structured data into channel notification meta"

Refuse. Decision #132: `meta` is `Record<string, string>`. Use `content` for structured data (as text), or `tools/call` round-trip if claude needs to read a file. The only structured-ish field allowed in meta is the single optional `file_path` string.

### Anti-pattern: "Inbound transport handler uses :cast for this dispatch"

Refuse for user-facing inbound transports (Feishu, future Slack/Discord/email). Decision #134 + `feedback_explicit_stop_signal_after_feishu`: human surfaces need synchronous error feedback. Use `:call` mode + decompose result + send error back through the channel + reaction emoji on denial.

### Anti-pattern: "Let's abstract a generic 'channel' covering both text + media"

Refuse. ROADMAP §9c + brainstorm trade-off: text/file = request-response (fits dispatch); streaming media = continuous flow (doesn't fit Behavior model). Generic abstraction hides the difference and invites misuse. Separate interfaces: Ezagent is control plane (signaling, auth, session, audit), media bytes go to external SFU (Dyte / LiveKit / Volcengine).

### Anti-pattern: "Make orchestrator deterministic — write the logic in Elixir"

Refuse. Decision D7-1 (#136): orchestrator is LLM-driven for team-composition reasoning. Permission control (the supposed benefit of deterministic dispatch) is preserved by scope-bounded cap delegation (Decision #137), not by removing reasoning.

### Anti-pattern: "SessionTemplate should fork with message history"

Refuse. Decision #141 (D7-7): fork unit = configuration only. Including message history would require three-way merge mechanics that are explicitly deferred to dev-team-v1.x+.

### Anti-pattern: "Add `mix ezagent.plugin.uninstall`"

Refuse for now. Decision #142 (D7-8): plugin unload requires Kind lifecycle management for live instances of the unregistered Kind — non-trivial. Defer until dev team agrees they need it, then design carefully (not as a symmetric mirror of `install`).

### Anti-pattern: "I'll add a backward-compat shim so old URIs still parse"

Refuse. SPEC v2 §5.11 + memory `feedback_let_it_crash_no_workarounds`: no back-compat shims. Existing DB data is wiped + rebuilt on migration. No operator shorthand. No legacy URI form accepted. Every URI in CLI input, LV form input, stored data, audit log, KindRegistry, routing matchers is canonical from day 1. Fix the call sites instead of compensating in the parser.

### Anti-pattern: "I'll `DynamicSupervisor.start_child` a Kind module directly"

Refuse. V1 structural prevention (Phase 9 follow-up, Allen 2026-05-21): all Kind processes go through `Ezagent.Kind.spawn(kind_module, params)` — the SOLE programmatic entry. Each Kind declares its target supervisor via the `supervisor/0` callback; `Ezagent.Kind.spawn/2` resolves it and calls `DynamicSupervisor.start_child` exactly once (inside `Ezagent.Kind`). Direct `DynamicSupervisor.start_child` calls for Kind modules are caught by CI gate `apps/ezagent_core/test/invariants/single_spawn_entry_test.exs` + runtime invariant `apps/ezagent_core/test/invariants/kind_provenance_test.exs`. Sidecars (PtyServer etc.) are exempt but explicitly listed in `allowed_sidecar_paths/0` — adding a new sidecar requires editing both the spawn-entry test's exemption list AND the moduledoc explanation. This is V1 (Layers 2+4+5 of `docs/futures/v2-feedback-log.md`); V2 `spawn_pipeline` macro will wrap `Ezagent.Kind.spawn` as its underlying primitive.

---

## How-to recipes

### How-to: add a new plugin

1. Create OTP app under `apps/ezagent_plugin_<name>/` with standard Mix layout. (Tier 3.)
2. Add `:ezagent_core` (always) + any `:ezagent_domain_*` you depend on as `in_umbrella` deps in `mix.exs`.
3. Implement `EzagentPlugin<Name>.Application` with `start/2`:
   - Register Behaviors on EXISTING core Kinds: `Ezagent.BehaviorRegistry.register(kind_module, action, behavior_module)`. Do NOT introduce a new top-level URI scheme (SPEC v2 §5.8 / invariant 8 + 11).
   - Register spawn fns (only if your plugin contributes a new sub-type under an existing scheme — usually no): `Ezagent.SpawnRegistry.register(scheme, fn uri -> ... end)`. The SpawnRegistry co-registers with `Ezagent.URI.SchemeRegistry`.
   - Register Template Classes (if any): `Ezagent.TemplateRegistry.register(class_module)`
   - Declare routing tables: `Ezagent.RoutingRegistry.declare_table(name, opts)`
4. If the plugin spawns sessions, call `Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)` after `SpawnRegistry.spawn` to plumb workspace scope (invariant 4).
5. Test via `mix ezagent.plugin.install /path/to/plugin` against running Ezagent (invariant 8).

Pre-built examples:
- `apps/ezagent_plugin_echo/` (smallest reference plugin)
- `apps/ezagent_plugin_feishu/` (canonical "external integration" — registers `FeishuReceive` on User Kind, no owned scheme)
- `apps/ezagent_plugin_cc/` (canonical "agent flavor" — adds `cc.agent` Template Class; agents live under `entity://agent/cc_<name>`)

### How-to: add a Kind

1. Create `apps/<your_domain_or_plugin>/lib/<your>/entity/<your_kind>.ex`. New first-class Kinds usually go in `domain_*`; plugin-specific agent flavors live in their plugin app.
2. Implement `@behaviour Ezagent.Kind` with three callbacks:
   - `type_name/0 → :your_kind` (snake atom; appears in cap `kind` field)
   - `behaviors/0 → [Ezagent.Behavior.X, ...]` (what `init_slice` runs at boot; per-Kind `BehaviorRegistry.register` decides what actions dispatch)
   - `persistence/0 → :ephemeral | :on_terminate | {:snapshot, :on_change}`
3. The URI shape is fixed by SPEC v2 §5.1: `<scheme>://<type>/<name>`. If your Kind is a new entity sub-kind, that's a parser allowlist change (rare — `entity://`'s axis is the closed set `{user, agent}`). More commonly: your Kind extends an existing scheme's type axis via free-form name prefix (agent flavor) or is a Behavior on an existing Kind (plugin side-channel).
4. If your Kind carries an Identity slice for caps, document the `init_slice/1` args shape (typically `%{initial_caps: MapSet.t()}`).

Reference Kinds:
- `apps/ezagent_domain_chat/lib/ezagent/entity/agent.ex` (Agent — most complex)
- `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex` (Session — typical container)
- `apps/ezagent_domain_chat/lib/ezagent/entity/agent_template.ex` (Template Kind)

### How-to: add a Behavior

1. Create `apps/<your_domain_or_plugin>/lib/<your>/behavior/<your_behavior>.ex`.
2. `@behaviour Ezagent.Behavior`.
3. Implement `state_slice/0`, `init_slice/1`, `interface/0` (action schema), `invoke/4`.
4. Register per-Kind in the plugin's `register_<X>_behaviors()`:
   `:ok = BehaviorRegistry.register(SomeKind, :action, YourBehavior)`.
5. Actions are dispatched via `?action=<your_behavior_dot_form>.<action>` per SPEC v2 §5.2. The behavior dot-form is what `interface/0` returns (e.g. `:chat` → `?action=chat.send`).

Reference: `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex` (most complex, well-commented).

### How-to: add a Template Class

1. Module implementing `@behaviour Ezagent.Kind.Template` with callbacks:
   - `template_name/0 → "your.class.name"` (stable string id; PR-D2 collapsed cc.pty + cc.channel_instance into `cc.agent` — current canonical name for cc plugin templates)
   - `validate/1 → :ok | {:error, _}` (pre-persist schema check; optional, default `:ok`)
   - `instantiate/3` → effectful spawn of one or more Kinds; **must be idempotent** (re-call on already-spawned returns same URIs)
2. Register at plugin boot: `:ok = Ezagent.TemplateRegistry.register(YourTemplateClass)`.
3. If your Template Class spawns sessions, call `Ezagent.WorkspaceRegistry.bind/2` for each spawned session URI (invariant 4) — `Ezagent.Workspace.Loader.invoke_template` does this for the canonical session classes; custom Template Classes follow the same pattern.
4. Per SPEC v2 §5.14: the AgentTemplate carries `kind_module` (the Behavior to use for instantiated agents). `Ezagent.AgentTypeRegistry` (PR #131) has been DELETED — the Template owns kind_module wiring directly.

Reference: `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` (current cc.agent class) + `apps/ezagent_domain_chat/lib/ezagent/template/generic_session.ex` (Session class).

### How-to: add a routing rule

Two paths:

- **Programmatic (test / runtime)**: `Ezagent.Routing.RuleStore.add(table_name, matcher, receivers, granted_by, opts)` then `RuleStore.load_into_registry(table_name)`.
- **LV / CLI (admin)**: `/admin/routing` form (unified per Allen's S-9 — Scope picker for global/workspace/session), or `mix ezagent.routing.add_rule`.

Always pass `workspace_uri:` opt unless the rule is intentionally global (matches messages from any workspace). Per SPEC v2 §5.4: scope hierarchy is `global ⊂ workspace ⊂ session`. Rules compose additively at dispatch time.

### How-to: write an invariant test

Pattern (see `apps/ezagent_domain_chat/test/integration/workspace_isolation_test.exs` for the canonical example):

1. **`use EzagentCore.DataCase, async: false`** (the test exercises persistence + dispatch + sandbox semantics)
2. Spawn the production setup (`Ezagent.SpawnRegistry.spawn(uri)`, `WorkspaceRegistry.bind`, `RuleStore.add` etc.) — not mock objects
3. Drive the production code path (`Ezagent.Invocation.dispatch`) — not direct function calls
4. Assert via observable side-effects (audit log `invocations` table, `messages` table, message_routings table) — not internal slice state
5. Name the test file `<invariant>_test.exs` so it's discoverable; tag `:slow` if it spawns OS subprocesses

The invariant test is what stops a future PR from re-breaking the architectural rule. Phrase the failure message so a future debugger immediately understands what was violated. Memory `feedback_completion_requires_invariant_test`: "done" claims require a test that fails when the goal is unmet.

### How-to: install a new plugin into running Ezagent (no phx restart)

`mix ezagent.plugin.install /path/to/your_plugin_otp_app`

Caveats:
- `Mix.env()` returns BUILD-time env (use `System.get_env("MIX_ENV")` if env-sensitive)
- Plugin unload is NOT supported (Decision #142). To remove a plugin, restart phx after deleting its OTP app from the umbrella.

---

## Debug recipes (symptom-first)

### Symptom: message disappeared / silent drop

In order of likelihood:

1. **URI shape mismatch — non-canonical input.** Per SPEC v2 §5.1, 2-segment authority `<scheme>://<type>/<name>` is mandatory; old 1-segment forms like `user://admin` return parse error from `Ezagent.URI.parse!/1`. Check the URI string at the call site — it must be `entity://user/admin`, not `user://admin`. Same for `entity://agent/cc_X` (not `agent://cc/X` per SPEC v2 §5.12 + §5.14).
2. **Channel notification meta has non-string value** (Decision #132). Grep `meta = ...` in your push path; ensure every value is `String.t()`. Run `apps/ezagent_domain_chat/test/esr/behavior/chat_test.exs` "to_claude payload meta values are all strings".
3. **Cap shape mismatch on `behavior`** (invariant 2). Check via `:rpc` that `Capability.matches?/2` returns true for the user's cap + the action's needed cap. Common error: cap struct has `behavior: :chat` (atom) while needed has `behavior: Ezagent.Behavior.Chat` (module).
4. **Workspace scope not plumbed** (invariant 4). Check `WorkspaceRegistry.lookup(session_uri)` returns `{:ok, _}` for the session involved. If `:error`, the session was spawned without `bind` (custom Template Class missed step 3 of how-to add a Template Class).
5. **Inbound transport using `:cast`** (Decision #134). For Feishu/Slack/etc inbound, verify the dispatch uses `mode: :call` and decomposes the result.
6. **Action syntax wrong** — per SPEC v2 §5.2, actions use query string `?action=behavior.action`. Old path-style `/behavior/X/Y` is removed (PR #146); if anything still constructs it, dispatch silently misses.

### Symptom: `:unauthorized` despite cap granted

1. Check the user's User Kind is **alive** (in-memory state). `Ezagent.Identity.list_caps_for/1` returns `MapSet.new()` if the Kind isn't spawned. The canonical user URI is `entity://user/admin` (PR #141) — spawn via `Ezagent.SpawnRegistry.spawn("entity://user/admin")` if needed.
2. Verify cap struct shape (invariant 2 — module vs atom on `behavior`).
3. For scope-tuple caps, verify the scope dimension matches the needed action's context — e.g. `{:within_session, A}` won't match an action targeted at session B (Decision #137).
4. For `{:spawned_by, _}` caps: until PR 40 ships the lineage registry, this shape returns false (deny-by-default placeholder, Decision #137 forensic note).
5. SQL spot-check: `select * from caps where principal_uri = 'entity://user/admin' and behavior = 'Elixir.Ezagent.Behavior.Chat'` — `behavior` column stores the module's string form, not the atom shorthand.

### Symptom: orphan node sidecar after phx restart

The sidecar's `process.stdin.on('end', ...)` handler may have been refactored away. Run `apps/ezagent_plugin_feishu/test/sidecar_orphan_reap_test.exs --include slow` — the integration test spawns + kills + asserts the OS pid dies within 3s. If it fails, restore the EOF handler in `apps/ezagent_plugin_feishu/priv/ws_sidecar/main.js`.

### Symptom: workspace-scoped routing rule never fires

Check that `WorkspaceRegistry.lookup(session_uri)` returns `{:ok, workspace_uri}` for the session the message originated in. If `:error`, the session is unbound — workspace_uri opt to Resolver will be `nil` → rule with `workspace_uri: <something>` won't match (Decision #135 + SPEC v2 §5.4).

### Symptom: session-scoped routing rule never fires

New shape per SPEC v2 §5.4 + S-10: `routing_rules.session_uri` column. Check `RuleStore` evaluation iterates global + workspace_uri + session_uri layers. If a fork's session-scoped rules disappeared, check `Ezagent.Entity.Session.spawn_from_template/2` replays the template's routing_rules under the new session_uri (S-10 fix).

### Symptom: SessionTemplate fork lost lineage

Check `parent_template_uri` field on the new template. If `nil`, the fork code path didn't preserve it — `Ezagent.Entity.SessionTemplate.fork/2` MUST set `parent_template_uri = parent_uri@hash` (the specific source hash). CI gate: `template_fork_lineage_test.exs`.

### Symptom: SchemeRegistry parse error on a previously-working URI

Per SPEC v2 §5.6 + PR #147: `Ezagent.URI.SchemeRegistry` is the runtime ETS source of truth, fed by `SpawnRegistry.register/2`. If a URI parses fine in isolation but fails inside `Ezagent.URI.parse!/1`, the scheme isn't registered yet (boot-order issue) or the URI uses a deleted scheme (`user://`, `agent://`, `message://`, `feishu://`, `routing-admin://`, `pty-input://`).

---

## Project conventions

- **`uv run` not `python` / `python3`** — global hook blocks raw python invocations; always prefix with `uv run`.
- **`pnpm` not `npm`** — same project convention.
- **`agent-browser` for any UI/web debugging** — never iterate via "try it and tell me what you see"; launch headless Chrome from the agent side and screenshot. Memory `feedback_agent_browser_debug`.
- **Bilingual docs convention**: `docs/<name>.md` (English) + `docs/<name>.zh_cn.md` (Chinese) parallel files; send the `.zh_cn.md` via Feishu; sync edits both ways. Memory `feedback_bilingual_docs_convention`.
- **Decision Log new entry**: append to ARCHITECTURE.md Appendix B with next sequential number; format follows existing entries (subject line in bold + WHY + DRIFT DEFENSES). Phase 7 added #135-#144; SPEC v2 migration (PRs #140-#149) added documentation deltas to existing entries rather than new numbers.
- **Forensic notes go in `docs/notes/`** — not inline in code comments. Cross-link from Decision Log entry + (where relevant) from a moduledoc.
- **Remote browser URLs use 100.64.0.27 (Tailscale IP), not localhost** — Allen accesses remotely. Memory `feedback_remote_browser_ip`.
- **URI shape (SPEC v2)**: `<scheme>://<type>/<name>` mandatory; `?action=behavior.action` for invocation; six schemes only (`entity, workspace, session, template, resource, system`). Detail in `docs/notes/uri-design.md` §5.
- **No back-compat shims** — per SPEC v2 §5.11 + memory `feedback_let_it_crash_no_workarounds`: delete legacy paths; don't keep them alongside new ones. Existing DB data is wiped + rebuilt on URI migrations.

---

## Pointer index

The durable record. When you (or a future contributor) need authoritative answers:

| Source | What's there |
|---|---|
| `ARCHITECTURE.md` Decision Log Appendix B | #1-#144, full architectural history (Phase 7 ended at #144; PRs #140-#149 SPEC v2 migration documented in `docs/notes/uri-design.md` rather than new numbered entries) |
| `ARCHITECTURE.md` §17.6 | Cap delegation baseline → v1 evolution (Decision #137) |
| `ARCHITECTURE.md` §7 | CapBAC model, cap-for-action, default capability table |
| `ARCHITECTURE.md` §12.8 | CC Channel adapter design (meta schema invariant inline) |
| `GLOSSARY.md` | All Phase 7 terms + 100+ prior project terms; 易混淆词消歧 |
| `IMPLEMENTATION_ROADMAP.md` §9 | Phase 6 closeout delivery accounting |
| `IMPLEMENTATION_ROADMAP.md` §9b | Phase 7 delivery accounting (this is where v1 release is recorded) |
| `IMPLEMENTATION_ROADMAP.md` §9c | Phase 8 record-only (multimedia / streaming / Dyte) |
| `docs/notes/uri-design.md` | **URI SPEC v2 normative spec — §5 (11 subsections), §6 migration sequence (PRs #140-#147)** |
| `docs/notes/entity-agnostic-architecture-reflection.md` | 8 entity-agnostic load-bearers in §2; 10 proposals S-1..S-10 in §4; foundation for PRs #141-#149 |
| `docs/superpowers/specs/2026-05-19-phase-8-ide-shell-liveview.zh_cn.md` | Phase 8 IDE Shell spec (Activity Bar / Resource Panel / Main Window / Right Sidebar / Status Bar / CommandPalette IA) |
| `docs/phase-specs/phase7/SPEC.md` | Phase 7 design (LOCKED v3) |
| `docs/phase-specs/phase7/VERIFICATION.md` | V1-V5 acceptance criteria + e2e flows |
| `docs/phase-specs/phase7/PLAN.md` | 24-PR sequence + per-PR workflow + risk register |
| `docs/phase-specs/phase7/DECISIONS.md` | Implementation-time IMPL-7-N decisions |
| `docs/notes/phase-7-handoff.md` | Ezagent v1 release note + 3 trade-offs not to cargo-cult |
| `docs/notes/phase-6-architecture-closeout.md` | Phase 6 forensic record (meta schema fix + User default caps + InboundDispatcher mode) |
| `docs/notes/plugin-receiver-kind-contract.md` | Why Plugin X cannot PubSub.broadcast to Plugin Y (Decision #127) — note: SPEC v2 §5.8 supersedes the "Receiver Kind = own a scheme" framing; current pattern is "register a Behavior on the existing core Kind" |
| `docs/notes/phase-7-resume-state.md` | Per-PR live status table (resume any session mid-Phase-7) |
| `docs/notes/phase-8-deploy-notes.zh_cn.md` | Phase 8 branch verification + operator runbook |

---

## UI / Frontend Contract

The UI obeys a **3-layer architecture** so changing one atom propagates to every page and changing one page touches only that page. Style replacements (font / accent / dark palette) hit a small, well-known set of files. **Never write inline `style=""` in `.heex` files** outside the auth boundary pages (see below) — it bypasses the boundary and breaks theme-toggle infrastructure.

### 3-layer UI architecture

- **Layer 1 — atoms** (`apps/ezagent_domain_ui/lib/ezagent_domain_ui/`): stateless `Phoenix.Component`s. Zero LV deps. Files: `primitives.ex` (low-level: button, badge, status_dot, avatar, modal, tabs, toast, tree_list, empty_state, form_field, uri_chip, uri_picker, toolbar, tooltip, icon), `components.ex` (page_header, breadcrumb, card, stat), the shell components (see **Nested shell architecture** below). **The style-replacement boundary lives here.**
- **Layer 2 — plugin component compositions** (`apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/` incl. `admin/`): `Phoenix.Component` modules that compose Layer 1 atoms into plugin-level pieces (e.g. `member_panel.ex`, `session_editor.ex`, `app_shell.ex`). Still no LV state — just structure + slots.
- **Layer 3 — LV containers** (`apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/*_live.ex`): the LiveView modules with `mount`, `handle_event`, socket assigns. Each `render/1` wraps content in `<AppShell.app_shell>` (see below).

### Nested shell architecture (refactor 2026-05-22, SPEC `docs/superpowers/specs/2026-05-22-nested-shell-refactor.md`)

ONE outer shell owns the universal chrome; TWO inner perspectives fill its body. (Replaced the prior two-sibling-shell design — `ide_shell` + `AdminSettingsShell` — which left admin pages with no avatar/notifications/search.)

```
AppShell.app_shell        (Tier-3, ezagent_plugin_liveview) — the single thing an LV renders.
│  Wraps the Tier-2 outer chrome AND fills its :command_palette slot with the
│  stateful CommandPaletteComponent ONCE. Has a `perspective` attr + a :body slot.
│
└─ IdeShell.ide_shell_outer (Tier-2, ezagent_domain_ui/ide_shell.ex) — OUTER chrome:
   │  universal header (context affordance · search/⌘K · notifications · help · avatar)
   │  + :command_palette slot + :body slot. `perspective :: :workspace | :admin`.
   └─ :body — exactly one inner perspective:
      ├─ WorkspaceShell.workspace_shell (Tier-2, workspace_shell.ex) — Activity Bar +
      │    Resource Panel + Main Window + Right Sidebar + Status Bar.
      └─ AdminShell.admin_shell        (Tier-2, admin_shell.ex) — left settings nav + main.
```

- An LV renders `<AppShell.app_shell perspective={:workspace}>` with `<WorkspaceShell.workspace_shell>` in `:body` (workflow surfaces — /sessions, /routing, /identities, /plugins, …) OR `perspective={:admin}` with `<AdminShell.admin_shell>` (system-config surfaces — /admin/*, /workspaces).
- CmdK / `CommandPaletteComponent` is wired exactly ONCE, inside `app_shell` — never per-LV. `CommandSource` (Tier-2) is the pure ranking fn; nav routes flow DOWN from the `EzagentWeb.LiveAuth` `:cmdk_nav` on_mount assign.
- `perspective` is a typed context contract: `:workspace` → header shows the workspace dropdown; `:admin` → a system-context label (admin pages are `workspace://system` global config — you don't "switch workspace" there).

### Header / status-bar separation principle (Allen 2026-05-22)

The shell chrome splits into a **top header** (in `ide_shell_outer/1`, the outer
shell) and a **bottom status bar** (`status_bar/1`, internal to `workspace_shell`).
They have DIFFERENT semantic roles — don't put a control in the wrong one:

- **Header = workspace-scoped, view-INVARIANT.** Shows info that does NOT
  change as the user navigates between surfaces: the `ezagent / <workspace>`
  dropdown, global search (⌘K), notifications bell, help, the avatar menu.
  A control belongs in the header only if it would make sense on *every*
  page.
- **Status bar = position-scoped, view-VARIANT.** Shows info + controls
  tied to *where the user currently is*: the current entity URI, the
  current `session://` URI, agents/bridges signal lights, the Members-panel
  toggle, debug-events count. When the user switches view, the status bar
  is allowed (expected) to change.

Litmus test before placing a button: *"does this control still make sense
when the user navigates to a different page?"* — yes → header; no (it acts
on the current view/session/position) → status bar.

History: the Members-panel toggle was first (wrongly) placed in the header
next to the bell (V1 fix PR #178); moved to the status bar 2026-05-22 when
Allen surfaced this principle.

### DO list

- Wrap every shell LV `render/1` in `<AppShell.app_shell perspective={:workspace|:admin}>` with one inner perspective (`<WorkspaceShell.workspace_shell>` or `<AdminShell.admin_shell>`) in its `:body` slot. Never render a shell component directly — `app_shell` is the entry point (it wires CmdK).
- For a manual URI field, use `<.uri_picker mode={:single|:multi} options={...} />` — not a raw text input. Options come from `Ezagent.UI.UriOptions` (caller-authorized, workspace-scoped).
- Use `<.page_header title="...">...<:subtitle>...</:subtitle></.page_header>` for every page title.
- Use `<.breadcrumb items={[{"Admin", "/admin"}, {"This page", nil}]} />` for nested pages.
- Use `<.card class="...">` to wrap content blocks.
- Use `<.button variant="primary|secondary|ghost|danger">` for action buttons.
- Use `<.badge variant="success|warning|danger|info|primary">` for status pills.
- Use `<.empty_state title="..." description="...">` for "no items yet" screens.
- Use `<.icon name="..." size="xs|sm|md">` for iconography (Heroicons 24/outline).
- **Always pair `bg-*` / `text-*` / `border-*` with `dark:` variants.** Substitution table:

  | Light | Dark |
  |---|---|
  | `bg-white` | `dark:bg-zinc-900` |
  | `bg-zinc-50` | `dark:bg-zinc-950` |
  | `text-zinc-900` | `dark:text-zinc-100` |
  | `border-zinc-200` | `dark:border-zinc-800` |
  | `bg-blue-50` | `dark:bg-blue-950` (apply same -50 → -950 pattern across colors) |
  | `text-emerald-700` | `dark:text-emerald-300` (apply same -700 → -300 pattern across colors) |

- Use `font-mono` for URI / entity id / command palette display (JetBrains Mono via `--font-mono` CSS var).
- Use `text-orange-600` (signature accent) **sparingly** — only for the active Activity Bar rail or equivalent "this is selected" indicator.

### DON'T list (concrete violations from PR-A through PR-H audit)

- DON'T write `<h1 style="font-size: 22px; font-weight: 600;">` — use `<.page_header>` or `<h1 class="text-xl font-semibold text-zinc-900 dark:text-zinc-100">`.
- DON'T write `<a style="color: #0969da;">` — use `<a class="text-blue-600 dark:text-blue-400 hover:text-blue-700">`.
- DON'T write `<section style="margin-top: 24px; padding: 16px; border: 1px solid #d1d5da; border-radius: 6px;">` — use `<.card class="mt-6">`.
- DON'T add raw `bg-white` / `text-zinc-900` etc without their `dark:` sibling — dark-mode toggle silently breaks for that subtree.
- DON'T hard-code hex colors (`#1f883d`, `#cf222e`) — use Tailwind tokens (`bg-emerald-600`, `text-rose-600`).
- DON'T introduce new fonts. Geist + JetBrains Mono are the only two; both loaded via Google Fonts in `root.html.heex`.
- DON'T write inline `<style>` blocks in `.heex` files **except** in the controller-rendered auth boundary pages (login, custom 404) — they don't load `app.css` so they need self-contained `<style>` to brand themselves.
- DON'T write `<%!-- ... --%>` inside a raw HTML heredoc string (e.g. `@login_html """..."""` in `session_controller.ex`). EEx comment syntax only works inside `.heex` templates; in a raw heredoc the literal text renders verbatim into the browser. **In raw heredocs use `<!-- ... -->` (HTML comments — the browser strips them).** Lesson Allen 2026-05-20 after Phase 8c login-form edit shipped the EEx-style comment as visible page text.
- DON'T link to a route that doesn't exist. If a feature was deleted, REMOVE the link rather than leaving a dead button. Memory `feedback_ui_no_misleading_buttons`.

### Style-replacement safety checklist

When changing the visual design:

- **Swap fonts**: edit `app.css` (`--font-sans` / `--font-mono`) + `root.html.heex` (Google Fonts link) + `session_controller.ex` (login boundary inline style) + `404.html.heex` (404 boundary inline style). 4 files total.
- **Swap signature accent color**: search-replace `orange-600` / `orange-700` across `apps/ezagent_domain_ui/lib/` — should be ~3 occurrences (active Activity Bar rail).
- **Swap dark mode palette**: edit `app.css` `@plugin "../vendor/daisyui-theme" { name: "dark"; ... }` block. Components inherit via `dark:` Tailwind tokens — no per-atom edits needed.
- **Atoms vs LVs**: changing an atom (e.g. `<.card>`) propagates to every LV automatically. Changing a single LV touches only that file. The 3-layer architecture is what makes this work — don't fork atom logic into an LV "just for this page."

### Adding a new component to Layer 1

- File: pick the matching tier — `primitives.ex` (low-level atoms), `components.ex` (composite page-level atoms like header / breadcrumb / card / stat), or the shell files (`ide_shell.ex` outer chrome, `workspace_shell.ex` / `admin_shell.ex` inner perspectives — see Nested shell architecture).
- Pattern:

  ```elixir
  attr :foo, :string, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def my_component(assigns) do
    ~H"""
    <div class={["base-classes dark:base-classes-dark", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end
  ```

- Tests: add to `apps/ezagent_domain_ui/test/ezagent_domain_ui/...`.
- Reference example: `breadcrumb/1` in `components.ex` (added in PR-E, commit `bfa74ba`).

### Architecture invariants enforced by tests

- `apps/ezagent_domain_ui/test/ezagent_domain_ui/` — shell component tests (`ide_shell_outer`, `workspace_shell`, `admin_shell`) incl. Activity Bar item count + path mappings + the `perspective` header contract.
- `apps/ezagent_core/test/invariants/sessions_have_workspace_test.exs` — every session has a WorkspaceRegistry binding (Allen 2026-05-20).
- `apps/ezagent_web/test/ezagent_web/controllers/error_html_test.exs` — branded 404 renders with Activity Bar fallbacks.

---

## Current state awareness (Phase 8 / Phase 9)

- **v1 release shipped 2026-05-18** (Phase 7 closeout — Decision #144 captures the cross-PR invariant set; `docs/notes/phase-7-handoff.md` is the release note).
- **URI SPEC v2 migration shipped 2026-05-19** as PRs #140–#149:
  - #140 — SPEC v2 doc (this is the normative source)
  - #141 — `user://` + `agent://` → `entity://`; CLI tokens for any Entity; `current_user_uri` → `current_entity_uri`
  - #142 — scope hierarchy `global ⊂ workspace ⊂ session` + session-scoped rules + SessionTemplate fork replay
  - #143 — Feishu re-shape: `feishu://` scheme deleted; FeishuReceive Behavior moves to User Kind
  - #144 — synthetic singletons (`routing-admin://default`, `pty-input://default`) dissolved
  - #145 — `Ezagent.URI.SchemeRegistry` runtime ETS + `parse!/1` lockdown
  - #146 — query-string action syntax (`/behavior/X/Y` → `?action=X.Y`) everywhere
  - #147–#149 — polish, `Ezagent.AgentTypeRegistry` removal, `Message.uri` → `Message.id`, FeishuOutbound interface + lazy slice init
- **Phase 8 IDE Shell + Phase 9 tenant isolation — both shipped** (merged to main). The VS-Code-like shell + per-workspace entity URIs + tenant-aware auth are live.
- **V1 acceptance phase (2026-05-22) — shipped**: `uri_picker` component + `UriOptions` (PR-1), CmdK command palette (`CommandSource` + `CommandPaletteComponent`, PR-2/2b), member-panel redesign (PR-3), `@interface` `description:` key (PR-0). Spec: `docs/superpowers/specs/2026-05-22-v1-uri-pickers-and-cmdk.md`.
- **Nested shell refactor (2026-05-22) — shipped**: two sibling shells → one outer `ide_shell` + `workspace_shell`/`admin_shell` inner perspectives (see **Nested shell architecture** above). Spec: `docs/superpowers/specs/2026-05-22-nested-shell-refactor.md`.

---

## When this skill conflicts with what's in front of you

Code wins. If you find a discrepancy between this skill's description of an invariant and what the code actually does, **the code is authoritative**. Either:
- The invariant changed and the skill wasn't updated (open a PR updating the skill)
- The code drifted from the invariant (open a PR fixing the code; the skill describes intent)

Don't silently change either to match. Surface the discrepancy in the PR description so a reviewer (or future Claude with context) can adjudicate.
