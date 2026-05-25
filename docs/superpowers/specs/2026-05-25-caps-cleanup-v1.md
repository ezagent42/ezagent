# SPEC — Caps cleanup v1 (3-issue architectural rectification)

**Status:** r2 (DRAFT). 2026-05-25.
**Tier:** `apps/ezagent_core/` framework rectification + sweep across every domain + plugin.
**Trigger:** Allen 2026-05-25 (Feishu) — three verbatim directives addressing accumulated cap-system pathology surfaced during the data-ownership-v2 / external-mirror-audit work:

1. "在代码中，完全不应该体现 admin_caps 的特殊性。admin 的特殊性是在验证权限的时候，通过 wildcard 匹配实现的"
2. "caps 的调用应该仅仅在 entity x behavior 的领域中实现。behavior 实现的时候，要求调用的 entity 需要持有某个权限，entity 中提供这个权限的凭证（目前就是简单的字符串）。所有其他的域理论上应该是透明不感知 caps 存在的"
3. "使用宏是必要的吗？还是可以通过其它方式更直接地完成？" (re: compile-time enforcement)

**Predecessors (all merged on `main`, none replaced):**
- `docs/superpowers/specs/2026-05-23-capability-registry.md` rev 4 — `Ezagent.CapabilityRegistry` single-entry registration. This SPEC supersedes that one for cap *enforcement*; the *cap-subject catalog* purpose collapses into Behavior callbacks directly.
- `docs/superpowers/specs/2026-05-24-caps-data-ownership-v2.md` rev 3 — `data_owner/1` callback + the principle that caps are CRUD authorization on a data class with a single legitimate grantor. This SPEC PRESERVES the data-ownership principle and the `data_owner/1` callback; it changes only how the cap is *represented* and *checked*.
- `docs/superpowers/specs/2026-05-25-external-mirror-auth-model-audit.md` r1 — 4-gate enforcement + FacadeNonceTable for forgery resistance. This SPEC PRESERVES FacadeNonceTable; it is orthogonal to cap representation.
- `apps/ezagent_core/lib/ezagent/capability.ex` — the 6-field struct this SPEC simplifies.
- `apps/ezagent_core/lib/ezagent/capability/parser.ex` — the existing string grammar this SPEC promotes from "operator CLI input" to "the canonical wire format".
- `apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex` — the existing compile-time gate this SPEC extends.

**Predecessor memories (load-bearing):**
- `feedback_let_it_crash_no_workarounds` (Allen 2026-05-05) — every "delete" in this SPEC is a hard delete. No `User.admin_caps()` deprecation period. No "if struct, convert to string at boundary" shim. The old call sites raise at compile time.
- `feedback_completion_requires_invariant_test` (Allen 2026-05-05) — each of the 3 issues gets an invariant test that fails when the architectural goal is unmet (§9).
- `feedback_north_star_plugin_isolation` (Allen 2026-05-05) — tiebreaker for design choices is "keeps plugin authors out of core". Issue 2 is the direct application of this principle.
- `feedback_uuid_is_canonical_identifier` (Allen 2026-05-12) — cap strings name *kinds of authority*, not user names. The instance URI does the identity binding.
- `feedback_bilingual_docs_convention` — Chinese mirror at `.zh_cn.md`.

**Companion:** `2026-05-25-caps-cleanup-v1.zh_cn.md`.

---

## 0a. r2 revision notes (what changed vs r1)

Codex r1 returned **needs-attention** with 4 HIGH + 1 MEDIUM. r2 closes all five structurally:

1. **HIGH fixed — migration widens workspace-scoped grants (was §5.8 conversion table).** r1's `CapMigration.convert/1` dropped the `workspace_uri` field on the assumption that the instance URI would carry workspace info. But for cap shapes with `instance: "any"` AND a concrete `workspace_uri` (e.g. the `User.default_caps/1` shape `{kind: :session, behavior: :any, instance: :any, workspace_uri: workspace://team}`), the migration produced a globally-scoped string like `"session.*"` — silently widening the original workspace-A grant into authorization on workspace B. r2 introduces a workspace suffix in the cap grammar (`;ws=<workspace_uri>`) AND extends the migration to preserve workspace dimension on every cap whose original `workspace_uri` is concrete. New invariant test §9.4 asserts no migrated cap authorizes a workspace it was not originally scoped to. Workspace iso (§5.5) gains a second arm: when a cap carries `;ws=` it constrains BOTH whether the cap matches AND the workspace check.
2. **HIGH fixed — system principal catalog not enforceable (was §4.1 / §4.2).** r1's `SystemPrincipal.ensure/2` accepted any `system://` URI and any cap list. r2 makes the catalog an executable allowlist: `Ezagent.SystemPrincipal.Catalog` (compile-time module) declares the 14 principals AND their permitted caps. `ensure/2` reads the catalog and rejects any URI not in it; the catalog is the single source of truth. A new invariant test §9.5 greps every `system://` URI literal in `apps/*/lib` and asserts it appears in the catalog. Compile-time check via `:ezagent_plugin_check` extension §6.1 check 11 — any module containing a `system://` URI literal that isn't in `SystemPrincipal.Catalog` fails the build.
3. **HIGH fixed — dispatch reads mutable slice without snapshot semantics (was §5.3).** r1's `read_caller_slice/1` did a fresh ETS read per dispatch with no version contract; concurrent grant/revoke could reach §5.5 / §5.6 / facade Gate 1-3 each seeing different cap states. r2 adds a cap-snapshot contract: `Ezagent.Identity.get_slice_versioned/1` returns `{caps :: [String.t()], revision :: pos_integer()}`. Dispatch reads it ONCE at dispatch admission (new step 5.0a) and propagates `{caps, revision}` through `ctx.caps_snapshot` for ALL downstream cap-consuming code (5.5, 5.6, facade gates). Cap mutations (`grant_cap`, `revoke_cap`) bump the revision; the action body's first CAS step (new step 8.5 — only for caps-mutating actions) verifies the snapshot revision still matches the entity's current revision before commit. If not, the action returns `{:error, :cap_snapshot_stale}` and the caller retries. Defines clear admission-time semantics that close the TOCTOU window.
4. **HIGH fixed — compile gate too weak (was §6.1 check 10).** r1 only verified values are binaries. r2 extends `:ezagent_plugin_check` to PARSE every `required_caps/0` value through `Ezagent.Cap.Parser.parse_strict/1` (new strict variant — rejects unknown kind atoms, unknown behavior atoms, malformed `@instance`, malformed `;ws=` suffixes). Cross-validates: cap's `kind` segment MUST match the parent Kind's `type_name/0`; cap's `behavior` segment MUST match the Behavior's `state_slice/0` OR `*`; cap's `action` segment MUST be one of the Behavior's `actions/0` OR `*`. Special strings `"*"` and `"cross-workspace:*"` are added to a SHORT explicit allowlist in the parser — documented, not undocumented exceptions. Runtime warn-only typo check (was §10.3) PROMOTED to compile-time hard failure.
5. **MEDIUM fixed — §0 OQs treated as ship-ready (was §0).** r2 moves the 6 OQs into "decisions" status with explicit closure rationale. The picked option becomes the decision; alternatives stay documented for traceability. PR-CC-2c (the irreversible migration sub-PR) gains a new acceptance gate: "all §0 decisions stamped 'Allen-approved YYYY-MM-DD' before merge." If Allen has not stamped a decision by then, PR-CC-2c blocks at review.

---

## 0. Decisions (formerly Open Questions)

Six decisions surfaced by brainstorm. Each carries the picked option as the SPEC's decision; alternatives stay documented for traceability. PR-CC-2c acceptance gate (§8) requires every decision stamped `Allen-approved YYYY-MM-DD` before merge — until then PR-CC-2c blocks at review.

Six questions surfaced by the brainstorm. SPEC currently picks the option marked **[picked]**; Allen approval flips any of them before implementation.

### OQ-CC-1 — Cap string format: does `@<instance_uri>` survive?

The existing `Capability.Parser` grammar already accepts `"chat.send@session://default/team/standup"` (kind.behavior@instance). Allen's verbatim says "目前就是简单的字符串" but does not pin whether instance-scoping survives.

- **[picked] Option A — Instance suffix DOES survive.** A cap string is `<kind>.<behavior>[.<action>|.*][@<instance_uri>]`. Without instance-scoping, the data-ownership-v2 invariant collapses: a session-owner cap (instance-bound to their session) cannot be distinguished from a global session-admin cap. Examples: `"session.chat@session://default/team/standup"`, `"workspace.workspace@workspace://team"`, `"*"`.
- Option B — Drop instance-scoping; caps become `<kind>.<behavior>` only. Simpler, but breaks data-ownership-v2 entirely. Would require a separate "scoped-by" mechanism (likely a 2-string-tuple), which is worse than just keeping the suffix.

**Why A:** preserves the structural invariant we just shipped (data-ownership-v2 rev 3), no new mechanism needed, the grammar already exists.

### OQ-CC-2 — Workspace iso mechanism after cap simplification

Today workspace iso lives in `Capability.matches?/2` via the `workspace_uri` field on the cap struct + dispatch step 5.6's `cross_workspace?/2` predicate. With strings, the cap no longer carries a workspace field.

- **[picked] Option A — Workspace iso becomes a per-Behavior callback `workspace_scoped?/0` (default `true`).** Cross-workspace bypass = caller is a member of `workspace://system` (existing Keycloak realm-admin model from Phase 9 PR-8) OR caller holds the explicit cross-workspace cap string `"cross-workspace:*"`. Dispatch step 5.6 keeps its position but reads the Behavior callback instead of cap struct fields.
- Option B — Workspace iso encoded in cap string as `@workspace://X.<rest>` prefix. Mixes two concerns into one syntax; harder to reason about; the suffix already does instance-scoping.
- Option C — Drop workspace iso from dispatch entirely; each Behavior does it in `invoke/4`. Violates "all domains transparent" — every Behavior writes the same check; classic primitive-in-each-plugin anti-pattern (memory `feedback_north_star_plugin_isolation`).

