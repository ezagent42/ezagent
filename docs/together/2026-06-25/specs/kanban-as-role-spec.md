# SPEC — kanban as an agent (role `kanban-manager` × flavor `native`) — rev 2 (snapshot path)

> Re-scheme of #964's kanban from a `resource://` live Kind (Plan-B) to an **agent** with **role = kanban-manager × flavor = native**. Brainstormed with @林懿伦 (Feishu 2026-06-25). **rev 2** supersedes the earlier snapshot-vs-file wavering: **board stays Kind snapshot state** (Allen-decided); this is the lightweight "re-home behaviors into a role" path, NOT a rewrite. Built on **role-foundation** (`role-foundation-design.md` / `role-foundation-plan.md` rev3, on main). Depends on the foundation subset **RF-1 (done) + RF-4 + RF-5a + RF-6 + RF-7 + RF-8**; does NOT need RF-2/RF-3 (runtime mount/detach) or RF-9.

## 1. Why
`resource://` is documented as "**not a live Kind — pure data ref, filesystem on disk**" (`uri-design.md`). #964 (Plan-B) overloaded it with live spawnable Kinds (`resource_kinds/0` + `ResourceKindRegistry` + a workspace resource-dispatcher), conflicting with that + the "resource = unified FS encapsulation" north star. Allen's resolution: **agent = actor (any non-human operator)**; a kanban is such an actor; its job = a **role** (`kanban-manager`); *how* it executes = a **flavor** (`native` — no external engine). The board is the agent's own state.

