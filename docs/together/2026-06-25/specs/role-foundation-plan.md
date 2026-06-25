# Role-foundation — Implementation Plan (DRAFT for codex review)

> From `role-foundation-design.md` rev3 (on main). PRs **RF-1..RF-8** on a target branch `feat/role-foundation` (lead merges the whole branch). Each PR: four-property DoD + CI green + rebased; dedicated worktree; not self-merged.

**Goal:** agents are role × flavor; an instance's behaviors are mounted **per-instance** (create-time batch + runtime incremental); roles are recipes applied via the lifecycle; passive (data) actors are isolated from chat-principal semantics.

**Architecture:** Reuse the EXISTING per-instance dispatch (`runtime.ex` `instance_set_gate` → `effective_set` → `:kind_base`, already the dispatch truth) and the EXISTING batch `Kind.spawn(%{behaviors})`. Add: (a) runtime incremental mount/detach on a live instance, (b) `roles/0` + recipe registry, (c) role-driven create wiring, (d) passive-actor isolation, (e) list-by-role, (f) native cap policy.

## Global constraints
- **HIGH-1**: a role can only mount behaviors the target Kind **declares** in `behaviors/0` (`effective_set/2` intersects `behaviors_of/1`; `instance_set_gate` admits only declared). Validate at mount; surface a clear error.
- Caps are caller-side (4-tuple); mount/detach changes the target's active set only.
- Cold-restart must rehydrate the active set (the `:kind_base`/`effective_set` path already does for the spawn-set; mount/detach must persist the same way).
- B/C/A share `arch_baseline_manifest.exs` → serialize edits.

---

### RF-1 — runtime per-instance `mount` (on a live Kind)
**Files:** `apps/ezagent_core/lib/ezagent/kind.ex` (+`mount(instance_uri, behavior)`), `apps/ezagent_core/lib/ezagent/kind/behavior_set.ex` (active-set mutation + persist), `kind/server.ex` (handle the mount call on the live GenServer). Tests: mount a declared behavior onto a live instance → its action dispatches; slice materialized; snapshot persists; cold-restart keeps it.
**Steps:** [ ] failing test (mount → action dispatchable + slice non-empty); [ ] `mount` adds to `:kind_base` active set, **runs the behavior's slice-init** (else empty-slice silent-wrong), **re-validates closure** (`behavior_set.ex` `validate_closure!`), snapshots; [ ] HIGH-1 guard (reject undeclared); [ ] cold-restart test; [ ] commit.
**Risk:** mounting on a LIVE GenServer mid-flight — slice-init + closure must be correct (the dispatch path itself is unchanged — it already reads the per-instance set).

### RF-2 — runtime `detach` + retire Kind-level `attach_behavior`
**Files:** `kind.ex` (+`detach(instance_uri, behavior)`; remove/deprecate Kind-level `attach_behavior` — no callers), `behavior_set.ex`, `server.ex`. Tests: detach → action no longer dispatches; behavior's `deactivate`/`destroy` ran; reverse-closure rejects detaching a still-required behavior; in-flight call handled.
**Steps:** [ ] failing tests (detach removes action; reverse-closure reject); [ ] `detach` runs `deactivate`/`destroy`, **reverse-closure check** (nothing remaining `@required_reads` it), handles in-flight dispatch, snapshots; [ ] retire Kind-level `attach_behavior` (keep Kind-level **declaration** = menu + collision guard); [ ] commit. Depends on RF-1.

### RF-3 — `roles/0` plugin callback + recipe registry (code-seed)
**Files:** `apps/ezagent_core/lib/ezagent/plugin.ex` (+`@callback roles/0` + boot registration, parallel to `agent_flavors/0`), a `RoleRegistry` (name→recipe, ETS like AgentFlavorRegistry). `OrchestratorRole` exposes `recipe/0` (already does). Tests: a plugin's `roles/0` recipe is registered + looked up by name.
**Steps:** [ ] failing test (lookup role by name → recipe); [ ] `roles/0` callback + boot loop + RoleRegistry; [ ] commit. (`template://role` + RoleTemplate Kind = follow-up, NOT here.)

