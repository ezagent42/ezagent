# SPEC: `domain.agent` — first-class Agent provisioning + per-agent isolation invariants

**Status**: draft for Allen's 拍板 (sign-off). Produced by Claude + codex collaborative brainstorm, 2026-06-02.
**Relationship**: foundational layer UNDER creation-unification #533. Two specs, dependency-ordered (this one first).
**Origin**: the scenario-34 live-tier debugging session surfaced that "an agent" has no domain home for its identity + filesystem isolation + lifecycle, causing real production bugs (a shared `working_directory` made cc agents clobber each other's bridge token → `:no_bridge` silent drops).

## Allen's decisions (2026-06-02 review)
- **NO new "artifacts" abstraction.** Per-agent isolation is expressed through the EXISTING **`sandbox`** concept (`Ezagent.Behavior.Sandbox`, which already owns `config_dir_path` + `template_class` + `respawn_template_data` + `pty_phase` per agent). domain.agent EXTENDS the sandbox to be the authoritative per-agent isolation home — it does NOT introduce a parallel `runtime_dir`/artifact vocabulary. Wherever this doc earlier said "runtime_dir / generated-artifact path", read it as **"the agent's per-agent sandbox dir"** (today `config_dir_path`; the bug is the bridge config is written OUTSIDE it, to the shared cwd). This settles D2 → "domain owns the sandbox's per-agent location; plugin materializes content into it."
- **Proceed** ("请继续") to the PR-1 implementation plan. The exact bridge-identity / clobber mechanism (channel-join auth vs MCP-server token, and whether cwd itself must be per-agent) is the FIRST investigation step of the PR-1 plan — it is NOT assumed here (see §6).

---

## 1. Problem

"An agent" is not a first-class domain concern with owned invariants. Per-agent concerns are **scattered** across the cc plugin Template Class, AgentTemplate data, and ~7 spawn paths. Concrete failures this caused:

1. **Generated-artifact clobber (the trigger).** A cc agent's bridge connect TOKEN lives in a per-agent `.mcp.json` that `CcAgent.build_claude_cmd/3` writes to `Path.join(agent_cwd, ".mcp.json")` and points `--mcp-config` at. `agent_cwd` comes from the AgentTemplate's `working_directory`. The `cc-worker` template was seeded with `working_directory = ~/.ezagent/cc-orchestrator` (SHARED). Every cc agent spawned from it wrote its token to the SAME file → last-writer-wins → claude authenticated the bridge under the WRONG agent URI → all-but-last agents `:no_bridge`-dropped inbound silently. Orchestrators share that dir too.
2. **The naive fix made it worse.** Forcing a unique per-agent **cwd** fixed workers but BROKE the orchestrator (claude `trust_folder_dialog` on a fresh folder + the orchestrator's operator-MCP-bridge config is wired to the shared dir → never joined `orch:bridge` → `ensure_orchestrator` 90s timeout → `create_session` rollback). **Lesson (Allen): the orchestrator is just another cc agent and must NOT be special-cased.** The fix has to be uniform.
3. **Scattered creation paths.** `spawn_fresh/4` (bare Kind, no runtime), `spawn_from_template_content/4` (full instantiate), `add_managed_member/4`, `ensure_orchestrator/3`, SessionTemplate materialization — ~7 paths. A "manage-cap" (who may manage/edit an agent) can only be granted reliably if creation is ONE authorized chokepoint.
4. **No runtime capability/skill management.** Skills are template-time files under `claude_config_dir`; the only orchestrator-driven skill copy is the hardcoded `ezagent-session-orchestrator` gated on `role:"orchestrator"`; `update_member_template` (regenerate a member from a new template) is explicitly deferred.

**Codex's load-bearing correction (accepted):** v0 over-collapsed three distinct things — **project cwd**, **generated runtime artifacts** (the bridge `.mcp.json`/token), and **plugin config content**. The structural bug is **generated-artifact PLACEMENT**, not the cwd. So the first invariant is *domain allocates a unique generated-artifact location per agent*, decoupled from cwd. cwd stays the project cwd.

---

## 2. Goals / non-goals

**Goals**
- Make per-agent **identity** + **generated-artifact isolation** + **lifecycle** domain invariants the plugin cannot violate.
- Fix the clobber **uniformly** (workers + orchestrator), with **no cwd change** and **no orchestrator special-case**.
- Give the flavor plugins (cc/codex/curl) a **narrow launch/materialization contract** — they stop choosing WHERE files live.
- Lay the provenance + desired-state foundation so creation-unification #533 can grant a manage-cap at one chokepoint.

**Non-goals (YAGNI / explicitly out)**
- Modeling Claude settings / MCP-server JSON semantics / prompt-model-tool policy (stays in the plugin's `claude_config_dir`, per AgentTemplate's existing contract).
- Rewriting `Kind.spawn/2` or `SpawnRegistry.spawn/1` into authorized-create paths (they stay process-spawn mechanisms; domain.agent sits ABOVE them).
- Changing claude's runtime **cwd** in the bugfix (the reverted patch proves fresh cwd is hazardous).
- `update_member_template` / manage-cap **in the first PR** (they land later with #533).

---

## 3. Design

### 3.1 What `domain.agent` owns (the invariants)

1. **Canonical identity.** One place derives the agent URI / instance name (today scattered: `Session.derive_orchestrator_uri/2` + `derive_orchestrator_instance_name/1`, `Agent.session_instance_name/3`, `spawned_member_instance_name`).
2. **Per-agent sandbox ownership (NOT a new artifacts layer — Allen's call).** The existing **`sandbox`** is the per-agent isolation home. Today the sandbox already carries a per-agent `config_dir_path` (e.g. `~/.ezagent/default/cc-agents/<ws>/<agent>`), unique per agent. The clobber happens because the bridge config (`.mcp.json` carrying the connect token) is written OUTSIDE the sandbox — to the (shared) `cwd` — and claude resolves it from there. domain.agent makes the sandbox the AUTHORITATIVE place the per-agent bridge identity lives, and guarantees the plugin can't relocate it onto a shared path. The structural fix is uniform — including orchestrators — without inventing a parallel `runtime_dir`. (Exactly WHICH file/token decides bridge identity, and whether `cwd` itself must therefore be the per-agent sandbox dir, is the PR-1 investigation — see §6.)
2b. **Single agent-file-operation entry point (Allen 2026-06-02).** The root cause is broader than one duplicated token: an agent's filesystem footprint is written today by MULTIPLE uncoordinated entry points — `McpConfigWriter.write_with_token!` (writes `.mcp.json` to THREE places: `~/.ezagent`, git-toplevel, cwd), `CcAgent.create_agent_config_dir/2`, `apply_orchestrator_role_bootstrap/2`, `destroy_config_dir/2` — none of which is "the sandbox owns all agent file ops." Any one of them can leak a shared / mis-seeded path; the bridge-token clobber (PR-1) is a *symptom* of this scatter. domain.agent makes the **sandbox the single, auditable owner** of an agent's file operations; the plugin materializes content THROUGH the sandbox, not via independent writers. (PR-1 removes the immediate symptom; consolidating the writers is the PR-3 work.)

3. **Durable desired runtime spec + artifact manifest.** A clean domain-owned record of (a) the agent's desired runtime (flavor, source template, desired skills/role, provenance) and (b) which paths the domain ALLOCATED vs the plugin MATERIALIZED — so destroy/regenerate is precise without reverse-engineering `CcAgent.agent_config_dir/1`. (Today `Sandbox` persists operational restart data only — `config_dir_path`, `template_class`, `respawn_template_data`, `pty_phase` — not a clean desired spec.)
4. **Lifecycle.** spawn / ensure-running / **regenerate** / terminate, and **migration/normalization** of persisted `respawn_template_data` on cold restart.
5. **Provenance (designed now, enforced with #533).** First-class creator/provenance fields on the agent, so #533 can anchor the manage-cap on kind `:agent`.

### 3.2 The plugin contract (launch + materialization, NOT allocation)

The domain provides identity + paths + desired state; the plugin materializes flavor files + builds the launch and runs sidecars. Conceptual contract (shape, not final signature):

```
prepare_launch(agent_spec, flavor_content) :: {:ok, launch_plan} | {:error, term}
  agent_spec   = %{agent_uri, workspace_uri, project_cwd, runtime_dir, config_dir,
                   bridge_mcp_config_path, desired_skills, provenance, prev_desired_state}
  flavor_content = the AgentTemplate's flavor-specific content (claude_config_dir ref, flags, …)
  launch_plan  = %{argv, cmd_env, cwd, sidecars, artifact_manifest, respawn_data}
```

- **Domain provides:** `agent_uri`, `workspace_uri`, `project_cwd`, `runtime_dir`, `config_dir`, `bridge_mcp_config_path`, `desired_skills`, `provenance`, `prev_desired_state`.
- **Plugin provides:** validate flavor content; copy/render flavor config into the provided dirs; build `argv`/`cmd_env`; start/ensure sidecars; list/toggle flavor extensions; destroy flavor artifacts.
- **cc plugin:** keeps `build_claude_cmd/3`-style argv/env assembly + `apply_orchestrator_role_bootstrap/2` materialization + extension callbacks; **removes target-path selection** from `agent_config_dir/1` / `create_agent_config_dir/2`, and writes the bridge `.mcp.json` to the domain's `bridge_mcp_config_path`.
- **codex plugin [hypothesis]:** domain provides runtime dirs + identity bridge slots; plugin owns the app-server sidecar + the TUI that resumes a bridge-created thread. Do NOT force codex into cc's `.claude` model.
- **curl plugin [hypothesis]:** domain owns identity/provenance + desired config; plugin returns no sidecar, no filesystem artifacts (HTTP).

### 3.3 Boundary with creation-unification #533 (two specs)

| Concern | Owner |
|---|---|
| Canonical URI derivation, generated-artifact allocation, desired runtime spec, lifecycle/regenerate, respawn-data migration | **domain.agent** (this spec) |
| The single AUTHORIZED operator/orchestrator create path, creator identity, **manage-cap grant**, surface unification (Workspace `:create_agent`/`:create_session`, orchestrator `add_managed_member`) | **#533 creation-unification** |

domain.agent ships **first** and exposes a provisioning API; `ensure_orchestrator` + `add_managed_member` route through it; **then** #533 makes the operator/tool surfaces use that API and grant the manage-cap. The existing system-scoped-orchestrator-into-tenant-workspace exception (`Session.spawn_orchestrator_via_template_content/5` bypassing dispatch) becomes a #533 authorization concern; the provisioning still goes through domain.agent.

### 3.4 Migration (the dangerous part = cold restart, not fresh create)

Existing live agents have persisted `respawn_template_data["cwd"]` pointing at the OLD shared dir, and `Sandbox.activate/2 → CcAgent.ensure_subprocess_alive/2` reuses it on restart BEFORE any new create path runs — so the clobber recurs on restart unless handled. **Pattern:** on restart, **lazy-normalize** old respawn data before launching the subprocess — derive the domain `runtime_dir`/`bridge_mcp_config_path` from `agent_uri`, keep the old `"cwd"` as `project_cwd`, write the bridge token to the new path; then persist the normalized data in a **post-ready** write (never an empty/partial write — see the snapshot hazard). `CcAgent.destroy_config_dir/2` (which asserts the path equals `agent_config_dir(agent_uri)`) must accept old+new paths during migration, then domain owns cleanup via the artifact manifest.

**Snapshot hazard (must be guarded).** Observed this session: a Session/Agent Kind cold-start whose `activate` yields empty state, combined with `{:snapshot, :on_change}`, can persist the empty state OVER a good 256KB snapshot (wiping members/legends/working-copy). domain.agent's normalize-then-persist MUST be post-ready and MUST NOT write a partial/empty desired-state over a good one. (This is also a standalone lifecycle bug worth its own fix — see todo.)

---

## 4. Decomposition (dependency-ordered, small PRs)

| PR | Scope | Why here |
|---|---|---|
| **PR-1 (beachhead)** | Domain allocates a per-agent `runtime_dir` + `bridge_mcp_config_path` keyed on the canonical agent URI; thread through `Agent.spawn_from_template_content/4`; cc writes the bridge `.mcp.json` there (not `cwd/.mcp.json`) and `--mcp-config` points there. **No cwd change. No orchestrator special-case.** | Fixes the clobber uniformly; both `spawn_orchestrator_via_template_content/5` and `spawn_member/6` already route through `spawn_from_template_content/4`, so one primitive covers all. |
| **PR-2** | Split `AgentTemplate.working_directory` into `project_cwd` vs domain-generated artifact fields (touch `to_template_data/2`, `fetch_working_directory/1`). | Removes the field whose mis-seeding caused the bug; clarifies semantics. |
| **PR-3** | Move cc config-dir ALLOCATION from `CcAgent.agent_config_dir/1` into the domain allocator; plugin keeps materialization + cleanup callbacks (`create_agent_config_dir/2` copies into a domain-provided target). | Completes "domain allocates, plugin materializes." |
| **PR-4** | Normalize cold-restart state: lazy-normalize old `respawn_template_data` before launch; guard the empty-over-good snapshot hazard. | Old live agents must not break / re-clobber on restart. |
| **PR-5** | **#533**: single authorized create path + manage-cap grant; route Workspace `:create_agent`/`:create_session` + orchestrator `add_managed_member` through domain.agent with explicit provenance. | Authority lands once provisioning is unified. |
| **PR-6** | Desired skills/capabilities as domain-owned state + `update_member_template`/regenerate (plugin materializes). | After manage-cap; the deferred member-update finally has an owner. |

**PR-1 is the minimal beachhead** that fixes the live E2E blocker (the relay `.mcp.json` clobber) uniformly — and is the thing that unblocks the scenario-34 cc→codex→curl round-trip.

---

## 5. DECISION POINTS for Allen (这些要你拍板)

| # | Decision | Options | Recommended default |
|---|---|---|---|
| D1 | What must be unique FIRST? | (a) Claude cwd; (b) generated bridge/MCP artifact path; (c) full config+work tree | **(b)** artifact path; keep cwd = project cwd |
| D2 | Where is path allocation owned? | plugin / domain-all / domain-allocates-plugin-materializes | **domain allocates, plugin materializes** |
| D3 | One spec or two? | one big / two dependent | **two**: domain.agent first, #533 second |
| D4 | Minimal bugfix PR shape | fresh cwd for all / bridge `.mcp.json` under domain runtime dir / orchestrator-only exception | **bridge `.mcp.json` under domain runtime dir, no exception** |
| D5 | Old `respawn_template_data` | break old agents / lazy-normalize at restart / DB snapshot migration | **lazy-normalize before launch, then persist** |
| D6 | Who owns skills? | domain writes files / plugin ad hoc / domain owns desired, plugin materializes | **domain owns desired skills, plugin materializes** |
| D7 | manage-cap timing | first PR / wait for #533 / never | **wait for #533, but design provenance fields now** |
| D8 | Plugin interface | keep Template Class map forever / generic launch+materialization contract / full rewrite | **generic launch/materialization contract, shim existing Template Class maps** |
| D9 | config-dir cleanup migration | strict old-path only / accept old+new / domain owns cleanup | **accept old+new during migration, then domain owns via manifest** |
| D10 | `update_member_template` scope | first PR / with manage-cap / defer indefinitely | **with the manage-cap/regeneration phase (PR-6)** |

---

## 6. Open items to verify during planning
- Exactly how claude auto-discovers `.mcp.json` (project-root vs `--mcp-config`): PR-1 must ensure the per-agent token is read ONLY from the domain path and the shared `cwd/.mcp.json` no longer carries a per-agent token (otherwise auto-read re-introduces the clobber). Verify against `EzagentPluginCc.McpConfigWriter` (the 3 write sites a/b/c).
- The codex two-stage startup (app-server sidecar creates a thread, TUI resumes it) — confirm the plugin contract's `sidecars` field models it without leaking codex specifics into the domain.
- Concurrency: the domain allocator needs URI-scoped single-writer semantics for artifact generation (today `create_agent_config_dir/2` uses marker-file idempotence).

---

## 7. Next step after sign-off
Per the brainstorming → writing-plans flow: once Allen approves this design (and the D1–D10 calls), produce a detailed implementation plan for **PR-1 (the beachhead)** first — it both fixes the live E2E blocker and validates the domain-allocates/plugin-materializes split before the larger PRs.
