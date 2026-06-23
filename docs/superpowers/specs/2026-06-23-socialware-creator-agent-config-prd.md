# PRD: world agent config/create — agent-contract adaptation

> **Date:** 2026-06-23 · **Author:** Claude (with the dev, PM-framed) · **Tracking:** `socialware-creator-agent-config`
> **Branch:** `socialware-creator-agent-config` (off `origin/main`) · **Deadline:** 2026-06-23 20:00 +08:00 (18:00 fallback = smallest demonstrable artifact)
> **Handoff:** `docs/together/2026-06-23/handoffs/socialware-creator-agent-config.md`
> **Required reading honored:** `ezagent-developer` skill; agent-contract design + spec1 + spec3; `world-coordination.md`.

## 0. Mission (narrowed)
Adapt the **existing** world agent create/config/detail surface (`Identities.tsx`: `AgentNewForm` / `AgentDetail` / `AgentApiKeys` / `AgentExtensions`) to the latest **AgentManifest / agent-contract** shape — so an operator can **create an agent with the supported contract-safe fields, judge whether it succeeded, and see which contract fields aren't wired yet**. The page is operator-task-first, not a contract-teaching page; it **never leaks derived config or raw caps**. **Not** a new socialware creator; **not** a world-nav change.

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

## 3. Design decision (PM-reviewed, 2026-06-23)
**Ship the supported fields enabled; show the rest as a read-only "Contract coverage" list (Pending backend approval); hand the `create_agent/3` extension to Allen as a separate proposal — the UI does NOT presume it.**

An earlier draft of this PRD designed "all fields enabled." A PM review flagged that as misleading: an operator would fill `soul/skills/tools/…`, submit, and **nothing would take effect**, because `create_agent/3` accepts only `{flavor, name, cwd, with_pty}` (+ a separate caps grant). Deciding to extend `create_agent/3` is **Allen's call, not ours**. Corrected posture:
- **Submittable create form = backend-supported fields only**, enabled: `name`, `flavor`, `project_cwd`, `with_pty`, `requested caps`. Filling them creates a **real** agent today.
- **The rest of the contract** (`soul/skills/tools/lifecycle`, executor extras, fork) appears as a **read-only "Contract coverage" list** with a per-field badge — `Wired` vs `Pending backend approval` — so the page is honest about the full contract **without faking inputs**. No `★` jargon, no input-looking-but-dead fields.
- **§5 is a proposal handed to Allen**, not something the UI has cashed. If/when he approves an item, that field **graduates** from the coverage list into the submittable form. The UI never wires a field to a side channel (`feedback_let_it_crash_no_workarounds` — no shim).
- **CapBAC stays honest:** the form collects **requested** caps (parsed + validated, with inline feedback); the detail page shows the **granted** caps separately. The UI never mints caps.

## 4. Screens
Both screens live **inside the existing world shell** — far-left global nav rail (**总览 / 会话 / 身份(active) / 工作区**, `main.tsx:336-340`) + the Identities surface. No new route, no nav change. Create = `/identities/agents/new`; detail = `/identities/agents/:uri` with its existing sub-tabs (详情 / caps / api-keys / extensions / terminal).

### 4.1 Agent create — `身份 › Agents › 新建`
**Submittable form = supported fields only** (enabled). Below it, a read-only **Contract coverage** list — never submittable inputs.
```
┌──────┬───────────────────────────────────────────────────────────┐
│ 总览 │ 身份 › Agents › 新建                                        │
│ 会话 │ name         [ storefront-greeter        ]  *必填           │
│[身份]│ flavor       [ cc ▾ ]                                       │
│ 工作 │ project_cwd  [ /srv/acme/storefront ]  *cc/codex 必填,curl免│
│  区  │ ☐ with_pty                                                  │
│      │ requested caps [ chat.send, workspace.read ]   解析校验 ✓   │
│      │   ↑ 这是「请求」；授予在详情页只读显示（requested ≠ granted）│
│      │                                              [ 创建 ]       │
│      │ ── Contract coverage（只读 · 本页不可填）────────────────── │
│      │   soul · skills · tools · lifecycle   [Pending backend appr]│
│      │   executor extras (settings/mcp/model) [Pending backend appr]│
│      │   fork（parent template）              [Deferred]           │
└──────┴───────────────────────────────────────────────────────────┘
```

### 4.2 Agent detail — `身份 › Agents › cc_greeter-7f3a` (read-only, **labeled fields — replaces the current JSON dump**)
```
┌──────┬───────────────────────────────────────────────────────────┐
│ 总览 │ 身份 › Agents › cc_greeter-7f3a                            │
│ 会话 │ [详情] caps · api-keys · extensions · terminal            │
│[身份]│ cc_greeter-7f3a · running · flavor cc · bridge connected   │
│ 工作 │ Executor      flavor cc · project_cwd /srv/… · with_pty true│
│  区  │ Granted caps（CapBAC 授予） chat.send · workspace.read     │
│      │ Config        config_dir .claude/cc_greeter-7f3a · ext     │
│      │ Version/模板  per-agent template …@<hash>（或 direct-spawn）│
│      │ ⊘ 派生/编译（CLAUDE.md·settings.json·system_prompt）只读   │
│      │   现状是 JSON dump（Identities.tsx:275）→ 本任务改成可读字段│
└──────┴───────────────────────────────────────────────────────────┘
```

