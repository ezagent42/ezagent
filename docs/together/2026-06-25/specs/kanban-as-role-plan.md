# kanban-as-role — Implementation Plan (K1..K5)

> From `kanban-as-role-spec.md` rev2 (snapshot path) + its §8 self-review. Target branch `feat/kanban-as-role`; lead verifies+merges each PR. **Depends on the foundation subset landed on main: RF-1 (done) + RF-4 + RF-5a + RF-6 + RF-7 + RF-8.** Each PR: TDD + four-property DoD + `mix precommit`/check_invariants/arch.scan green + rebased + dedicated worktree + codex adversarial review + lead verify+merge.

**Goal:** kanban becomes an agent (role `kanban-manager` × flavor `native`); board stays Kind snapshot state; 24 behaviors re-homed into a recipe, dispatched per-instance on `Entity.Agent`; passive isolation; world list-by-role; Plan-B deleted; resource-only-files gate.

**Global constraints:** board = `:kanban` snapshot slice (no collision with Entity.Agent slices — verified). kanban actions are DIRECT dispatches carrying the human caller (passive actor, no chat-receive). world:dispatch MUST thread the human caller's identity+caps to entity://agent. resource:// stays pure FS.

---

### K1 — `kanban-manager` recipe + `roles/0` registration  (depends RF-4 **and RF-6**)
**Files:** `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex` (add `roles/0` callback returning the kanban-manager `Ezagent.Role` recipe).
**Recipe (review-corrected):** `behaviors: [Ezagent.Behavior.Kanban]` **ONLY** — `Kanban.Connectors` is NOT a Behavior (no `use Lifecycle`, no `actions/0`); all 24 actions (node + the 9 connector actions) are declared as `action(...)` in `kanban.ex` and forwarded to `Connectors` via thin `handle_x`, so they ALL resolve through `Behavior.Kanban` (BLOCKER-1). `requested_caps:` = **cap-template maps** `%{behavior: Ezagent.Behavior.Kanban, action: :<a>}` per action — NOT bare atoms (`Role.new/1` `canon_cap` rejects non-maps; HIGH-1). `passive: true` — **the `passive` field does NOT exist on `%Role{}` today; RF-6 MUST add it to the struct + `Role.Compose` + the create-attrs the gates read** (BLOCKER-2). So K1's passive assertion depends on **RF-6**, not RF-4.
**Steps:** [ ] failing test: `Role.new(recipe) == {:ok, %Role{behaviors: [Behavior.Kanban], passive: true}}` (catches BLOCKER-1 + HIGH-1 + BLOCKER-2 in one gate); [ ] `RoleRegistry.lookup("kanban-manager")` returns it; [ ] add `roles/0` + recipe (caps as `{behavior,action}` maps); [ ] register at boot (RF-4); [ ] suite + commit. Depends **RF-4 + RF-6**.

### K2 — kanban-recipe per-instance dispatch verification on Entity.Agent  (rescoped — review HIGH-2)
**Boundary (corrected):** **RF-8 OWNS** the `native` `agent_flavor_decl` (`flavor:"native"`, `kind: Entity.Agent`) + native's GENERIC CapMint cap-policy (grants a recipe's `requested_caps`, fail-closed). K2 does NOT re-add them. If native's generic policy already grants recipe caps, **no kanban-specific cap work is needed**; K2 is purely the dispatch-verification gate.
**Steps:** [ ] failing test: spawn `Entity.Agent` with `%{behaviors: [Behavior.Kanban]}` → `kanban.add_node` dispatches (RF-1 `resolve_action`) + `:kanban` slice materializes + `commit/1` persists via Entity.Agent snapshot; a sibling Entity.Agent without it → `:unknown_action`; [ ] confirm native's CapMint (RF-8) grants the kanban `requested_caps` (add a kanban-specific allow-list ONLY if native's generic policy doesn't); [ ] suite + commit. Depends RF-1, RF-8.

### K3 — create a kanban-manager agent (role×native) + passive wired + e2e
**Files:** the create path (RF-5a generic role step) — create with role `kanban-manager` × flavor `native`; `passive: true` flows through `Role.Compose` (RF-6).
**Steps:** [ ] failing test: create a kanban-manager agent → its 24 actions dispatch via `entity://<ws>/agent/<id>?action=kanban.<a>` with the caller's caps; board persists (snapshot); [ ] **passive test**: the kanban-manager is NOT @-mentionable / NOT `:join`-able / does NOT receive chat (RF-6 gates); [ ] per-node owner test: `claim` sets owner=caller, a non-owner non-admin `rename_node` is denied (owner_or_admin?); [ ] implement create wiring; [ ] suite + commit. Depends RF-5a, RF-6.

