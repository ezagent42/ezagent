# SPEC — Role materialization foundation (per-instance behavior mount/detach + role recipes)

> Brainstormed + adversarially reviewed with @林懿伦 (Feishu 2026-06-25). **rev 2** — folds in the codex spec review + Allen's final scope decision. Prerequisite for **kanban-as-role** AND **orchestrator**. Next: codex review of this rev → plan → implement.

## 1. North star
**agent = actor** (any non-human operator, actor-model sense, not just LLM) = **role (what it does) × flavor (how it executes)**. An instance's active behaviors are **mounted per-instance at runtime**; creating with a role = mounting the role's behaviors. No flavor/role-specific branches in the create path.

## 2. What ALREADY exists (verified on origin/main — the dispatch half is built)
- **Per-instance dispatch is already there.** `kind/runtime.ex:159` chain = `lookup_behavior` (global menu) → **`instance_set_gate`** (denies if the behavior is not in this instance's `BehaviorSet.effective_set/2`) → `authz_check`. So **the per-instance active set is already the dispatch truth.**
- **Per-instance behavior subsets ship today.** `Session` spawns `Kind.spawn(Session, %{behaviors: Session.chat_behaviors()})` (`…instance_message/application.ex:725`); captured to `:kind_base`; re-derived via `effective_set/2` on cold restart (free).
- `effective_set/2` **intersects** the captured set with the Kind's `behaviors_of/1` (`behavior_set.ex:172-204`).
- `Ezagent.Role` (recipe), `Role.Compose.materialize` (pure compose → `%{behaviors, sandbox_content}`), `Role.CapMint.mint/3` ✓ exist; `OrchestratorRole.recipe/0` is the code-seed exemplar (currently only feeds CLAUDE.md). `Workspace.grant_initial_caps/3` (`workspace.ex:901`) is the cap-grant chokepoint.
- `Kind.attach_behavior(b, to: kind_module)` (`kind.ex:835`) is **Kind-level** (registers action→behavior globally) and has **no runtime callers** — the conceptual mistake to replace.

So the **dispatch + persistence + cold-restart of a per-instance set is done.** The genuinely new work is **mutating a LIVE instance's active set** (runtime mount/detach).

## 3. Scope (Allen-decided, rev 2)
**No respawn-shortcut. Build per-instance RUNTIME mount/detach as THE mechanism, replacing the Kind-level `attach_behavior`. create uses it too (unified).**

### Part 1 — Per-instance runtime mount/detach (the core new work)
- `mount(instance_uri, behavior)`: add to the live instance's active set (`:kind_base`) — must **run the behavior's slice-init** (else dispatch reads an empty slice = silent-wrong), **re-validate closure** (`behavior_set.ex:360` — set stays closed under `@required_reads`), snapshot.
- `detach(instance_uri, behavior)`: remove it — run its **`deactivate`/`destroy`**, **reverse-closure check** (nothing remaining REQUIRES it), handle **in-flight dispatch** (a `:call` already past `instance_set_gate`).
- **create unified**: the existing batch `Kind.spawn(%{behaviors: ...})` is the **create-time/batch form** of "set the active set"; runtime mount is the **live form**. Same active-set + dispatch + cold-restart semantics; one model.
- **Retire** the Kind-level `attach_behavior` (no callers). Kind-level **declaration** stays (the menu + the `__before_compile__` collision guard + `BehaviorRegistry` 1:1 `{kind,action}→behavior`).
- **Why runtime, not respawn**: the sidecar (PtyServer/SdkSidecar/AppServer) is **separately supervised** (`EzagentDomainPty.Supervisor`), so for sidecar-backed agents (cc/codex) a destroy-based respawn restarts the sidecar (loses LLM/PTY session). Runtime mount mutates behaviors **without touching the sidecar** — strictly better, and enables near-term "add role/tool to a running agent."

### Part 2 — Role = recipe (definition)
`Ezagent.Role` recipe; **defined** via code-seed module (`recipe/0`, OrchestratorRole-style) + a **`roles/0` plugin callback** (parallel to `agent_flavors/0`) → name→recipe registry at boot. (`template://<ws>/role/<name>` operator-forkable Templates + RoleTemplate Kind = **follow-up**, not needed to unblock kanban/orchestrator.)

### Part 3 — Apply at create via lifecycle
create-with-role → look up recipe → `Role.Compose.materialize(recipe, flavor)` →
- **behaviors** → **mount** (Part 1) at create (batch form),
- **skills/plugins/prompt** → config_dir in `create/1`/`activate/2`,
- **requested_caps** → `Role.CapMint.mint/3` at **`Workspace.grant_initial_caps`** (workspace provisioning layer — NOT the agent's own `Lifecycle.create/1`, which lacks the granter ctx).
No role-**specific** branch in `AgentCreate`; one generic role-resolution step (parallel to how flavor is already handled).

## 4. Hard constraint (HIGH-1 — shapes downstreams)
`effective_set/2` intersects with the Kind's declared `behaviors_of/1`, and `instance_set_gate` only admits **declared** behaviors. So **a role can only mount behaviors the target flavor's Kind declares in `behaviors/0`** (or a shared base Kind). → kanban-as-role's gate must include: the `native` flavor's Kind declares the kanban behaviors.

## 5. To build
1. **Part 1 runtime mount/detach** (the core; full scope above incl slice-init / closure / detach teardown / in-flight). Retire Kind-level `attach_behavior`.
2. **Part 2** `roles/0` callback + name→recipe registry (code-seed). (`template://role` follow-up.)
3. **Part 3** wire compose → mount + config_dir + `CapMint@grant_initial_caps` into create; generic role step in `AgentCreate`.
4. **收编 `OrchestratorRole`** onto this path.

## 6. Risks
- **R1** Part 1 mounts/detaches on a LIVE GenServer mid-flight — slice-init correctness, closure re-validation, detach teardown + in-flight dispatch are the real difficulty (the dispatch resolution itself is NOT changing — it already reads the per-instance set).
- **R2** caps stay caller-side (4-tuple `{behavior,action,instance,workspace}`); mount/detach changes the target's active set, NOT cap storage. (`CapabilityRegistry` is already menu/validation, not dispatch truth — nothing to "demote".)
- **R3** cold-restart must rehydrate the mounted set (the `:kind_base`/`effective_set` path already does this for the spawn-set; mount/detach must persist the same way).
- **R4** orchestrator收编 must not regress cc orchestrator.

## 7. Acceptance (/goal — set after review)
- An agent's behaviors are **mounted per-instance at runtime** (and **detachable**) via the new mechanism, which also backs create; Kind-level `attach_behavior` retired.
- Roles defined as recipes (code-seed + `roles/0`) + applied via the lifecycle (mount + config_dir + CapMint@grant); no role-specific `AgentCreate` branch.
- `OrchestratorRole` migrated; cc orchestrator unregressed.
- Unblocks **kanban-as-role** (kanban-manager recipe mounted on `native`, whose Kind declares the kanban behaviors per §4).
- full `mix test` 0 failures + CI green; cold-restart + mount/detach + closure regression tests.

## 8. Downstream (depend on this)
- **kanban-as-role** (`kanban-as-role-spec.md` on `integration/kanban`) — add §4 (native Kind declares kanban behaviors); board via snapshot (not file); delete Plan-B; world read-model list-by-role.
- **orchestrator** role-Template materialization.