## 5. Backend extension proposal — handed to Allen (NOT presumed by the UI)
This is a **proposal for Allen to accept/sequence** — the UI ships without these until he approves (§3). It records the precise blocker per contract field so the decision is concrete. No parallel storage: a coverage-list field **graduates** into the submittable form only when its extension lands.

| # | Field(s) | Proposed backend change | Where it threads | Risk |
|---|---|---|---|---|
| E1 | `soul`, `skills`, `tools`, `lifecycle` | Extend `create_agent/3` args to accept a manifest-shaped payload; build an inline `%AgentManifest{}` and route through the **existing** file-flavor template-registration path (`agent_create.ex` cc/codex branch → persisted template's `desired_skills` etc.) or `AgentManifest.load/1`. | `world_live.ex dispatch_agent_create/2` → `Workspace.create_agent/3` → `agent_create.ex` | med — touches create contract (additive args), no schema change if mapped to existing template fields |
| E2 | executor extras (`settings_path`/`mcp_config_path` cc; `model`/`provider`/`api_url` curl) | Accept per-flavor `executor.params` in the create args; pass to the flavor's template-data extras (already exist on `AgentTemplate`). | same as E1 | low — `AgentTemplate` already has these extra fields; just not collected at create |
| E3 | `desired_caps` (granted at spawn vs post-create `grant_initial_caps`) | Optionally thread desired caps into the template so they grant atomically at spawn instead of a second call. | `agent_create.ex` + Grant chokepoint | low/med — CapBAC-adjacent → **discuss-first with extra care** |
| E4 | `parent_template_uri` (fork from existing template) | Surface the CLI `--from` clone in the create payload. | `coerce_create_args/1` already reads `from` | low — deferred (not in this task's screens) |

**Hard line:** none of E1–E4 ships without Allen's sign-off; the UI wires each field only after its extension lands (`feedback_let_it_crash_no_workarounds` — no shim, no side channel).

## 6. Scope
**MVP (today — a real create loop, deadline-safe, no backend change):**
- Submittable form = `name` / `flavor` / `project_cwd` (rename from `cwd`) / `with_pty` / `requested caps`, with **flavor-differentiated required fields**: cc/codex require `project_cwd`; curl/np don't; echo requires it only with `with_pty` (`agent_create.ex:144-157`).
- **Requested-caps input parses + validates** via `Capability.Parser` with inline feedback; labeled "requested", distinct from the detail page's "granted".
- **Failure feedback, no silent drop** (handoff §4 + invariant #9 "no silent drops at user-facing surfaces"): surface `cwd_required_for_cc`, bad-caps parse error, `grant_initial_caps` failure, and workspace-authz failure as explicit operator-facing messages.
- On success → land on the **detail page** with **labeled readable status** (agent URI / status / flavor / project_cwd / config_dir / granted caps), reusing `AgentApiKeys`/`AgentExtensions`; **replace the current JSON dump** (`Identities.tsx:275`) with labeled fields; **no editable derived config**.
- A read-only **Contract coverage** list naming the not-yet-wired contract fields with a `Pending backend approval` badge.
- Additive state in `identity_data.ex` (`agent_new_form` / `agent_detail`); no broad rewrite of the identities surface.

**Handed to Allen (separate, §5):** the `create_agent/3` extension for `soul/skills/tools/lifecycle` + executor extras + spawn-time `desired_caps`. Each, once approved, **graduates** from the coverage list into the form.

**Out / deferred:** caps **preset/picker** (follow-up — MVP does parse+validate only, not a picker); `tools`/`fallback`/`on_exhausted` as advanced manifest authoring (not a quick-create task); AgentManifest **runtime-schema** change; any **CapBAC semantics** change; a new creator route; template/team editors; routing/team management; versioning UI; fork-from-template (E4).

## 7. Definition of Done (from handoff §5)
- [ ] Screenshot of the updated world agent create page (supported fields + Contract coverage list).
- [ ] Evidence of a **real create** using supported fields, for **two flavors** (cc with cwd; a no-cwd flavor) — agent URI/status captured.
- [ ] Create **failures surface explicit operator messages** (cwd missing / bad caps / grant or authz failure) — **no silent drop**.
- [ ] Detail page renders **labeled readable status** (not a raw JSON dump); **requested vs granted** caps are distinct.
- [ ] **Contract coverage** list shows not-yet-wired fields as `Pending backend approval`, with **no submittable inputs** for them.
- [ ] Agent detail shows contract/executor status **without exposing derived config as editable**.
- [ ] No broad socialware creator route introduced.
- [ ] No CapBAC / AgentManifest runtime schema change without discuss-first.
- [ ] Focused tests/gates for touched files (or a note if only UI copy changed).

## 8. world-coordination
**Wired-now part** touches only the world **identity/agent config** surface (`Identities.tsx` + `identity_data.ex` + the `dispatch_agent_create` clause); additive, no new route, no nav change, no `styles.css` restyle. Owns identity/agent-config UI; does not touch hello rendering or session routing UI (handoff §7). **The §5 extension proposal** does reach `domain_workspace` (`agent_create.ex` / `create_agent/3`) — that part is **discuss-first and lands only on Allen's approval**, separately from the UI slice, so the world UI change stays mergeable on its own.
