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
| `name` · `flavor` · `cwd`(=project_cwd) · `with_pty` | ✓ | ✓ | **supported** |
| `caps` | ✓ | ✓ (post-create grant) | **supported** (relabel "desired caps") |
| `soul` · `skills` · `tools` · `lifecycle` · `desired_skills` · `desired_caps` | ✗ | ✗ **not accepted** | **BLOCKER** (§5) |
| `config_dir` | ✗ | auto-derived | non-blocker (intentional per-agent isolation) |
| executor extras (cc `settings_path`/`mcp_config_path`; curl `model`/`provider`/`api_url`) | ✗ | ✗ | **BLOCKER** |
| `parent_template_uri` (fork) | ✗ | `--from` CLI only | gap (defer) |

## 3. Design decision (PM, 2026-06-23)
**Show-but-disable + precise blocker.** The create page presents the **whole contract shape** grouped by bucket; the fields the backend can't accept today (`soul/skills/tools/lifecycle`, executor extras) are **visible but disabled** with an inline blocker (`需后端扩 create_agent/3 · discuss-first`). It **collects only backend-supported fields** and **invents no parallel storage**. Rationale: the handoff asks the page to *explain* the contract + *surface precise blockers*, not silently drop fields or fake inputs.

## 4. Screens

### 4.1 Agent create (contract-shaped form)
```
屏 1 · Agent 创建（contract-shaped）
┌──────────────────────────────────────────────────────────────────┐
│ ① 身份 / Author                                                    │
│   name           [ storefront-greeter            ]   启用           │
│   ⌐ - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - ⌐  │
│   | soul（persona）· skills · tools · lifecycle  —— 可见但禁用     |  │
│   | ⊘ blocker：需后端扩 create_agent/3 收这些字段（discuss-first）  |  │
│   ⌐ - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - ⌐  │
│ ② Executor（后端支持）                                             │
│   flavor [ cc ▾ ]   project_cwd [ /srv/acme/storefront        ]    │
│   ☐ with_pty        config_dir = 自动派生（只读）                  │
│   ⊘ Executor 扩展禁用：cc settings/mcp · curl model/provider       │
│ ③ Desired caps（后端支持）                                         │
│   caps  [ chat.send, workspace.read ]  请求→系统按 CapBAC 授予      │
│   ⌐ Blocker: create_agent/3 仅接受 flavor/name/cwd/with_pty(+caps) ⌐│
│   ⌐ soul/skills/tools/lifecycle 需 discuss-first 扩后端，不造平存 ⌐│
│                                                       [ 创建 ]      │
└──────────────────────────────────────────────────────────────────┘
```

### 4.2 Agent detail / config (read-only contract/executor status)
```
屏 2 · Agent 详情（只读 contract/executor 状态）
┌──────────────────────────────────────────────────────────────────┐
│ entity://acme/agent/cc_greeter-7f3a · running                     │
│ flavor cc · bridge connected                                       │
│ ──────────────────────────────────────────────────────────────    │
│ # Executor（只读）  flavor cc · project_cwd … · with_pty · params  │
│ # 授予的 caps（只读·CapBAC）  chat.send · workspace.read（系统授予）│
│ # Config & 扩展（只读）  config_dir … · API keys · extensions      │
│ # 版本 / 模板  per-agent template …@<hash>（或 direct-spawn 无模板）│
│ ⌐ ⊘ 派生/编译配置（CLAUDE.md·settings.json·system_prompt）不在此编辑 ⌐│
│ ⌐    由 flavor.compile 生成（契约不变式 G-INV-2 / G-INV-5）        ⌐│
└──────────────────────────────────────────────────────────────────┘
```

## 5. Precise blockers (return these; do NOT invent parallel storage)
1. **`create_agent/3` only accepts `{flavor, name, cwd, with_pty}`** (+ separate caps grant). To collect `soul/skills/tools/lifecycle/desired_skills/desired_caps`, the backend create path must thread them into the manifest/template (`agent_create.ex` file-flavor template registration or an `AgentManifest.load`-based path). **Extending or rerouting create is discuss-first** (handoff §6).
2. **Executor extras** (`settings_path`/`mcp_config_path` for cc; `model`/`provider`/`api_url` for curl) aren't accepted by `create_agent/3` either → same blocker, same discuss-first.
3. **`parent_template_uri` (fork from an existing template)** is CLI-only (`--from`); not in the create payload → deferred.

## 6. Scope
**In (this task, deadline-safe):**
- Re-shape `AgentNewForm` per the contract buckets (① Author / ② Executor / ③ Desired caps), **enabled** only for `name` / `flavor` / `project_cwd` (rename from `cwd`) / `with_pty` / `caps` (relabel "desired caps"); **disabled + blocker** for `soul/skills/tools/lifecycle` + executor extras.
- Additive state in `identity_data.ex` (`agent_new_form`): contract-section metadata + the blocker copy. No broad rewrite of the identities surface.
- `AgentDetail` shows **read-only** executor/flavor + granted caps + config_dir + version/template status, reusing `AgentApiKeys`/`AgentExtensions`; **no editable derived config**.
- Verify a **real create** with the supported fields (cc or echo) → capture screenshot + resulting agent URI/status; capture the precise blocker for the unsupported fields.

**Out / deferred:** any backend `create_agent/3` change, AgentManifest schema change, CapBAC change (all discuss-first); a new creator route; template/team editors; routing/team management; manifest versioning UI; fork-from-template.

## 7. Definition of Done (from handoff §5)
- [ ] Screenshot of the updated world agent create page (contract-shaped).
- [ ] Evidence of a real create using contract-safe fields (agent URI/status).
- [ ] Agent detail shows contract/executor status without exposing derived config as editable.
- [ ] No broad socialware creator route introduced.
- [ ] No CapBAC / AgentManifest runtime schema change without discuss-first.
- [ ] Focused tests/gates for touched files (or a note if only UI copy changed).

## 8. world-coordination
Touches only the world **identity/agent config** surface (`Identities.tsx` + `identity_data.ex` + the `dispatch_agent_create` clause); additive, no new route, no nav change, no `styles.css` restyle. Owns identity/agent-config UI; does not touch hello rendering or session routing UI (handoff §7).
