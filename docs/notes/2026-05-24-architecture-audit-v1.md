# Architecture Audit — 2026-05-24 (2-day session)

> Scope: PRs #287 — #296 (10 PRs merged 2026-05-22 → 2026-05-24). Read-only audit; no production code modified.
> Skills loaded: `ezagent-developer` (P1-P27 + 14 invariants), `elixir-phoenix-helper`.
> Method: read each PR's full diff, checked against P1 (plugin-isolation), P9 (tier ownership "reads what data"), P11 (no plugin-owned schemes), P14 (dispatch is the only path), P15 (cap modules), P17 (workspace structure), tier table at SKILL §"Boundary rules summary".

## Summary verdict

**Pass-with-caveats.** All 10 PRs respect the core/domain/plugin tier model. Dispatch-only, cap-checked, single-source-of-truth properties are preserved. Two findings worth deliberate follow-up: (1) `Ezagent.Capability.cross_workspace?/2` in core now uses runtime `apply/3` to reach `Ezagent.Workspace.Store` (domain) — same lazy-load pattern identity → workspace uses, but it's the first core → domain runtime reach and deserves an explicit comment in the layer-purity invariant; (2) `:install_from_source_not_implemented` for `toggle_extension(_, _, true)` is a documented stub the LV exposes — fine for PR3 scope, but it's a user-visible "deferred" the next phase must close per `feedback_dont_defer_what_is_solvable_now`.

`apps/ezagent_core/test/invariants/layer_purity_test.exs` still passes (2/2).

---

## Per-PR audit

### PR #287 (PR1: lift `:fork` to `Behavior.Template`)

Files: `apps/ezagent_domain_chat/lib/ezagent/behavior/template.ex`, `entity/agent_template.ex`, `entity/session_template.ex`, +2 tests.

- **Tier compliance**: PASS. All changes inside `ezagent_domain_chat` (Tier 2). New `parent_template_uri` slice field stays in `AgentTemplate` slice; no core change required (slice is opaque blob).
- **Dispatch & cap (P14, P15)**: PASS. `:fork` action goes through `Ezagent.Invocation.dispatch/1` (caller never imports Behavior). Owner-cap grant uses the documented `{:within_workspace, %URI{}}` shape — module reference for `behavior:` (not atom shorthand). Cap preflight delegated to dispatch CapBAC against parent URI.
- **Plugin-isolation (P1)**: PASS. The Kind-specific branching (`SessionTemplate` vs `AgentTemplate`) is on `ctx[:kind_module]` — branches keyed off the *core Kind* registered for that Behavior, not plugin identity. A plugin that ships a new Template Kind would extend this with one branch in `behavior/template.ex` — acceptable since `Behavior.Template` IS the generic Template contract owner. (Plugins that just register Behaviors on existing Template Kinds need zero changes.)
- **Single-source-of-truth (P3)**: PASS. `parent_template_uri` lineage is set in slice ONCE on fork; no parallel store.
- **Owner-cap grant via dispatch (P14)**: PASS — grants `identity.grant_cap` on the owner's User Kind via dispatch, not direct write.
- **Invariant test (P6)**: PASS. New `template_fork_lineage_test.exs` (4 tests) asserts the lineage property fails when violated.
- **Concerns / followups**: minor — `fork_session_template/3` calls `SessionTemplate.persist_version/3` directly (in-module helper), bypassing `:write` dispatch. The comment justifies this as "deadlock-avoidance: parent's slice already in hand," identical to `:instantiate`'s in-process path. Acceptable but worth documenting as the second canonical case of "in-process write w/o self-dispatch."

### PR #288 (PR2: `Behavior.Sandbox` + `Kind.Template` extension callbacks)

Files: `apps/ezagent_core/lib/ezagent/behavior/sandbox.ex` (new, 389 LOC), `kind/template.ex` (+3 optional callbacks), `domain_chat/lib/ezagent/entity/agent.ex` (adds Sandbox to behaviors), `application.ex` (registers cap rows for `Sandbox` actions), +2 tests + invariant.

