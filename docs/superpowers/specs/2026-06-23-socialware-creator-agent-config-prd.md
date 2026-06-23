# PRD: world agent config/create — agent-contract adaptation

> **Date:** 2026-06-23 · **Author:** Claude (with the dev, PM-framed) · **Tracking:** `socialware-creator-agent-config`
> **Branch:** `socialware-creator-agent-config` (off `origin/main`) · **Deadline:** 2026-06-23 20:00 +08:00 (18:00 fallback = smallest demonstrable artifact)
> **Handoff:** `docs/together/2026-06-23/handoffs/socialware-creator-agent-config.md`
> **Required reading honored:** `ezagent-developer` skill; agent-contract design + spec1 + spec3; `world-coordination.md`.

## 0. Mission (narrowed)
Adapt the **existing** world agent create/config/detail surface (`Identities.tsx`: `AgentNewForm` / `AgentDetail` / `AgentApiKeys` / `AgentExtensions`) to the latest **AgentManifest / agent-contract** shape — so an operator can create/configure an agent with **contract-safe fields**, the page **explains the full contract shape**, and it **never leaks derived config or raw caps**. **Not** a new socialware creator; **not** a world-nav change.

## 1. Phase-0 field model (verified against `origin/main`)
The agent contract sorts into **three buckets**; the UI must respect them.

| Bucket | Fields | UI treatment |
|---|---|---|
| **AUTHOR** | `name`, `soul` (persona), `skills`, `tools`, `caps` (**desired**), `lifecycle` | author-editable inputs |
| **EXECUTOR** | `flavor` (candidate list), `executor.params` (`project_cwd`, `config_dir`, `settings_path`, `mcp_config_path`, `model`, `provider`, …), `fallback`, `on_exhausted` | author-editable; **`flavor.compile/2` output is NOT** |
| **DERIVED** (read-only, never author input) | `version_hash`/`tag`, `created_by`/`at`, `parent_template_uri`, **compiled config** (`CLAUDE.md`, `settings.json`, `system_prompt`), `config_dir` files, **actual granted caps** | read-only status / not shown as editable |

Source: `agent_manifest.ex:17-33`, `agent_template.ex:33-127`, spec1 §3 (`flavor.compile` purity G-INV-5; no `derived_config` write-back G-INV-2), spec3 (version hash/tag). **CapBAC:** `caps` is *desired* — the system grants via the `Ezagent.Identity.Grant` chokepoint; the UI must **not** mint caps.

## 2. Gap — what the current backend create path accepts
`AgentNewForm` submits `{flavor, name, cwd, caps, with_pty}`; `world_live.ex dispatch_agent_create/2` → `Ezagent.Workspace.create_agent/3` accepts **`%{flavor, name, cwd, with_pty}`** (+ caps granted separately via `grant_initial_caps/3`). It does **not** build from an AgentManifest.

| contract field | form | `create_agent/3` | status |
|---|---|---|---|
| `name` · `flavor` · `cwd`(=project_cwd) · `with_pty` | ✓ | ✓ | **supported now** |
| `caps` | ✓ | ✓ (post-create grant) | **supported now** (relabel "desired caps") |
| `soul` · `skills` · `tools` · `lifecycle` · `desired_skills` · `desired_caps` | ✗ | ✗ not accepted | **needs `create_agent/3` extension** (proposed §5) |
| `config_dir` | ✗ | auto-derived | non-blocker (intentional per-agent isolation) |
| executor extras (cc `settings_path`/`mcp_config_path`; curl `model`/`provider`/`api_url`) | ✗ | ✗ | **needs extension** (proposed §5) |
| `parent_template_uri` (fork) | ✗ | `--from` CLI only | deferred |

