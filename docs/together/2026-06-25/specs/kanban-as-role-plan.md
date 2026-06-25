# kanban-as-role — Implementation Plan (K1..K5)

> From `kanban-as-role-spec.md` rev2 (snapshot path) + its §8 self-review. Target branch `feat/kanban-as-role`; lead verifies+merges each PR. **Depends on the foundation subset landed on main: RF-1 (done) + RF-4 + RF-5a + RF-6 + RF-7 + RF-8.** Each PR: TDD + four-property DoD + `mix precommit`/check_invariants/arch.scan green + rebased + dedicated worktree + codex adversarial review + lead verify+merge.

**Goal:** kanban becomes an agent (role `kanban-manager` × flavor `native`); board stays Kind snapshot state; 24 behaviors re-homed into a recipe, dispatched per-instance on `Entity.Agent`; passive isolation; world list-by-role; Plan-B deleted; resource-only-files gate.

**Global constraints:** board = `:kanban` snapshot slice (no collision with Entity.Agent slices — verified). kanban actions are DIRECT dispatches carrying the human caller (passive actor, no chat-receive). world:dispatch MUST thread the human caller's identity+caps to entity://agent. resource:// stays pure FS.

---

### K1 — `kanban-manager` recipe + `roles/0` registration
**Files:** `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex` (add `roles/0` callback returning the kanban-manager `Ezagent.Role` recipe); a `roles.ex`/inline recipe builder. Recipe = `%{behaviors: [Ezagent.Behavior.Kanban, Ezagent.Behavior.Kanban.Connectors], requested_caps: <the 24 kanban caps + connector caps>, skills: [], prompt: nil, passive: true}`.
**Steps:** [ ] failing test: `RoleRegistry.lookup("kanban-manager")` returns the recipe with the 24 behaviors + passive:true; [ ] add `roles/0` + recipe; [ ] register at boot (RF-4 mechanism); [ ] `Role.new/1` validates the recipe (real behaviors, closed set); [ ] suite + commit. Depends RF-4.

### K2 — `native` flavor + CapMint policy + per-instance dispatch on Entity.Agent
**Files:** `native` `agent_flavor_decl` (RF-8 — likely already added by RF-8; if so, K2 just adds the cap-policy for kanban's caps). CapMint policy granting the recipe's requested_caps (fail-closed default).
**Steps:** [ ] failing test: spawn `Entity.Agent` with `%{behaviors: kanban-recipe-behaviors}` → `kanban.add_node` dispatches (RF-1 resolve_action) + the `:kanban` slice materializes; a non-kanban Entity.Agent → `:unknown_action`; [ ] cap-policy test: CapMint grants the 24 caps under native; [ ] implement; [ ] suite + commit. Depends RF-1, RF-8.

### K3 — create a kanban-manager agent (role×native) + passive wired + e2e
**Files:** the create path (RF-5a generic role step) — create with role `kanban-manager` × flavor `native`; `passive: true` flows through `Role.Compose` (RF-6).
**Steps:** [ ] failing test: create a kanban-manager agent → its 24 actions dispatch via `entity://<ws>/agent/<id>?action=kanban.<a>` with the caller's caps; board persists (snapshot); [ ] **passive test**: the kanban-manager is NOT @-mentionable / NOT `:join`-able / does NOT receive chat (RF-6 gates); [ ] per-node owner test: `claim` sets owner=caller, a non-owner non-admin `rename_node` is denied (owner_or_admin?); [ ] implement create wiring; [ ] suite + commit. Depends RF-5a, RF-6.

### K4 — world rewire: list-by-role + entity://agent dispatch
**Files:** `apps/ezagent_plugin_world/lib/ezagent/world/kanban_data.ex` (`list_instances(:kanban)` → list-by-role(kanban-manager), RF-7; build target URI `entity://<ws>/agent/<id>` instead of `Ezagent.URI.resource(ws,"kanban",id)`); `world/agent_actions.ex` / KanbanActions (pass the entity:// URI; thread the human caller's caps — R3). React `Kanban.tsx`/`KanbanCanvas.tsx`/`main.tsx case "kanban"` unchanged (only the URI + read-model source change).
**Steps:** [ ] failing test: world read-model returns kanban-manager agents via list-by-role with `entity://agent` URIs; a kanban action from world dispatches to the agent with the caller's caps (cap-gate intact); [ ] rewire read-model + dispatch target + caller threading; [ ] world LiveView/dispatch tests green; [ ] commit. Depends RF-7, K3.

### K5 — delete Plan-B + resource-only-files AST gate
**Files (delete):** `apps/ezagent_core/lib/ezagent/resource_kind_registry.ex` + its test; `plugin.ex` `resource_kinds/0` callback; `ets_owner.ex` resource_kind table; `compile/ezagent_plugin_check.ex` resource_kinds check; `domain_workspace/application.ex` resource-dispatcher startup; `kanban/application.ex` resource_kinds registration; `kanban/test/e2e/spawn_via_resource_dispatcher_test.exs`; manifest entries. **Add:** an AST arch gate `resource_kind_as_genserver` (cap 0) in `ezagent.arch.scan.ex` forbidding any `resource_kinds`-style registration / resource:// → live-Kind (like B's `raw_port_spawn_executable`).
**Steps:** [ ] failing gate test (cap 0); [ ] delete Plan-B pieces; [ ] add the AST gate + manifest baseline 0; [ ] full suite + check_invariants + arch.scan green (no orphaned refs); [ ] commit. Depends K1-K4 (kanban works via the new path before deleting the old).

---

## Order / deps
K1 (RF-4) → K2 (RF-1/8) → K3 (RF-5a/6) → K4 (RF-7) → K5 (after the new path works). Final acceptance: live e2e (agent-browser) — create a kanban-manager agent + drag a node + screenshot; full mix test 0 failures + CI green; resource-only-files gate=0.

## Self-review (open Qs for codex plan-review)
- K2: is `native` flavor's `agent_flavor_decl` added by RF-8 or does K2 add it? Confirm the boundary.
- K3: does RF-5a's generic create step accept a role name + flavor, and does `Role.Compose` thread `passive` into the spawned agent's attributes for RF-6's gates to read?
- K4: exact caller-threading seam in `world:dispatch` → entity://agent (where caps are attached) — confirm it's not rewritten to caller=agent.
- K5: deletion order — must kanban fully work via the agent path (K1-K4 merged) BEFORE deleting Plan-B, else a window with neither.