**Why A:** workspace iso is a structural property of *what data this Behavior operates on*, declared once per Behavior, enforced once at dispatch.

### OQ-CC-3 — Cap-only Behaviors (Presence pattern) after simplification

Today `Behavior.Presence` returns `dispatchable?/0 == false` — it exists only to declare a cap subject (`:online`) used by `NotificationSubscriptions` as an auth gate, without being a dispatch target. After simplification, the cap subject catalog goes away — the cap is just a string and the gate that consumes it reads `required_caps/0` from the Behavior.

- **[picked] Option A — Drop cap-only Behaviors entirely.** The pattern was a workaround for "I want to declare a cap subject without exposing a dispatchable action." Without a central subject catalog, the workaround is unnecessary: `Behavior.Presence` becomes a normal Behavior whose `:online` action is dispatchable (or it converts the gate-consumer to read the cap string directly without going through a Behavior). Audit shows exactly TWO cap-only Behaviors today: `Presence` and `Sandbox`. Both are migratable in 1-2 PRs of PR-CC-2.
- Option B — Keep `dispatchable?/0` as a Behavior callback. Preserves the existing pattern but keeps a vestigial concept around (a "Behavior" that cannot be invoked is conceptually a tag, not a Behavior).

**Why A:** simpler conceptual model; the pattern was load-bearing only because `CapabilityRegistry` existed; with `CapabilityRegistry` deleted, the pattern dissolves.

### OQ-CC-4 — `Behavior.IdentityAdmin` split — keep or merge back?

Today `Behavior.Identity` is split into safe `Identity` (`:list_caps`, `:has_cap?`) + privileged `Behavior.IdentityAdmin` (`:grant_cap`, `:revoke_cap`) per data-ownership-v2 PR-OWN-3. The split exists because cap struct is Behavior-scoped — granting one cap on `Behavior.Identity` would have authorized *both* read and grant.

After simplification: `required_caps/0` is per-action, so `Behavior.Identity` could re-merge — `:list_caps` requires `"user.identity.list_caps"`, `:grant_cap` requires `"user.identity.grant_cap"` — different cap strings.

- **[picked] Option A — Keep the split.** Even with per-action cap strings, the two-Behavior split keeps the privilege boundary visible in the module tree (anyone reading `Behavior.IdentityAdmin` knows "this is sensitive"). Re-merging would save 1 module but bury the privilege difference behind action-name discipline. The split is independent of cap representation; it's about module organization.
- Option B — Re-merge into single `Behavior.Identity`. 1 fewer module, but a future reader of the merged module has to inspect each action's `required_caps/0` to know which are admin-only.

**Why A:** module split is cheap; the visibility benefit persists.

### OQ-CC-5 — How does Issue 1's system principal catalog interact with Issue 2's cap shape?

Each system principal (e.g. `system://boot-reconciler`) needs caps for what it's allowed to dispatch. After Issue 2, those caps are strings. So `system://boot-reconciler`'s caps are something like `["session.external_mirror.*"]`. Where are they stored?

- **[picked] Option A — System principals are persisted Entity slices, same shape as Users.** Each system principal is spawned at boot as an Entity Kind (with `:identity` slice carrying its cap list). Stored in the existing `users` table (or a separate `system_principals` table with identical schema). `Ezagent.Identity.list_caps_for(uri)` works uniformly for both. Bootstrap script seeds the catalog (the 16+ principals listed in §4.1). The User Kind handles "system://" URIs too — no new Kind needed; just the URI scheme distinguishes.
- Option B — System principals are in-memory only, stored in a `SystemPrincipal` ETS table. Avoids DB migration but loses crash-safety (principals must re-seed every boot from compiled-in defaults).
- Option C — System principals don't exist; each call site passes a hardcoded cap list. Re-introduces ambient authority via a different name; rejected by Allen's "audit log shows the actual principal" requirement.

**Why A:** uniformity with User caps means no new primitive; the existing snapshot path persists them; the existing `:identity` slice contract works as-is; LV `/admin/caps` page sees them via the existing path.

### OQ-CC-6 — Migration data path: in-place or wipe-and-rebuild?

Existing users have `caps_json` column storing `[%Capability{kind, behavior, instance, workspace_uri, granted_by, granted_at}]`. New shape is `[String.t()]`. The struct → string conversion is lossy in TWO places:

- `granted_by` / `granted_at` are dropped (the cap string carries no provenance). Provenance moves to a separate `grants` audit table (or is dropped entirely — see Q below).
- `workspace_uri` is dropped from the cap (per OQ-CC-2 Option A — workspace iso moves to Behavior callback). The cap string's instance suffix carries workspace info via URI structure.

- **[picked] Option A — Wipe and rebuild dev DB; ship a one-shot conversion script for production.** Matches the data-ownership-v2 / external-mirror-domain pattern (Phase 9 SPEC v3 §8). The conversion script: read every `caps_json` row, derive the cap string per the mapping table in §5.8, write back. Provenance dropped (an explicit Allen decision needed — see sub-question below). Dev `mix ezagent.reset` regenerates fresh.
- Option B — In-place migration with provenance retained in a parallel `cap_grants` audit table. More moving pieces; more PRs.

**Sub-question — provenance:** drop granted_by/granted_at entirely, OR retain in a separate audit table?

- **[picked] Drop entirely.** Today no production code path reads `granted_by` (verified via grep — only test fixtures and serialization round-trip use it). The data-ownership-v2 grant-chain idea (cap-A delegated by cap-B-holder) was deferred to a future SPEC and never landed. If we ever need provenance, it's a `cap_grants` audit table that lives next to caps_json — additive change.

**Why A + drop:** matches the wipe-and-rebuild convention; no consumer of provenance today; provenance can be added back additively if a future use case appears.

---

## 1. Context — how we got here

ezagent's cap system today conflates SIX concerns into one `%Ezagent.Capability{}` struct + one `CapabilityRegistry` ETS + one `User.admin_caps()` hatch:

1. **What** authority (kind + behavior fields)
2. **On which target** (instance field)
3. **In which workspace** (workspace_uri field)
4. **By whom granted** (granted_by field)
5. **When granted** (granted_at field)
6. **Discovery / catalog** (CapabilityRegistry — what caps exist, what their descriptions are, who their data owner is)

The conflation produced three pathologies that have eaten 5+ rounds of codex review each over the last 3 SPECs:

### 1.1 Pathology A — Ambient authority via `User.admin_caps()`

When a system-internal operation (BootReconciler, AdapterInstall, migration mix task, ChatRouter reply dispatch, Worker publish) needs to dispatch, it has no real user URI. The convenient escape is `User.admin_caps()` — a structurally-:any cap MapSet that matches everything. Audit shows **16 production sites + 21 test sites** doing this (the 57 grep results, less 20 docstring mentions and comment references):

| Site category | Sample call sites |
|---|---|
| Boot / reconciler | `EzagentDomainIdentity.Application` (admin User spawn), `EzagentDomainChat.Application` (CC orchestrator seed), `EzagentDomainWorkspace.Workspace.Loader` (boot loader) |
| Mix tasks | `mix ezagent.agent.create`, `mix ezagent.demo.seed_cc_agent`, `mix ezagent.demo.seed_cc_sandbox` |
| Plugin reply dispatch | `Plugin.CurlAgent` (LLM reply dispatch), `Plugin.NP` (NP-agent reply), `Plugin.CC.Channel` (channel reply), `Plugin.Echo` (echo reply), `Plugin.Feishu.BindingPolicy` |
| Chat domain internals | `Behavior.Chat` (reply send, system messages), `Behavior.Template` (template materialization), `Entity.Session` (member sync, slice mutations), `Entity.Agent` (default caps grant), `Orchestrator.{MCPServer, Tools, CCSeed}` |
| LV admin defaults | `terminal_live`, `agent_extensions_live`, `agent_detail_live`, `entity_caps_live`, `agent_new_live`, `admin_live`, `routing_live` (when caller is `nil`) |
| Web root | `home_live` (when no current_entity) |
| Worker | `Behavior.ExternalMirrorWorker` (publish-to-adapter dispatches) |

Each site is *spoofable* (the calling code declares "I am admin") and *untraceable* (audit log says "admin did X", not "BootReconciler did X").

### 1.2 Pathology B — Cap-check logic scattered across non-Behavior layers

The contract today is "dispatch step 5.5 checks caps via `Capability.matches?/2`". But the current code has cap-check copies / paraphrases in:

- `Behavior.Identity.invoke(:grant_cap, ...)` — `check_grant_authorized/2` re-checks the cap shape against data-ownership rules (200+ LOC)
- `Behavior.ExternalMirror` facade — Gates 1, 2, 3 in `Ezagent.ExternalMirror.bind/5` (200+ LOC of facade-level cap checks per external-mirror-audit §2)
- `NotificationSubscriptions` admin predicate — `has_admin_cap?/1` with hand-written shape matching
- `MemberPanel` LV — `cc_agent_uri?/1` workspace-membership check
- `SenderResolver` (Feishu) — `Ezagent.Identity.list_caps_for(bound_uri)` then membership inspection
- Various `_live` modules — `MapSet.member?` checks for cap-driven UI gating

Plugin authors have to *invent* the trust model every time. PR #303 NotificationSubscriptions HIGH-3 finding was exactly this: a hand-written predicate was too wide because there was no framework-level "you must hold cap-X on data-D" gate.

### 1.3 Pathology C — Compile-time enforcement spread across `use Macro` + after_compile + Mix compiler

