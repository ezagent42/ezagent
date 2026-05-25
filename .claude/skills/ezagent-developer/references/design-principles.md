# Design Principles (authoritative — other docs reference this)

**This file is the single canonical principles set for the ezagent codebase.** It consolidates what was previously scattered across `CLAUDE.md` "8 条硬不变式", `ARCHITECTURE.md` §2 "实现原则" + §5.6 "三条 dispatch 不变式", `docs/notes/uri-design.md` §5 (URI normative spec), and a set of cross-cutting principles surfaced through ongoing project work (plugin-isolation north star, let-it-crash, single source of truth, converge-to-URI-list, shared-referent-needs-identity, completion-claim-requires-invariant-test, production-usability, UUID-canonical).

When this file and one of the deep docs (ARCHITECTURE / uri-design / Decision Log) disagree on a rule, **this file wins** — the deep docs keep the "why" and the implementation detail; the rules live here. Each principle cites its CI gate (if any) so violations have a concrete failure mode. The grouping (Engineering / Architecture & boundaries / Dispatch & runtime / Persistence & URIs / Plugin contract) is for skim-ability, not a strict layering.

## Table of contents

- **Group A — Engineering principles (P1-P7)**
- **Group B — Architecture & boundaries (P8-P13)**
- **Group C — Dispatch & runtime (P14-P19)**
- **Group D — Persistence & URIs (P20-P22)**
- **Group E — Plugin contract (P23-P27)**
- Where each old principle now lives
- Contradiction resolution log

---

## Group A — Engineering principles (the meta-rules that produce the rest)

### **P1. Plugin-isolation north star.**

Future devs add a new agent flavour / external integration / UI feature by writing one plugin OTP app, without touching `ezagent_core`, `ezagent_domain_*`, `ezagent_web`, or other plugins. Tiebreaker for any design decision: **"keeps plugin authors out of core."**
*Why*: the system survives Allen's departure only if a plugin author needs zero core knowledge. Every other principle below is downstream of this one.
*See also*: `docs/onboarding/adding-a-plugin.md` §"Plugin isolation north star"; ARCHITECTURE Decision Log #88, #107, #111, #119.

### **P2. Let-it-crash; no workarounds, no defaults, no whitelists.**

Prefer a direct structural fix over a shim, a default value, an isolation whitelist, or a `:warning` + degrade path. When a URI shape, cap shape, or invariant changes, fix all call sites — do not absorb the change in the parser / matcher / Behavior with back-compat logic.
*Why*: shims compound. Each back-compat path becomes a permanent silent-divergence surface. Existing DB data is wiped + rebuilt on migrations (uri-design §5.11).
*Case study*: `docs/notes/2026-05-23-generator-reconciler-retrospective.md` — 10 rounds of saga-cleanup hardening that never converged (HIGH count stuck at 1-2 per round). The saga model was, structurally, a workaround — defaulting `cleanup_partial` against N enumerated stores. The structural fix was deleting the whole saga surface (reconciler + per-step idempotency); the result was ~800 LOC removed. **The cleanest available demonstration of "structural fix > accumulated defaults."**
*See also*: uri-design §5.11; memory `feedback_let_it_crash_no_workarounds`.

### **P3. Single source of truth for any datum.**