- **Tier compliance**: PASS. `Behavior.Sandbox` lives in `apps/ezagent_core/lib/ezagent/behavior/` and references ONLY core primitives (`Ezagent.KindRegistry`, `Ezagent.KindSupervisor`, `DynamicSupervisor`) + the optional Template Class callbacks declared on `Ezagent.Kind.Template`. No reach into any domain or plugin. Grep'd for `Ezagent.Entity.`, `ezagent_domain_*` — zero hits. Layer-purity test still 2/2.
- **Plugin-isolation (P1)**: PASS — exemplary. Sandbox's `:destroy` invokes `template_class.destroy_config_dir/2` via `function_exported?` + try/rescue/catch. Core knows nothing about cc / claude / plugin bundles. Echo / curl / np / generic_session opt out by omission; cc opts in. This is the canonical "plugin extends core via @optional_callbacks" pattern.
- **All-or-nothing invariant (P6)**: PASS. New `template_class_extension_contract_test.exs` enumerates every `@behaviour Ezagent.Kind.Template` impl in the umbrella, asserts each implements all-3-or-none-of-3 of the extension callbacks. Discovery walks `apps/*/mix.exs` so a new plugin app is auto-covered (round-3 fix vs hardcoded list).
- **Dispatch (P14)**: PASS. Sandbox actions registered via `CapabilityRegistry.register(Agent, action, Sandbox)`; `Agent.behaviors/0` now lists Sandbox so `init_slice/1` fires. All call paths go through `Ezagent.Invocation.dispatch/1`.
- **No silent drops (P22)**: PASS. Sandbox `:destroy` returns `{cleanup: :ok | {:error, reason}}` to the caller; FS failures preserve the slice (round-4 HIGH-2) so ops can retry rather than orphaning a credential dir.
- **Process-dict destroyed gate (P3-adjacent)**: NOTABLE. The "destroyed?" flag is stored in `Process.get/put` keyed by `{__MODULE__, :destroyed?}`, NOT the slice. Reason documented inline: a re-spawn of the same Agent URI must start clean — slice-stored gate would persist via `:on_terminate` snapshot and permanently brick the URI. This is the right call (slice rehydration would otherwise create a "ghost-locked URI" failure mode). Minor concern: process dict means the gate is invisible to introspection tooling — `:sys.get_state/1` would show the slice but not the gate. Consider exposing it via a `:read` meta field for ops.
- **Concerns / followups**: none material. The 20ms detached-Task termination pattern mirrors `Behavior.Lifecycle.schedule_termination/2` — consistent.

### PR #289 (PR3: cc plugin extensions + plugin-agnostic LV)

Files: `apps/ezagent_domain_chat/lib/ezagent/entity/agent.ex` (`record_sandbox_state/3`, `cleanup_partial_config_dirs/2`), `orchestrator/tools.ex` (migrate `terminate_worker` from `lifecycle.terminate` → `sandbox.destroy`), `ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` (+604 LOC: `agent_config_dir/1`, `list_extensions/1`, `toggle_extension/3`, `destroy_config_dir/2`, `create_agent_config_dir/2`), `ezagent_plugin_liveview/lib/.../agent_extensions_live.ex` (new, plugin-agnostic LV), router.

- **Tier compliance**: PASS.
  - cc plugin's three callback impls live in `apps/ezagent_plugin_cc/` and implement the `@behaviour Ezagent.Kind.Template` contract (Tier 3 → Tier 1 callback).
  - The LV is in `ezagent_plugin_liveview/` and uses `AgentFlavorRegistry.lookup(flavor)` to discover the Template Class dynamically. No `Ezagent.PluginCc.*` import — it would render any flavor that opts into the 3 callbacks.