Today `Behavior` is enforced via `@behaviour Ezagent.Behavior` (compile warning) + `cap_subjects/0` lookup at `CapabilityRegistry.register/3` time (raises if action missing). Some plugin authors have added `use SomeMacro` patterns over the top. The compile-time gate is split across three mechanisms. Allen's Q3: "使用宏是必要的吗？还是可以通过其它方式更直接地完成？" — answer is NO. The existing `:ezagent_plugin_check` Mix compiler is already the right surface; it just needs to grow the cap-related checks.

### 1.4 What this SPEC fixes

This SPEC unwinds all three pathologies in one coordinated cleanup:

- **Issue 1** removes ambient authority. System operations declare their own named principals. Admin's wildcard authority remains, but via data (caps MapSet on the admin Entity) not via code (`User.admin_caps()` deleted).
- **Issue 2** moves cap declaration to per-action Behavior callbacks. Entities hold cap strings. All other code is cap-transparent — dispatch is the only place the gate runs. `Capability` struct + `CapabilityRegistry` ETS + `Identity.{grant_cap,list_caps_for,revoke_cap}` all delete or simplify.
- **Issue 3** moves enforcement into the existing `:ezagent_plugin_check` Mix compiler. No macros. ~50-100 LOC of additions.

---

## 2. Goals (outcome statements)

After this SPEC's 3 PRs are merged:

**G1 — Ambient authority is gone.** `grep -rn "User.admin_caps" apps/` returns 0 results outside `test/support/`. Every dispatch carries a real principal URI in `ctx.caller`. Audit log shows the actual operating principal for every internal operation. The admin Entity's caps slice still contains the wildcard `"*"` cap string — admin authority is data, not code.

**G2 — Caps live only at Behavior × Entity.** `Behavior.required_caps/0` declares per-action cap strings. `Entity.holds_cap?/2` decides membership. `Invocation.dispatch/1` step 5.5 calls both. Every other module is cap-transparent. `grep -rn "Capability.matches\|cap_subjects\|list_caps_for\|grant_cap" apps/` returns 0 production results outside `apps/ezagent_core/lib/ezagent/{behavior,entity,invocation,kind}*.ex` and `apps/ezagent_domain_identity/lib/ezagent/{identity,behavior/identity}*.ex`.

**G3 — Compile-time enforcement is data, not macros.** Every `@behaviour Ezagent.Behavior` module exports a valid `required_caps/0`. Build fails with a precise diagnostic if (a) the callback is missing, (b) the key set differs from `actions/0`, or (c) any value is not a binary cap string. Zero macros added; the `:ezagent_plugin_check` compiler grows by ~50-100 LOC.

---

## 3. Non-goals

- **NOT switching to RBAC** (role-based) — the cap model stays. A "role" is just a named bundle of cap strings that callers can grant atomically.
- **NOT replacing the FacadeNonceTable** from external-mirror-audit. Trust transfer between facade Task and action body is orthogonal to cap simplification.
- **NOT touching dispatch's other steps** (1–4, 5.1–5.4, 5.6–10, 11–12). Only step 5.5 (CapBAC) and 5.6 (workspace iso) change. Step 5.5 reads `Behavior.required_caps()` + calls `Entity.holds_cap?/2`; step 5.6 reads `Behavior.workspace_scoped?/0`.
- **NOT changing `data_owner/1`** from data-ownership-v2. The callback signature and default-grant derivation stay. Only the cap *representation* changes (struct → string); the data-ownership *rule* (only the owner grants caps on their data) is preserved.
- **NOT adding cap provenance audit table in this SPEC.** Dropping `granted_by` / `granted_at` per OQ-CC-6. If provenance becomes needed, it lands as a separate `cap_grants` audit-only table additively.
- **NOT changing UI cap-list display** beyond the field reduction. `/admin/caps` LV still enumerates "what cap strings exist" via `Behavior.required_caps/0` aggregation across all registered Behaviors.

---

## 4. Issue 1 — Ambient authority removal

### 4.1 System principal catalog

Each system-internal dispatch gets a named principal URI under the `system://` scheme. Principal URIs are spawned as Entity Kinds at app boot (per OQ-CC-5 Option A), with their cap lists seeded from a compiled-in catalog.

| Principal URI | Operating context | Required cap strings |
|---|---|---|
| `system://bootstrap` | Admin User spawn at first boot (only used to mint the admin Entity itself) | `"*"` (single use, granted from compiled-in constants) |
| `system://boot-reconciler` | `EzagentDomainExternalMirror.BootReconciler` — reconciles persisted bindings against running adapters at boot | `"session.external_mirror.*"` |
| `system://adapter-install` | `EzagentDomainExternalMirror.AdapterInstall` — installs adapter cap subjects against Session Kind at plugin boot | `"session.*.bind"` (registers per-adapter Behaviors) |
| `system://chat-router` | `Behavior.Chat`'s system-message dispatch path (system-sent welcome msgs, reaction notifications) | `"session.chat.send"`, `"session.chat.system_message"` |
| `system://chat-reply` | Plugin reply dispatches (Echo, CurlAgent, NP, CC, Feishu) — the "agent's response to a session" path | `"session.chat.send"`, `"session.chat.reaction"` |
| `system://worker-publish` | `Behavior.ExternalMirrorWorker` outbound publish dispatches | `"session.external_mirror.publish"` |
| `system://template-materialize` | `Behavior.Template` template-instantiation dispatch | `"workspace.template.*"`, `"session.*"` |
| `system://orchestrator-tools` | `Orchestrator.{MCPServer, Tools, CCSeed}` agent-tool dispatches | `"session.*"` (agent operates within its session lineage) |
| `system://session-internal` | `Entity.Session` slice-internal dispatches (member sync, scope mutations) | `"session.chat.*"`, `"workspace.workspace.read"` |
| `system://agent-internal` | `Entity.Agent` default-caps grant at agent spawn | `"user.identity.grant_cap"` (scoped to the spawned agent) |
| `system://workspace-loader` | `Workspace.Loader` boot path that re-spawns persisted workspaces | `"workspace.workspace.*"` |
| `system://mix-task` | `mix ezagent.agent.create`, `mix ezagent.demo.seed_*` operator tasks | `"*"` (operator already has shell access; principal exists for audit traceability) |
| `system://feishu-binding-policy` | `Plugin.Feishu.BindingPolicy.apply/2` re-grant of default session caps | `"user.identity.grant_cap"` |
| `system://lv-anon-mount` | LV mount path when no `current_entity_uri` is in session | `[]` (empty — LV anon mounts cannot dispatch; replaces the silent `User.admin_caps()` fallback that hid auth bugs) |

Total: 14 principals. **The list is enforced closed — `Ezagent.SystemPrincipal.Catalog` is the single source of truth (per r2 HIGH-2 fix).** Adding a 15th principal requires (a) editing `Catalog`, (b) editing this SPEC, (c) shipping in a separate PR. The catalog is enforced at three layers:

1. Runtime: `SystemPrincipal.ensure/2` rejects URIs not in the catalog (raise).
2. Compile-time: `:ezagent_plugin_check` check 11 greps every `system://` URI literal in app source and asserts membership in the catalog (build fails).
3. Invariant test (§9.5): same grep, fail-loud at test time as defense in depth.

### 4.2 Catalog module (r2 HIGH-2)

`Ezagent.SystemPrincipal.Catalog` (new compile-time module in `apps/ezagent_core/lib/ezagent/system_principal/catalog.ex`):

