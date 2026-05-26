# Architecture invariants (NON-NEGOTIABLE — CI gates each one)

The Design Principles (references/design-principles.md) capture *what / why*; the numbered invariants below are the *operational specifics + CI gate names*. Pre-existing numbering preserved — each maps back to a principle.

## Table of contents

1. Dispatch is the only path
2. Capabilities are module references, not atoms
3. Channel `meta` is `Record<string, string>`
4. Workspace scoping enforced via `Ezagent.WorkspaceRegistry`
5. Scope-bounded delegation cap shapes narrow, never broaden
6. User Kind structural baseline cap
7. Dispatch mode is a transport choice, NOT a hard contract
8. Plugin authoring contract
9. No silent drops at user-facing surfaces
10. SessionTemplate fork = config only
11. URI shape — 3-segment authority for per-tenant schemes + query-string action + 6-scheme allowlist
12. Synthetic singletons dissolved
13. Cross-workspace dispatch requires structural authority
14. Per-tenant DB tables MUST carry `workspace_uri NOT NULL`
15. ExternalMirror Domain: outbound mirrors go through the 3-layer model
16. No `Phoenix.PubSub.subscribe` in ExternalMirror Domain or any Binding module
17. No re-entry to Ezagent dispatch from `target_ownership_check/2` or `event_to_payload/1`

---

## 1. **Dispatch is the only path** (Decision #3, #43, #127, SPEC v2 §5.8)

Every actor-to-actor message goes through `Ezagent.Invocation.dispatch/1`. **Never** `PubSub.broadcast` from one Kind to another, write directly to an external system from inside a `handle_info`, or call another Kind's GenServer.call directly.

If you think you need to, you're describing a Behavior on an existing core Kind — NOT a new top-level scheme. Per SPEC v2 §5.8, plugins do NOT own top-level schemes (`feishu://` was deleted in PR #143). Pattern: register a new Behavior on the existing User or Session Kind via `BehaviorRegistry.register/3`, store the external identifier (feishu_open_id, slack_user_id, etc.) as metadata in the entity slice or a side join table, and receive/send through the core Kind's dispatch path.

CI gate: any module that `import`s `Phoenix.PubSub` AND writes to an external API without going through dispatch fails `receiver_kind_pattern_test.exs`.

## 2. **Capabilities are module references, not atoms** (Decision #137, plus the AtomShorthand trap)

`Ezagent.Capability.behavior` field is a `module()` (e.g. `Ezagent.Behavior.Chat`), NOT an atom shorthand (`:chat`). Atom mismatch silently denies because `Capability.matches?/2` requires exact equality on `behavior`. The parser converts string "chat" → `Ezagent.Behavior.Chat` at parse time; programmatic cap construction MUST use the module reference.

If your code path can't import the module reference (circular dep), use `:any` and scope by `:kind` instead — but document this as a trade-off, NOT an idiom (see forensic note `docs/notes/phase-7-handoff.md` §"Three trade-offs not to cargo-cult").

## 3. **Channel `meta` is `Record<string, string>`** (Decision #132)

For `notifications/claude/channel` payloads (per Anthropic channels-reference spec), every meta value MUST be a string. List/map/nested-object values cause claude TUI to silently drop the entire notification — no error to either side. Structured data goes in `content` as text breadcrumbs, or via a `tools/call` round-trip. The optional `meta.file_path` string (mirroring cc-openclaw convention) is the only way to surface a single file path through meta.

CI gate: `apps/ezagent_domain_chat/test/esr/behavior/chat_test.exs` "to_claude payload meta values are all strings".

## 4. **Workspace scoping is enforced via Ezagent.WorkspaceRegistry** (Decision #135)

`Ezagent.Behavior.Chat.invoke(:send, ...)` calls `Ezagent.Routing.Resolver.resolve/4` with `workspace_uri:` opt derived from `Ezagent.WorkspaceRegistry.lookup(session_uri)`. Without this plumbing, workspace-scoped routing rules silently never fire. New plugin Template Classes that spawn sessions MUST call `Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)` after `SpawnRegistry.spawn`.