For any fact (which Behavior runs an agent / which workspace owns a session / what schemes parse / what plugins are installed / etc.), exactly one home. Other surfaces are caches, projections, or references — never independent records.
*Why*: divergent SoTs silently drift; the bug surfaces months later in an audit. Examples: `Ezagent.URI.SchemeRegistry` ETS is THE scheme allowlist (uri-design §5.6, P19); MessageStore is THE chat history (Decision #89); the AgentTemplate's `kind_module` is THE source for "which Behavior runs this agent" (uri-design §5.14, P18); `WorkspaceRegistry` is now a *cache* of the workspace segment that already lives in the URI structurally (uri-design §5.15, P17).
*Case study*: `docs/notes/2026-05-23-generator-reconciler-retrospective.md` — the Generator's old `cleanup_partial/1` saga threaded an accumulator ("what I just did") as a second SoT alongside the actual store state. Divergence between accumulator and store was the bug class codex kept finding (rounds 1-10). The reconciler dissolves the accumulator: SessionTemplate IS the desired-state SoT; live state IS the actual-state SoT; the reconciler is the function `converge(spec, current)`. Nothing to drift.
*See also*: ARCHITECTURE Decision Log #89; uri-design §5.6, §5.14, §5.15.

### **P4. Production-usability is the selection criterion.**

When choosing between options, pick the one that makes the production deployment more usable / debuggable / safe — not the one that looks cleanest on paper. Forcing configuration to work (vs silently defaulting) is a feature.
*Why*: the cleanest design is irrelevant if operators can't run it. Example: agent reply must carry `session_uris` — without it, a floating agent silently can't deliver; the "extra typing" is a production safety property.
*See also*: memory `feedback_production_usability_is_selection_criterion`; `docs/phase-specs/phase3/DECISIONS.md` (D8 reply contract).

### **P5. UUID-canonical identifier; username / handle / display-name is mutable display-only.**

Any cap-key / route-key / DB-FK references the immutable canonical identifier (UUID, URI, structural id). Mismatches between a display name and an identity get resolved by adding a display→canonical lookup step, NEVER by migrating downstream tables to key on the display string.
*Why*: display names change; cap grants do not. Keying on display names builds in a migration the day a user renames themselves.
*See also*: memory `feedback_uuid_is_canonical_identifier`.

### **P6. Completion claim requires an invariant test.**

Never claim "done" / "fixed" / "shipped" on type-check + tests-pass + PR-merge alone. Define a test that **fails** when the architectural goal is unmet; THAT test is the gate. Phase / multi-PR closeouts are gated by their invariant test, not by their feature list.
*Why*: "tests pass" answers the wrong question for invariant rules — they pass because nobody wrote the test that would have failed. Without a failing-when-violated test, the next PR silently re-breaks the rule.
*See also*: memory `feedback_completion_requires_invariant_test`; `docs/onboarding/first-30-days.md` §"invariant tests"; recipes/how-to-recipes.md §"write an invariant test".

### **P7. Converge multi-modal inputs to a unified data shape.**

When several UI surfaces / operation paths seem to need different downstream logic, FIRST check whether they converge to a unified shape (typically `[URI.t()]` or a single `%Invocation{}`). If yes, the inputs are just constructors populating the same list; downstream stays one code path.
*Why*: surface-specific downstream logic multiplies test surface + drift risk. Example: routing rule mutation from LV admin / CLI / programmatic all produces `%Invocation{}` to the scope-owning Kind (P10).
*See also*: memory `feedback_converge_to_uri_list`.

## Group B — Architecture & boundaries

### **P8. Less invented, more assembled (`少发明,多装配`).**

Total ezagent-authored code stays small (~920 LOC core target); everything else is Phoenix + OTP + ecosystem. New abstractions get added only when ≥2 downstream tiers need them. Decision rule: *"do new joiners have to learn one more concept, or one fewer?"* — one more = reject, one fewer = accept.
*Why*: every invented abstraction is a permanent training cost. Phoenix / OTP idioms are free (every Elixir dev knows them); custom ones aren't.
*See also*: ARCHITECTURE.md §2.1 (was the deep source — now references back here); §14 LOC budget.

### **P9. "Reads what data" decides tier ownership.**

What belongs in `core` / `domain` / `plugin` is decided by **what data the code reads**, not by "is this infra or business":
- Reads `%Invocation{}` / `%Message{}` / KindRegistry / RoutingRegistry → `core`
- Reads plugin-specific payload (Feishu card type, Slack thread_ts) → `plugin`
- Generic invariants (delivery / idempotency / readiness) → `core`
- External-protocol binding → `plugin`

*Why*: a Matcher reading `%Message{}.mentions` belongs in core because every Message-routing plugin needs it; putting it in `esr_behavior_chat` forces every future Behavior plugin to depend on chat. Hard test: *plugin authors should never face "do I need to install the PendingDelivery plugin?"*
*See also*: ARCHITECTURE.md §2.2 (was the deep source — now references back here); references/three-tier-structure.md.

### **P10. Shared referent needs identity (don't expand to tuples).**

Any concept referenced by ≥2 unrelated callers (cap subject, session bindings, user.default, plugin runtime config, …) MUST have a stable addressable URI — never expanded into a tuple/field-set distributed across the callers. Editing one site would otherwise fan-out into silent divergence.
*Why*: Workspace is the canonical example — it's pointed to by 5+ caller types, so it must be a Resource Kind, not "folder URIs + agent_def + settings" inlined everywhere. Same logic applies to any future "scope-owning Kind."
*See also*: ARCHITECTURE.md §3.1.1 (Resource shared-referent rule); SPEC v2 §5.7 (synthetic singletons dissolved → real scope-owning Kinds, P11).

### **P11. Plugin external integration = Receiver Kind / Behavior on an existing scheme, never a plugin-owned top-level scheme.**

A plugin connecting ezagent to an external system (Feishu, Slack, Discord, email, etc.) MUST NOT own a top-level URI scheme. Pattern: register a Behavior on the existing core Kind (User for per-user channels, Session for per-room channels), store the external identifier (feishu_open_id, slack_user_id) as metadata in the entity slice or a side join table, receive/send through the core Kind's dispatch path.
*Why*: `feishu://` was deleted in PR #143 because plugin-owned schemes break P1 (plugin authors carving private worlds) and P3 (URI is no longer a unified SoT). Synthetic singletons (`routing-admin://`, `pty-input://`) dissolved in PR #144 for the same reason — routing rule mutation dispatches to the rule's actual scope-owning Kind (`workspace://`, `session://`, or `system://routing/default`); PTY input dispatches to the target agent.
*CI gate*: `receiver_kind_pattern_test.exs` (no `Phoenix.PubSub` import + external API write outside dispatch); `Ezagent.URI.SchemeRegistry` ETS lockdown (6-scheme allowlist).
*See also*: uri-design §5.7 + §5.8; invariant 1, 12 in references/architecture-invariants.md; `docs/notes/plugin-receiver-kind-contract.md`.

### **P12. Adapter pattern: protocol-specific code in adapters only.**

External entry points (Feishu / Slack / CLI / MCP / HTTP / internal) are Adapters. An Adapter does exactly two things: (1) parse external input into `%Invocation{}`, (2) render result back to the external protocol via `ctx.reply`. **No business semantics inside an adapter.** Hard test: *"can this be reproduced via `Invocation.dispatch/1` in ExUnit?"* — if no, the adapter has business logic and must be split.
*Why*: keeps the dispatch path the single semantic spine; adapters become swap-able and the system is testable without spinning up a transport.
*See also*: ARCHITECTURE.md §2.4 + §12 (was the deep source — now references back here).

### **P13. Phoenix is transport, not fullstack.**

Phoenix.Endpoint / Channel / PubSub / Presence / Plug / Router / LiveView — yes. Phoenix.Controller / Phoenix.View / Phoenix.HTML form helpers — no. HTTP entry points are Plug-level (webhook / admin API); we never use MVC convention.
*Why*: we are a router runtime that ALSO has a UI, not a server-rendered web app. The framework choices follow.
*See also*: ARCHITECTURE.md §2.3 (was the deep source — now references back here).

## Group C — Dispatch & runtime

### **P14. Dispatch is the only path between Kinds.**

Every actor-to-actor message goes through `Ezagent.Invocation.dispatch/1`. Never `PubSub.broadcast` from one Kind to another (use it only for unknown-bystander view fan-out / telemetry — never inbound delivery); never write directly to an external system from inside a `handle_info`; never call another Kind's `GenServer.call` directly; callers never `import` Behavior modules.
*Why*: bypassing dispatch bypasses CapBAC (P15) + audit + idempotency + the ReadyGate window. Phoenix.PubSub does not buffer topics with no subscribers — a naked broadcast into an inbound topic loses messages in the register→subscribe window (the "事故 2.1" root cause that birthed this invariant). This was previously stated three times (CLAUDE.md "硬不变式 #1", ARCHITECTURE §5.6 #1, SKILL invariant 1) — unified here.
*CI gates*: `receiver_kind_pattern_test.exs`; grep gate against `PubSub.broadcast` on inbound topics.
*See also*: ARCHITECTURE.md §5.6 + §5.7.6; invariant 1 in references/architecture-invariants.md.

### **P15. Capabilities are module references, not atom shorthands; scope-bounded shapes narrow.**

`Ezagent.Capability.behavior` is a `module()` (e.g. `Ezagent.Behavior.Chat`), NOT an atom (`:chat`). Atom mismatch silently denies (`matches?/2` requires exact equality). Scope-bounded instance shapes (`{:within_session, _}` / `{:spawned_by, _}`) are MORE specific than URI caps, never less — they narrow, never broaden. `:any` is the only true wildcard and is reserved for the bootstrap admin + documented circular-dep workarounds (User default cap on `:session`).
*Why*: silent denial is the worst failure mode; the cap shape that "almost matched" but didn't is invisible without an audit. The scope-bounded shape preserves CapBAC's checkability while letting orchestrators delegate.
*CI gates*: `apps/ezagent_core/test/esr/capability_test.exs` ("scope-bounded instance tuples"); `apps/ezagent_domain_identity/test/esr/entity/user_test.exs` (`default_caps/0`).
*See also*: ARCHITECTURE.md §7 + §17.6 + Decision Log #133, #137; invariants 2, 5, 6 in references/architecture-invariants.md.

### **P16. Kind lifecycle is a single non-bypassable entry: `Ezagent.Kind.spawn/2`.**

All Kind processes are spawned via `Ezagent.Kind.spawn(kind_module, params)`. The lifecycle is `register → subscribe → announce_ready` (provided by `Ezagent.Kind.Server`); plugin authors cannot hand-write `init/1` to skip it. Direct `DynamicSupervisor.start_child` for Kind modules is forbidden — sidecars (PtyServer, etc.) are exempt only via an explicit allowlist in the spawn-entry test. `:call` to a not-ready actor MUST fail-fast (no buffering — caller is blocked on deadline_ms); `:cast` to a not-ready actor is buffered by PendingDelivery (bounded, overflow → DLQ).
*Why*: silent message drops + register/subscribe-window races came from inconsistent lifecycle. The single entry + ReadyGate are P3 (SoT for "is this Kind ready") + P14 (dispatch is the only path) combined.
*CI gates*: `apps/ezagent_core/test/invariants/single_spawn_entry_test.exs`; `kind_provenance_test.exs`.
*See also*: ARCHITECTURE.md §5.7.1-§5.7.6 + Decision Log #66, #67.

### **P17. Workspace is plumbed via URI structure, with `WorkspaceRegistry` as a consistency cache.**

Per-tenant URIs (entity / session / template / resource) carry their workspace as a structural URI segment (P19). `Ezagent.Capability.workspace_of/1` extracts it at O(1). `Ezagent.WorkspaceRegistry` is now a cache (post-Phase-9) — its invariant test verifies every binding equals the workspace segment of its session URI. Custom Template Classes that spawn sessions MUST call `WorkspaceRegistry.bind/2`. Cross-workspace dispatch requires structural authority (cross-workspace cap, system caller, system target, or `workspace://system` membership) and surfaces a distinct `:cross_workspace_denied` error.
*Why*: workspace-scoped routing rules silently never fired in Phase 6 because workspace was an envelope context. Phase 9 made it structural per uri-design §5.15 — P3 (one SoT, the URI) applied to tenant isolation.
*CI gates*: `workspace_isolation_test.exs`; `cross_workspace_isolation_test.exs`; `system_workspace_membership_test.exs`; `sessions_have_workspace_test.exs`.
*See also*: uri-design §5.15 + SPEC v3 §13; invariants 4, 13 in references/architecture-invariants.md.

### **P18. Dispatch mode is a transport choice, not a hard contract; no silent drops at user-facing surfaces.**

`Behavior.@interface[:action] = :cast | :call | ...` is the DEFAULT transport hint. A caller (transport) can legitimately override — Feishu's `InboundDispatcher` dispatches `Chat.send` as `:call` so it can decompose `{:error, :unauthorized}` and react with a THUMBSDOWN emoji + error text back to the human. When a human-facing inbound transport (Feishu / future Slack / Discord / email) fails dispatch, the transport MUST surface the error back via the original channel + a reaction. Silent drop is the bug Decision #134 prevents.
*Why*: humans need to know why their message didn't take. `:cast` discards errors; `:call` from inbound surfaces preserves them.
*CI gate*: `feishu_inbound_cap_denial_feedback_test.exs`.
*See also*: ARCHITECTURE.md §6.1 + Decision Log #134; invariants 7, 9 in references/architecture-invariants.md; `feedback_explicit_stop_signal_after_feishu`.

### **P19. Three dispatch hygiene rules (formerly ARCHITECTURE §5.6 "三条 dispatch 不变式").**

1. **Caller never imports a Behavior module** — everything goes through Registry so ACL / telemetry hooks are non-bypassable. (Redundant restatement of P14, kept for emphasis at the call site.)
2. **Behavior reads only its own slice** — cross-Behavior coordination goes through a new action, not by peeking at another slice.
3. **Each `dispatch/1` emits `:start`, `:stop`, `:exception` telemetry** — distributed tracing is automatic via the OpenTelemetry handler.

*Why*: these are the local hygiene that makes P14 + P15 + P16 stay honest. Documented inline because they're easy to violate by reflex.
*See also*: ARCHITECTURE.md §5.6 (was the deep source — now references back here).

## Group D — Persistence & URIs

### **P20. URI shape — 6-scheme allowlist + 3-segment authority for per-tenant schemes + query-string action.**

Exactly six schemes ever: `entity, workspace, session, template, resource, system`. `Ezagent.URI.SchemeRegistry` is the runtime ETS source of truth (P3) — `parse!/1` rejects anything else at parse time.
- **Per-tenant** (3-segment): `<scheme>://<type>/<workspace>/<name>` for `entity://`, `session://`, `template://`, `resource://`
- **Workspace / system** (2-segment, unchanged): `workspace://<name>` + `system://<type>/<name>`
- **Actions** are query-string: `?action=behavior.action` (never path)
- **No deleted schemes** ever come back: `user://`, `agent://`, `message://`, `feishu://`, `routing-admin://`, `pty-input://`

*Why*: URI is the universal operationId. Mixing schemes per plugin breaks P11 + P3; multi-segment paths reintroduce silent shape divergence.
*CI gates*: `Ezagent.URI.SchemeRegistry` ETS lockdown; `entities_have_workspace_test.exs`; `all_per_tenant_uris_have_workspace_test.exs`.
*Deep normative spec*: `docs/notes/uri-design.md` §5 (§5.1, §5.2, §5.6, §5.11, §5.12, §5.13, §5.15) — the §5 list is the normative deep source for URI shape and stays the authoritative URI reference; this principle is the index entry.
*See also*: invariants 11, 12 in references/architecture-invariants.md; `Ezagent.URI.SchemeRegistry`; `Ezagent.Capability.workspace_of/1`; `Ezagent.URI.entity_workspace_uri/1`.

### **P21. Per-tenant DB tables carry `workspace_uri NOT NULL`; reads scope via `Persistence.scope_by_workspace/2`.**

Every per-tenant table has a `workspace_uri TEXT NOT NULL` column with index. Read paths wrap queryables in `Ezagent.Persistence.scope_by_workspace/2`. Write paths derive workspace from the entity URI's workspace segment (P20). Exempt tables are explicitly listed in the invariant test + migration.
*Why*: P3 + P17 at the storage layer — tenant isolation must be structural, not relying on app-layer scope discipline.
*CI gates*: `per_tenant_tables_have_workspace_column_test.exs`; `no_nil_workspace_writes_test.exs`; `no_nil_workspace_writes_identity_test.exs`.
*See also*: uri-design §5.15 + SPEC v3 §7; invariant 14 in references/architecture-invariants.md.

### **P22. Reliability primitives live in core; plugin authors cannot bypass.**

Three primitives are baked into `use Ezagent.Kind` + `Ezagent.Invocation.dispatch/1`:
- **ReadyGate** — three-state per-URI registry (`:unknown / :not_ready / :ready`); dispatch consults it
- **PendingDelivery** — bounded per-URI buffer for `:cast` during not-ready window; overflow → DLQ
- **Idempotency** — webhook retry dedup via `ctx.idempotency_key`; v0 semantics: seen-on-arrival (failure still counts)

**Snapshot writes only on slice change** (`new_slice != old_slice`); audit telemetry handlers `cast` to `Ezagent.Audit.Writer` async — never sync-write SQLite in the invoke path. **Zero-match routes** emit telemetry + DLQ-unroutable; silent drop is forbidden (ezagent is a router, not a request-response app — receivers may not exist, so the system must always know).
*Why*: ezagent is a router runtime (ARCHITECTURE §1.2 差异 1) — if a message has no receiver, *someone* must know. Hand-coding observability in every plugin failed; these primitives make correctness the default.
*See also*: ARCHITECTURE.md §5.7 (was deep source); Decision Log #59, #60, #66, #67, #68; this consolidates CLAUDE.md hard-invariants #1, #3, #5, #6, #7.

## Group E — Plugin contract

### **P23. Plugin authoring contract — declare, don't call.**

A plugin is one OTP app under `apps/ezagent_plugin_<name>/` that implements `@behaviour Ezagent.Plugin` via `use Ezagent.Plugin`. The plugin DECLARES what it ships (`plugin_info/0`, optional `kinds/0`, `behaviors/0`, `spawns/0`, `template_classes/0`, `agent_flavors/0`, `routing_tables/0`, `config_surface/0`, `children/0`, `after_boot/0`); the framework DOES the registration via `Ezagent.Plugin.boot/1` (two-phase: start supervisor children first, then publish registry entries). Plugins MAY NOT call `*Registry.register` / `declare_table` directly. Enforcement is two layers: `use Ezagent.Plugin` does plugin-LOCAL `@after_compile` checks, and a non-optional Mix-compiler-+-CI gate (`plugin_contract_test.exs`) catches everything cross-module.
*Why*: P1 made structural. "Declare don't call" matches the rest of the codebase (`@interface`, `form_fields/0`, auto-derive Kind admin) — plugin authors learn one pattern. Two-phase boot avoids the rev-1 race (spawn fn published before its supervisor existed).
*CI gates*: `plugin_contract_test.exs`; the `:ezagent_plugin_check` Mix compiler.
*See also*: `docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md` (deep spec); invariant 8 in references/architecture-invariants.md.

### **P24. Plugins extend existing schemes; they don't introduce top-level schemes or core dependencies.**

A plugin contributes Kinds by **either** (a) extending an existing scheme's type axis via free-form name prefix (e.g. `entity://agent/cc_<name>` — cc plugin's agent flavor lives in the name prefix; AgentTemplate's `kind_module` is the authoritative source for "which Behavior runs this agent"), **or** (b) registering a Behavior on an existing core Kind (P11). Plugins MAY depend on `core` + any `domain_*`. Plugins do NOT write new core or domain primitives. Plugin unload is NOT supported in v1.
*Why*: P1 north star at the boundary level — `ezagent_core` knows nothing about cc / curl / echo / feishu / etc. `Ezagent.AgentTypeRegistry` was deleted (PR #131 reverted) because flavor → kind mapping centralized in core was a P1 violation.
*See also*: uri-design §5.8 + §5.14; references/three-tier-structure.md §"Boundary rules summary"; invariant 8 in references/architecture-invariants.md.

### **P25. Channel notification `meta` is `Record<string, string>`.**

For `notifications/claude/channel` payloads (Anthropic channels-reference spec), every `meta` value MUST be a string. List / map / nested-object values cause claude TUI to silently drop the entire notification — no error returned to either side. Structured data goes in `content` as text breadcrumbs, or via a `tools/call` round-trip. The only structured-ish field allowed is the optional `meta.file_path: <abs-path>` string (mirroring cc-openclaw convention).
*Why*: silent drop on the human-facing surface — the worst class of bug. CC channels use stdio (protocol-required), so the meta schema is the one we can defend at our boundary.
*CI gate*: `apps/ezagent_domain_chat/test/esr/behavior/chat_test.exs` ("to_claude payload meta values are all strings").
*See also*: ARCHITECTURE.md §12.8 + Decision Log #132; invariant 3 in references/architecture-invariants.md.

### **P26. SessionTemplate fork = configuration only.**

`SessionTemplate` carries `agent_slots + routing_rules + orchestrator_template_uri + workspace + parent_template_uri + version_hash`. It does NOT store message history. Forking copies config only; instantiated sessions start with empty chat. Three-way merge of running sessions' working-copies is explicitly out of scope.
*Why*: P3 + P10 — a SessionTemplate is a recipe (content-addressed via `@<hash>` — the only Kind with content addressing); a running session is the instance with its own history. Mixing them needs three-way merge mechanics that are explicitly deferred to dev-team-v1.x+.
*See also*: Decision Log #141; invariant 10 in references/architecture-invariants.md.

### **P27. Silent drops to clients OK only if security-motivated; silent drops in logs never OK.**

Some user-facing surfaces MUST hide failure mode from the client response — e.g. magic-link request (anti-enumeration: an attacker shouldn't tell "valid email" from "invalid email" from "rate-limited" via response diffs). That uniformity is the security property; preserve it.

But server-side observability is non-negotiable. Every code path that returns `:ok` to the client without doing the side effect MUST `Logger.info` / `Logger.warning` why, with enough context (email / IP / reason atom) for the operator to debug "user reports nothing happened". Anti-enumeration constrains the RESPONSE, not the logs.

P18 covers the related "no silent drop on dispatch error to human-facing transport" case (Feishu reaction feedback); P27 generalizes the principle to ANY anti-enumeration-style success-on-failure path.

*Why*: Allen 2026-05-23 hit `lin.yilun@h2oslabs.com` magic-link "no email received"; the controller's `maybe_send_magic_link/2` had 4 silent-drop paths (SMTP unconfigured / email rate-limited / IP rate-limited / domain not in whitelist) but ZERO Logger calls. Diagnosis required reading source — that's the failure mode this principle prevents.
*CI gate*: code review catches `:ok ->` / `_ -> :ok` clauses in user-facing controllers without a preceding `Logger` call; no automated test (lints/AST scans don't reliably distinguish security-silent from bug-silent).
*See also*: `apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex` `maybe_send_magic_link/2` post-PR for the canonical pattern; P18 (dispatch-side variant); P2 (anti-default rule that this complements).

---

## Where each old principle now lives

For cross-reference updates:

| Old location | New principle(s) |
|---|---|
| `CLAUDE.md` "8 条硬不变式" #1 (inbound走dispatch) | P14, P19 |
| `CLAUDE.md` "8 条硬不变式" #2 (use Ezagent.Kind 生命周期) | P16 |
| `CLAUDE.md` "8 条硬不变式" #3 (`:call` to not-ready fail-fast) | P16 |
| `CLAUDE.md` "8 条硬不变式" #4 (put_new vs put RoutingRegistry) | P22 (reliability primitives) — operational detail in ARCHITECTURE §5.4.2 |
| `CLAUDE.md` "8 条硬不变式" #5 (Snapshot 只在变了写) | P22 |
| `CLAUDE.md` "8 条硬不变式" #6 (Audit 异步 cast) | P22 |
| `CLAUDE.md` "8 条硬不变式" #7 (零匹配路由 telemetry + DLQ) | P22 |
| `CLAUDE.md` "8 条硬不变式" #8 (CC channel 用 stdio) | P25 (operational; stdio is protocol-imposed) |
| `IMPLEMENTATION_ROADMAP.md §1.3` #9 (CLI ↔ LV 同 BEAM) | Operational invariant; see ARCHITECTURE §13 + invariant test `cli_lv_same_server_invariant_test.exs` |
| `IMPLEMENTATION_ROADMAP.md §1.3` #10 (External-integration via Receiver Kind) | P11 |
| `ARCHITECTURE.md §2.1` 少发明多装配 | P8 |
| `ARCHITECTURE.md §2.2` Plugin判定原则 | P9 |
| `ARCHITECTURE.md §2.3` Phoenix as transport | P13 |
| `ARCHITECTURE.md §2.4` Adapter pattern | P12 |
| `ARCHITECTURE.md §5.6` 三条 dispatch 不变式 | P19 (verbatim) |
| `docs/notes/uri-design.md §5.1`-§5.14 | P20 (the §5 list itself remains the deep normative spec; P20 is the principle-level index entry) |
| `docs/notes/uri-design.md §5.15` (SPEC v3 per-tenant URI) | P17, P20 |
| Cross-cutting "plugin-isolation north star" | P1 |
| Cross-cutting "let-it-crash / no workarounds" | P2 |
| Cross-cutting "single source of truth" | P3 |
| Cross-cutting "production-usability selection criterion" | P4 |
| Cross-cutting "UUID is canonical identifier" | P5 |
| Cross-cutting "completion claim requires invariant test" | P6 |
| Cross-cutting "converge multi-modal inputs to flat URI list" | P7 |
| Cross-cutting "plugin external integration = Receiver Kind" | P11 |

## Contradiction resolution log

- **CLAUDE.md says "8" hard invariants; IMPLEMENTATION_ROADMAP §1.3 says "10".** Resolution: SKILL is the newest. The CLAUDE list was authored before Decision #127 (Receiver Kind / Plan B) and Decision #130 (CLI distributed-Erlang RPC); the ROADMAP §1.3 added items 9-10 as the project evolved. All 10 are now folded into P11 / P14 / P16 / P22 + operational invariants.
- **CLAUDE.md "8 条" #8 ("CC channel 用 stdio") is operational, not architectural.** Resolution: stdio is a protocol requirement, not a chosen invariant. Recorded under P25 (channel meta) as operational context; not promoted to a principle.
- **ARCHITECTURE.md §2.2 framing ("基础设施 vs 业务") vs SKILL's "core / domain / plugin" tier model.** Resolution: SKILL three-tier wins. §2.2's two-bucket framing predates the explicit `domain_*` tier added in Phase 6 Restructure (Decision #88's plugin authoring contract). P9 keeps the §2.2 "reads what data" *test*; references/three-tier-structure.md is the tier model.
- **`docs/notes/plugin-receiver-kind-contract.md` framing ("Receiver Kind = own a scheme") vs SPEC v2 §5.8 ("plugins don't own schemes").** Resolution: SPEC v2 § 5.8 wins (newer). The Receiver Kind pattern survives — but it lives on an *existing* core Kind via Behavior registration, not as a plugin-owned scheme. P11 reflects the current rule; the forensic note is kept for history with a header pointing at P11.