## 3. Design decision (PM, 2026-06-23)
**Design for the extended `create_agent/3`; propose the extension in the PR; Allen decides which parts to land.** The trend is clear — we *will* extend the create path to accept the full contract, so the design should not be artificially capped by today's backend. Therefore:
- The create page is designed at the **full contract shape, all fields enabled** (Author + Executor + Desired caps). It is the target the backend grows toward — not a lowest-common-denominator of what `create_agent/3` happens to accept right now.
- The PR carries a concrete **backend extension proposal** (§5): exactly what `create_agent/3` / the file-flavor template-registration path must accept to satisfy each field, each tagged **discuss-first** so Allen reviews and chooses what to push in which order.
- We still honor the hard rules: **no unilateral backend/schema/CapBAC change** lands without Allen's sign-off; the UI **never mints caps** and **never invents a parallel storage path** — fields whose backend extension Allen hasn't approved yet are wired to the extension once it lands, not to a side channel.
- **Deadline pragmatics:** what ships first is the contract-shaped UI with the **already-supported** fields fully wired (real create works today), plus the proposal. Each approved extension then flips its field from "proposed" to "wired" without redesign.

## 4. Screens
Both screens live **inside the existing world shell** — far-left global nav rail (**总览 / 会话 / 身份(active) / 工作区**, `main.tsx:336-340`) + the Identities surface. No new route, no nav change. Create = `/identities/agents/new`; detail = `/identities/agents/:uri` with its existing sub-tabs (详情 / caps / api-keys / extensions / terminal). `★` = field that needs the §5 backend extension (designed enabled; wired when Allen lands the extension).

### 4.1 Agent create — `身份 › Agents › 新建`
```
┌──────┬───────────────────────────────────────────────────────────┐
│ 总览 │ 身份 › Agents › 新建                                        │
│ 会话 │ ① Author                                                   │
│[身份]│   name        [ storefront-greeter            ]            │
│ 工作 │   soul ★      [ 你是前台导购… {{customer_name}}        ]   │
│  区  │   skills ★    [ greet, triage ]                            │
│      │   tools ★     [ dispatch tool 声明（action/participant）]  │
│      │   lifecycle ★ [ persistent ▾ ]                             │
│      │ ② Executor                                                 │
│      │   flavor [ cc ▾ ]   project_cwd [ /srv/acme/storefront ]   │
│      │   ☐ with_pty        config_dir 自动派生（只读）            │
│      │   params ★：cc settings_path/mcp · curl model/provider     │
│      │ ③ Desired caps                                             │
│      │   caps  [ chat.send, workspace.read ]  请求→系统授予        │
│      │   ★ = 需扩 create_agent/3（PR 附扩展提案）       [ 创建 ]   │
└──────┴───────────────────────────────────────────────────────────┘
```

### 4.2 Agent detail / config — `身份 › Agents › cc_greeter-7f3a` (read-only)
```
┌──────┬───────────────────────────────────────────────────────────┐
│ 总览 │ 身份 › Agents › cc_greeter-7f3a                            │
│ 会话 │ [详情] caps · api-keys · extensions · terminal            │
│[身份]│ cc_greeter-7f3a · running · flavor cc · bridge connected   │
│ 工作 │ ────────────────────────────────────────────────────────  │
│  区  │ # Executor（只读）   flavor cc · project_cwd … · params    │
│      │ # 授予的 caps（只读·CapBAC）  chat.send · workspace.read   │
│      │ # Config & 扩展（只读）  config_dir … · API keys · ext     │
│      │ # 版本 / 模板  per-agent template …@<hash>（或 direct-spawn）│
│      │ ⊘ 派生/编译（CLAUDE.md·settings.json·system_prompt）只读，  │
│      │   flavor.compile 生成（G-INV-2 / G-INV-5）                 │
└──────┴───────────────────────────────────────────────────────────┘
```

## 5. Backend extension proposal (PR carries this; Allen picks what lands)
Each item is what `create_agent/3` (and the path behind it) must accept to wire the matching `★` form field. All **discuss-first** — proposed, not unilaterally implemented. No parallel storage: a field stays "proposed" in the UI until its extension lands.

