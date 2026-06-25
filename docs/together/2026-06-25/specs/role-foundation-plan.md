# Role-foundation — Implementation Plan (rev 2, DRAFT for codex review)

> From `role-foundation-design.md` rev3 + Allen's **generalized keystone** decision (2026-06-25) + the codex plan-review of rev1 (HIGH/MED folded). PRs **RF-1..RF-9** on a target branch `feat/role-foundation` (lead merges the whole branch). Each PR: four-property DoD + CI green + rebased; dedicated worktree; not self-merged.

**Goal:** agents are role × flavor; a generic Kind hosts behaviors that are **loaded + resolved PER-INSTANCE** from the instance's recipe (no Kind declaration of plugin/role behaviors); roles are recipes applied via the lifecycle; passive (data) actors are isolated from chat-principal semantics.

**Architecture (the keystone — Allen, generalized):** Today `lookup_behavior` (runtime.ex:272) resolves `action→behavior` via the **static `{kind,action}` `BehaviorRegistry`**, so a behavior is dispatchable only if its Kind *declares* it (post-A: `Entity.Agent.behaviors/0` = `base ++ registry_instance_behaviors()` union — agent.ex:81). **Generalize: make resolution PER-INSTANCE** — `lookup_behavior` resolves from the *instance's loaded behavior set* first (recipe-provided), falling back to the static registry. Then a generic Kind (`Entity.Agent`) hosts ANY plugin/role behavior loaded per-instance, **without the Kind declaring it**. This **supersedes A3's union as the dispatch gate** (the union stays only as the Capability/discovery menu); the instance's loaded set becomes the single truth for BOTH resolution (`lookup_behavior`) and the existing gate (`instance_set_gate`/`effective_set`).

## Global Constraints
- Post-A main: flavor registry + `behaviors/0` derivation live in `ezagent_domain_agent`; `Entity.Agent.behaviors/0` is registry-union (agent.ex:81); `lookup_behavior` is core (runtime.ex:272); the per-instance SET gate (`instance_set_gate`→`effective_set`→`:kind_base`) already exists.
- Caps stay caller-side (4-tuple); mount/detach + per-instance resolution change the target's behavior set/map, NOT cap storage.
- Cold-restart must rehydrate the per-instance loaded set (the `:kind_base`/`effective_set` path already does for the spawn-set; mount/detach + recipe-load must persist the same way).
- B/C/A landed; this shares `arch_baseline_manifest.exs` → serialize edits.

---

### RF-1 — per-instance `action→behavior` resolution + generic host (the keystone)
**Files:** `apps/ezagent_core/lib/ezagent/kind/runtime.ex` (`lookup_behavior/2` → `lookup_behavior/3` taking instance state; resolve from the instance's loaded behaviors' actions first, then `BehaviorRegistry`), `kind/behavior_set.ex` (expose the instance's `action→behavior` map from its loaded set), a generic host marker on `Entity.Agent`. Tests: an instance with a recipe-loaded behavior NOT declared on its Kind dispatches that behavior's action; a non-loaded instance does NOT; static-registry behaviors still resolve (back-comp).
**Steps:** [ ] failing test (instance-loaded, Kind-undeclared behavior dispatches; sibling instance w/o it gets `:unknown_action`); [ ] `behavior_set` exposes per-instance `action→behavior`; [ ] `lookup_behavior/3` consults instance set first → static fallback; [ ] thread instance state into the dispatch call site (runtime.ex:~155-160); [ ] back-comp test (existing static behaviors unaffected); [ ] suite + commit.
**Risk:** dispatch hot path — resolution must stay O(1)-ish (per-instance map cached in state, not recomputed). The SET gate (`instance_set_gate`) is unchanged; only RESOLUTION generalizes. Validation shifts: a behavior is admissible iff it's in the instance's loaded set (recipe-authorized), replacing the Kind-declaration gate (HIGH-1 relaxed → the loading flavor/role is the authority).

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
**Steps (5a):** [ ] failing test (create direct-spawn agent w/ role → behaviors active via RF-1 + sandbox + caps); [ ] generic role step (direct path); [ ] wire compose→set + config_dir + CapMint@grant; [ ] commit. Depends on RF-1, RF-4.

### RF-6 — passive-actor isolation (🔴 jjkysy review)
**The leak (codex HIGH-C):** receive routing is NOT uniformly membership-gated — only `$session_users`/`$mentions` run `valid_member?`; **concrete-URI / `{:from,_}` / `Always→X` receivers bypass it** (resolver.ex `{:uri,_}`/`%URI{}`/`{:role,_}`/string return unfiltered) → a routing rule pointing at a passive actor delivers `chat.receive` + mints a `:receive` cap = principal leak.
**Files:** a `passive` flag on the recipe (`%Role{}` role.ex:43-51 has none — add) AND/OR flavor decl, threaded through `Compose`; gates at: the session **mention-resolver** (`$mentions`), the **`:join`** path (`session.ex` `handle_join`), and **the UNIVERSAL `resolve_with_ctx` final-output filter** (resolver.ex ~219-223 — the same chokepoint the F14 self-loop fix used; one drop covers ALL rule types). Tests: passive actor NOT @-mentionable, NOT joinable, does NOT receive via ANY rule type (Always/from/concrete-URI); a normal agent unaffected.
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

## Self-review (open Qs for codex)
- RF-1: is threading instance state into `lookup_behavior` on the hot path acceptable, and is the per-instance `action→behavior` map correctly sourced from `effective_set`? Does it interact safely with the static `{kind,action}` collision guard?
- RF-1 validation shift: relaxing the Kind-declaration gate to "in the instance's recipe-loaded set" — any safety hole vs the current `behaviors_of` intersection?
- RF-3: is a new `on_detach/2` Behavior callback the right teardown seam (vs reusing `terminate/3`)?
- RF-5: confirm one generic role step suffices for the direct-spawn path with no role-specific branch.
- RF-6: confirm the universal `resolve_with_ctx` final-output filter is the complete receive chokepoint (no other delivery path).
