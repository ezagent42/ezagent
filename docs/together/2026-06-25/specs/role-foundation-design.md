# SPEC — Role materialization foundation (per-instance behavior mount + role recipes)

> Brainstormed with @林懿伦 (Feishu 2026-06-25) — this is the収口'd design. Prerequisite for **kanban-as-role** AND **orchestrator** (both currently waiting on it). Status: spec → codex adversarial review → plan → implement. The `#54` role-over-flavor work landed `Ezagent.Role` + `Role.Compose` + `Role.CapMint` but **left the spawn/create path unbuilt** (verified: `Workspace.AgentCreate` ignores Role; `Role.Compose.materialize` is only called by `OrchestratorRole` for cc's CLAUDE.md, not a spawn; no `template://role` resolver / RoleTemplate Kind).

## 1. North star
**agent = actor** (any non-human operator, actor-model sense, not just LLM). An actor = **role (what it does) × flavor (how it executes)**. Creating an agent with a role = mounting that role's behaviors onto the instance + materializing its sandbox/caps. No flavor- or role-specific branches in the create path.

## 2. The收口'd model (3 parts)

### Part 1 — Per-instance behavior mount/detach (the core new mechanism)
**Today's mistake:** `Kind.attach_behavior(behavior, to: kind_module)` is **Kind-level** (registers action→behavior globally in `CapabilityRegistry` for ALL instances of a Kind). Kind-level mounting has no real meaning — *mounting is inherently per-instance*. (Verified: `CapabilityRegistry`/`BehaviorRegistry` are global Kind→action→behavior; the instance's `:kind_base` slice holds its behavior set but is fixed at spawn; `attach_behavior` has no runtime callers.)

**Correct model:**
- **Kind declares the AVAILABLE-behavior menu** (which behaviors *may* be mounted on this Kind) — validation/declaration only.
- **Per-instance, at runtime, mount/detach the ACTIVE behaviors** — mutate the instance's active set (`:kind_base`) + resolve dispatch (action→behavior) **per-instance** from that active set.
- API: `attach_behavior` becomes **per-instance** (`mount(instance_uri, behavior)`); add **`detach_behavior`/`unmount(instance_uri, behavior)`**.
- `CapabilityRegistry` demotes to the per-Kind **menu + collision/authority validation**; the per-instance active set is the dispatch truth.

### Part 2 — Role = a recipe (definition)
`Ezagent.Role` already exists: `%{skills, plugins, prompt, behaviors, requested_caps, session_template}` (flavor-agnostic). A role is **defined** by:
- **code-seed module** (`OrchestratorRole`-style): `def recipe(), do: Role.new(%{behaviors: [...], skills: [...], prompt: ..., requested_caps: [...], session_template: nil})` — built-in roles in code.
- **`roles/0` plugin callback** — a plugin declares its built-in roles (parallel to `agent_flavors/0`); registered into a **name→recipe registry** at boot. (kanban plugin declares `kanban-manager`.)
- **`template://<ws>/role/<name>`** — operator-forkable role Templates (a RoleTemplate Kind + a `role` branch in the template:// resolver) for user-defined roles.

### Part 3 — Apply at create, via the lifecycle (not a create branch)
`AgentCreate` (workspace-side provisioning) → `Kind.spawn` → the agent Kind's `Lifecycle.create/1` (self-init). Role application distributes over these without a role-specific branch:
- **behaviors** → mounted per-instance (Part 1) during spawn/activate (sourced from the role recipe).
- **skills/plugins/prompt** → written to config_dir in `create/1`/`activate/2` hooks.
- **requested_caps** → minted via `Role.CapMint` at the existing `grant_initial_caps` step.
So "create-with-role" = look up the role recipe → `Role.Compose.materialize(recipe, flavor)` → mount + materialize via lifecycle. `AgentCreate` stays generic.

## 3. Existing pieces to reuse / 收编
- `Ezagent.Role` (recipe struct) ✓; `Role.Compose.materialize` (pure compose of role+flavor behaviors + skills/prompt) ✓; `Role.CapMint` ✓ (wire it into create); `Lifecycle` hooks (`create/1`,`activate/2`,`grant_initial_caps`) ✓; `:kind_base` slice ✓.
- **OrchestratorRole** = the existing code-seed exemplar (currently only feeds CLAUDE.md, not a spawn) → migrate it onto the unified role path (收编, repays #54 debt).

## 4. To build (the foundation)
1. **Per-instance mount/detach** (Part 1): runtime `:kind_base` mutation + per-instance dispatch resolution + `mount`/`detach` API; `CapabilityRegistry`→menu/validation. *(Highest blast radius — touches the core Kind/Behavior/dispatch model.)*
2. **Role registry + seed** (Part 2): name→recipe registry; `roles/0` plugin callback; `template://role` resolver branch + RoleTemplate Kind.
3. **Role-driven create via lifecycle** (Part 3): wire recipe lookup → `Role.Compose.materialize` → mount behaviors + config_dir + `CapMint` into the create/activate lifecycle; no `AgentCreate` role-branch.
4. **收编 OrchestratorRole** onto the unified path.

## 5. Risks (for codex review)
- **R1 (BLOCKER-class)** Part 1 is a core change to dispatch resolution (global→per-instance). Every Kind dispatches through this. Must preserve current behavior for agents that mount their full declared set; the per-instance resolution must be correct + performant + persistent (survive restart via `:kind_base` snapshot).
- **R2** `CapabilityRegistry` demotion: caps + collision checks are currently keyed Kind-global; per-instance mounting must still enforce caps/collisions correctly.
- **R3** boot/restart ordering: a mounted behavior set must rehydrate on cold restart (the #110/#113/#114 class).
- **R4** orchestrator收编 must not regress the cc orchestrator.

## 6. Acceptance (/goal — set after review)
- An agent is created with a role; its behaviors are **mounted per-instance** (and **detachable** at runtime); dispatch resolves per-instance.
- Roles are **defined as recipes** (code-seed + `roles/0` + `template://role`) and **applied via the lifecycle** with no role-specific branch in `AgentCreate`.
- `OrchestratorRole` migrated onto the unified path; cc orchestrator unregressed.
- Unblocks **kanban-as-role** (kanban-manager = a recipe mounted on a native flavor) — verified by that follow-on.
- full `mix test` 0 failures + CI green; cold-restart regression test for mounted sets.

## 7. Downstream (separate specs, depend on this)
- **kanban-as-role** (`kanban-as-role-spec.md` on `integration/kanban`) — kanban-manager recipe × native flavor; board via snapshot; delete Plan-B; world read-model list-by-role. Update it to reference this foundation + the corrections (board snapshot not file; native flavor needs no bridge).
- **orchestrator** — its long-pending role-Template materialization.