```elixir
defmodule Ezagent.SystemPrincipal.Catalog do
  @moduledoc """
  The closed allowlist of system principal URIs and their permitted caps.

  Any `system://` URI used as a dispatch principal MUST appear here.
  `:ezagent_plugin_check` enforces this at compile time; the runtime
  `SystemPrincipal.ensure/2` enforces it at boot.

  Adding a 15th principal requires:
  1. Add row here.
  2. Update SPEC `caps-cleanup-v1.md` §4.1 catalog table.
  3. Ship in a separate PR (review surface = "are we adding ambient authority?").
  """

  @catalog %{
    "system://bootstrap"                 => ["*"],
    "system://boot-reconciler"           => ["session.external_mirror.*"],
    "system://adapter-install"           => ["session.*.bind"],
    "system://chat-router"               => ["session.chat.send", "session.chat.system_message"],
    "system://chat-reply"                => ["session.chat.send", "session.chat.reaction"],
    "system://worker-publish"            => ["session.external_mirror.publish"],
    "system://template-materialize"      => ["workspace.template.*", "session.*"],
    "system://orchestrator-tools"        => ["session.*"],
    "system://session-internal"          => ["session.chat.*", "workspace.workspace.read"],
    "system://agent-internal"            => ["user.identity.grant_cap"],
    "system://workspace-loader"          => ["workspace.workspace.*"],
    "system://mix-task"                  => ["*"],
    "system://feishu-binding-policy"     => ["user.identity.grant_cap"],
    "system://lv-anon-mount"             => []
  }

  @doc "Is this URI a registered system principal?"
  @spec member?(URI.t() | String.t()) :: boolean()
  def member?(uri), do: Map.has_key?(@catalog, normalize(uri))

  @doc "Permitted caps for this principal. Raises if not in catalog."
  @spec caps_for!(URI.t() | String.t()) :: [String.t()]
  def caps_for!(uri) do
    key = normalize(uri)

    case Map.fetch(@catalog, key) do
      {:ok, caps} -> caps
      :error -> raise ArgumentError,
        "#{key} is not in SystemPrincipal.Catalog (caps-cleanup-v1 §4.1). " <>
        "Add the row to Catalog + SPEC + open a separate PR."
    end
  end

  @doc "List every catalog URI (for invariant test §9.5)."
  @spec uris() :: [String.t()]
  def uris, do: Map.keys(@catalog)

  defp normalize(%URI{} = u), do: URI.to_string(u)
  defp normalize(s) when is_binary(s), do: s
end
```

### 4.3 Seed flow

Each domain Application that needs a system principal seeds it in its `start/2` via:

```elixir
Ezagent.SystemPrincipal.ensure(URI.parse("system://boot-reconciler"))
```

`Ezagent.SystemPrincipal.ensure/1` (new module in `apps/ezagent_core/lib/ezagent/system_principal.ex`):
- Reads the cap list from `Catalog.caps_for!/1` — no second arg; caller cannot pass arbitrary caps.
- Spawns an Entity Kind with `:identity` slice carrying the cap list (same as a User Kind, but URI is `system://...` not `entity://user/...`).
- Idempotent: if already spawned, no-op.
- Persists via the same `users` table (column `caps_json` carries the list of strings).
- Hard-raises if URI is not in the catalog OR is non-`system://` (defense in depth).

`Behavior.Identity.init_slice/1` already handles the slice shape — only the URI scheme changes.

### 4.4 Migration of system call sites

| Old | New |
|---|---|
| `caps: User.admin_caps()` in dispatch ctx | DELETE — `ctx.caps` field removed per r2 HIGH-3 fix (§5.3 cap-snapshot). Dispatch reads caller slice from caller URI directly; system principals are loaded via the same path |
| `caller: User.admin_uri()` in dispatch ctx | `caller: URI.parse("system://<service>")` |
| Bare `User.admin_caps()` call | DELETE — function deleted from `Entity.User` (compile error if used) |

Each LV that today falls back to `User.admin_caps()` for anonymous mounts (`agent_extensions_live`, `terminal_live`, etc.) switches to `system://lv-anon-mount` with EMPTY caps. The LV mount path that previously silently elevated to admin will now correctly deny anonymous access. This is the existing auth-bug surfacer — anonymous LV mounts SHOULD have been denied; the `User.admin_caps()` fallback was hiding it. Per memory `feedback_let_it_crash_no_workarounds`, the fix is to make the bug visible at the gate, not to preserve the fallback.

### 4.5 Audit log changes

`telemetry.execute([:ezagent, :authz, :granted], ...)`'s `caller` field today shows `entity://user/system/admin` for both real admin operations AND every system-internal dispatch. After this PR, those split: real admin operations still show admin URI; system operations show `system://<service>`.

Codex r2 will demand the audit consumers (today: `audit.ex` writes to `audit_events` table) handle the new URI scheme. They already do — `audit_events.caller` is a String column with no constraint on scheme. The CSV / `/admin/audit` LV displays the URI verbatim.

### 4.6 Invariant test

`apps/ezagent_core/test/invariants/no_admin_caps_fallback_test.exs` (new):

```elixir
test "no production code calls User.admin_caps/0" do
  offenders =
    Path.wildcard("apps/*/lib/**/*.ex")
    |> Enum.filter(fn path -> not String.contains?(path, "test/support") end)
    |> Enum.filter(fn path ->
      File.read!(path) =~ ~r/\bUser\.admin_caps\(\)|Ezagent\.Entity\.User\.admin_caps\(\)/
    end)

  assert offenders == [],
         "ambient authority leak: #{inspect(offenders)} call User.admin_caps()"
end

test "User module does not export admin_caps/0" do
  refute function_exported?(Ezagent.Entity.User, :admin_caps, 0),
         "Ezagent.Entity.User.admin_caps/0 must be deleted per caps-cleanup-v1 §4"
end
```

The first asserts the cleanup is complete; the second asserts the escape hatch is structurally removed.

---

## 5. Issue 2 — Caps at Behavior × Entity boundary

### 5.1 `Behavior.required_caps/0` callback (plain function)

Added to `Ezagent.Behavior` as a mandatory callback (no macros):

```elixir
@doc """
Map from action atom to required cap string. Read by Invocation.dispatch/1
step 5.5 to derive the cap the caller must hold.

The cap string follows the grammar in §5.4. Examples:

    %{
      send: "session.chat.send",
      receive: "session.chat.receive",
      join: "session.chat.join"
    }

Every action returned by `actions/0` MUST have an entry here.
Compile-time enforced by `:ezagent_plugin_check` (Issue 3).
"""
@callback required_caps() :: %{required(action()) => String.t()}
```

The Behavior author writes ONE map. No macros, no DSL, no separate "register at boot" step.

### 5.2 `Entity.holds_cap?/2` callback (default impl + wildcard semantics)

Added to `Ezagent.Kind` (the Entity contract — Entities are Kinds with persistence + identity):

```elixir
@doc """
Does this entity's persisted state grant the given cap string?

Default implementation reads `slice[:identity][:caps]` and matches via
glob (`*` = wildcard segment). Plugin authors override only when
the cap-source is non-standard (rare).
"""
@callback holds_cap?(entity_slice :: map(), cap_string :: String.t()) :: boolean()

# Default impl provided by Ezagent.Kind (concrete Kinds inherit unless
# they override). Walks the cap list, glob-matches each held cap
# against the needed string per §5.4 wildcard semantics.
def holds_cap?(slice, cap_string) when is_binary(cap_string) do
  caps = get_in(slice, [:identity, :caps]) || []
  Enum.any?(caps, &Ezagent.Cap.matches?(&1, cap_string))
end
```

`Ezagent.Cap.matches?/2` (new helper module in `apps/ezagent_core/lib/ezagent/cap.ex`):
- `matches?("*", _needed)` → true (admin wildcard)
- `matches?("chat.*", "session.chat.send")` → true (kind-glob)
- `matches?("session.chat.*", "session.chat.send")` → true (action-glob)
- `matches?("session.chat.send", "session.chat.send")` → true (exact)
- `matches?("session.chat@session://X", "session.chat.send@session://X")` → true (instance-scoped, same instance)
- `matches?("session.chat@session://X", "session.chat.send@session://Y")` → false (different instance)
- `matches?("session.chat", "session.chat.send")` → true (behavior-level cap grants all actions on the behavior — preserves the cap struct's "no action field" semantics)

The matcher is ~50 LOC, fully unit-tested, no external dependencies.

### 5.3 Dispatch step 5.5 simplification + cap snapshot contract (r2 HIGH-3)

Today `apps/ezagent_core/lib/ezagent/kind/runtime.ex:215-239` (`authz_check/4`) reads `Capability.cap_for_action/3` + iterates `ctx.caps` MapSet through `Capability.matches?/2`. After this SPEC:

**New step 5.0a — cap snapshot at dispatch admission.** `Invocation.dispatch/1` (after step 1's idempotency, before step 5.5) reads the caller's caps ONCE per dispatch and pins them to `ctx.caps_snapshot`:

```elixir
defp admit_cap_snapshot(%Invocation{ctx: ctx} = inv) do
  case Ezagent.Identity.get_slice_versioned(ctx.caller) do
    {:ok, %{caps: caps, revision: rev}} ->
      snapshot = %{caps: caps, revision: rev, taken_at_us: System.monotonic_time(:microsecond)}
      %{inv | ctx: Map.put(ctx, :caps_snapshot, snapshot)}

    :not_found ->
      # Caller URI not spawned — system principals MUST be ensured at
      # boot; user principals MUST be spawned at login. Hard-raise per
      # feedback_let_it_crash_no_workarounds — no silent empty-caps
      # fallback (that's the User.admin_caps() pathology in a new costume).
      raise ArgumentError,
        "caller #{URI.to_string(ctx.caller)} has no Identity slice; cannot dispatch"
  end
end
```

The snapshot is the ONLY source of caller caps for the lifetime of the dispatch. Steps 5.5 (CapBAC), 5.6 (workspace iso), and any facade-internal cap re-checks (ExternalMirror Gates 1-3) read `ctx.caps_snapshot.caps` — never re-read the slice.

**Step 5.5 — uses the snapshot:**

```elixir
defp authz_check(kind_module, action, target, ctx) do
  behavior = lookup_behavior(kind_module, action)  # same as today
  needed_cap = Map.fetch!(behavior.required_caps(), action)
  needed_with_instance = "#{needed_cap}@#{URI.to_string(Ezagent.URI.instance(target))}"

  if cap_in_snapshot?(ctx.caps_snapshot.caps, needed_with_instance) do
    :telemetry.execute([:ezagent, :authz, :granted], %{revision: ctx.caps_snapshot.revision},
                       meta(ctx, target, action, needed_with_instance))
    :ok
  else
    :telemetry.execute([:ezagent, :authz, :denied], %{revision: ctx.caps_snapshot.revision},
                       meta(ctx, target, action, needed_with_instance))
    {:error, :unauthorized}
  end
end

defp cap_in_snapshot?(caps_list, needed) when is_list(caps_list) do
  Enum.any?(caps_list, &Ezagent.Cap.matches?(&1, needed))
end
```

**New step 8.5 — CAS guard for cap-mutating actions.** For actions whose `Behavior.mutates_caps?/0` returns `true` (default `false`; only `Behavior.IdentityAdmin.grant_cap` / `revoke_cap` override), Kind.Server's invoke wrapper compares `ctx.caps_snapshot.revision` against the **caller**'s current Identity slice revision BEFORE the action commits. If the revision drifted, return `{:error, :cap_snapshot_stale}` and the caller may retry with a fresh snapshot.

```elixir
defp cas_guard_for_cap_mutating(inv, kind_module, action) do
  behavior = lookup_behavior(kind_module, action)

  if behavior_mutates_caps?(behavior, action) do
    current = Ezagent.Identity.get_revision(inv.ctx.caller)

    if current == inv.ctx.caps_snapshot.revision do
      :ok
    else
      {:error, :cap_snapshot_stale}
    end
  else
    :ok
  end
end
```

For non-cap-mutating actions (the 99% case — chat send, session join, etc.) the CAS guard is skipped: those actions don't care if caps drift mid-dispatch because they neither read nor write caps after step 5.5.

**Identity slice revision semantics.** Added to `Ezagent.Identity` slice:
- New slice key `:revision` — monotonically increasing counter.
- `grant_cap` and `revoke_cap` bump `:revision` atomically with the cap-list mutation (single ETS update).
- `get_slice_versioned/1` reads `{caps, revision}` in one ETS lookup.
- `get_revision/1` reads `revision` alone (used by CAS guard).

Revision is per-Entity. A grant on user-A doesn't bump user-B's revision; concurrent dispatches against different users never CAS-fail each other.

**Key changes summary:**
- `ctx.caps` is GONE (was the pre-loaded MapSet that needed `User.admin_caps()` as fallback). Replaced by `ctx.caps_snapshot` set at admission.
- Cap check reads from snapshot, not from live ETS.
- Cap-mutating actions CAS-guard against stale snapshots; other actions skip the check.
- `Capability.matches?/2` is GONE — replaced by `Ezagent.Cap.matches?/2`.
- `Capability.cap_for_action/3` is GONE — replaced by `Behavior.required_caps()[action]` lookup.
- All facade-internal cap-rechecks (ExternalMirror Gates 1-3) read `ctx.caps_snapshot.caps` — never re-fetch.

### 5.4 Cap string format (canonical grammar — r2 HIGH-1 + HIGH-4)

```
cap_string := allowlisted_special | scoped_cap
allowlisted_special := "*" | "cross-workspace:*"
scoped_cap := authority instance_suffix? workspace_suffix?
authority := kind "." behavior ( "." action | ".*" )?
instance_suffix := "@" instance_uri
workspace_suffix := ";ws=" workspace_uri
kind := atom_string | "*"
behavior := atom_string | "*"
action := atom_string
instance_uri := URI.t() string form (no '@', no ';' inside path)
workspace_uri := full workspace:// URI string

Examples:
"*"                                                     # admin all (allowlisted)
"cross-workspace:*"                                     # cross-workspace bypass (allowlisted)
"session.*"                                             # all session-kind actions, ANY workspace
"session.*;ws=workspace://team-alpha"                   # all session-kind actions, only in team-alpha workspace
"session.chat"                                          # all session.chat.* actions, ANY workspace
"session.chat.send"                                     # specific action, ANY workspace
"session.chat@session://default/team/main"              # all chat actions on one session (workspace structural via instance)
"session.chat.send@session://default/team/main"         # one action on one session
"session.chat.send;ws=workspace://team-alpha"           # one action, scoped to team-alpha workspace (no specific instance)
```

**Workspace suffix `;ws=<workspace_uri>` (r2 HIGH-1 fix).** When the cap has no instance suffix but the original `%Capability{}` carried a concrete `workspace_uri`, the suffix preserves that dimension. Matching semantics (§5.2 `Cap.matches?/2` extended):

- A cap WITHOUT `;ws=` matches a needed cap in ANY workspace.
- A cap WITH `;ws=W` matches a needed cap only if the needed cap's target is in workspace W (or its instance URI structurally derives to W).
- The `@instance_uri` suffix is STRONGER than `;ws=` — if both are present, the instance URI's workspace MUST equal the `;ws=` value (compile-time contradictions like `session.chat@session://default/team/main;ws=workspace://other` fail the parser).

**Allowlisted specials.** The two strings `"*"` and `"cross-workspace:*"` are NOT regular cap shapes — they're documented escape hatches with explicit allowlist in the parser. Adding a third special requires SPEC amendment. This closes codex r1's "unstated exceptions" concern (HIGH-4).

**Strict parser `Cap.Parser.parse_strict/1`** (r2 HIGH-4):
- Used by `:ezagent_plugin_check` at compile time.
- Rejects unknown kind atoms (via `String.to_existing_atom` — kind must be a registered Kind name).
- Rejects unknown behavior atoms similarly.
- Rejects unknown action atoms (must be in declaring Behavior's `actions/0`).
- Rejects malformed `@instance_uri` (URI parse must succeed; scheme must be one of the registered scheme allowlist).
- Rejects malformed `;ws=` (must parse to `workspace://*` URI).
- Rejects unknown specials (only `"*"` and `"cross-workspace:*"` admitted).

The lenient `Cap.Parser.parse/1` exists for runtime / CLI input where the cap may reference plugins not yet loaded — it falls back gracefully (same behavior as today's `Capability.Parser`).

The grammar is a strict extension of the existing `Capability.Parser` grammar — every string today's CLI accepts continues to work; the new `;ws=` suffix and explicit allowlist are additive.

### 5.5 Workspace iso separation (per OQ-CC-2)

`Behavior.workspace_scoped?/0` (new optional callback, default `true`):

```elixir
@doc """
Should dispatch enforce workspace isolation for actions on this Behavior?

