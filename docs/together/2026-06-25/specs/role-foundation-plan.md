# Role-foundation — Implementation Plan (rev 3, DRAFT for codex review)

> From `role-foundation-design.md` rev3 + Allen's **generalized keystone** decision (2026-06-25, branch **(a)** chosen — `role-foundation > kanban-spec`: the foundation defines the general model; `kanban-as-role-spec` §4 "native must declare kanban" is REMOVED to conform) + BOTH prior codex plan-reviews folded (rev1 HIGH/MED + rev2's decisive BLOCKER-1 fix). PRs **RF-1..RF-9** on a target branch `feat/role-foundation` (lead merges the whole branch). Each PR: four-property DoD + CI green + rebased; dedicated worktree; not self-merged.

**Goal:** agents are role × flavor; a generic Kind hosts behaviors that are **loaded + resolved PER-INSTANCE** from the instance's recipe (no Kind declaration of plugin/role behaviors); roles are recipes applied via the lifecycle; passive (data) actors are isolated from chat-principal semantics.

**Architecture (the keystone — Allen, generalized, branch a):** Today a behavior is dispatchable only if its Kind *declares* it, enforced at TWO points: (1) `lookup_behavior` (runtime.ex:272) resolves `action→behavior` via the static `{kind,action}` `BehaviorRegistry`; (2) — **the load-bearing one (rev2 BLOCKER-1)** — `init_set/2` (first spawn) and `effective_set/2` (every load) do `Enum.filter(declared, &MapSet.member?(requested, &1))` where `declared = behaviors_of(kind)`, so a requested behavior NOT in `Entity.Agent.behaviors/0` (agent.ex:81 union) is **filtered out before its slice is ever materialized** → empty slice → `FunctionClauseError` at dispatch (verified). **Generalize BOTH:** (1) `lookup_behavior` resolves from the instance's loaded set first; (2) replace the `∩ declared` filter with **"keep captured members that are validated real Behaviors (`Behavior.new_style?/1` ++ `base_behaviors()`)"**. Then a generic Kind (`Entity.Agent`) hosts ANY recipe-loaded behavior **without declaring it**. **Subset-denial survives:** a declared-but-scoped-out behavior is still absent from the captured `:kind_base` set, so `instance_set_gate`'s `declared? and not in_instance?` still denies it; `Role.new/1` already validates recipe behaviors are real Behaviors → "validated recipe member" replaces "∩ declared" as the trust check. A3's union is no longer the dispatch gate; discovery of role-mounted behaviors is sourced from the recipe (MED-1), not `behaviors/0`.

## Global Constraints
- Post-A main: flavor registry + `behaviors/0` derivation live in `ezagent_domain_agent`; `Entity.Agent.behaviors/0` is registry-union (agent.ex:81); `lookup_behavior` is core (runtime.ex:272); the per-instance SET gate (`instance_set_gate`→`effective_set`→`:kind_base`) already exists.
- Caps stay caller-side (4-tuple); mount/detach + per-instance resolution change the target's behavior set/map, NOT cap storage.
- Cold-restart must rehydrate the per-instance loaded set (the `:kind_base`/`effective_set` path already does for the spawn-set; mount/detach + recipe-load must persist the same way).
- B/C/A landed; this shares `arch_baseline_manifest.exs` → serialize edits.

---

