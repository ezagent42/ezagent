# Anti-patterns the skill refuses

If a contributor (or your own draft) attempts any of these, push back BEFORE writing code. Each refusal cites the violated Decision Log entry / SPEC section + the CI gate that will fail.

## "I'll PubSub.broadcast from this plugin to that one"

Refuse. Bypasses dispatch → bypasses CapBAC → bypasses audit → bypasses idempotency. Per SPEC v2 §5.8 + invariant 1 + 8: register a Behavior on the existing core Kind (User for per-user channels, Session for per-room channels) and dispatch through it. Reference impl: `apps/ezagent_plugin_feishu/lib/ezagent/behavior/feishu_receive.ex`.

## "I'll add a new top-level scheme for my plugin's domain (slack://, discord://, etc.)"

Refuse. SPEC v2 §5.6 + §5.8: exactly six schemes ever. Extend via type segment (only sometimes — agent flavor is free-form per §5.14) or register a Behavior on an existing core Kind. The Feishu plugin's `feishu://` scheme was DELETED in PR #143 — your new plugin does not get to reintroduce the anti-pattern. CI gate: `Ezagent.URI.SchemeRegistry` ETS lockdown.

## "I'll dispatch via path-style `/behavior/X/Y`"

Refuse. SPEC v2 §5.2 + PR #146: action invocation uses query string, never path. `?action=chat.send`, `?action=routing.add_rule`, `?action=pty.write`. The old `/behavior/<kind>/<action>` syntax is removed entirely — no transitional shim. Update audit logs, route tables, doctests at the same time as code.

## "I'll add `user://X` or `agent://X` back as an alias"

Refuse. SPEC v2 §5.12 + PR #141: `user://` and `agent://` merged into `entity://`. Canonical forms: `entity://user/<workspace>/<name>`, `entity://agent/<workspace>/<flavor>_<name>`. No 1-segment fallback, no legacy URI form accepted, no `default`-injection logic. `Ezagent.URI.new!/1` rejects un-canonical input.

## "I'll use Message.uri"

Refuse. SPEC v2 §5.13 + PR #149: `Ezagent.Message.uri` field is renamed to `id` and stores a plain UUID string (no `message://` prefix). Reply-to references store the message id directly. LV stream `dom_id` uses the message id.

## "I'll resurrect routing-admin:// or pty-input:// as a singleton"

Refuse. SPEC v2 §5.7 + PR #144: synthetic singleton Kinds dissolved. Routing rule mutation dispatches to the rule's actual scope-owning Kind (`workspace://`, `session://`, or `system://routing/default`); PTY input dispatches to the target agent (`entity://agent/<workspace>/cc_X?action=pty.write`). Find the Kind whose scope the action naturally owns and add a Behavior there.

## "I'll bypass the cap check with admin_caps()"

Refuse. `admin_caps()` is the bootstrap principal's structural cap, NOT a goto for "make this work right now." If your code needs to act on behalf of a system component, use a scope-bounded delegation cap (`{:within_session, _}` or `{:spawned_by, _}` per Decision #137) — narrow, named, auditable. The ambient-authority pattern (looking up "who am I impersonating") was removed by PR-CC-1 (2026-05-25); use `Ezagent.SystemPrincipal.Catalog` for system-internal principals.

## "I'll add a new system principal URI inline"

Refuse. Per PR-CC-1 (2026-05-25): every system-internal principal URI is registered in `Ezagent.SystemPrincipal.Catalog` (closed allowlist). Adding a new system principal means editing the catalog module + adding its cap declaration. The catalog is part of `core` (invariant 8 list); inline URI synthesis (`URI.parse("entity://system/...")` from a Behavior) is rejected by the `no_wildcard_system_principals` invariant test.

## "I'll write the behavior as :chat in the cap struct"

Refuse. `Capability.behavior` is a module reference; the atom `:chat` is structurally different from `Ezagent.Behavior.Chat` and `matches?/2` will return false. Use the module reference. If a circular dep prevents that, use `:any` + narrow `:kind` (invariant 2 / forensic note).

## "I'll put structured data into channel notification meta"

