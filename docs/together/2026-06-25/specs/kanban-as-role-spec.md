# SPEC — kanban as an agent (role `kanban-manager` × flavor `native`)

> Re-scheme of #964's kanban from a `resource://` live Kind (Plan-B) to an **agent** (`entity://agent/...`) with **role = kanban-manager**, **flavor = native**. Decided with @林懿伦 (Feishu 2026-06-25). Base: `integration/kanban` (= #964 rebased onto main `dde54e1b`). Goal: keep `resource://` as pure FS; reuse the agent (actor) model; delete Plan-B.

## 1. Why
`resource://` is documented (`uri-design.md`) as "**not a live Kind — pure data ref, filesystem on disk**" + the prior plugin-resource-type design (`resource_types/0` + `FsResolver`) made it the unified FS-encapsulation seam. #964 overloaded `resource://` with live spawnable Kinds (`resource_kinds/0`), conflicting with that. Allen's resolution: **agent = actor (any non-human operator, not just LLM)**; a kanban is such an actor; its job is a **role** (`kanban-manager`); *how* it executes is a **flavor** (`native` — no external engine). The board's data is a `resource://` file the agent holds.

## 2. Target model
- **kanban instance = an agent**: `entity://agent/<ws>/<name>`, materialized from **role `kanban-manager` × flavor `native`** (via `Ezagent.Role.Compose`).
- **role `kanban-manager`** (`template://<ws>/role/kanban-manager`): `behaviors: [Ezagent.Behavior.Kanban, Ezagent.Behavior.Kanban.Connectors]`, kanban skills/plugins, `requested_caps` = the 24 kanban actions, `session_template: nil` (action-driven, no conversation). Flavor-agnostic (no :flavor/:kind fields) ✓.
- **flavor `native`** (NEW): the execution substrate for no-external-engine operator agents. `kind: Ezagent.Entity.Agent`, no sidecar/PTY/app-server, in-process bridge (or none), `instance_behaviors` = base only (role supplies the kanban behaviors). Registered via `agent_flavors/0` (in a small `ezagent_plugin_native` or core-adjacent home — see Q1).
- **board data** = the agent's config_dir file: `resource://<ws>/native-agents/<name>/board.json` (or the agent's sandbox path) — read/written by `Behavior.Kanban`. **`resource://` stays pure FS** ✓.
- **interaction** = dispatch to the agent: `entity://agent/<ws>/<name>/behavior/kanban/<action>`. per-node CapBAC = the agent's cap model (`Shared.admin?`/`owner_or_admin?` map onto the agent's caps). Connectors = the role's outbound behavior.

## 3. What gets DELETED (Plan-B machinery)
- `apps/ezagent_core/lib/ezagent/resource_kind_registry.ex` + its test.
- The `resource_kind_decl` type + `resource_kinds/0` callback on `Ezagent.Plugin` (and the default impls).
- The workspace-domain `resource` spawn dispatcher (the `register_resource_spawn_fn` path added for kanban) — confirm no other resource-kind exists (kanban is the only one).
- `EzagentPluginKanban.Kanban` as a standalone Kind module (its behaviors move to the role; the module may shrink to just the role/flavor declarations or be removed).
- `apps/ezagent_plugin_kanban/test/e2e/spawn_via_resource_dispatcher_test.exs` (replaced by the agent-spawn path test).

## 4. What CHANGES
- **kanban plugin** declares the **role** (`roles/0` or the role-template registration mechanism — see Q2) instead of `resource_kinds/0`; keeps `Behavior.Kanban`(+Connectors/Shared) as the role's behaviors.
- **native flavor plugin** (new, tiny) declares `agent_flavors/0 → [%{flavor: "native", kind: Entity.Agent, ...}]`.
- **world wiring**: `kanban_data.ex` `state_for(component: "kanban")` reads the board via dispatch to the kanban-manager **agent** (not the resource Kind); `kanban_actions.ex` dispatches actions to `entity://agent/.../behavior/kanban/<action>`. The agent demand-spawns via the normal agent path (LocalRuntime.ensure_started + entity dispatcher + flavor/role compose) — no resource dispatcher.
- **world routes/UI**: `/plugins/kanban/<id>` now addresses a kanban-manager agent URI. **`Kanban.tsx`/`KanbanCanvas.tsx` unchanged** (read-model + `onWorkspacePluginAction`→`world:dispatch` preserved).
- **board create**: "new kanban" = create an agent (role kanban-manager × native) — via the unified agent create path (not a resource spawn).

## 5. Open questions (for brainstorm/codex review)
- **Q1 native flavor home**: a new `ezagent_plugin_native` plugin, or fold `native` into an existing home? It must register `agent_flavors/0` without core naming it (plugin-isolation). What does a "no sidecar, in-process" flavor's `kind`/bridge/transport look like concretely (echo is the closest precedent — its bridge is `in_process_sync`)?
- **Q2 role registration**: how is a role-template (`template://<ws>/role/kanban-manager`) registered/seeded by a plugin today? Is there a `roles/0` plugin callback, or are roles operator-authored Templates? (Role exists as `Ezagent.Role` + `Role.Compose`, but the plugin→role registration path needs confirming.) If none, this spec must define the role-seed mechanism — or kanban-manager ships as a seeded default role.
- **Q3 board-data lifecycle**: config_dir file create-on-spawn + read/write by Behavior.Kanban + persistence across restart (agent snapshot vs the file is the source of truth). Which is authoritative — the file or a snapshot?
- **Q4 native + role compose**: does `Role.Compose` cleanly handle a behaviors-only role × a no-engine flavor (no LLM sandbox to load)? Verify the compose path doesn't assume a sidecar.
- **Q5 create UX**: does "create kanban" go through the agent-create UI/flow, or a kanban-specific create that targets role:kanban-manager? (Coordinate with the agent console / A consolidation.)

## 6. Acceptance (/goal — to set after review)
- kanban instances are agents (`entity://agent/...`), role kanban-manager × flavor native; `resource://` carries **only** FS data (no live Kind); `resource_kinds/0`/`ResourceKindRegistry`/resource-dispatcher **deleted**; arch scan confirms no `resource_kind` surface remains.
- All kanban actions/connectors/per-node CapBAC work via dispatch to the agent; world UI (Kanban.tsx) unchanged + green.
- full `mix test` 0 failures + CI green; **E2E**: create kanban (agent) → add node → claim → status → connector → 9-stage chain → drop, via the live world UI (agent-browser), on the disposable stack.

## 7. Plan sketch (PRs on `integration/kanban`)
- **K1** add `native` flavor (+ its tiny plugin) + a compose test (native × a behaviors-only role).
- **K2** define `kanban-manager` role + seed mechanism (Q2); move `Behavior.Kanban` into the role; kanban plugin declares the role, drops `resource_kinds/0`.
- **K3** delete Plan-B (resource_kind_registry, resource_kind_decl/callback, workspace resource-dispatcher, the resource-dispatcher e2e); kanban Kind module retired.
- **K4** world wiring → dispatch to the kanban-manager agent (kanban_data/kanban_actions); board → config_dir file; routes/UI target agent URIs.
- **K5** tests + E2E on disposable stack.
- Each PR: four-property DoD + CI green + rebased; dedicated worktree.