CI gate: `apps/ezagent_domain_chat/test/integration/workspace_isolation_test.exs`.

## 5. **Scope-bounded delegation cap shapes narrow, never broaden** (Decision #137)

`{:within_session, session_uri}` and `{:spawned_by, principal_uri}` on `cap.instance` are first-class shapes for orchestrator-style bounded delegation. They are MORE specific than a URI cap, not less. A cap holder with `{:within_session, A}` can only act within session A, never extending to session B. `:any` remains the only true wildcard.

CI gate: `apps/ezagent_core/test/esr/capability_test.exs` "scope-bounded instance tuples" describe block.

## 6. **User Kind structural baseline cap** (Decision #133)

Every user created via `Ezagent.Domain.Identity.Users.create/3` inherits `Ezagent.Entity.User.default_caps()` (currently `kind=:session, behavior=:any, instance=:any`). This is a STRUCTURAL invariant — without it, users can't send chat messages even from LV. The `:any` here is a circular-dep workaround (see invariant 2), NOT an idiom to copy into new plugin defaults.

CI gate: `apps/ezagent_domain_identity/test/esr/entity/user_test.exs` `describe "default_caps/0 (PR 27)"`.

## 7. **Dispatch mode is a transport choice, NOT a hard contract** (Decision #134)

`Behavior.@interface[:action] = :cast | :call | ...` declares the DEFAULT transport behavior. Callers (transports) can override (e.g. Feishu `InboundDispatcher` dispatches `Chat.send` as `:call` for error feedback). This is legitimate. Silent-drop on cap denial is the bug we avoid by using `:call` for inbound user surfaces.

When adding a new transport (Slack, Discord, email), the inbound path should use `:call` mode + decompose result + send error message back through the originating channel on `:unauthorized`.

## 8. **Plugin authoring contract** (Decision #88, Phase 6 Restructure, SPEC v2 §5.6 + §5.8)

Plugins register at `Application.start/2` via:
- `Ezagent.BehaviorRegistry.register(kind_module, action, behavior_module)`
- `Ezagent.SpawnRegistry.register(scheme, spawn_fn)` — co-registers with `Ezagent.URI.SchemeRegistry` per SPEC v2 §5.6 + PR #147. URI-only single arg per Decision #65.
- `Ezagent.TemplateRegistry.register(class_module)` (single arg; reads `template_name/0`)
- `Ezagent.RoutingRegistry.declare_table(name, opts)`

**Plugins MUST NOT introduce a new top-level scheme** (SPEC v2 §5.8). Only six schemes exist: `entity, workspace, session, template, resource, system`. A plugin contributes Kinds either by (a) extending an existing scheme's type axis via a free-form name prefix (e.g. `entity://agent/cc_<name>` — cc plugin's flavor lives in the name prefix), or (b) registering a Behavior on an existing core Kind (e.g. Feishu plugin registers `FeishuReceive` on the User Kind, NOT a `feishu://` scheme).

`Mix.env()` in `Application.start/2` returns BUILD-time env (NOT runtime) when hot-installed via `mix ezagent.plugin.install`. Use `System.get_env("MIX_ENV")` if env-dependent boot logic is needed.

## 9. **No silent drops at user-facing surfaces** (Decision #134)

When an inbound message from a human-facing transport (Feishu, future Slack/Discord/email) fails dispatch (`:unauthorized` or otherwise), the transport MUST surface the error back to the human via the original channel + a reaction emoji. Silent drop is the bug `feedback_explicit_stop_signal_after_feishu` + Decision #134 were created to prevent.

## 10. **SessionTemplate fork = config only** (Decision #141)

SessionTemplate stores agent_slots + routing_rules + orchestrator_template_uri + workspace + parent_template_uri + version_hash. It does NOT store message history. Forking copies config only; instantiated sessions start with empty chat. Three-way merge of running sessions' working-copies is explicitly out of scope.