Default `true` — caller's workspace must match target's workspace, OR
caller must hold `"cross-workspace:*"` cap, OR caller must be a member of
workspace://system.

Behaviors operating on cross-cutting data (e.g. system://, template://,
resource://) override to `false`. Examples today: `Behavior.Routing`
on System Kind, `Behavior.Template` on cross-workspace template lookup.
"""
@callback workspace_scoped?() :: boolean()
```

Dispatch step 5.6 reads this callback in place of the cap struct's `workspace_uri: :any` predicate:

```elixir
defp workspace_isolation_check(behavior, target, ctx) do
  if behavior.workspace_scoped?() do
    caller_ws = workspace_of_caller(ctx.caller)
    target_ws = Ezagent.URI.workspace_of(target)
    snapshot_caps = ctx.caps_snapshot.caps  # r2 HIGH-3 — snapshot, not live

    cond do
      caller_ws == :any -> :ok                                          # system caller
      target_ws == :any -> :ok                                          # cross-cutting target
      caller_ws == target_ws -> :ok                                     # same workspace
      Enum.member?(snapshot_caps, "cross-workspace:*") -> :ok           # explicit bypass cap
      caller_in_system_workspace?(ctx.caller) -> :ok                    # membership bypass (Phase 9 PR-8)
      true -> {:error, :cross_workspace_denied}
    end
  else
    :ok
  end
end
```

The cap struct's `workspace_uri` field is gone; iso is per-Behavior data + per-caller membership + the `;ws=<workspace_uri>` cap suffix (which the §5.5 `Cap.matches?/2` consults so a cap scoped to workspace A cannot authorize an action in workspace B — see §5.4 for matching semantics).

### 5.6 FacadeNonceTable interaction (PRESERVED)

External-mirror-audit's `FacadeNonceTable` (`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/facade_nonce_table.ex`) is UNCHANGED. The nonce protects the trust-transfer between the facade Task and the action body — it's a separate forgery-resistance primitive that operates BELOW the cap check. After this SPEC:

- Facade still runs Gates 1, 2, 3 via the new `holds_cap?` flow (3 cap-check call sites updated to read `required_caps/0` + `Kind.holds_cap?/2`).
- Gate 4 (target_ownership_check) unchanged — it's adapter I/O, not a cap check.
- FacadeNonceTable claim/consume unchanged.
- Dispatch step 5.5 still runs as defense-in-depth — invariant test from external-mirror-audit §6 continues to verify.

### 5.7 Migration of cap-check call sites

| Surface | Count | Migration |
|---|---|---|
| `Capability.matches?/2` direct calls | 4 prod + ~30 test | Delete prod calls (dispatch handles); test calls move to `Ezagent.Cap.matches?/2` |
| `CapabilityRegistry.register/3` calls | 5 sites | Delete — Behaviors declare via `required_caps/0` callback; compiler reads it |
| `CapabilityRegistry.needed_for/3` calls | 0 prod (only dispatch internals) | Delete with the module |
| `CapabilityRegistry.lookup_subject/2` calls | 4 sites (mostly tests asserting registration) | Delete; tests migrate to `Behavior.required_caps()[:action]` direct call |
| `Identity.list_caps_for/1` calls | 22 sites (LV mounts, MCPServer, BindingPolicy, etc.) | DELETE the function; dispatch reads slice directly. LV mounts that needed the list for *display* use new `Identity.read_caps_for_display/1` (read-only, no dispatch, returns `[String.t()]`) |
| `Identity.grant_cap/3` calls | ~10 sites | Replace with `Ezagent.Entity.add_cap/3(entity_uri, cap_string, granter_uri)` — direct slice mutation through dispatch on `Behavior.IdentityAdmin.invoke(:grant_cap, ...)` (the cap_string is the arg; dispatch step 5.5 verifies granter holds `"user.identity_admin.grant_cap"` for the data owner per data-ownership-v2) |
| `Identity.revoke_cap/3` calls | ~5 sites | Same as grant_cap pattern |
| Inline `MapSet.member?(caps, ...)` cap checks in plugin code | ~8 sites (LV, Feishu, NP, CC) | DELETE — these are the symptoms of cap-check leaking into non-dispatch surfaces. Route through dispatch on the relevant Behavior |
| `Behavior.Identity.check_grant_authorized/2` (200 LOC) | 1 module | Move logic INTO dispatch step 5.5 — data-ownership-v2's owner-check is now part of the standard cap-check path |
| `Behavior.ExternalMirror` facade Gates 1, 2, 3 | 1 module | Update to read `required_caps/0` + `holds_cap?/2`; logic shape preserved |

Total touched files: ~50-70 across PRs CC-2a..2d (which we sub-split per §7.2 below).

### 5.8 Data migration

Existing `users.caps_json` rows store `[%{kind, behavior, instance, workspace_uri, granted_by, granted_at}]`. One-shot conversion script (`apps/ezagent_core/priv/repo/data_migrations/20260525_caps_to_strings.exs`).

**r2 HIGH-1 fix — workspace dimension MUST be preserved.** r1's migration dropped `workspace_uri` on the assumption that `instance` would carry it. But for caps with `instance: "any"` AND concrete `workspace_uri` (the `User.default_caps/1` shape is the canonical example), the converted string `"session.*"` is GLOBALLY scoped — silently widening a workspace-A grant into authorization on workspace B. The fix uses the `;ws=<workspace_uri>` suffix from §5.4 to preserve the scope:

```elixir
defmodule CapMigration do
  # Admin's structural cap: all dimensions :any → the allowlisted special.
  def convert(%{"kind" => "any", "behavior" => "any", "instance" => "any",
                "workspace_uri" => "any"}), do: "*"

  # Admin's cross-workspace cap shape (rare).
  def convert(%{"kind" => "any", "behavior" => "any", "instance" => "any",
                "workspace_uri" => ws}) when ws != "any" do
    # Even admin gets workspace-pinned if the original was workspace-scoped.
    # (Pathological — admin caps SHOULD all be :any. Migration preserves
    # whatever was on disk; an invariant test catches stragglers.)
    "*;ws=#{ws}"
  end

  # Common case: kind+behavior-scoped, no specific instance,
  # original was workspace-scoped (e.g. User.default_caps shape).
  def convert(%{"kind" => kind, "behavior" => behavior, "instance" => "any",
                "workspace_uri" => ws}) when ws != "any" do
    "#{kind}.#{deatomize_behavior(behavior)};ws=#{ws}"
  end

  # Kind+behavior-scoped, cross-workspace (rare; explicit admin grant).
  def convert(%{"kind" => kind, "behavior" => behavior, "instance" => "any",
                "workspace_uri" => "any"}) do
    "#{kind}.#{deatomize_behavior(behavior)}"
  end

  # Instance-scoped: instance URI carries workspace structurally.
  # Assert workspace_uri matches the instance URI's workspace OR is :any
  # — else the original cap was malformed and we hard-raise (let-it-crash).
  def convert(%{"kind" => kind, "behavior" => behavior, "instance" => instance_str,
                "workspace_uri" => ws}) do
    instance_ws = Ezagent.URI.workspace_of_string(instance_str)

    cond do
      ws == "any" or ws == instance_ws ->
        "#{kind}.#{deatomize_behavior(behavior)}@#{instance_str}"

      true ->
        raise "Cap migration sanity check failed: cap on instance #{instance_str} " <>
              "(workspace #{instance_ws}) has workspace_uri=#{ws} which does not " <>
              "match. Original cap is structurally malformed."
    end
  end

  defp deatomize_behavior("any"), do: "*"
  defp deatomize_behavior("Elixir.Ezagent.Behavior." <> name), do: Macro.underscore(name)
end
```

Provenance (`granted_by`, `granted_at`) is dropped per §0 decision OQ-CC-6.

The script:
1. Reads every `users` row.
2. JSON-decodes `caps_json`.
3. Converts each cap map to a string via `CapMigration.convert/1`.
4. Writes back the new JSON list of strings.
5. Bumps a `caps_schema_version` column from `1` to `2`.

Application boot reads `caps_schema_version` — if `1`, refuses to start with a `MIGRATION_REQUIRED` log line. Per Phase 9 SPEC v3 §8 convention. Dev `mix ezagent.reset` regenerates fresh.

### 5.9 Plugin author flow (the north-star payoff)

After this SPEC, a plugin author adding `Plugin.CC` with a new "create session" action writes:

```elixir
defmodule Ezagent.Plugin.CC.Behavior.CreateSession do
  @behaviour Ezagent.Behavior

  @impl true
  def actions, do: [:create]

  @impl true
  def required_caps, do: %{create: "session.create_session.create"}

  @impl true
  def workspace_scoped?, do: true

  @impl true
  def invoke(:create, slice, args, ctx) do
    # Plain action body. NO cap-check code. Dispatch already gated.
    # NO admin-fallback. ctx.caller is the real principal.
    # NO ambient authority. The Session being created carries
    # ctx.caller as its created_by field, structurally.
    new_session = build_session(args, created_by: ctx.caller)
    {:ok, Map.put(slice, :sessions, [new_session | slice.sessions])}
  end
end
```

Total cap-system contact surface for the plugin author: 2 callback lines (`required_caps/0`, `workspace_scoped?/0`). They never touch `CapabilityRegistry` (deleted), `Capability` struct (deleted), `Identity.grant_cap` (renamed + dispatch-only), `User.admin_caps` (deleted).

This IS the north-star: plugin authors stay out of core (memory `feedback_north_star_plugin_isolation`).

---

## 6. Issue 3 — Compile-time enforcement via `:ezagent_plugin_check`

### 6.1 Extension to existing compiler

`apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex` grows three new checks (~80 LOC):

```elixir
# New check 8 — every @behaviour Ezagent.Behavior module exports
# required_caps/0
defp check_required_caps_exported(diagnostics, plugin_module) do
  plugin_module.behaviors()
  |> Enum.map(fn {_kind, _action, behavior} -> behavior end)
  |> Enum.uniq()
  |> Enum.reduce(diagnostics, fn behavior, acc ->
    cond do
      not function_exported?(behavior, :required_caps, 0) ->
        [diagnostic("#{inspect(behavior)} (a declared Behavior) does not " <>
          "export required_caps/0. Every Behavior MUST declare per-action " <>
          "cap strings (caps-cleanup-v1 SPEC §5.1).") | acc]

      true ->
        acc
    end
  end)
end

# New check 9 — required_caps/0 keys equal actions/0
defp check_required_caps_keys_match_actions(diagnostics, plugin_module) do
  plugin_module.behaviors()
  |> Enum.map(fn {_, _, b} -> b end)
  |> Enum.uniq()
  |> Enum.filter(&function_exported?(&1, :required_caps, 0))
  |> Enum.reduce(diagnostics, fn behavior, acc ->
    declared_actions = MapSet.new(behavior.actions())
    cap_keys = MapSet.new(Map.keys(behavior.required_caps()))

    cond do
      declared_actions == cap_keys -> acc

      true ->
        missing = MapSet.difference(declared_actions, cap_keys)
        extra = MapSet.difference(cap_keys, declared_actions)
        [diagnostic("#{inspect(behavior)}: required_caps/0 keys must " <>
          "equal actions/0 exactly. Missing: #{inspect(MapSet.to_list(missing))}; " <>
          "extra: #{inspect(MapSet.to_list(extra))} (SPEC §6).") | acc]
    end
  end)
end

# New check 10 — every required_caps/0 value parses with the strict
# cap parser AND cross-validates against the declaring Behavior/Kind
# (r2 HIGH-4 fix — was "is_binary?" only)
defp check_required_caps_values_parse_strict(diagnostics, plugin_module) do
  plugin_module.behaviors()
  |> Enum.uniq_by(fn {_, _, b} -> b end)
  |> Enum.filter(fn {_, _, b} -> function_exported?(b, :required_caps, 0) end)
  |> Enum.reduce(diagnostics, fn {kind, _action, behavior}, acc ->
    Enum.reduce(behavior.required_caps(), acc, fn {action, cap_str}, inner_acc ->
      cond do
        not is_binary(cap_str) ->
          [diagnostic("#{inspect(behavior)}: required_caps/0[#{inspect(action)}] " <>
            "is #{inspect(cap_str)}; must be a binary cap string (SPEC §6).") | inner_acc]

        true ->
          case Ezagent.Cap.Parser.parse_strict(cap_str,
                  expected_kind: kind, expected_behavior: behavior, expected_action: action) do
            :ok -> inner_acc

            {:error, reason} ->
              [diagnostic("#{inspect(behavior)}: required_caps/0[#{inspect(action)}] " <>
                "= #{inspect(cap_str)} fails strict parse: #{inspect(reason)} " <>
                "(SPEC §5.4 + §6).") | inner_acc]
          end
      end
    end)
  end)
end

# New check 11 — every `system://` URI literal in app source must
# appear in Ezagent.SystemPrincipal.Catalog (r2 HIGH-2 fix)
defp check_system_principals_in_catalog(diagnostics) do
  source_files = Path.wildcard("lib/**/*.ex")

  system_uri_pattern = ~r/"(system:\/\/[a-zA-Z0-9_\-\/]+)"/

  unauthorized =
    source_files
    |> Enum.flat_map(fn file ->
      content = File.read!(file)

      Regex.scan(system_uri_pattern, content, capture: :all_but_first)
      |> Enum.map(fn [uri] -> {file, uri} end)
    end)
    |> Enum.reject(fn {_file, uri} -> Ezagent.SystemPrincipal.Catalog.member?(uri) end)

  if unauthorized == [] do
    diagnostics
  else
    msg = Enum.map_join(unauthorized, "\n  ", fn {f, u} -> "#{u} in #{f}" end)

    [diagnostic("System principal URIs found in source that are NOT in " <>
      "Ezagent.SystemPrincipal.Catalog. Add to the catalog (caps-cleanup-v1 §4.2) " <>
      "OR remove the literal:\n  #{msg}") | diagnostics]
  end
end
```

Wired into the existing `run/1` pipeline:

```elixir
diagnostics =
  []
  |> check_uses_behaviour(plugin_module)
  |> check_declared_modules(plugin_module)
  |> check_agent_flavors(plugin_module)
  |> check_adapters(plugin_module)
  |> check_spawns_empty(plugin_module)
  |> check_config_surface(plugin_module)
  |> check_no_direct_registry_calls()
  |> check_required_caps_exported(plugin_module)              # NEW (8)
  |> check_required_caps_keys_match_actions(plugin_module)    # NEW (9)
  |> check_required_caps_values_parse_strict(plugin_module)   # NEW (10, r2)
  |> check_system_principals_in_catalog()                     # NEW (11, r2)
```

Plus `ezagent_core` itself needs a parallel check for `@behaviour Ezagent.Behavior` modules that live in `ezagent_core` / `ezagent_domain_*` (the compiler runs against EACH app, with the same wiring). Each domain app already wires `:ezagent_plugin_check` in `mix.exs` (or gets it added in PR-CC-3).

### 6.2 Failure modes

- Missing `required_caps/0` → build fails with `(ezagent_plugin_check) Ezagent.Behavior.X (a declared Behavior) does not export required_caps/0...`
- Key mismatch with `actions/0` → build fails with diff of missing + extra keys.
- Non-string value → build fails listing the bad entries.
- **Strict-parse failure (r2 HIGH-4)** — cap string with unknown kind atom / behavior atom / action atom, or malformed `@instance_uri` / `;ws=` suffix, or unrecognized special string fails the build with the parser's `{:error, reason}`. The runtime warn-only typo check from r1 §10.3 is DELETED — typos fail at compile time.
- **Uncataloged `system://` URI (r2 HIGH-2)** — any source file containing a `system://...` literal not in `SystemPrincipal.Catalog` fails the build.

Per memory `feedback_let_it_crash_no_workarounds`: NO warning + degrade. The build fails. CI catches it before merge.

---

## 7. Migration plan (3 PRs, ordered)

### 7.1 PR-CC-1 — Issue 1 (Ambient authority removal)

**Branch:** `feat/caps-cleanup-pr1-ambient-authority`
**Effort:** 3-5 days (focused; 14 principals × seed + ~30 prod call sites to migrate).

Scope:
- Add `Ezagent.SystemPrincipal` module (§4.2).
- Seed 14 principals in their owning Application's `start/2` (§4.1).
- Migrate 30 prod call sites from `User.admin_caps()` → `SystemPrincipal.caps(...)` per the catalog.
- Migrate 21 test sites — most become `SystemPrincipal.test_principal("test-xyz")` (a test-only helper that mints a principal with arbitrary caps).
- DELETE `Ezagent.Entity.User.admin_caps/0` (let-it-crash — build fails on remaining call sites; sweep follows).
- Add invariant test §4.5.
- Audit log already accepts non-`entity://` URIs — no schema change.

Acceptance:
- `grep -rn "User.admin_caps" apps/ | grep -v test/support` returns 0 results.
- All existing tests pass.
- Invariant test §4.5 passes.
- `/admin/audit` shows `system://` callers for at least 3 distinct system operations.

Independent of PR-CC-2 — can ship alone.

### 7.2 PR-CC-2 — Issue 2 (Caps at Behavior × Entity)

The biggest PR. Sub-split into 4 sub-PRs to keep each reviewable:

**PR-CC-2a — Add new primitives (additive, no deletions):**
- `Ezagent.Cap.matches?/2` (the string matcher, §5.2).
- `Behavior.required_caps/0` callback declaration in `Ezagent.Behavior` (mandatory; new optional callback initially).
- `Behavior.workspace_scoped?/0` callback (optional, default true).
- `Kind.holds_cap?/2` default impl (additive).
- Every Behavior implements `required_caps/0` (29 Behaviors × 2-line addition each). At this point both old and new paths exist.

**PR-CC-2b — Switch dispatch to new path:**
- Dispatch step 5.5 rewritten per §5.3 (read `required_caps/0`, call `holds_cap?/2`).
- Dispatch step 5.6 rewritten per §5.5 (read `workspace_scoped?/0`, drop cap struct's workspace field reads).
- All tests pass with NEW path. Old `Capability.matches?/2` still exists but unused.

**PR-CC-2c — Migration of caps slices + cap-check call sites:**
- Data migration script (§5.8) — wipe-dev, run script on staging/prod.
- Bump `caps_schema_version` to 2.
- Migrate all `Identity.list_caps_for/1` call sites (22) per §5.7 table.
- Migrate all `Identity.grant_cap/3` call sites (~10) per table.
- Migrate inline `MapSet.member?` cap checks in plugin LVs.
- Update `Behavior.Identity.invoke(:grant_cap, ...)` to consume cap strings.
- Update `Behavior.ExternalMirror` facade Gates 1, 2, 3 to new API (preserve FacadeNonceTable).

**PR-CC-2d — Delete old machinery:**
- Delete `Ezagent.Capability` struct (`apps/ezagent_core/lib/ezagent/capability.ex`).
- Delete `Ezagent.CapabilityRegistry` (`apps/ezagent_core/lib/ezagent/capability_registry.ex` + `apps/ezagent_core/lib/ezagent/capability_registry/`).
- Delete `Ezagent.Identity.list_caps_for/1`, `grant_cap/3`, `revoke_cap/3` (replace exports with `Ezagent.Entity.add_cap/3`, `remove_cap/3`, `read_caps_for_display/1`).
- Delete `Behavior.cap_subjects/0` callback (per OQ-CC-3 collapse — replaced by `required_caps/0`).
- Delete `Behavior.dispatchable?/0` callback (per OQ-CC-3 — cap-only Behaviors removed; Presence + Sandbox become normal dispatchable Behaviors).
- Update `Capability.Parser` → `Cap.Parser` (CLI grammar same).

**Effort:** 2 weeks across the 4 sub-PRs (CC-2a = 2 days, CC-2b = 2 days, CC-2c = 5 days, CC-2d = 2 days).

Acceptance per sub-PR:
- 2a: All Behaviors export `required_caps/0`; CI green; nothing dispatch-side changed yet.
- 2b: Dispatch uses new path; `[:ezagent, :authz, :granted]` telemetry has new shape with `needed_cap` as string.
- 2c: `caps_schema_version == 2` on all envs; old cap-check call sites all migrated; grep §G2 returns 0 results.
- 2d: Old modules deleted; build green; grep `Capability\.matches\|CapabilityRegistry\|admin_caps` returns 0 results.

### 7.3 PR-CC-3 — Issue 3 (Compile-time enforcement)

**Branch:** `feat/caps-cleanup-pr3-compile-time-gate`
**Effort:** 1-2 days.

Scope:
- Add the 3 new checks per §6.1 to `:ezagent_plugin_check` compiler.
- Wire the compiler into every domain app's `mix.exs` (those that don't already have it — audit shows most do, but `ezagent_core` itself does not run the gate against its own Behaviors; the new checks should run against core + domains too).
- Verify build fails when:
  - A Behavior is added with `actions: [:foo]` but no `:foo` key in `required_caps/0`.
  - A Behavior's `required_caps/0` returns `%{foo: :not_a_string}`.

Acceptance:
- Adding a deliberately-broken Behavior to a fixture app fails the build with a precise diagnostic.
- All existing Behaviors pass the new checks (PR-CC-2a already added `required_caps/0` to all of them).

---

## 8. Acceptance criteria (per-PR)

| PR | Gate |
|---|---|
| CC-1 | (a) Invariant `no_admin_caps_fallback_test.exs` passes; (b) `grep -rn "User.admin_caps" apps/lib` returns 0 lines; (c) audit log on `/admin/audit` shows `system://` URI for boot-reconciler dispatch within 5 seconds of fresh boot |
| CC-2a | All 29 Behaviors export `required_caps/0`; `mix test apps/ezagent_core` green |
| CC-2b | Dispatch `[:ezagent, :authz, :granted]` telemetry payload includes `needed_cap` as a binary; old `Capability.matches?/2` invoked 0 times in a full test run (verify via :telemetry hook in invariant test) |
| CC-2c | (a) `caps_schema_version == 2`; (b) all 22 `list_caps_for/1` call sites removed (grep `Identity\.list_caps_for` outside test/support returns 0); (c) existing user with seeded caps still authorized for their session post-migration (e2e test); (d) **§0 decisions stamped `Allen-approved YYYY-MM-DD`** — PR-CC-2c is BLOCKED at review until every decision row in §0 carries Allen's explicit stamp (r2 MEDIUM-5 fix); (e) invariant test §9.4 passes (no migration widening) |
| CC-2d | `Capability`, `CapabilityRegistry`, `Identity.{list_caps_for,grant_cap,revoke_cap}` modules / functions deleted; `mix compile` green; full test suite green |
| CC-3 | Deliberately-broken fixture Behavior fails build with `(ezagent_plugin_check)` diagnostic; existing Behaviors all pass |

---

## 9. Invariant tests (the architectural gates per `feedback_completion_requires_invariant_test`)

Each issue's structural goal is gated by a test that fails when the goal is unmet — these are the locks against future regression.

### 9.1 G1 — Ambient authority gone

`apps/ezagent_core/test/invariants/no_admin_caps_fallback_test.exs` (§4.5):
1. No production file calls `User.admin_caps/0`.
2. `User` module does not export `admin_caps/0`.

### 9.2 G2 — Caps only at Behavior × Entity boundary

`apps/ezagent_core/test/invariants/caps_only_at_boundary_test.exs` (NEW):

```elixir
test "no production module calls Capability.matches? / cap_subjects / list_caps_for / grant_cap" do
  allowed_paths = [
    "apps/ezagent_core/lib/ezagent/behavior",       # Behavior callback definitions
    "apps/ezagent_core/lib/ezagent/entity",         # Entity holds_cap? default
    "apps/ezagent_core/lib/ezagent/invocation",     # Dispatch
    "apps/ezagent_core/lib/ezagent/kind",           # Kind runtime
    "apps/ezagent_core/lib/ezagent/cap.ex",         # The matcher itself
    "apps/ezagent_domain_identity/lib/ezagent"      # Identity facade (read-only path)
  ]

  offenders =
    Path.wildcard("apps/*/lib/**/*.ex")
    |> Enum.reject(fn p ->
      String.contains?(p, "test/support") or
        Enum.any?(allowed_paths, &String.starts_with?(p, &1))
    end)
    |> Enum.filter(fn p ->
      File.read!(p) =~ ~r/Ezagent\.Capability\.(matches|cap_for_action)|cap_subjects\(|list_caps_for\(|Identity\.grant_cap\(/
    end)

  assert offenders == [],
         "caps escaped the Behavior×Entity boundary into: #{inspect(offenders)}"
end
```

### 9.3 G3 — Compile-time enforcement is non-bypassable

`apps/ezagent_core/test/invariants/required_caps_compile_gate_test.exs` (NEW):

```elixir
test "build fails when a Behavior omits required_caps/0" do
  # Create a fixture app under tmp/, copy a minimal mix.exs + a Behavior
  # with actions/0 but no required_caps/0, run mix compile, assert the
  # build fails with the ezagent_plugin_check diagnostic.
  fixture = create_broken_fixture(omit: :required_caps)
  assert {output, 1} = System.cmd("mix", ["compile"], cd: fixture, stderr_to_stdout: true)
  assert output =~ "(ezagent_plugin_check)"
  assert output =~ "does not export required_caps/0"
end

test "build fails when required_caps/0 keys differ from actions/0" do
  fixture = create_broken_fixture(mismatch_keys: true)
  assert {output, 1} = System.cmd("mix", ["compile"], cd: fixture, stderr_to_stdout: true)
  assert output =~ "must equal actions/0 exactly"
end

test "build fails when required_caps/0 has a non-string value" do
  fixture = create_broken_fixture(non_string_value: true)
  assert {output, 1} = System.cmd("mix", ["compile"], cd: fixture, stderr_to_stdout: true)
  assert output =~ "must be cap strings"
end
```

The 3 sub-tests cover the 3 failure modes from §6.2. Each spawns a real `mix compile` on a fixture to verify the gate is non-bypassable.

### 9.4 — Workspace dimension preserved across migration (r2 HIGH-1)

`apps/ezagent_core/test/invariants/cap_migration_no_widening_test.exs` (NEW):

```elixir
test "no migrated cap authorizes a workspace it was not originally scoped to" do
  # Read pre-migration snapshot (a fixture file representing the
  # actual schema-v1 caps_json shape from prod) + post-migration
  # output. For every (user, original_cap) → migrated_cap pair,
  # assert that migrated_cap.matches?(needed) ⇒
  # original_cap.matches?(needed) for every needed shape involving
  # a different workspace.

  pre = load_fixture("pre_migration_caps_v1.json")
  post = CapMigration.run(pre)

  for {user_uri, old_caps} <- pre, {user_uri_p, new_caps} <- post, user_uri == user_uri_p do
    Enum.zip(old_caps, new_caps)
    |> Enum.each(fn {old, new} ->
      # The cross-workspace probe: for every workspace OTHER than the
      # original's workspace_uri, the migrated cap MUST NOT authorize.
      other_ws = "workspace://probe-#{:rand.uniform(1_000_000)}"
      needed = "session.chat.send@session://default/#{other_ws}/probe"

      if old["workspace_uri"] != "any" do
        refute Ezagent.Cap.matches?(new, needed),
               "Cap migration widened: original cap #{inspect(old)} was scoped to " <>
               "workspace #{old["workspace_uri"]} but migrated cap #{inspect(new)} " <>
               "now authorizes #{needed} (different workspace)."
      end
    end)
  end
end
```

This is the structural lock against r2 HIGH-1's regression.

### 9.5 — System principal catalog closed (r2 HIGH-2)

`apps/ezagent_core/test/invariants/system_principals_in_catalog_test.exs` (NEW):

```elixir
test "every system:// URI literal in source is in SystemPrincipal.Catalog" do
  source_files = Path.wildcard("apps/*/lib/**/*.ex")

  uri_pattern = ~r/"(system:\/\/[a-zA-Z0-9_\-\/]+)"/

  found =
    source_files
    |> Enum.flat_map(fn file ->
      Regex.scan(uri_pattern, File.read!(file), capture: :all_but_first)
      |> Enum.map(fn [uri] -> {file, uri} end)
    end)

  uncataloged = Enum.reject(found, fn {_f, u} ->
    Ezagent.SystemPrincipal.Catalog.member?(u)
  end)

  assert uncataloged == [],
         "Uncataloged system:// URIs found:\n  " <>
         Enum.map_join(uncataloged, "\n  ", fn {f, u} -> "#{u} in #{f}" end)
end

test "SystemPrincipal.ensure rejects URIs not in catalog" do
  assert_raise ArgumentError, ~r/not in SystemPrincipal.Catalog/, fn ->
    Ezagent.SystemPrincipal.ensure(URI.parse("system://hypothetical-ambient-authority"))
  end
end
```

### 9.6 — Cap snapshot CAS for cap-mutating actions (r2 HIGH-3)

`apps/ezagent_core/test/invariants/cap_snapshot_cas_test.exs` (NEW):

```elixir
test "concurrent grant_cap dispatches detect snapshot drift" do
  # Spawn caller-A with `"user.identity_admin.grant_cap"` cap on target user T.
  # Open two dispatches D1 + D2 that both want to call grant_cap on T,
  # at the same revision. D1 commits first, bumping T's revision.
  # D2's invoke wrapper (step 8.5 CAS) MUST return {:error, :cap_snapshot_stale}.

  {caller, target} = setup_users()
  rev = Ezagent.Identity.get_revision(caller)

  inv1 = build_invocation(caller, target, :grant_cap, %{cap: "session.chat.send"}, rev)
  inv2 = build_invocation(caller, target, :grant_cap, %{cap: "session.chat.join"}, rev)

  # Dispatch D1 inline, then D2 — D2's snapshot should now be stale.
  assert :ok = Invocation.dispatch(inv1)
  assert {:error, :cap_snapshot_stale} = Invocation.dispatch(inv2)
end

test "non-cap-mutating dispatch does not CAS-fail across cap mutations" do
  # The 99% case: send a chat message; concurrent grant_cap on the
  # caller's slice must NOT cause the chat dispatch to fail.
  {caller, target_session} = setup_chat_user_session()
  rev = Ezagent.Identity.get_revision(caller)

  chat_inv = build_chat_send_invocation(caller, target_session, rev)

  # Concurrently bump caller's revision by granting a new cap.
  Task.async(fn -> grant_unrelated_cap(caller) end)

  assert :ok = Invocation.dispatch(chat_inv)
end
```

---

## 10. Risks + rollback

### 10.1 Risk — PR-CC-2 mid-flight conflicts with concurrent SPECs

`feat/workspace-default-to-system-impl` (#335) and `feat/agent-duplicate-simple-from-flag` (#338) are in flight. Both touch caps adjacently. Mitigation: PR-CC-1 is independent and can land first; PR-CC-2 waits for those to merge OR coordinates a synchronized rebase.

### 10.2 Risk — Data migration on production stale state

If a production user has a cap shape unforeseen by `CapMigration.convert/1`, the script raises. Mitigation: dry-run the script on a snapshot first; the script logs every conversion; failures are reported with the offending row UUID for manual fixup. Per `feedback_let_it_crash_no_workarounds`, no fallback — better to surface unknown shapes than silently default.

### 10.3 Risk — Cap-string typos (CLOSED by r2 HIGH-4 fix)

**RESOLVED in r2.** r1 §10.3 proposed a runtime warn-only typo check. Codex r1 HIGH-4 correctly identified this as too weak — the spec's compile-time enforcement goal demands that `"session.chta.send"` fail at build time. r2 §6.1 check 10 (`check_required_caps_values_parse_strict`) calls `Ezagent.Cap.Parser.parse_strict/1` which cross-validates the cap's `kind` segment against the parent Kind's `type_name/0`, the `behavior` segment against `state_slice/0`, and the `action` segment against the Behavior's `actions/0`. Typos fail the build with a precise diagnostic. The runtime warning path is DELETED.

### 10.4 Rollback

Each sub-PR is rebase-and-revert-clean. The migration script is one-way (no undo) — `caps_schema_version` bump is a Rubicon. Rollback past PR-CC-2c requires DB restore, not a code revert. This is acceptable because the wipe-and-rebuild pattern matches Phase 9 SPEC v3 §8 and the deployment story for that was Allen's explicit choice.

---

## 11. Out-of-scope (futures)

- **Cap provenance audit table** — if a future use case needs "who granted me cap X", a `cap_grants(grantee_uri, cap_string, granter_uri, granted_at)` table lands additively without changing the cap shape.
- **Role bundles** — operator UX for granting "frontend-admin" as a named bundle of cap strings is a UI feature, not a structural change. The cap shape is unchanged; the bundle is just a server-side expansion at grant time.
- **Cross-workspace cap delegation** — today only admin holds `"cross-workspace:*"`. A future SPEC may allow per-Behavior cross-workspace grants (e.g. "User-X may dispatch chat actions across workspaces"). Would land as a new cap-string syntax (`"session.chat@*"` perhaps); orthogonal to this SPEC.
- **Cap expiration / TTL** — caps today are persistent. If TTL becomes needed, the cap string format gains a `;expires=<iso8601>` suffix; the matcher checks at runtime. Orthogonal.

---

## 12. Sequencing for r3 codex review (if needed)

r1 codex returned `needs-attention` (4 HIGH + 1 MEDIUM). r2 (this revision) closes all five structurally per §0a. The round-2 cap per dispatch prompt allows ONE more codex cycle.

If r2 codex still HIGH/CRIT:
- **Workspace dimension** (§5.4 `;ws=` suffix, §5.8 migration, §9.4 invariant) — review whether the suffix grammar is unambiguous and the migration's `instance_ws` derivation handles all real cap shapes (specifically `system://` caller URIs that have `:any` workspace).
- **Catalog enforceability** (§4.2 / §6.1 check 11, §9.5 invariant) — review whether the grep pattern catches every literal form (string concatenation, sigils, atom-interpolated URIs).
- **Snapshot/CAS contract** (§5.3 step 5.0a + 8.5, §9.6 invariant) — review whether `:cap_snapshot_stale` retry semantics propagate correctly to facade gates (ExternalMirror's 4-gate flow has multi-step state).
- **Strict parser** (§5.4, §6.1 check 10) — review whether plugin-boot-order dependency is handled: a plugin author's `required_caps` may reference a Behavior from a sibling plugin not yet loaded at compile time.

Escalate to Allen if r3 still HIGH/CRIT — likely indicates a deeper architectural disagreement that needs a brainstorm reset. Per memory `feedback_spec_codex_adversarial_review`.