- **Plugin-isolation (P1)**: PASS — north-star aligned. `AgentExtensionsLive`'s docstring explicitly says: "This LV knows NOTHING about Claude Code plugins / skills / MCP / hooks." A future Codex plugin shipping its own `template_class.list_extensions/1` gets this UI for free. The convention-over-config "extension" wording in `Kind.Template` callbacks (vs cc-specific "plugin/skill") was the right vocabulary pick.
- **Dispatch (P14)**: PASS. `record_sandbox_state/3` dispatches `sandbox.write_path` per worker via `Ezagent.Invocation`. LV's `sandbox_read/1` dispatches `sandbox.read`. LV's `toggle_extension` path directly calls `template_class.toggle_extension/3` (no dispatch) — but that's a plugin-internal FS write, not actor-to-actor. The CapBAC pre-check (`authorized_to_toggle?/1`) gates the mutation with the same cap shape Sandbox's `:write_path` would have required, so the surface IS cap-checked even though no dispatch happens.
- **Cap shape (P15)**: PASS. `authorized_to_toggle?/1` constructs `needed = %{kind: :agent, behavior: Ezagent.Behavior.Sandbox, instance: agent_uri, workspace_uri: ws}` — module reference, not atom; correct shape.
- **Path safety**: PASS — defense-in-depth. `toggle_extension/3` validates `extension_id` (no `/`, no `\`, no `.`/`..`) AND post-join checks `Path.expand(target)` starts with `Path.expand(plugins_dir) <> "/"`. `destroy_config_dir/2` compares the supplied path against `agent_config_dir(agent_uri)` and rejects on mismatch — prevents accidental `rm -rf /` if a caller passes a bogus path.
- **Partial-spawn rollback (P2 let-it-crash)**: PASS. `record_sandbox_state/3` failure triggers BOTH `undo_fresh_workers/1` AND `cleanup_partial_config_dirs/2` — the leak window (config dir created, slice never populated, agent never came up so `:destroy` couldn't run) is closed. Per-codex round notes, this took 4 rounds to converge.
- **Concerns / followups**:
  - `toggle_extension(_, _, true)` returns `{:error, :install_from_source_not_implemented}` — a documented deferral pending marketplace integration. The LV surfaces a clear message. Per `feedback_dont_defer_what_is_solvable_now`, log this in `docs/futures/todo.md` with a target PR; the deferral itself is reasonable (no marketplace exists yet).
  - The LV's `authorized_to_toggle?/1` re-implements a cap check by hand instead of using `Ezagent.Capability.cap_for_action/3`. Two paths drift if `cap_for_action/3` evolves. Recommend: refactor to `Ezagent.Capability.cap_for_action(Ezagent.Entity.Agent, :write_path, agent_uri)` then `matches?/2`. Small change, removes drift risk.

### PR #290 (workspaces LV system-leak fix)

Files: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/workspaces_live.ex` (1-line `list_persisted/0` → `list_visible/0`), +SPEC doc.

- **Tier compliance**: PASS. Plugin-tier read swap.
- **Single-source-of-truth (P3)**: PASS — the bug was a SoT divergence (workspace dropdown used `list_visible/0`, this LV used `list_persisted/0`). Now consistent.
- **Concerns / followups**: consider an invariant test asserting "every workspace-listing call site uses `list_visible/0` unless explicitly exempt" — same pattern as the Template Class extension contract test. Without it, the same bug re-lands in the next LV that lists workspaces.

### PR #291 (SPEC v2 doc only)

Files: `docs/superpowers/specs/2026-05-24-workspace-user-mental-model-v2.md` (+208 lines).

- **Tier compliance**: N/A (docs only).
- **Concerns / followups**: none. Doc-only PR that motivates PR-A through PR-D.

### PR #292 (PR-A: per-workspace `magic_link_rule`)

Files: migration, `Ezagent.Workspace.MagicLinkRule` (new, 217 LOC in `domain_workspace`), `Ezagent.Workspace` facade (+5 delegators), `Ezagent.Registration.email_allowed?/1` (new, in `domain_identity`), `session_controller.ex` (wire-in), test.

- **Tier compliance**: PASS. `MagicLinkRule` Ecto schema + reads/writes live in `domain_workspace` (Tier 2). `domain_identity` reaches `Ezagent.Workspace.any_workspace_accepts?/1` via runtime `apply/3` + `Code.ensure_loaded?` — this avoids the compile-time circular dep (workspace depends on identity for cap defaults; identity here needs workspace at runtime). The pattern was already established (same shape used elsewhere) — acceptable.
- **Plugin-isolation (P1)**: PASS. New table + Ecto schema; no plugin-specific knowledge.
- **Workspace structure (P17, P21)**: PASS. `workspace_uri` column is `TEXT NOT NULL`; rows index `:workspace_uri` + `[:rule_type, :rule_value]` for reverse lookup.
- **SQL pushdown (P2)**: PASS. `accepts_email?/2` uses `Repo.exists?` with an indexed predicate — was originally an in-memory scan (round-1 MEDIUM-1 fix); the scan would've been an auth-path DoS surface.
- **`invite_only` gating (P27)**: PASS. `invite_only` rows DO NOT grant access in `accepts_email?/2` (round-1 HIGH-2 fix); they're reserved for PR-D's token gate. The codex review caught this before merge — exactly the kind of silent-allowlist bypass `feedback_completion_requires_invariant_test` aims to prevent.
- **Concerns / followups**: none material. The lazy `apply/3` to call across `domain_identity → domain_workspace` is a code smell to track — if it grows beyond this + `email_allowed?/1` + `maybe_add_workspace_member/2`, the right structural fix is to extract a `domain_account` app neither depends on (the "shared user+workspace primitives" tier). Not urgent.

### PR #293 (PR-E: shared `AuthBoundaryLayout`)

Files: `apps/ezagent_web/lib/ezagent_web/auth_boundary_layout.ex` (new, +297 LOC), `registration_controller.ex` + `session_controller.ex` (CSS unified).

- **Tier compliance**: PASS. Pure presentation-layer refactor in `ezagent_web`.
- **Plugin-isolation (P1)**: N/A — auth surface lives in web layer.
- **Concerns / followups**: none. Removes 299 LOC duplication.

### PR #294 (PR-B: registration onboarding flow + `OnboardingController`)

Files: `apps/ezagent_domain_identity/lib/ezagent/registration.ex` (`create_principal/4` adds workspace arg), `magic_link_controller.ex` (redirect to `/onboarding/workspace`), `onboarding_controller.ex` (new, 312 LOC), `registration_controller.ex`, router, 3 controller tests.

- **Tier compliance**: PASS. `OnboardingController` lives in `ezagent_web` (presentation). `Registration.create_principal/4` adds workspace arg — domain function correctly taking workspace context. `maybe_add_workspace_member/2` uses the same lazy `apply/3` pattern as `email_allowed?/1`.
- **Workspace structure (P17, P20)**: PASS. User URIs are now `entity://user/<workspace>/<slug>` (3-segment per-tenant). Slug uniqueness is PER-workspace ("alice" in acme ≠ "alice" in beta).
- **Anti-enumeration (P27)**: PARTIAL — need to verify the controller doesn't reveal "this workspace exists" / "this email's domain matched a rule" through response timing or content diffs. Quick read suggests rendered errors are uniform ("could not join — invalid"). Worth a focused look-over in PR review terms, but not a blocker.
- **Session hygiene (codex round-1 HIGH-2)**: PASS. `MagicLinkController.consume/2` does `configure_session(renew: true) + delete_session(:pending_workspace)` so stale onboarding state from a prior click doesn't bleed in.
- **Concerns / followups**: a regression test asserting "magic-link click never lands at `/register/complete` directly when workspace not chosen" would lock the new flow. Worth adding.

### PR #295 (PR-C: delete `default` workspace + operator seed)

Files: `ezagent_domain_chat/.../application.ex` (drop `ensure_workspace("default")`), `ezagent_domain_identity/.../application.ex` (drop operator seed), `registration.ex` (drop AppSetting fallback), `login_email_test.exs`.

- **Tier compliance**: PASS. Pure deletion of seed code from boot.
- **Plugin-isolation (P1)**: PASS.
- **Production-usability (P4)**: PASS — removes confusing "where do I live?" default-workspace UX surface. Now every regular user must pick a workspace through onboarding.
- **Single source of truth (P3)**: PASS — collapses `email_allowed?/1` to a single path (workspace rules), removes the back-compat AppSetting fallback that was a divergent SoT.
- **Concerns / followups**: `create_principal/4`'s `workspace \\ "default"` default arg is now load-bearing for legacy callers / tests but no `default` workspace exists at boot. If any non-test caller still uses the 3-arity form, it will silently produce `entity://user/default/<slug>` URIs that resolve to a non-existent workspace. Recommend an invariant: grep `Registration.create_principal/.*\b3\b)` and assert zero hits in `lib/`, or remove the default entirely (force explicit). The PR description acknowledges this; closing the loop is small.

### PR #296 (PR-D: "Promote to system" + capability membership)

Files: `apps/ezagent_core/lib/ezagent/capability.ex` (`cross_workspace?/2` now ORs `home_is_system?` + `member_of_system?`), invariant test, `users_live.ex` (promote/revoke buttons).

- **Tier compliance**: **CAVEAT.** `Ezagent.Capability.cross_workspace?/2` (core) now does `apply(Ezagent.Workspace.Store, :get_by_name, ["system"])` to check membership. This is a runtime core → domain reach — first one in `capability.ex`. The `Code.ensure_loaded?` guard keeps the compile-time dep graph clean (layer-purity test still passes), and the cross-app boundary semantically belongs here (cross-workspace check IS a capability concern). But it's a precedent worth marking:
  - Recommend: add a comment in `layer_purity_test.exs` listing each known runtime-only core → domain reach (currently `Capability.cross_workspace?/2` → `Workspace.Store.get_by_name/1`) so the test's intent stays explicit. Without the comment, a future "fix the layer-purity test" PR may try to ban `apply/3` entirely and break things.
  - Long-term structural fix: move the membership check behind a core-defined behaviour (e.g. `Ezagent.WorkspaceMembership` callback module) that `domain_workspace` implements; core resolves via Application env. Same pattern as Phoenix's adapter pattern. Not urgent; the `apply/3` pattern is established.
- **Plugin-isolation (P1)**: PASS.
- **CapBAC semantics (P15, invariant 13)**: PASS. Membership in `workspace://system` correctly maps to cross-workspace authority via the existing `Capability.cross_workspace?/2` membership path (SPEC v3 §5 + §13). NO new cap rows are created — membership IS the cap. The invariant test (`promote_to_system_grants_cross_workspace_test.exs`) asserts: (1) promote → cross-workspace TRUE on a workspace-scoped cap; (2) revoke → FALSE; (3) non-system workspace membership does NOT grant cross-workspace authority (sanity).
- **Completion invariant (P6)**: PASS. The test is explicitly "fails when the architectural goal is unmet" — exactly the gate `feedback_completion_requires_invariant_test` requires.
- **Workspace switcher UX (invariant 13)**: not exercised by this PR; the existing system-member context-swap path applies once a user is promoted. Verify that path renders correctly post-promote in next session.
- **Concerns / followups**: see CAVEAT above on the layer-purity precedent.

### Workspace fix (covered as PR #290 — same PR)

(No separate "workspace fix" PR beyond #290; covered.)

---

## Cross-cutting findings

### Finding 1 — Core → domain runtime reach in `Capability.cross_workspace?/2`

- **Severity**: LOW (precedent, not violation)
- **What**: `apps/ezagent_core/lib/ezagent/capability.ex:264` uses `apply(Ezagent.Workspace.Store, :get_by_name, ["system"])` to check system-workspace membership. Layer-purity (mix.exs deps) is clean because the call is runtime-only and guarded by `Code.ensure_loaded?`. But it IS a core module reaching into domain at runtime — the same lazy-load shape that identity uses for workspace.
- **Where**: `apps/ezagent_core/lib/ezagent/capability.ex:259-275` (`member_of_system?/1`).
- **Recommendation**:
  1. Add an inline comment in `layer_purity_test.exs` enumerating each known runtime-only core → domain reach (currently just this one), so the test's intent is explicit and future PRs don't naively try to ban `apply/3`.
  2. Long-term: extract `Ezagent.WorkspaceMembership` as a core behaviour, have `domain_workspace` implement it, resolve via Application env. Not urgent — single occurrence today, well-documented inline.

### Finding 2 — `:install_from_source_not_implemented` is a user-visible deferral

- **Severity**: LOW
- **What**: PR3's cc `toggle_extension(_, _, true)` returns a documented stub. LV surfaces "marketplace integration TBD" — operator can manually drop a bundle. Per `feedback_dont_defer_what_is_solvable_now`, every deferral needs a tracked target.
- **Where**: `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` (toggle-on branch) + `agent_extensions_live.ex` flash handling.
- **Recommendation**: add to `docs/futures/todo.md` (per `project_durable_todo_list`) with a target ("PR-Marketplace-1: install-from-source for cc extensions"). Today the deferral is reasonable because no marketplace exists yet.

### Finding 3 — LV `authorized_to_toggle?/1` re-implements cap construction

- **Severity**: LOW
- **What**: `AgentExtensionsLive.authorized_to_toggle?/1` (PR3) builds the `needed` cap shape by hand instead of using `Ezagent.Capability.cap_for_action/3`. Two construction paths can drift.
- **Where**: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/agent_extensions_live.ex:228-243`.
- **Recommendation**: replace the hand-constructed map with `Ezagent.Capability.cap_for_action(Ezagent.Entity.Agent, :write_path, agent_uri)`. Small refactor; eliminates drift risk.

### Finding 4 — Workspace listing SoT discipline

- **Severity**: LOW
- **What**: PR #290 fixed the workspaces LV that leaked `system`. Other LVs that list workspaces could repeat the bug — currently the discipline is "use `list_visible/0`, never `list_persisted/0`" by convention.
- **Where**: any future `Ezagent.Workspace.list_*/0` caller.
- **Recommendation**: add an invariant test that greps for `Workspace.list_persisted` in LV / web code, asserts each call site has either an explicit exemption comment or is in admin-only scope. Same pattern as the Template Class extension contract test.

### Finding 5 — `Registration.create_principal/3` default arg

- **Severity**: LOW
- **What**: PR-B added a 4th workspace arg with default `"default"`. PR-C deleted the `default` workspace from boot. Result: legacy 3-arity calls would silently create `entity://user/default/<slug>` URIs that reference a non-existent workspace.
- **Where**: `apps/ezagent_domain_identity/lib/ezagent/registration.ex:155-160`.
- **Recommendation**: grep `Registration.create_principal\b` across `apps/*/lib/` (NOT tests) — if zero callers use the 3-arity form, remove the default arg. Force explicit workspace at every call site.

---

## North Star — plugin isolation

**Pass.** The 2-day session's centerpiece (PR1-PR3, plus PR-A through PR-D's workspace primitives) materially advances P1. Concrete evidence:

1. **PR2's `Behavior.Sandbox` + `Kind.Template` callbacks** — core publishes a 3-callback contract; cc plugin is the first opt-in; echo / curl / np / generic_session opt out by omission. A future Codex plugin shipping `list_extensions/1 + toggle_extension/3 + destroy_config_dir/2` would (a) get a per-agent config dir for free via Sandbox, (b) get a working `/admin/agents/:uri/extensions` LV for free via `AgentExtensionsLive`, (c) hook into `terminate_worker`'s `sandbox.destroy` for free. Zero changes required in `ezagent_core` / `ezagent_domain_*` / other plugins. This is exactly the "future devs ship without touching core" property the memory demands.

2. **The all-or-nothing invariant** (`template_class_extension_contract_test.exs`) prevents the "partial opt-in" failure mode — a future plugin author who implements `list` + `toggle` but forgets `destroy_config_dir` gets a clear compile-time error pointing at the missing pieces. This is P6 (completion-requires-invariant-test) applied prospectively to plugin authors.

3. **PR3's `AgentExtensionsLive` is plugin-agnostic by construction** — looks up Template Class via `AgentFlavorRegistry`, dispatches generic callbacks, never imports cc-specific modules. Its docstring is explicit: "This LV knows NOTHING about Claude Code plugins / skills / MCP servers / hooks."

4. **PR-A's per-workspace `magic_link_rule`** keeps tenant access policy in domain — a future plugin (auth provider) wouldn't need to touch this; auth providers register Behaviors on the User Kind (per P11), they don't fork the access-policy table.

Caveat: PR-D's core → domain runtime reach (Finding 1) is the first time `capability.ex` looks at workspace membership. The pattern is correct for the concern but worth marking explicitly so it doesn't become a normalized escape hatch.

---

## Recommendations for next session

1. **Finding 1 mitigation**: add the runtime-reach enumeration comment to `layer_purity_test.exs`. 5-min change.
2. **Finding 3 refactor**: collapse `AgentExtensionsLive.authorized_to_toggle?/1` to use `Capability.cap_for_action/3`. 10-min change.
3. **Finding 5 audit**: grep `Registration.create_principal\b` and either remove the `"default"` workspace default arg or document why each callsite needs it. 15-min.
4. **Finding 4 invariant**: add `workspace_list_visible_discipline_test.exs` along the same shape as the Template Class extension contract test. 30-min.
5. **Finding 2 tracking**: add a `docs/futures/todo.md` entry for cc extension install-from-source. 5-min.
6. **Marketplace PR scoping**: brainstorm the cc extension marketplace surface — needed for Finding 2 closure AND for a Codex/Curl plugin to demonstrate the multi-plugin extension UX. Likely 1-2 sessions of design + 3-4 PRs of implementation.
7. **PR-B onboarding regression**: add a controller test that asserts magic-link click → `/onboarding/workspace`, NOT `/register/complete`, when the email has no principal AND no workspace was chosen. Locks in the PR-B redirect chain.
