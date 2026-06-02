# SPEC: `domain.agent` — first-class Agent provisioning + per-agent isolation invariants

**Status**: decisions LOCKED (Allen 拍板 2026-06-02). PR-1 implemented (as-built diverged from the original beachhead — see §4). PR-2…6 pending per-PR plans.
**Relationship**: foundational layer UNDER creation-unification #533. Two specs, dependency-ordered (this one first).
**Origin**: the scenario-34 live-tier debugging session surfaced that "an agent" has no domain home for its identity + filesystem isolation + lifecycle, causing real production bugs (a shared `working_directory` made cc agents clobber each other's bridge token → `:no_bridge` silent drops).

## Allen's decisions (2026-06-02, LOCKED)
- **D1 — reuse the `sandbox`, NO new "artifact" concept.** Per-agent isolation is expressed through the EXISTING **`sandbox`** (`Ezagent.Behavior.Sandbox`, which already owns a per-agent `config_dir_path` + `template_class` + `respawn_template_data` + `pty_phase`). domain.agent EXTENDS the sandbox to be the authoritative per-agent isolation home. There is **no `runtime_dir` / `artifact` vocabulary** anywhere in this design — the per-agent location IS the sandbox's `config_dir`. (This doc has been swept to remove the earlier "artifact/runtime_dir" wording.)
- **D2–D10 — accepted at the recommended defaults** (see §5; the table now records the decision, not a proposal).
- **Strategy (2026-06-02): finish domain.agent BEFORE re-running the E2E.** The live blockers (relay-cc registry-row vanish, bridge-token clobber, session cold-restart wipe) are symptoms of this missing abstraction; they are solved systematically by PR-3 (writer consolidation) and PR-4 (cold-restart normalization), not by ad-hoc live patching.

---

## 1. Problem

"An agent" is not a first-class domain concern with owned invariants. Per-agent concerns are **scattered** across the cc plugin Template Class, AgentTemplate data, and ~7 spawn paths. Concrete failures this caused:

1. **Bridge-token clobber (the trigger).** A cc agent's bridge connect TOKEN was written into a per-agent `.mcp.json` by `EzagentPluginCc.McpConfigWriter.write_with_token!` — to THREE locations (`~/.ezagent`, git-toplevel, cwd), one of them SHARED. The `cc-worker` template was seeded with `working_directory = ~/.ezagent/cc-orchestrator` (SHARED). Every cc agent wrote its token to the SAME shared file → last-writer-wins → claude authenticated the bridge under the WRONG agent URI → all-but-last agents `:no_bridge`-dropped inbound silently. Orchestrators shared that dir too.
2. **The naive fix made it worse.** Forcing a unique per-agent **cwd** fixed workers but BROKE the orchestrator (claude `trust_folder_dialog` on a fresh folder + the operator-MCP-bridge config wired to the shared dir → never joined `orch:bridge` → `ensure_orchestrator` 90s timeout → `create_session` rollback). **Lesson (Allen): the orchestrator is just another cc agent and must NOT be special-cased.** The fix has to be uniform.
3. **Scattered creation paths.** `spawn_fresh/4` (bare Kind, no runtime), `spawn_from_template_content/4` (full instantiate), `add_managed_member/4`, `ensure_orchestrator/3`, SessionTemplate materialization — ~7 paths. A "manage-cap" (who may manage/edit an agent) can only be granted reliably if creation is ONE authorized chokepoint.
4. **No runtime capability/skill management.** Skills are template-time files under `claude_config_dir`; the only orchestrator-driven skill copy is the hardcoded `ezagent-session-orchestrator` gated on `role:"orchestrator"`; `update_member_template` (regenerate a member from a new template) is explicitly deferred.

**Codex's load-bearing correction (accepted):** v0 over-collapsed three distinct things — **project cwd**, **the generated bridge identity** (the `.mcp.json` token), and **plugin config content**. The structural bug is **WHERE the generated bridge identity lives**, not the cwd. cwd stays the project cwd. (As-built PR-1 went one step further — see §4 — and removed the token from any shared file entirely, routing identity through claude's process env, so no per-agent *file* path is needed for the bridge token at all.)

---

## 2. Goals / non-goals