| # | Field(s) | Proposed backend change | Where it threads | Risk |
|---|---|---|---|---|
| E1 | `soul`, `skills`, `tools`, `lifecycle` | Extend `create_agent/3` args to accept a manifest-shaped payload; build an inline `%AgentManifest{}` and route through the **existing** file-flavor template-registration path (`agent_create.ex` cc/codex branch → persisted template's `desired_skills` etc.) or `AgentManifest.load/1`. | `world_live.ex dispatch_agent_create/2` → `Workspace.create_agent/3` → `agent_create.ex` | med — touches create contract (additive args), no schema change if mapped to existing template fields |
| E2 | executor extras (`settings_path`/`mcp_config_path` cc; `model`/`provider`/`api_url` curl) | Accept per-flavor `executor.params` in the create args; pass to the flavor's template-data extras (already exist on `AgentTemplate`). | same as E1 | low — `AgentTemplate` already has these extra fields; just not collected at create |
| E3 | `desired_caps` (granted at spawn vs post-create `grant_initial_caps`) | Optionally thread desired caps into the template so they grant atomically at spawn instead of a second call. | `agent_create.ex` + Grant chokepoint | low/med — CapBAC-adjacent → **discuss-first with extra care** |
| E4 | `parent_template_uri` (fork from existing template) | Surface the CLI `--from` clone in the create payload. | `coerce_create_args/1` already reads `from` | low — deferred (not in this task's screens) |

**Hard line:** none of E1–E4 ships without Allen's sign-off; the UI wires each field only after its extension lands (`feedback_let_it_crash_no_workarounds` — no shim, no side channel).

## 6. Scope
**Designed (this PRD + PR):** the full contract-shaped create form (all fields) + read-only detail, inside the existing world shell, with the §5 extension proposal.

**Wired now (deadline-safe, no backend change):** `name` / `flavor` / `project_cwd` (rename from `cwd`) / `with_pty` / `caps` (relabel "desired caps"). Re-shape `AgentNewForm` into the ① Author / ② Executor / ③ Desired caps groups; additive state in `identity_data.ex` (`agent_new_form`) for the section metadata + the `★` proposed markers. `AgentDetail` shows **read-only** executor/flavor + granted caps + config_dir + version/template status, reusing `AgentApiKeys`/`AgentExtensions`; **no editable derived config**. Verify a **real create** (cc or echo) → screenshot + agent URI/status.

**Wired after Allen approves (per §5):** the `★` fields (`soul/skills/tools/lifecycle`, executor extras), each flipped from proposed → live as its extension lands.

**Out / deferred:** AgentManifest **runtime schema** change; any **CapBAC semantics** change; a new creator route; template/team editors; routing/team management; manifest versioning UI; fork-from-template (E4).

## 7. Definition of Done (from handoff §5)
- [ ] Screenshot of the updated world agent create page (contract-shaped).
- [ ] Evidence of a real create using contract-safe fields (agent URI/status).
- [ ] Agent detail shows contract/executor status without exposing derived config as editable.
- [ ] No broad socialware creator route introduced.
- [ ] No CapBAC / AgentManifest runtime schema change without discuss-first.
- [ ] Focused tests/gates for touched files (or a note if only UI copy changed).

## 8. world-coordination
**Wired-now part** touches only the world **identity/agent config** surface (`Identities.tsx` + `identity_data.ex` + the `dispatch_agent_create` clause); additive, no new route, no nav change, no `styles.css` restyle. Owns identity/agent-config UI; does not touch hello rendering or session routing UI (handoff §7). **The §5 extension proposal** does reach `domain_workspace` (`agent_create.ex` / `create_agent/3`) — that part is **discuss-first and lands only on Allen's approval**, separately from the UI slice, so the world UI change stays mergeable on its own.