## 11. **URI shape — 3-segment authority for per-tenant schemes + query-string action + 6-scheme allowlist** (SPEC v3 §5.15 — Phase 9 PRs #159, #167; SPEC v2 §5.1, §5.2, §5.6 — PRs #140, #145, #146)

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

## 12. **Synthetic singletons are dissolved — Behaviors live on the actual scope-owning Kind** (SPEC v2 §5.7, PR #144)

There is no longer a singleton "admin" Kind for cross-cutting actions. Instead:
- Routing rule mutation dispatches to the rule's actual scope-owning Kind: `workspace://default/X?action=routing.add_rule`, `session://<template>/Y?action=routing.add_rule`, or `system://routing/default?action=add_rule`.
- PTY input dispatches to the target agent: `entity://agent/cc_X?action=pty.write`.

When adding a new "global" action, find the Kind whose scope the action naturally belongs to and add a Behavior there. Do NOT introduce a new `*-admin://default` singleton.

## 13. **Cross-workspace dispatch requires structural authority** (SPEC v3 §5 + §13, Phase 9 PRs #162 + #169)

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

## 14. **Per-tenant DB tables MUST carry `workspace_uri` NOT NULL column** (SPEC v3 §7, Phase 9 PR #164)

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

## 15. **ExternalMirror Domain: outbound mirrors go through the 3-layer model** (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`, Decision #122)

Any "Session slice → external system" path (Feishu chat / Slack / game room / …) MUST use the ExternalMirror Domain — never a plugin-owned one-off. The plugin author ships **two modules + one declaration**: an Adapter (`@behaviour Ezagent.ExternalMirror.Adapter`, stateless), a Binding (`@behaviour Ezagent.ExternalMirror.Binding`, stateful per-target GenServer), and `adapters/0` returning `[{Adapter, Binding}]` in the plugin module. The Grill-5 compile-time check enforces 1:1 adapter↔binding pairing; runtime registry verification (`AdapterRegistry.register/1` + `BindingRegistry.register_module/2`) backstops against hot-install bypasses.

Per-binding crash isolation, FacadeNonceTable forgery-proof handoff between facade and `:bind` action body, two-tier supervision (`RootSupervisor` 100/60s budget → `PerBindingSupervisor` 3/30s budget → `Kind.Server`), eager spawn + restart adoption via deterministic Worker URI, and rehydration on Session restart — ALL provided by the Domain.

CI gates: `apps/ezagent_domain_external_mirror/test/invariants/` (8 invariants — see SPEC §10).

## 16. **No Phoenix.PubSub.subscribe in ExternalMirror Domain or any Binding module** (SPEC §10 (f), PR-EM-FINAL invariant 4)

Bindings receive slice changes via `Ezagent.Behavior.Publisher.subscribe_from/3` ONLY. Direct `Phoenix.PubSub.subscribe` from a Binding module (or anywhere under `apps/ezagent_domain_external_mirror/`) bypasses the per-binding crash boundary AND the Worker `:publish` CapBAC gate — the P11 escape PR-EM was designed to close.

CI gates: `apps/ezagent_domain_external_mirror/test/invariants/no_pubsub_bypass_in_external_mirror_test.exs` (grep gate on Domain lib + every loaded module declaring `@behaviour Ezagent.ExternalMirror.Binding`).

## 17. **No re-entry to Ezagent dispatch from `target_ownership_check/2` or `event_to_payload/1`** (SPEC §10 (g), PR-EM-FINAL invariant from r4 round-3 MEDIUM)

Adapter modules are stateless pure-function modules per SPEC §2.2. The ONE allowed I/O callback is `target_ownership_check/2` — and even that callback MUST NOT call `Ezagent.Invocation.dispatch/1`, `Ezagent.Kind.spawn/2`, or `Behavior.invoke/4` directly: re-entering ezagent from inside a Task spawned by the facade's bind action creates a dispatch-during-dispatch deadlock (`:bind` is itself a dispatched action). External API calls (Lark / Slack / game protocol) ARE allowed from `target_ownership_check`; ezagent re-entry IS NOT.

