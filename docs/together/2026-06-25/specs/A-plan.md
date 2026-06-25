# A — agent flavor + config unification — Implementation Plan (rev 2, post codex plan-review)

> **For agentic workers:** implement task-by-task; each PR independently testable, four-property DoD, CI green + rebased before return. Steps `- [ ]`.
> Source: `A-agent-flavor-config-unification.md`. Reviews: `A-codex-adversarial-review.md` (spec) + this plan was codex-reviewed (findings folded in below; rev 2).

**Goal:** Adding a flavor = adding a plugin, zero core edits, locked by an arch gate; behaviors derived from the registry; agent config served by domain.agent.

**Architecture:** Move the flavor cluster (registry + resolver + attributes) out of `ezagent_core` into `ezagent_domain_agent`, inverting the **two** core→flavor edges via registered hooks (mirroring `Ezagent.ReadyGate.register_external_gate/1`): (1) `Kind.Template`'s store/delete-flavor-attrs, (2) `Plugin.publish/1`'s registry write. Derive `Entity.Agent.behaviors/0` from the registry behind a boot barrier. Replace `Ezagent.AgentConfig` with a domain.agent config API.

## Global Constraints
- `im → session → agent` acyclic; `domain_session` **already deps `domain_agent`** (mix.exs:61) → moved-module readers are legal. **core may NOT dep agent.** The two real core→flavor edges to invert: `kind/template.ex:355,367`, `plugin.ex:469`.
- D3 adds `domain_agent → domain_identity` (acyclic: identity deps only core).
- **Worktree isolation (process fix):** every PR/agent works in its OWN `git worktree`; NEVER the shared `/Users/h2oslabs/Workspace/esr-ng` checkout. Review/verify agents must read `origin/main` (or a clean checkout), not the shared tree (it drifts onto other branches — corrupted two reviews already).
- Each PR: `mix precommit` + `mix ezagent.check_invariants` green on PR head, rebased on current main. B/C/A share `arch_baseline_manifest.exs` → serialize edits.

---

### PR-A1: Invert `Kind.Template` flavor coupling via a registered hook (ReadyGate idiom)
**Idiom (pinned):** mirror `Ezagent.ReadyGate.register_external_gate/1` (`apps/ezagent_core/lib/ezagent/ready_gate.ex:61-85`) — a `:persistent_term`-backed list of downstream-registered modules, invoked by core with `Code.ensure_loaded?/1` + `function_exported?/2` guards + safe no-op default.
**Files:** Create `Ezagent.Kind.Template.FlavorHook` (core) — `register/1` + `store/2` + `delete/1` dispatch (no-op if none registered). Modify `apps/ezagent_core/lib/ezagent/kind/template.ex:353-369` (`maybe_store_agent_flavor`/`delete_agent_flavor` → call the hook, drop the direct `AgentFlavorAttributes` ref). Implement the hook in domain.agent (still delegating to core-resident `AgentFlavorAttributes` until A2). Test: template instantiate/delete fires the registered hook; no-hook = no-op.
**Steps:** [ ] failing test (hook fires on instantiate w/ `agent_uri`); [ ] FlavorHook (persistent_term, ReadyGate-style); [ ] swap the 2 calls; [ ] register domain.agent impl; [ ] suite + precommit; [ ] commit.
**Risk R2:** Kind.Template used by ALL kinds — behavior-preserving; only the call direction inverts (physical move is A2).

---

### PR-A2: move flavor cluster core→domain.agent + arch gate (split into 4 sub-steps)
**A2a — publish-hook inversion (the crux).** `apps/ezagent_core/lib/ezagent/plugin.ex:468-469` `publish/1` calls `AgentFlavorRegistry.register/1` directly. Add a SECOND ReadyGate-style hook `Ezagent.Plugin.FlavorPublishHook` (core): `publish/1` forwards each `agent_flavor_decl` to the registered impl (domain.agent), which writes the now-domain.agent registry. Core stops referencing the registry.
**A2b — domain.agent ETS owner.** `EzagentDomainAgent.Application` (`application.ex:25-40`) has NO ETS owner (only 2 DynamicSupervisors). Add an EtsOwner child **started FIRST**, owning the moved tables (`:ezagent_agent_flavor_registry`, `:ezagent_agent_flavor_attributes`). Remove `AgentFlavorAttributes.init/0`'s lazy any-caller table creation → fail loud if owner missing (R3).
**A2c — move + readers.** Move `agent_flavor_registry.ex`, `agent_flavor_resolver.ex`, `agent_flavor_attributes.ex` (+ their tests) core→domain.agent; drop the 2 entries from core `ets_owner.ex:68,73`; fix aliases in readers (domain_session `uri_query_resolvers.ex`, domain_workspace `agent_create.ex`, plugin_world `identity_data.ex` — all already dep domain.agent). Point A1's FlavorHook impl at the moved AgentFlavorAttributes.
**A2d — gate.** Add `no_flavor_refs_in_core` to `ezagent.arch.scan.ex` + baseline 0 in `arch_baseline_manifest.exs`. Real core edges to drive to 0 first: `kind/template.ex:355,367` (A1), `plugin.ex:469` (A2a), `agent_flavor_resolver.ex:87,111` + `agent_flavor_attributes.ex:84` (moved by A2c). role.ex/compose.ex/check_invariants hits are comments — exclude or strip.
**Verify:** acyclic invariant test stays green (proves no core→agent edge); gate=0; full suite + check_invariants. Depends on A1.