### K4 — world rewire: list-by-role + entity://agent dispatch
**Files:** `apps/ezagent_plugin_world/lib/ezagent/world/kanban_data.ex` (`list_instances(:kanban)` → list-by-role(kanban-manager), RF-7; build target URI `entity://<ws>/agent/<id>` instead of `Ezagent.URI.resource(ws,"kanban",id)`); `world/agent_actions.ex` / KanbanActions (pass the entity:// URI; thread the human caller's caps — R3). React `Kanban.tsx`/`KanbanCanvas.tsx`/`main.tsx case "kanban"` unchanged (only the URI + read-model source change).
**HIGH-3 (liveness — must address):** today `list_instances` walks the LIVE Registry only; a PASSIVE kanban-manager has no chat traffic to keep it warm, so after a BEAM restart it's dormant → if list-by-role is live-only, the board **silently vanishes** from the UI (chicken-and-egg: the UI gets the dispatch URI FROM the list). Fix: **RF-7 list-by-role MUST enumerate PERSISTED managers (not live-only)**, OR K4 adds an `ensure_spawned` for listed managers (parallel to the old `session_kanban_uri`/ensure_spawned path at `kanban_data.ex:88`). `Invocation.dispatch` lazy-spawns-from-snapshot, so once listed+dispatched the manager revives.
**Steps:** [ ] failing test: world read-model returns kanban-manager agents via list-by-role with `entity://agent` URIs; a kanban action from world dispatches with the caller's caps (R3 — verified: `dispatch_ctx` sets caller=human, not rewritten); [ ] **cold-restart test: restart → list-by-role still returns the manager (persisted) → board renders** (HIGH-3); [ ] rewire read-model (persisted enumeration) + dispatch target + ensure_spawned; [ ] world LiveView/dispatch tests green; [ ] commit. Depends RF-7, K3.

### K5 — delete Plan-B + resource-only-files AST gate
**Files (delete):** `apps/ezagent_core/lib/ezagent/resource_kind_registry.ex` + its test; `plugin.ex` `resource_kinds/0` callback; `ets_owner.ex` resource_kind table; `compile/ezagent_plugin_check.ex` resource_kinds check; `domain_workspace/application.ex` resource-dispatcher startup; `kanban/application.ex` resource_kinds registration; `kanban/test/e2e/spawn_via_resource_dispatcher_test.exs`; manifest entries. **Add:** an AST arch gate `resource_kind_as_genserver` (cap 0) in `ezagent.arch.scan.ex` forbidding any `resource_kinds`-style registration / resource:// → live-Kind (like B's `raw_port_spawn_executable`).
**AST gate predicate (concrete — review MEDIUM):** `resource_kind_as_genserver` (cap 0) flags, via `Code.string_to_quoted` AST walk over lib files: (a) any module defining a `def resource_kinds(` / `@impl` `resource_kinds/0` plugin callback, (b) any call to a `ResourceKindRegistry`-style register, (c) any `resource://`→live-Kind/GenServer dispatch wiring. Ship with positive fixture (a `resource_kinds/0` module → flagged) + negative fixture (a normal `resource_types/0` FsResolver → NOT flagged). Note path: `apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex`.
**Steps:** [ ] failing gate test (positive+negative fixtures, cap 0); [ ] implement the AST matcher in `ezagent.arch.scan.ex` + manifest baseline 0; [ ] delete Plan-B pieces (resource_kind_registry.ex+test, plugin.ex resource_kinds, ets_owner table, domain_workspace/application.ex dispatcher, kanban/application.ex registration, spawn_via_resource_dispatcher_test.exs, manifest entries); [ ] full suite + check_invariants + arch.scan green (no orphaned refs); [ ] commit. Depends K1-K4 (kanban works via the new path BEFORE deleting the old — no neither-path window).

---

## Order / deps
K1 (RF-4 **+ RF-6** for passive) → K2 (RF-1/8) → K3 (RF-5a/6) → K4 (RF-7) → K5 (after the new path works). **The foundation subset is mostly UNBUILT** — only RF-1 is on `feat/role-foundation`; RF-4/5a/6/7/8 must land first; K-work cannot start until then. Final acceptance: live e2e (agent-browser) — create a kanban-manager agent + drag a node + screenshot; full mix test 0 failures + CI green; resource-only-files gate=0.

## Corrections this plan imposes on the role-foundation impl (fold into RF-6 / RF-7)
- **RF-6 must add a `passive` field to `%Ezagent.Role{}`** (role.ex:46-51 has none — `Role.new/1` currently drops it) + thread it through `Role.Compose` into the spawned agent's attributes that the mention/`:join`/receive gates read. Without this, K1's `passive:true` is silently dropped.
- **RF-7 list-by-role must enumerate PERSISTED instances** (not just the live Registry), so a dormant passive kanban-manager still appears in the board list after a BEAM restart (else HIGH-3 board-vanish).

## Codex plan-review (folded — code-verified) — VERDICT: executable after corrections
- **BLOCKER-1** recipe drops `Connectors` (not a Behavior) → `behaviors:[Behavior.Kanban]` only. ✓ folded (K1).
- **BLOCKER-2** `passive` field absent on `%Role{}` → RF-6 adds it; K1 depends RF-6. ✓ folded (K1, deps, RF-6 correction).
- **HIGH-1** `requested_caps` = `{behavior,action}` cap-template maps + a `Role.new=={:ok}` gate test. ✓ folded (K1).
- **HIGH-2** K2 rescoped; RF-8 owns native flavor + cap policy. ✓ folded (K2).
- **HIGH-3** passive-actor liveness: RF-7 enumerate persisted + K4 cold-restart test. ✓ folded (K4, RF-7 correction).
- **MED** K5 AST-gate predicate + fixtures specified. ✓ folded (K5).
- Confirmed sound (verified): R3 caller-threading (`dispatch_ctx` caller=human, not rewritten); `with_action` on entity://; `:kanban` slice no-collision; K5 deletion list complete + correctly ordered.