Refuse. Decision #132: `meta` is `Record<string, string>`. Use `content` for structured data (as text), or `tools/call` round-trip if claude needs to read a file. The only structured-ish field allowed in meta is the single optional `file_path` string.

## "Inbound transport handler uses :cast for this dispatch"

Refuse for user-facing inbound transports (Feishu, future Slack/Discord/email). Decision #134 + `feedback_explicit_stop_signal_after_feishu`: human surfaces need synchronous error feedback. Use `:call` mode + decompose result + send error back through the channel + reaction emoji on denial.

## "Let's abstract a generic 'channel' covering both text + media"

Refuse. ROADMAP §9c + brainstorm trade-off: text/file = request-response (fits dispatch); streaming media = continuous flow (doesn't fit Behavior model). Generic abstraction hides the difference and invites misuse. Separate interfaces: Ezagent is control plane (signaling, auth, session, audit), media bytes go to external SFU (Dyte / LiveKit / Volcengine).

## "Make orchestrator deterministic — write the logic in Elixir"

Refuse. Decision D7-1 (#136): orchestrator is LLM-driven for team-composition reasoning. Permission control (the supposed benefit of deterministic dispatch) is preserved by scope-bounded cap delegation (Decision #137), not by removing reasoning.

## "SessionTemplate should fork with message history"

Refuse. Decision #141 (D7-7): fork unit = configuration only. Including message history would require three-way merge mechanics that are explicitly deferred to dev-team-v1.x+.

## "Add `mix ezagent.plugin.uninstall`"

Refuse for now. Decision #142 (D7-8): plugin unload requires Kind lifecycle management for live instances of the unregistered Kind — non-trivial. Defer until dev team agrees they need it, then design carefully (not as a symmetric mirror of `install`).

## "I'll add a backward-compat shim so old URIs still parse"

Refuse. SPEC v2 §5.11 + memory `feedback_let_it_crash_no_workarounds`: no back-compat shims. Existing DB data is wiped + rebuilt on migration. No operator shorthand. No legacy URI form accepted. Every URI in CLI input, LV form input, stored data, audit log, KindRegistry, routing matchers is canonical from day 1. Fix the call sites instead of compensating in the parser.

## "I'll `DynamicSupervisor.start_child` a Kind module directly"

Refuse. V1 structural prevention (Phase 9 follow-up, Allen 2026-05-21): all Kind processes go through `Ezagent.Kind.spawn(kind_module, params)` — the SOLE programmatic entry. Each Kind declares its target supervisor via the `supervisor/0` callback; `Ezagent.Kind.spawn/2` resolves it and calls `DynamicSupervisor.start_child` exactly once (inside `Ezagent.Kind`). Direct `DynamicSupervisor.start_child` calls for Kind modules are caught by CI gate `apps/ezagent_core/test/invariants/single_spawn_entry_test.exs` + runtime invariant `apps/ezagent_core/test/invariants/kind_provenance_test.exs`. Sidecars (PtyServer etc.) are exempt but explicitly listed in `allowed_sidecar_paths/0` — adding a new sidecar requires editing both the spawn-entry test's exemption list AND the moduledoc explanation.

## "I'll duplicate the Feishu one-off outbound shape for my new integration"

Refuse. As of Stream 2 PR-EM-0..FINAL (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`, Decision #122), **every** outbound mirror — Session slice → external system — goes through the **ExternalMirror Domain**. The plugin author writes **two modules + one declaration**: an Adapter (`@behaviour Ezagent.ExternalMirror.Adapter` — `event_to_payload/1` pure + `target_ownership_check/2` + `cap_subject/0`), a Binding (`@behaviour Ezagent.ExternalMirror.Binding` — `init/1` + `publish/2` + optional `terminate/2`), and `adapters/0` returning `[{Adapter, Binding}]` in the plugin module. Per-binding crash isolation, FacadeNonceTable forgery-proof handoff, two-tier supervision, eager spawn + restart adoption, rehydration on restart — ALL provided by the Domain. Re-implementing any of this in a plugin one-off is a P1 violation (plugin isolation north star) AND a P11 violation (PubSub-bypass — bindings MUST subscribe via `Publisher.subscribe_from/3`, never `Phoenix.PubSub.subscribe` directly).

## "I'll `Phoenix.PubSub.subscribe` from inside my Binding's `init/1` to get slice changes"

Refuse. SPEC §10 (f) + invariant `no_pubsub_bypass_in_external_mirror_test.exs` (grep gate). Bindings subscribe to slice changes via `Ezagent.Behavior.Publisher.subscribe_from/3` ONLY — which the Worker Kind invokes from its own `handle_continue`. Direct `Phoenix.PubSub.subscribe` from a Binding bypasses (a) per-binding crash boundary (the Worker's PerBindingSupervisor catches the publish failure; a raw PubSub consumer in some other process does not), (b) the Worker `:publish` CapBAC gate (step 5.5 enforces against the Worker Kind, not against the Binding GenServer), and (c) Publisher retention + cursor semantics. The structural enforcement is the grep gate — any binding module whose source carries `Phoenix.PubSub.subscribe` fails CI.

## "I'll call `Ezagent.Invocation.dispatch` from inside `target_ownership_check/2` to look up the session's chat slice"

Refuse. SPEC §10 (g) + invariant `no_dispatch_in_target_ownership_check_test.exs`. `target_ownership_check/2` runs inside the bind facade's `Task.Supervisor.async_nolink/3` — but `:bind` is itself a dispatched action; re-entering dispatch creates a dispatch-during-dispatch deadlock. The callback is ALLOWED to make external API calls (Lark/Slack/etc — that's its whole purpose) but MUST NOT re-enter ezagent. If you need session state inside this check, take it as an arg from the facade call site, or read via `Ezagent.Kind.get_slice/2` (NOT dispatch).

## "I'll cap-check inside the LV / inside a controller, not at dispatch"

Refuse. Per PR-CC-2-v2 (2026-05-25): cap-checking is a Behavior × Entity boundary concern, performed exactly once at **dispatch step 5.5** via the chokepoint callback `Kind.holds_cap?/2` consulting `Behavior.required_caps/0`. LV `handle_event` calls dispatch → step 5.5 fires → result propagates back. Pre-dispatch cap checks inside the LV are a defence-in-depth pattern only (e.g. to hide a button); they MUST NOT be the source of authority. The `cap_check_only_at_chokepoint` invariant test fails any module under `apps/ezagent_*` (except the chokepoint itself) that calls `Capability.matches?/2` in production code.

## "I'll write a new Behavior using `@behaviour Ezagent.Behavior` + `invoke/4`" — OR even `use Ezagent.Behavior` directly

Refuse for any developer Behavior. Two layers of obsolescence: (1) `Behavior.invoke/4` is `@optional_callbacks` only since Phase 3 PR #464 — no runtime path consults it. (2) Since the Lifecycle migration (2026-05-29), `use Ezagent.Behavior` itself is the **INTERNAL ENGINE** — developer code uses **`use Ezagent.Lifecycle`** (read `references/lifecycle.md`). The Phase C gate `mix ezagent.check_invariants.lifecycle` HARD-fails CI on a developer-tier `use Ezagent.Behavior` / `def init_slice` / `def state_slice` / `def invoke(_,_,_,_)` / `def post_init`/`handle_continue`/`on_ready`/`reconcile_after_load`. Engine allowlist: `behavior.ex` / `kind/runtime.ex` / `lifecycle.ex` / `mix/tasks/compile/ezagent_plugin_check.ex`.

## "I'll put this PID / ETS handle / port / monitor ref in `create`'s state"

Refuse. A live handle in `state` gets snapshotted and rehydrated as a DEAD reference on cold-load — the exact #110/#113/#114 bug class. Transient handles have ONE home: the `transients` container, returned from `activate/2` (rebuilt every start) and written via `{:set_transient, k, v}`. `state` is for durable domain data only. Read `references/lifecycle.md` two-container model.

## "I'll rebuild the subprocess / re-subscribe / re-monitor in a boot hook I picked"

Refuse. There is exactly ONE start hook: `activate/2`. It runs on fresh spawn, supervisor restart, AND cold-load identically. Do NOT split rebuild logic across `post_init`/`handle_continue`/`on_ready`/`reconcile_after_load` (folded into `activate` and gated away). If the work must run POST-`:ready` (a reachability broadcast inviting peer `:call`, or a self-deferred `send(self(), …)` worker-spawn loop), use `activated/2` or `activate → send(self(), msg) → handle_signal(msg, ctx)` — NEVER `activate` itself (it is pre-`:ready`, R10-1).

## "I'll name this core module `AgentTermination` / `SessionManager` / `Lifecycle`" (NP-1/2/3)

Refuse. §11 naming principles, enforced by the `mix ezagent.check_invariants.lifecycle` lint. NP-2: a module in `ezagent_core` must NOT name an upper-layer concept (`Agent`/`Session`/`Orchestrator`/`Workspace`/`Worker`/`Feishu`/`Cc`/`Codex`/`Np`/`Curl`) — use a core-layer capability name in the `Enumerable`/`Collectable` idiom (`Terminable`, not `AgentTermination`). NP-3: a generic name (`Lifecycle`/`Admin`/`Manager`/`Control`/`Handler`/`Service`/`Worker`) on a ≤1-action module over-promises. NP-1: name by what it DOES, not what it attaches to. Canonical lesson: `Behavior.Lifecycle` (1 `:terminate` action) → `Behavior.Terminable` (OQ-6). When converting a module, REPORT a naming violation — do NOT silently rename (it touches call sites + snapshot slice keys).

## "I'll `Phoenix.PubSub.broadcast` from inside my new-contract handler"

Refuse. Per SPEC PR #445 + §11 grep gate: new-contract handlers MUST emit a `{:notify, topic, payload}` effect for fire-and-forget broadcasts; framework calls `Phoenix.PubSub.broadcast/3` from inside `Kind.Runtime.apply_new_contract_effects/4` in the declared bucket order. Direct calls bypass (a) the bucket ordering invariant (notifies fire after dispatches), (b) the effect substitution for `{:ref, ...}` references, (c) the audit + trace correlation. Same applies to `Ezagent.Invocation.dispatch/1` (→ `{:dispatch, %Cmd{}}` effect) and `Ezagent.Kind.terminate/1` (→ `{:terminate, target}` effect).

Exception: result-dependent in-handler dispatch (where you need the dispatch return value, e.g. `ReadMarker.mark` only on successful chat.receive cast) — stay in-handler with `Ezagent.Router.dispatch/1` because the effect grammar discards dispatch return values. See `Ezagent.Behavior.Chat.handle_send/2` for the canonical pattern.

## "I'll import `Ezagent.EventLog` / `Ezagent.SnapshotStore` / `Ezagent.Kind.StateRebuilder` / `Ezagent.SagaRunner` from my plugin"

Refuse. SPEC §11 grep gate: any `Ezagent.Plugin.*` or `ezagent_plugin_*` / `ezagent_domain_*` module referencing these framework-internal modules fails CI. Plugin code:
- Emits events via `{:emit, event_name, payload}` effect — framework calls `EventLog.append/4`
- Lets framework write snapshots — framework calls `SnapshotStore.write/3` per `:set` effects + the every-N + on-terminate policy
- Lets framework rebuild from snapshot — `Kind.Host.init/1` calls `StateRebuilder.rebuild/1` on demand
- Hands sagas to runner via `{:saga, %Saga{}}` effect — framework calls `SagaRunner.execute/2`

The grep gate is structural: it ensures plugin authors can write a Behavior without ever knowing these modules exist.

## "I'll tune snapshot policy on my new Kind via `persistence/0`"

Refuse for new-contract Kinds. Per SPEC r2 codex HIGH-3 closure: snapshot policy is **framework-decided**, not per-Behavior. `Ezagent.SnapshotStore` writes every N events (default 100, configurable `:ezagent_core, :snapshot_every_n_events`) + on graceful terminate. The legacy `Kind.persistence/0` callback enum (`:on_change` / `{:periodic, ms}` / `:on_terminate` / `:ephemeral` / `:external`) still exists for Phase 2 migrated Kinds in coexistence, but Phase 2+ NEW Kinds should not declare it — let SnapshotStore handle it.

If you genuinely need different snapshot semantics (e.g. high-volume Worker Kind), declare the Kind with `pattern: {:resource, :hot}` (OQ-6) — that picks `:ephemeral` default + opt-in periodic, framework-managed. Do NOT reach for `persistence/0`.

## "I'll call `Ezagent.KindRegistry.lookup` / `Ezagent.SpawnRegistry.spawn` directly from my plugin" (task #95)

Refuse — `apps/ezagent_plugin_*` must go through `Ezagent.LocalRuntime` (owner-gated facade): `kind_alive?/1` for a liveness probe, `ensure_started/1` + `ensure_started_detailed/1` for spawn. A bare `KindRegistry.lookup/1` is a LOCAL-ONLY read that gives the wrong answer once a workspace is owned by another BEAM node (the decentralization direction) — it returns `:error` for a Kind alive elsewhere, so your plugin spuriously respawns. The facade routes through `Ezagent.WorkspaceOwnerGate` so the locality assumption is explicit (single-node no-op; non-owner → `false` / `{:error, {:not_workspace_owner, …}}`). Enforced by `plugin_workspace_locality_contract_test.exs`. Exempt: per-agent sidecar/executor `GenServer.call(pid, …)` (agent-local IPC, not Kind resolution). Full rule: architecture-invariants #22.

## "I'll add `Entity.Salesperson` / `Entity.Advisor` — a new Kind for my agent type"

Refuse. An agent type is `role × flavor` on the unified `Ezagent.Entity.Agent`, never its own Kind — own-Kind-per-type was retired in P4b (`Entity.PyAgent` → unified `Entity.Agent`). Register a **role recipe** via the `roles/0` plugin callback (behaviors loaded per-instance, role-foundation #54); host it on an existing flavor (cc/codex/py/curl/native). A per-type Kind breaks P1 (plugin-isolation), P24 (plugins don't mint core primitives), P9 (it reads chat like every agent — not a new core concept) and grants unwanted `entity://agent/*` chat-principal semantics. Canonical fix: kanban-as-role (`kanban-manager` recipe on `native` — `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex` `roles/0`, plugin declares NO `kinds/0`). A new Kind is justified only for a genuinely new *non-agent* primitive (P9/P10 + lead sign-off). See SKILL.md §"Extending agents…" + `references/extending-agents.md`.

## "I'll route the render / feed / transport through my business agent (and gate it with a `:salesperson` cap)"

Refuse. A generic platform mechanism (render transport, feed encoder, dispatch path) is producer-agnostic — it names no business persona and is NOT gated by a business-specific cap; the business agent is a fixture/role that *consumes* it. Coupling forces the next producer (advisor, dashboard) to re-implement or impersonate (P1/P3) and makes the mechanism untestable in isolation (P12: "reproducible via `dispatch/1` without the persona?"). The render-card path shipped transport-only in #1035 — `apps/ezagent_web/lib/ezagent_web/socialware/feed_encoding.ex` reads `body["render"]`/`body["render_css"]` for every message, no `:salesperson` cap. Build the mechanism standalone; let agents consume it. See `references/extending-agents.md` case B.

## "I'll keep this product's persona/corpus/routing in the seed because the seed makes it work"

Refuse as the long-term product shape. A seed is an installer or E2E harness, not the feature carrier. Product content belongs in definition data: AgentTemplate / soul markdown / resource fixture / SessionTemplate / socialware definition / ConfigObject. The seed may import those artifacts, ingest data, grant caps through CapBAC, and call a supported product/API path. If the seed owns business persona strings, KB corpus constants, routing policy, or hand-written runtime bindings (`McpRegistry.register/2`, `SessionManager.ensure_started/1`, working-copy stitching), it is proving a path, not defining the product. Require a follow-up that moves business content out of seed code and turns private stitching into a supported path. See `docs/together/contributing/seed-vs-product-boundary.md`.