---

### PR-A3: `behaviors/0` registry-derived + a REAL boot barrier
**The hole (codex):** `Plugin.boot/1` runs each plugin's `after_boot/0` right after its own publish (`plugin.ex:421-425`); cc's `after_boot` calls `Workspace.Loader.load_all/0` (`plugin_cc/application.ex:144,156`) which can spawn an `Entity.Agent` → `BehaviorSet.init_set/2` intersect+persist into `:kind_base` — BEFORE curl/codex have published. No global post-all-plugins point exists.
**Fix (choose + spell out):** add a "flavor registry sealed" flag (`:persistent_term`/EtsOwner) set once after ALL plugins boot; `Entity.Agent.behaviors/0` derivation + first `:kind_base` capture wait on / assert it. OR relocate agent-spawning `load_all/0` out of per-plugin `after_boot` to an umbrella-level post-boot step. **Decide in the PR; default to the sealed-flag (smaller blast radius).**
**Files:** `apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex` (`behaviors/0` → `base_behaviors() ++ registry-union of folded-flavor instance_behaviors`); the seal mechanism; boot wiring.
**Steps:** [ ] cold-restart regression test FIRST (must fail if derivation races boot); [ ] behaviors/0 derived test (base+cc-headless+curl from registry); [ ] implement derivation + seal barrier; [ ] both green + suite; [ ] commit. Depends on A2 (registry in domain.agent).
**Risk R1:** the seal barrier is the whole point — without it, #110/#113/#114 cold-restart class returns.

---

### PR-A4: `config_schema` in `agent_flavor_decl`
**Files:** `plugin.ex` `agent_flavor_decl` type (+`optional(:config_schema)`, type-only, stays in core); domain.agent registry value + `register/1` validation; cc/codex/curl `agent_flavors/0` declare schemas. Test: `lookup("cc").config_schema`.
**Steps:** [ ] failing test; [ ] extend decl+registry+validation; [ ] populate schemas; [ ] suite; [ ] commit.

---

### PR-A5: domain.agent config API replaces `Ezagent.AgentConfig`; migrate the REAL callers
**Real callers (verified origin/main — codex's "world doesn't call it" was a stale-worktree error):** `world/agent_actions.ex:196,219,242` (apply_delta/delete_path/repoint), `world/identity_data.ex:184` (read_cascade), and `domain_identity/behavior/config_evolve.ex`. (+ tests: `agent_config_dispatch_test.exs`, `agent_config_state_test.exs`.)
**Files:** Create domain.agent config API (relocate the `agent_config.ex` facade + tests; delegate to identity's `Socialware.ConfigStore` + cascade, cap-gated). Add `ezagent_domain_agent → ezagent_domain_identity` mix dep. Repoint world's 4 call sites + config_evolve. Remove old `Ezagent.AgentConfig`.
**Steps:** [ ] port `agent_config_test.exs` as parity; [ ] implement API + mix dep; [ ] migrate world's 4 sites + config_evolve; [ ] world dispatch/state tests green; [ ] remove old facade; [ ] suite; [ ] commit. **Coordinate gaga** (console wires this contract).

---

### PR-A6: drop `AgentKind` alias
Modify `plugin_cc/application.ex` (use `Entity.Agent` directly). May fold into A2. [ ] replace; [ ] suite; [ ] commit.

---

## Order / deps
A1 → A2(a→b→c→d) → A3. A4/A5/A6 build on A2's registry/decl but are mutually independent. A5 coordinates gaga.

## Self-review (open questions — now resolved by codex review)
- A1 idiom = **ReadyGate** (resolved). A2 publish-edge = **second ReadyGate-style hook** (resolved, was the undesigned crux). A2 ETS = **new domain.agent EtsOwner started first** (resolved — none exists today). A3 barrier = **sealed-flag** (resolved — no barrier existed). A5 callers = **world(4)+config_evolve** (resolved — verified on origin/main).