**Goals**
- Make per-agent **identity** + **per-agent sandbox isolation** + **lifecycle** domain invariants the plugin cannot violate.
- Fix the clobber **uniformly** (workers + orchestrator), with **no cwd change** and **no orchestrator special-case**.
- Give the flavor plugins (cc/codex/curl) a **narrow launch/materialization contract** — they stop choosing WHERE files live.
- Lay the provenance + desired-state foundation so creation-unification #533 can grant a manage-cap at one chokepoint.

**Non-goals (YAGNI / explicitly out)**
- Modeling Claude settings / MCP-server JSON semantics / prompt-model-tool policy (stays in the plugin's `claude_config_dir`, per AgentTemplate's existing contract).
- Rewriting `Kind.spawn/2` or `SpawnRegistry.spawn/1` into authorized-create paths (they stay process-spawn mechanisms; domain.agent sits ABOVE them).
- Changing claude's runtime **cwd** in the bugfix (the reverted patch proves fresh cwd is hazardous).
- `update_member_template` / manage-cap **before #533** (PR-5/PR-6).
- A new `artifact` / `runtime_dir` layer (D1: the sandbox `config_dir` IS the per-agent home).

---

## 3. Design

### 3.1 What `domain.agent` owns (the invariants)

1. **Canonical identity.** One place derives the agent URI / instance name (today scattered: `Session.derive_orchestrator_uri/2` + `derive_orchestrator_instance_name/1`, `Agent.session_instance_name/3`, `spawned_member_instance_name`).
2. **Per-agent sandbox ownership (D1 — the sandbox, not a new layer).** The existing **`sandbox`** is the per-agent isolation home; it already carries a per-agent `config_dir_path` (e.g. `~/.ezagent/default/cc-agents/<ws>/<agent>`), unique per agent. domain.agent makes the sandbox the AUTHORITATIVE owner of that per-agent location and guarantees the plugin cannot relocate agent files onto a shared path. The original clobber happened because the bridge token was written OUTSIDE the sandbox (to the shared cwd / shared `~/.ezagent`); as-built PR-1 removed the token from any shared file (env-based identity), and PR-3 consolidates the remaining file writers so EVERY agent file op flows through the sandbox.
3. **Single agent-file-operation owner (Allen 2026-06-02).** An agent's filesystem footprint is written today by MULTIPLE uncoordinated entry points — `McpConfigWriter.write_with_token!` (`.mcp.json` to 3 places), `CcAgent.create_agent_config_dir/2`, `apply_orchestrator_role_bootstrap/2`, `destroy_config_dir/2` — none of which is "the sandbox owns all agent file ops." Any one can leak a shared / mis-seeded path. domain.agent makes the **sandbox the single, auditable owner**; the plugin materializes content THROUGH the sandbox, not via independent writers. (PR-1 removed the immediate symptom; consolidating the writers is PR-3.)
4. **Durable desired runtime spec.** A clean domain-owned record of (a) the agent's desired runtime (flavor, source template, desired skills/role, provenance) and (b) which paths the domain ALLOCATED vs the plugin MATERIALIZED — so destroy/regenerate is precise without reverse-engineering `CcAgent.agent_config_dir/1`. (Today `Sandbox` persists operational restart data only — `config_dir_path`, `template_class`, `respawn_template_data`, `pty_phase` — not a clean desired spec.)
5. **Lifecycle.** spawn / ensure-running / **regenerate** / terminate, and **migration/normalization** of persisted `respawn_template_data` on cold restart.
6. **Provenance (designed now, enforced with #533).** First-class creator/provenance fields on the agent, so #533 can anchor the manage-cap on kind `:agent`.

### 3.2 The plugin contract (launch + materialization, NOT allocation)

The domain provides identity + the per-agent sandbox location + desired state; the plugin materializes flavor files + builds the launch and runs sidecars. Conceptual contract (shape, not final signature):

```
prepare_launch(agent_spec, flavor_content) :: {:ok, launch_plan} | {:error, term}
  agent_spec     = %{agent_uri, workspace_uri, project_cwd, config_dir,
                     desired_skills, provenance, prev_desired_state}
  flavor_content = the AgentTemplate's flavor-specific content (claude_config_dir ref, flags, …)
  launch_plan    = %{argv, cmd_env, cwd, sidecars, respawn_data}
```

- **Domain provides:** `agent_uri`, `workspace_uri`, `project_cwd`, the sandbox-owned `config_dir`, `desired_skills`, `provenance`, `prev_desired_state`. (No `runtime_dir` / `bridge_mcp_config_path` — per D1 the per-agent home is the sandbox `config_dir`, and per as-built PR-1 the bridge identity rides `cmd_env`, not a file path.)
- **Plugin provides:** validate flavor content; copy/render flavor config into the provided `config_dir`; build `argv`/`cmd_env` (incl. the per-agent bridge identity in `cmd_env`); start/ensure sidecars; list/toggle flavor extensions; destroy flavor files.
- **cc plugin:** keeps `build_claude_cmd/3`-style argv/env assembly (which already exports the per-agent `EZAGENT_AGENT_URI`/token into `cmd_env`) + `apply_orchestrator_role_bootstrap/2` materialization + extension callbacks; **removes target-path selection** from `agent_config_dir/1` / `create_agent_config_dir/2` (domain provides the target).
- **codex plugin [hypothesis]:** domain provides the sandbox location + identity bridge slots; plugin owns the app-server sidecar + the TUI that resumes a bridge-created thread. Do NOT force codex into cc's `.claude` model.
- **curl plugin [hypothesis]:** domain owns identity/provenance + desired config; plugin returns no sidecar, no filesystem footprint (HTTP).

### 3.3 Boundary with creation-unification #533 (two specs)

| Concern | Owner |
|---|---|
| Canonical URI derivation, per-agent sandbox-location ownership, desired runtime spec, lifecycle/regenerate, respawn-data migration | **domain.agent** (this spec) |
| The single AUTHORIZED operator/orchestrator create path, creator identity, **manage-cap grant**, surface unification (Workspace `:create_agent`/`:create_session`, orchestrator `add_managed_member`) | **#533 creation-unification** |

domain.agent ships **first** and exposes a provisioning API; `ensure_orchestrator` + `add_managed_member` route through it; **then** #533 makes the operator/tool surfaces use that API and grant the manage-cap. The existing system-scoped-orchestrator-into-tenant-workspace exception (`Session.spawn_orchestrator_via_template_content/5` bypassing dispatch) becomes a #533 authorization concern; the provisioning still goes through domain.agent.

### 3.4 Migration (the dangerous part = cold restart, not fresh create)

Existing live agents have persisted `respawn_template_data["cwd"]` pointing at the OLD shared dir, and `Sandbox.activate/2 → CcAgent.ensure_subprocess_alive/2` reuses it on restart BEFORE any new create path runs. With as-built PR-1 the bridge token no longer rides a shared file, so the *token* clobber does not recur on restart; the remaining migration concern is ensuring each restarted agent's `config_dir` is its own per-agent sandbox dir (not the shared one) and that old `respawn_template_data` is normalized. **Pattern:** on restart, **lazy-normalize** old respawn data before launching — keep the old `"cwd"` as `project_cwd`, ensure `config_dir` = the per-agent sandbox dir derived from `agent_uri` — then persist the normalized data in a **post-ready** write (never an empty/partial write — see the snapshot hazard). `CcAgent.destroy_config_dir/2` (which asserts the path equals `agent_config_dir(agent_uri)`) must accept old+new paths during migration (D9), then domain owns cleanup.

**Snapshot hazard (must be guarded — PR-4).** Observed this session: a Session/Agent Kind cold-start whose `activate` yields empty state, combined with `{:snapshot, :on_change}`, can persist the empty state OVER a good 256KB snapshot (wiping members/legends/working-copy). This is **blocker #2** (bound-to-Feishu session wiped on cold boot). domain.agent's normalize-then-persist MUST be post-ready and MUST NOT write a partial/empty desired-state over a good one. (This is also a standalone lifecycle bug; PR-4 owns it.) **Codex review note:** `Ezagent.Kind.Server.init/1` already does `Snapshot.load_or_init` (load, kind/server.ex:110) BEFORE `persist_initial_snapshot` (:130), so the broad order is correct — the real fix is a concrete guard in `persist_initial_snapshot` / `Sandbox.activate/2` that refuses to write empty/default state when a good prior snapshot exists (`ever_created?`), plus an activate-time `{:ok, transients, reconciled_state}` write if lazy-normalization is to persist.

### 3.5 Delivery readiness + bridge lifecycle (blocker #1 — codex BLOCKER finding, 2026-06-02)

**Codex adversarial review refuted the original premise that PR-3 (file-writer consolidation) fixes blocker #1** (a cc relay member's row VANISHING from `AgentBridge.Registry` over time → `deliver → :no_bridge` → silent drop). A row that logged `join ok` was successfully `bind/3`'d; its later absence is a **lifecycle/termination/delivery** problem, NOT file placement. Two verified gaps:

1. **No delivery readiness for non-orchestrator agents.** `CcAgent.await_orchestrator_boot_readiness/2` (cc_agent.ex:~1508) returns `:ok` immediately for non-orchestrators — relay members are non-orchestrators, so NOTHING ensures their bridge is alive+bound before a routed message is delivered. Only orchestrators get the ensure/await gate.
2. **Routed delivery silently drops `:no_bridge`.** `Chat.handle_receive/3` (chat.ex:686) calls `_ = Ezagent.AgentBridge.deliver(...)` and discards the result; `AgentBridge.deliver/2` / `drop/2` (agent_bridge.ex:11-47) do not respawn or rebind on a miss. So once a relay member's row is gone, every routed message to it is dropped invisibly.

The remaining root-cause question (WHY the row vanishes) is a bridge/channel/PtyServer lifecycle issue — likely the cc subprocess / Python MCP bridge / WS channel exits (`PtyServer` child-exit stops the server; the Channel `terminate/2 → Registry.unbind/2` then removes the row), with no proactive rebind. This is the actual fix for the live E2E and is a **domain.agent lifecycle invariant** (§3.1.5), not file ownership.

---

## 4. Decomposition (dependency-ordered, small PRs)

| PR | Scope | Status / why here |
|---|---|---|
| **PR-1 (beachhead)** | **AS-BUILT (diverged from plan, simpler):** made the shared bridge `.mcp.json` clobber-safe by **removing per-agent identity** (`EZAGENT_AGENT_URI`/token) from it — identity now flows via claude's process env (`cmd_env`, set per-agent in `CcAgent.build_claude_cmd/3`, inherited by every MCP server claude launches); the shared `.mcp.json` env block keeps only `EZAGENT_BRIDGE_WS_URL`. **No per-agent path allocated, no cwd change, no orchestrator special-case.** | **DONE** (commit `29e04550`, `mcp_config_writer.ex` + test). Fixes the clobber uniformly. NOTE: this means the "domain allocates a per-agent bridge path" idea is moot for the *token*; the per-agent need that remains is the cc **`config_dir`** (PR-3) + cwd/field clarity (PR-2). |
| **PR-2** | Split the overloaded `AgentTemplate.working_directory` into an explicit **`project_cwd`** vs the sandbox-owned `config_dir` (touch `to_template_data/2`, `fetch_working_directory/1`). | Removes the field whose shared mis-seeding caused the bug; makes "cwd is the project dir, per-agent files live in the sandbox `config_dir`" explicit. |
| **PR-DR (delivery readiness — blocker #1)** | Extend the ensure-alive + await-registration gate from orchestrator-only to **all bridge-backed agents**, so a routed message to a cc relay member ensures its subprocess/bridge is alive+bound before delivery; make `Chat.handle_receive/3` NOT silently drop `:no_bridge` (ensure/rebind path); root-cause + fix the actual subprocess/bridge exit that drops the row. | **The real systematic fix for blocker #1** (relay-cc vanish), per the codex BLOCKER finding (§3.5). A domain.agent lifecycle invariant. THIS is what unblocks the cc→codex→curl round-trip. |
| **PR-3** | Move cc `config_dir` ALLOCATION from `CcAgent.agent_config_dir/1` into the domain (sandbox-owned), and route ALL agent file ops (`McpConfigWriter` 3 sites, `create_agent_config_dir/2`, `apply_orchestrator_role_bootstrap/2`, `destroy_config_dir/2`) through the sandbox as the single owner; plugin keeps materialization + cleanup callbacks. **Coupled with PR-2 via `working_directory`/`"cwd"`/`agent_config_dir` — needs compat shims (accept old+new), not a clean cut (codex MEDIUM).** | **Config-ownership cleanup — NOT the blocker-#1 fix** (codex correction). Removes the latent file-writer scatter; structural hygiene, not E2E-gating. |
| **PR-4** | Normalize cold-restart state: lazy-normalize old `respawn_template_data` before launch (D5); **guard the empty-over-good snapshot** — concrete check in `persist_initial_snapshot`/`Sandbox.activate/2` refusing empty/default over a good prior snapshot (`ever_created?`), per codex §3.4 note (the load-before-persist order is already correct). | **Systematic fix for blocker #2** (session cold-restart wipe). Old live agents must not break / re-clobber on restart. |
| **PR-5** | **#533**: single authorized create path + manage-cap grant; route Workspace `:create_agent`/`:create_session` + orchestrator `add_managed_member` through domain.agent with explicit provenance (D7). | Authority lands once provisioning is unified. Separate spec (#533). |
| **PR-6** | Desired skills/capabilities as domain-owned state + `update_member_template`/regenerate, plugin materializes (D6, D10). | After manage-cap; the deferred member-update finally has an owner. |

**Codex correction to the blocker→PR mapping:** blocker #1 (relay-cc vanish) ≠ file scatter ⇒ it is **PR-DR**, not PR-3. blocker #2 (session wipe) = **PR-4**. The bridge-token clobber = PR-1 (done).

**"Complete domain.agent" (Allen's directive) — the E2E-clearing core = PR-DR + PR-4** (the two that actually fix the live blockers), plus **PR-2 + PR-3** (cwd/config-dir isolation cleanup). PR-5 (#533 authority) and PR-6 (member regenerate) are the next layer, after the E2E validates the core. Fastest-to-E2E ordering: **PR-DR → PR-4 → (E2E) → PR-2 → PR-3 → PR-5 → PR-6**.

---

## 5. DECISION POINTS — LOCKED (Allen 拍板 2026-06-02)

| # | Decision | DECIDED |
|---|---|---|
| D1 | What must be unique FIRST? | **Reuse the sandbox `config_dir`** (per-agent already); NO new artifact concept; cwd stays = project cwd. (As-built PR-1: the bridge *token* needs no path at all — env-based.) |
| D2 | Where is path allocation owned? | **domain allocates, plugin materializes** |
| D3 | One spec or two? | **two**: domain.agent first, #533 second |
| D4 | Minimal bugfix PR shape | **uniform, no orchestrator exception** (as-built: shared `.mcp.json` made clobber-safe via env) |
| D5 | Old `respawn_template_data` | **lazy-normalize before launch, then persist (post-ready)** |
| D6 | Who owns skills? | **domain owns desired skills, plugin materializes** |
| D7 | manage-cap timing | **wait for #533 (PR-5), but design provenance fields now** |
| D8 | Plugin interface | **generic launch/materialization contract, shim existing Template Class maps** |
| D9 | config-dir cleanup migration | **accept old+new during migration, then domain owns cleanup** |
| D10 | `update_member_template` scope | **with the manage-cap/regeneration phase (PR-6)** |

---

## 6. Open items to verify during per-PR planning
- **PR-3:** confirm claude's `.mcp.json` auto-discovery (project-root vs `--mcp-config`) cannot re-introduce a shared-path read once allocation moves to the sandbox `config_dir`; verify against the 3 `McpConfigWriter` write sites. (The token itself is already env-based after PR-1, so this is about the remaining config files.)
- **PR-3 (codex):** the codex two-stage startup (app-server sidecar creates a thread, TUI resumes it) — confirm the `sidecars` field models it without leaking codex specifics into the domain.
- **PR-3 concurrency:** the domain allocator needs URI-scoped single-writer semantics for `config_dir` creation (today `create_agent_config_dir/2` uses marker-file idempotence).
- **PR-4:** reproduce the empty-over-good snapshot in a test before fixing; confirm the boot cold-start path loads from snapshot before any `:on_change` persist.

---

## 7. Process
Decisions are locked. **Codex adversarial-review done (2026-06-02)** — outcome folded in above: BLOCKER (PR-3 does not fix blocker #1 → added PR-DR), HIGH (delivery-readiness hole; PR-4 ordering already correct, needs concrete empty-over-good guard), MEDIUM (PR-2/PR-3 coupling → compat shims; PR-1 fixes identity clobber only, shared `.mcp.json` discovery can still clobber server-command shape), LOW (stale python-bridge comment). Next per brainstorming → writing-plans: detailed plan for **PR-DR first** (the blocker-#1 fix that unblocks the E2E), then PR-4, then PR-2/PR-3; each plan → codex review → TDD before code.