### RF-1 — per-instance behavior set+resolution: generalize BOTH the slice-materialization filter AND `action→behavior` resolution (the keystone)
**Two changes (rev2 BLOCKER-1: resolution alone crashes — the slice is filtered out before dispatch):**
1. **Slice-materialization filter (load-bearing):** in `apps/ezagent_core/lib/ezagent/kind/behavior_set.ex`, replace `init_set/2` and `effective_set/2`'s `Enum.filter(declared, &MapSet.member?(requested, &1))` (where `declared = Ezagent.Kind.behaviors_of(kind)`) with **"keep captured/requested members that are validated real Behaviors (`Ezagent.Behavior.new_style?/1`) ++ `base_behaviors()`"** — so a recipe-loaded behavior NOT in `behaviors_of(Entity.Agent)` is KEPT, its `init_slice`/`create` runs, slice materialized + persisted.
2. **Resolution:** `runtime.ex` `lookup_behavior/2`→`/3` taking instance state; resolve `action→behavior` from the instance's loaded set first, then static `BehaviorRegistry`.
**Files:** `kind/behavior_set.ex` (the filter rewrite in both `init_set` + `effective_set`; expose the per-instance `action→behavior` map from the loaded set), `kind/runtime.ex` (`lookup_behavior/3` + thread instance state into the dispatch call site ~155-160), generic-host marker on `Entity.Agent`.
**Steps:**
- [ ] **P1-regression test FIRST**: a declared-but-scoped-out behavior (in `behaviors_of` but NOT in the instance's captured set) is STILL denied at dispatch (`instance_set_gate` `declared? and not in_instance?`) — proves subset-denial survives the filter change.
- [ ] failing test: instance with a recipe-loaded, `Entity.Agent`-UNdeclared behavior → its slice materializes + its action dispatches; a sibling instance without it → `:unknown_action`/denied.
- [ ] rewrite `init_set`/`effective_set` filter → `new_style?`-validated captured ++ base (keep the `nil`-capture `MissingKindBaseError` branch untouched — it fires before the list branch).
- [ ] `behavior_set` exposes per-instance `action→behavior`; `lookup_behavior/3` consults it first → static fallback; thread instance state into dispatch.
- [ ] back-comp test (existing static/declared behaviors unaffected); full suite (no cold-restart/`:kind_base` regression — #110/#113/#114 class); commit.
**Validation-shift (HIGH-1 relaxed, safe — codex-verified):** trust = "a validated real Behavior in the instance's recipe-loaded set" (`Role.new/1` already validates recipe behaviors are real Behaviors), replacing "∩ `behaviors_of`". Subset-denial preserved (scoped-out declared behaviors stay absent from the captured set). Post-gate chain is behavior-sourced (`required_caps()`/`interface()`) so undeclared `{Entity.Agent, action}` does NOT crash authz/validate. **Invariant to assert:** no two role-mounted behaviors on `Entity.Agent` share an `action` name (else per-instance resolution is ambiguous; the `{kind,action}` collision guard no longer covers role behaviors).
**Risk:** dispatch hot path — per-instance `action→behavior` map cached in state, not recomputed per call. This is the highest-blast-radius PR (touches the per-instance-denial invariant) → the P1-regression test is the gate.

### RF-2 — runtime `mount` (add a behavior to a live instance's loaded set)
**Files:** `kind.ex` (+`mount(instance_uri, behavior)`), `behavior_set.ex` (loaded-set mutation + persist; there is NO `:kind_base` setter today — add one), `kind/server.ex` (`handle_call({:ezagent_mount, ...})`). Tests: mount a behavior onto a live instance → its action dispatches (via RF-1); slice materialized; cold-restart keeps it.
**Steps:** [ ] failing test (mount → action dispatchable + slice non-empty + survives restart); [ ] `:kind_base` loaded-set **writer**; [ ] mount runs the behavior's **`init_slice`** AND the spawn-time **`post_init/2` continuation + `on_ready/2`** (codex HIGH-A — slice-init alone leaves it half-initialized, e.g. Publisher broadcasts in `on_ready`); [ ] re-validate closure (`behavior_set` `validate_closure!`); snapshot; [ ] commit. Depends on RF-1.

### RF-3 — runtime `detach` (new per-behavior teardown) + retire Kind-level `attach_behavior`
**The gap (codex HIGH-B):** `Lifecycle.deactivate/destroy` are **whole-ENTITY** (destroy = permanent deletion; deactivate = `:ok`-only, can't mutate persisted state). There is **no per-behavior teardown hook**. RF-3 must **design + add one** (a `Behavior.on_detach/2`-style optional callback that CAN mutate/clear the behavior's slice), not call deactivate/destroy.
**Files:** `behavior.ex` (+ optional `on_detach/2`), `kind.ex` (+`detach/2`; remove Kind-level `attach_behavior` kind.ex:835 — no runtime callers; keep the declaration/collision machinery), `behavior_set.ex`, `server.ex`. Tests: detach → action no longer dispatches; `on_detach` ran + slice cleared; **reverse-closure** rejects detaching a still-required behavior; in-flight `:call` (serialized in the single GenServer mailbox — low risk; note deferred/saga to OTHER kinds).
**Steps:** [ ] failing tests (detach removes action; reverse-closure reject; on_detach clears slice); [ ] `on_detach` callback + detach impl + reverse-closure; [ ] retire Kind-level `attach_behavior`; [ ] commit. Depends on RF-1, RF-2.

### RF-4 — `roles/0` plugin callback + recipe registry (code-seed)
**Files:** `plugin.ex` (+`@callback roles/0` + boot registration, parallel to `agent_flavors/0` plugin.ex:212/448-470), a `RoleRegistry` (name→recipe, ETS in domain.agent like the post-A flavor registry). `OrchestratorRole.recipe/0` (in plugin_cc) is the exemplar. Tests: a plugin's `roles/0` recipe is registered + looked up by name. (`template://role` + RoleTemplate Kind = follow-up.)
**Steps:** [ ] failing test (lookup role by name → recipe); [ ] `roles/0` + boot loop + RoleRegistry; [ ] commit.

### RF-5 — role-driven create via lifecycle (split: 5a direct-spawn, 5b file-flavor)
**The thicket (codex MED-E):** `do_create_agent` (agent_create.ex:284-420) has two spawn routes — `direct_spawn_flavor_agent`→`spawn_args_for_flavor` (already threads `:instance_behaviors`→batch `:behaviors`; **kanban's path**) and the file-flavor/template route (cc/codex; does NOT pass `spawn_args_for_flavor`).
- **RF-5a (kanban-blocking, small/atomic):** generic role-resolution step in the **direct-spawn** path → `Role.Compose.materialize(recipe, flavor)` → behaviors loaded (RF-1 set) + sandbox→config_dir + caps→`Role.CapMint.mint/3` at **`Ezagent.Workspace.grant_initial_caps`** (workspace.ex:901 — public module, NOT `behavior/workspace.ex`; codex MED-D; CapMint runs before grant, output concatenated with CLI `--caps`).
- **RF-5b (cc/codex; atomicity-risky; kanban doesn't need):** thread role behaviors through the file-flavor/template route too. Separate PR.
**Steps (5a):** [ ] failing test (create direct-spawn agent w/ role → behaviors active via RF-1 + sandbox + caps); [ ] generic role step (direct path); [ ] wire compose→set — **the composed `:behaviors` (role ++ flavor) must OVERRIDE `spawn_args_for_flavor`'s thunk-sourced `:behaviors`** (HIGH-1: it sources solely from `decl.instance_behaviors`; without the override the role's behaviors never reach `:kind_base`); [ ] config_dir + CapMint@grant; [ ] commit. Depends on RF-1, RF-4.

### RF-6 — passive-actor isolation (🔴 jjkysy review)
**The leak (codex HIGH-C):** receive routing is NOT uniformly membership-gated — only `$session_users`/`$mentions` run `valid_member?`; **concrete-URI / `{:from,_}` / `Always→X` receivers bypass it** (resolver.ex `{:uri,_}`/`%URI{}`/`{:role,_}`/string return unfiltered) → a routing rule pointing at a passive actor delivers `chat.receive` + mints a `:receive` cap = principal leak.
**Files:** a `passive` flag on the recipe (`%Role{}` role.ex:43-51 has none — add) AND/OR flavor decl, threaded through `Compose`; gates at: the session **mention-resolver** (`$mentions`), the **`:join`** path (`apps/ezagent_domain_session/lib/ezagent/behavior/session.ex` `handle_join` — rev2 review left this UNverified; confirm the exact site), and **the UNIVERSAL `resolve_with_ctx` final-output filter** (resolver.ex ~209-218 — the F14 chokepoint; one drop covers ALL rule types). **Cross-app seam (HIGH-2):** the filter is in `ezagent_core` but `passive?` lives on the recipe/flavor (domain) — inject a `passive?`-predicate via `opts` at the call site, **parallel to the existing `role_resolver` opt** (resolver.ex:191). Tests: passive actor NOT @-mentionable, NOT joinable, does NOT receive via ANY rule type (Always/from/concrete-URI); a normal agent unaffected.
**Steps:** [ ] failing tests (passive rejected at mention/join/every receive-rule type); [ ] `passive` flag + Compose threading; [ ] 3 gates incl the universal final-output filter; [ ] commit.

### RF-7 — list-by-role read model
**The gap (codex MED-F):** `KindRegistry` is a bare URI→pid map (explicitly says by-role indices belong elsewhere). Build a new read model: tag the instance with its role at materialize + a "list instances by role" query (parallel to list-by-Kind-type). Tests: create N role-R agents → list-by-role(R) returns them.
**Steps:** [ ] failing test; [ ] role-tag at materialize + by-role query; [ ] commit. Depends on RF-5.

### RF-8 — native flavor + its cap policy
**Files:** a `native` `agent_flavor_decl` (`flavor: "native"`, `kind: Entity.Agent` — generic host, no sidecar/bridge; behaviors come per-instance via RF-1, so native declares NOTHING flavor-specific); an explicit **CapMint cap-policy predicate** for native (which `requested_caps` pass; **fail-closed default stated** — else all dropped). Tests: native agent spawns (no sidecar); CapMint grants only policy-permitted caps.
**Steps:** [ ] failing test; [ ] native decl + cap policy; [ ] commit. Depends on RF-4/RF-5.

### RF-9 — 收编 `OrchestratorRole` onto the unified path
Migrate `OrchestratorRole` (currently only feeds CLAUDE.md) to register via `roles/0` + apply via RF-5. Tests: cc orchestrator unregressed. Depends on RF-4/RF-5.

## Order / deps
RF-1 (keystone) → RF-2 → RF-3; RF-4 → RF-5a (needs RF-1) → RF-7/RF-8; RF-6 after RF-5; RF-9 last.
**kanban-as-role unblocks on RF-1 + RF-4 + RF-5a + RF-6 + RF-7 + RF-8** — NOT RF-2/RF-3 (runtime mount/detach = live-reconfig). With RF-1 (per-instance resolution), kanban's `Behavior.Kanban` dispatches **without** `Entity.Agent` declaring it — the union (A3) is no longer the gate.

## Self-review (open Qs for codex re-review of rev3)
- **RF-1 filter rewrite (the crux):** does replacing `init_set`/`effective_set`'s `∩ behaviors_of` with `new_style?`-validated-captured ++ base break any OTHER consumer that relies on `effective_set` being intersected with the declared union (e.g. `materialized_set`/`run_on_ready_hooks`, the `requires_explicit_behavior_set?`/`MissingKindBaseError` path, capability resolution)? Confirm cold-restart (#110/#113/#114) class stays closed.
- RF-1: per-instance `action→behavior` resolution + the "no two role behaviors share an action on `Entity.Agent`" invariant — is asserting it at recipe-registration (RF-4) the right place?
- RF-3: is a new `on_detach/2` Behavior callback the right teardown seam (vs reusing `terminate/3`)?
- RF-5a: confirm the composed `:behaviors` correctly OVERRIDES `spawn_args_for_flavor`'s thunk-sourced value (HIGH-1 from rev2 review).
- RF-6: confirm the `passive?`-predicate injection into `resolve_with_ctx` (parallel to `role_resolver` opt) + verify the `:join`/mention gates (rev2 review left them unverified).