CI gates: `apps/ezagent_domain_external_mirror/test/invariants/no_dispatch_in_target_ownership_check_test.exs` (grep gate on every loaded module declaring `@behaviour Ezagent.ExternalMirror.Adapter`).

## 18. **Sibling slice reads are opt-in via `reads_sibling_slices/0`** (Decision #124, PR #389)

A Behavior on Kind K can read OTHER Behaviors' slices on the same Kind instance **only** if it declares the keys it wants:

```elixir
@impl Ezagent.Behavior
def reads_sibling_slices, do: [:api_keys]
```

`Ezagent.Kind.Runtime.handle_dispatch/4` then injects `ctx[:sibling_slices]` containing **only the declared keys** — not the whole state map. The default (callback not exported) is `[]` — no sibling reads.

**Why**: closes the slice isolation gap that the ApiKeys flip surfaced. Pre-fix, CurlAgent dispatched `identity.get_api_key` back to `ctx.self_uri` to read its own ApiKeys (foreign to CurlAgent's slice); after the flip, both slices live on the same Kind instance and the dispatch becomes `GenServer.call(self)` — `:calling_self` exit. The structural fix is in-process sibling read, but with explicit declaration so cross-slice reads are visible at code review (not a generic `:all_slices` escape hatch — that was the original codex CRIT finding).

**Rule of thumb**: if your Behavior's `invoke/4` reads a slice it doesn't own, declare it. If you find yourself wanting all slices, you probably want to refactor the slice boundaries instead.

## 19. **Capability inputs flow through `Ezagent.Capability.normalize!/2`** (Decision #125, PR #400)

Any cap that lands in a slice MUST be a `%Ezagent.Capability{}` struct with atom keys. Bare maps (JSON-parsed with string keys) cause `BadMap` / `Protocol.UndefinedError` downstream in `Capability.matches?/2`. The normalizer is the single chokepoint that converts struct / atom-keyed / string-keyed inputs into the canonical struct.

`Ezagent.Behavior.Identity.invoke(:grant_cap, ...)` calls `normalize!/2`. New non-LV cap-granting paths MUST also pipe through `normalize!/2` before writing to `slice.caps`. Direct `MapSet.put(slice.caps, raw_map)` is the anti-pattern.

Revoke matching uses `Capability.identity_key/1` (4-tuple `{kind, behavior, instance, workspace_uri}` ignoring `granted_by`/`granted_at` provenance) — `Capability.revoke/2` is the canonical revoke. Symmetric to grant: bypassing it (manual `MapSet.delete`) is the anti-pattern that causes the "revoke silently no-ops because `granted_at` differs" bug class.

CI gates: `apps/ezagent_domain_identity/test/ezagent/behavior/identity_grant_cap_shape_test.exs` (verifies all three input shapes produce the same in-slice representation + downstream `matches?` agreement).

## 20. **Behaviors with DB projections implement `reconcile_after_load/2`** (Decision #129 / task #34, PR #403)

`Ezagent.Kind.Snapshot.load_or_init/3` merges snapshot state OVER `init_slice/1` fresh state — so any Behavior whose slice is backed by a DB projection table (e.g. `Ezagent.Behavior.ExternalMirror.bindings` ← `external_mirror_bindings`) loses DB rows inserted between the last snapshot and the next Kind restart.

The fix: implement the optional `Ezagent.Behavior.reconcile_after_load/2` callback. Snapshot calls it after `Map.merge(fresh, loaded)`; the Behavior re-reads its DB projection and unions/dedupes into the merged slice.

**Required for**: any Behavior where a DB row outside the dispatch path can legitimately exist (SQL fix-ups, race recovery, plugin authors bypassing the canonical bind/insert API). **NOT required for**: Behaviors whose slice is purely in-memory or fully owned by the dispatch path (the default identity is correct for them).

**Idempotence required**: union-by-natural-key, not list-append. Calling reconcile twice must equal once.

CI gates: `apps/ezagent_domain_external_mirror/test/ezagent/behavior/external_mirror_reconcile_test.exs` (4 tests covering empty-slice + idempotence + union + non-URI safety).