### RF-4 — role-driven create via lifecycle (the wiring)
**Files:** `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create.ex` (one **generic** role-resolution step — no role-specific branch), `Role.Compose.materialize` (already returns `%{behaviors, sandbox_content}`), config_dir write in `create/1`/`activate/2`, `Role.CapMint.mint/3` at **`Workspace.grant_initial_caps`** (workspace.ex:901 — NOT the agent's own lifecycle). Tests: create an agent with a role → its behaviors active (via RF-1 batch/mount), sandbox written, caps minted; HIGH-1 enforced.
**Steps:** [ ] failing test (create-with-role → behaviors + sandbox + caps); [ ] generic role step in AgentCreate; [ ] wire compose→behaviors (batch spawn-:behaviors form), sandbox→config_dir, caps→CapMint@grant; [ ] commit. Depends on RF-1, RF-3.

### RF-5 — passive-actor isolation (🔴 from jjkysy review)
**Files:** recipe/flavor `passive` flag (`Ezagent.Role` + `agent_flavor_decl`), gates in the session **mention-resolver**, the **`:join`** path, and **receive-routing** (`agent.ex` routing layer) rejecting passive actors. Tests: a passive actor is NOT @-mentionable, NOT joinable as a member, does NOT receive chat; a normal (principal) agent is unaffected.
**Steps:** [ ] failing tests (passive actor rejected at mention/join/receive); [ ] `passive` flag + 3 gates; [ ] commit. (General — used by kanban-manager + future data actors.)

### RF-6 — list-by-role read model
**Files:** tag the instance with its role at materialize (a queryable attr/index), + a "list instances by role" query (parallel to list-by-Kind-type). Tests: create N agents with role R → list-by-role(R) returns them.
**Steps:** [ ] failing test; [ ] role-tag + by-role query; [ ] commit.

### RF-7 — native flavor + its cap policy
**Files:** a `native` `agent_flavor_decl` (`flavor: "native"`, `kind:` a Kind that declares the needed behaviors — per HIGH-1; no bridge), + an explicit **CapMint cap-policy predicate** for native (which requested_caps pass; **fail-closed default stated**). Tests: native flavor agent spawns (no sidecar); CapMint grants only policy-permitted caps.
**Steps:** [ ] failing test; [ ] native flavor decl + cap policy; [ ] commit. Depends on RF-3/RF-4.

### RF-8 — 收编 `OrchestratorRole` onto the unified path
**Files:** migrate `OrchestratorRole` (currently only feeds CLAUDE.md) to register via `roles/0` + be applied via RF-4. Tests: cc orchestrator unregressed (its existing tests green).
**Steps:** [ ] migrate; [ ] orchestrator regression green; [ ] commit. Depends on RF-3/RF-4.

## Order / deps
RF-1 → RF-2; RF-3 → RF-4 (RF-4 also needs RF-1); RF-5/6/7 after RF-4; RF-8 last. **kanban-as-role unblocks after RF-3/4/5/6/7** (uses create-time batch form — does NOT need RF-1/RF-2 runtime mount, which is the live-reconfig capability). So a viable cut: ship RF-3/4/5/6/7 (+ batch create) to unblock kanban + orchestrator; RF-1/2 (runtime mount/detach) lands for live "add role/tool to a running agent."

## Self-review (open Qs for codex)
- RF-1/2 live-mutation on a running GenServer (slice-init/closure/in-flight) is the riskiest — is the codex HIGH-2 scope fully captured?
- RF-5 passive-flag placement (recipe vs flavor vs both) + the exact 3 gate sites (mention-resolver / :join / receive) — confirm the file:line gate points.
- RF-4 "generic role step" in AgentCreate (already a flavor thicket) — confirm one step suffices, no role-specific branch.
- Sequencing: can kanban truly land on RF-3/4/5/6/7 without RF-1/2 (batch create only)?