## 2. What stays / what moves (code-verified against `origin/integration/kanban`)
**Current impl (kept unchanged):** `EzagentPluginKanban` behaviors — `Behavior.Kanban` (24 actions: add_node/rename_node/move_node/remove_node/set_stage/claim_node/unclaim_node/set_status/attach_artifact/detach_artifact/set_metric/drop_subtree/get_tree/export_markmap/import_markmap/…) + `Connectors` (sync_github/push_pr/register_pr/sync_prs/sync_miro/…). Reads via `ctx[:read].(:key, default)`, writes via `{:set, key, value}` converging through a single `commit/1`. **per-node CapBAC = owner-based write-auth** (`ctx.caller == node.owner` or admin wildcard); reads are whole-tree via `:get_tree`. **Persistence = Kind snapshot `{:snapshot, :on_change}` — UNCHANGED (board = snapshot state, NOT a resource:// file).**

**What moves:** these behaviors move from the standalone kanban **Kind** into the **`kanban-manager` role recipe**; the host becomes the generic `Entity.Agent` (flavor `native`); per-instance behavior loading is via **RF-1** (no Kind declaration of kanban behaviors).

## 3. Design
### 3.1 The recipe (`kanban-manager`)
`Ezagent.Role` recipe (code-seed via a `roles/0` callback on the kanban plugin — RF-4): `%{behaviors: [Behavior.Kanban, Behavior.Kanban.Connectors], requested_caps: [the 24 kanban caps + connector caps], skills: [...], prompt: ..., passive: true}`. Materialized via `Role.Compose.materialize(recipe, :native)` at create (RF-5a).

### 3.2 The flavor (`native`)
`native` `agent_flavor_decl` — host `kind: Entity.Agent`, NO sidecar/bridge (RF-8). It declares NOTHING kanban-specific; the kanban behaviors load **per-instance** via the recipe (RF-1 generalized keystone: a generic host dispatches recipe-loaded behaviors it does not declare; authz still gates). native's CapMint cap-policy (RF-8) grants the recipe's requested_caps (fail-closed default stated).

### 3.3 Board persistence — snapshot (UNCHANGED)
Board = the agent's Kind snapshot state (the tree), `{:snapshot, :on_change}`. The 24 handlers + `commit/1` + per-node owner-write-auth operate on the in-memory tree exactly as today. **No resource:// file, no FsResolver for the board.** (Future: a `kanban-manager` `export(board → file)` action if other agents need decoupled direct reads — backlog, NOT this spec.) Other agents/views read the board by dispatching `get_tree` to the manager (manager-mediated), as today.

### 3.4 Passive-actor isolation (RF-6)
`kanban-manager` is a **passive data actor** — `passive: true` on the recipe. The foundation's RF-6 gates (mention-resolver / `:join` / the universal `resolve_with_ctx` final-output filter) reject it: NOT @-mentionable, NOT joinable as a session member, does NOT receive chat. It acts ONLY on direct kanban.* dispatch.

### 3.5 world UI rewiring
- **read-model**: `kanban_data.ex` `state_for(component: "kanban")` changes from **list-by-Kind-type(:kanban)** → **list-by-role(kanban-manager)** (RF-7).
- **dispatch target**: the React `onWorkspacePluginAction` → `world:dispatch` target changes from the `resource://` Kind to **`entity://<ws>/agent/<kanban-manager-instance>?action=kanban.<action>`**. `Kanban.tsx`/`KanbanCanvas.tsx` rendering + `main.tsx` `case "kanban"` + `routes.ex /plugins/kanban/<id>` stay (only the dispatch URI + read-model source change).

### 3.6 Delete Plan-B
Remove `resource_kinds/0`, `ResourceKindRegistry`, and the workspace resource-dispatcher introduced by #964. `resource://` returns to pure-FS-only.

### 3.7 resource://-files-only gate (Allen's 3rd essential)
Add an **AST arch gate** (cap 0, like B's `raw_port_spawn_executable`) forbidding any `resource://` from being implemented as a live Kind / GenServer (`resource_kinds`-style registration). Permanently prevents the Plan-B pattern's return.

## 4. /goal (acceptance — Allen sets after review)
```
kanban-as-role 完成 = 全部满足：
1. kanban-manager role recipe（24 behaviors + Connectors + caps + passive:true）经 roles/0 注册；
   native flavor（host Entity.Agent，零 kanban 声明）经 RF-1 per-instance 加载这些 behaviors。
2. 创建一个 kanban-manager agent（role×native）→ 24 kanban 动作经 entity://agent dispatch 全部工作；
   board = snapshot state，commit/1 + per-node owner-写授权不变；get_tree 读整树。
3. passive 隔离：kanban-manager 不可被 @ / :join / 收 chat（RF-6 三闸）。
4. world：读模型 list-by-role；dispatch 目标 entity://agent；UI 渲染不变。
5. Plan-B 全删（resource_kinds/ResourceKindRegistry/resource-dispatcher）；resource:// 纯 FS。
6. resource-only-files AST gate 基线=0 且通过。
验收：全量 mix test 0 失败 + CI 绿；live e2e（agent-browser）创建 kanban-manager + 拖节点 + 截图；
导出功能列入 backlog（本任务不做）。
```

## 5. PR breakdown
- **K1** kanban-manager recipe + `roles/0` registration (depends RF-4).
- **K2** native flavor decl + CapMint cap-policy (depends RF-8); kanban behaviors load per-instance on Entity.Agent (RF-1) — dispatch test.
- **K3** create-a-kanban-agent path (RF-5a) + passive:true wired (RF-6) — e2e: create + dispatch + passive-rejection.
- **K4** world rewire: read-model list-by-role (RF-7) + dispatch target entity://agent.
- **K5** delete Plan-B + add resource-only-files AST gate.
- Each PR: four-property DoD + CI green + rebase.

## 6. Risks
- **R1** the 24 behaviors must be closure-clean as a recipe set (validate_closure!); verify no behavior requires a sibling slice not in the set.
- **R2** per-node owner-write-auth depends on `ctx.caller` — confirm the create path sets the kanban-manager's caller/identity correctly so node ownership works.
- **R3** world dispatch URI change must keep the existing cap-gating (the React action → world:dispatch → entity://agent must carry the caller's caps).
- **R4** deleting Plan-B must not break #964's other (non-Plan-B) pieces that landed.

## 7. Dependencies / sequencing
Implement after the foundation subset: **RF-1 (done) + RF-4 + RF-5a + RF-6 + RF-7 + RF-8**. K1..K5 then build on it. (RF-2/RF-3 runtime mount/detach + RF-9 orchestrator NOT required.)

## 8. Adversarial review (self, code-verified against origin) — VERDICT: sound on the snapshot path
- **✓ snapshot board on `Entity.Agent` — NO slice collision.** `Behavior.Kanban` is `use Ezagent.Lifecycle` with NO `state_slice:` → auto-derived slice `:kanban`. `Entity.Agent`'s base slices are `:identity`/`:sandbox`/`:api_keys`/`credential_grant`/`config_evolve` — none is `:kanban`. Entity.Agent's `{:snapshot,:on_change}` persists the `:kanban` slice. So the board lives + persists on the agent with no collision.
- **✓ RF-1 dispatch by action.** `runtime.ex` resolves via `BehaviorSet.resolve_action/3` keyed on the ACTION atom (the behavior-name segment is parsed but not used for resolution). `entity://<ws>/agent/<id>?action=kanban.add_node` → action `:add_node` → per-instance fallback finds `Behavior.Kanban` (it declares `:add_node`) on the generic `Entity.Agent` WITHOUT declaration. ✓
- **✓ closure.** `Behavior.Kanban`/`Connectors` read their OWN `:kanban` slice via `ctx[:read]`; no `reads_sibling`/`@required_reads` → the recipe set `[Kanban, Connectors]` is closed (no `validate_closure!` failure).
- **✓ per-node owner-write-auth (R2 resolved).** `owner_or_admin?(ctx, node)` = `ctx.caller == node.owner` or admin; `claim` sets `owner = caller`. Because kanban actions are **DIRECT dispatches** (not agent chat-receive — kanban-manager is passive), `ctx.caller` is the **human user**, threaded through `world:dispatch` → entity://agent. So owner auth compares user-to-owner exactly as today. **REQUIREMENT (R3):** world:dispatch MUST thread the human caller's identity + caps to the entity://agent target (NOT rewrite caller=agent).
- **✓ RF-7 genuinely needed.** `kanban_data.ex` `list_instances(:kanban)` filters by Kind type via `KindRegistry`; a kanban-manager is `Entity.Agent` Kind → `match_kind?(.., :kanban)` is false → list-by-role required. **Note (pre-existing, not introduced here):** `list_instances` walks only LIVE (Registry) instances, not all persisted — a kanban-manager must be live to appear; list-by-role inherits this.
- **✓ dispatch target rewire.** `kanban_data.ex` builds the target via `Ezagent.URI.resource(ws,"kanban",id)`; change to `entity://<ws>/agent/<id>`. The list source feeds the URI to the React side → wiring list-by-role to return `entity://agent` URIs handles both the list + the dispatch target.
- **✓ Plan-B deletion scope (~8 files, K5):** `plugin.ex` (resource_kinds callback), `resource_kind_registry.ex`, `ets_owner.ex` (table), `compile/ezagent_plugin_check.ex`, `arch_baseline_manifest.exs`, `resource_kind_registry_test.exs`, `domain_workspace/application.ex` (dispatcher startup), `kanban/application.ex` (resource_kinds registration), + delete the `spawn_via_resource_dispatcher_test.exs` e2e. Spans core + workspace + kanban — scope carefully.
- **Net:** spec is implementable as written; only refinement is the R3 caller-threading requirement (added above) + the list-LIVE-only note. No blocker.
