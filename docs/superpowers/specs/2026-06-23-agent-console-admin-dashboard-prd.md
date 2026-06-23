# PRD: Agent Console — admin dashboard (operate-first IA + MVP)

> **Date:** 2026-06-23 · **Author:** Claude (with the dev, PM-framed) · **Tracking:** task #84
> **Supersedes the IA of:** the Phase-0 demo (`apps/ezagent_web/priv/static/agent-console-demo/`, landed `798f46bd`). The demo's *authority model* + cold/hot split stand; its **flat, tool-first navigation is redesigned here** per Allen's feedback.
> **Companion:** `2026-06-22-agent-console-manage-gate-proposal.md` (the authorization protocol — unchanged).
> **Inputs:** Allen's IA critique (2026-06-23), the handoff `2026-06-22-agent-console-in-world-handoff.md`, `docs/guide/world-coordination.md`, and a backend verification pass (§7).

> **Review update (2026-06-23):** This PRD is the **design-confirmation demo target**, not a green light for backend-connected CRUD. The next deliverable is a **standalone static demo** under `apps/ezagent_web/priv/static/agent-console-demo/`, served for design review/Tailnet, with no backend connection. The demo must show real slice / URI / tool mapping and the filled authorization matrix (§6). Development of the real in-world surface starts only after demo approval and the Manage-gate blockers in §6.1 are closed.

## 1. The problem with the Phase-0 IA (Allen's critique)
The demo's tabs are **tools** (Team / Routing / Template Studio / Migrate / Observability), not **objects**. That makes it *flat* and mixes object levels:
- **Team** drills into a *session list* (you pick a session), but **Routing** has *no* session list — yet routing **belongs to a session**.
- **Template Studio** doesn't say *whose* template; it looks like you can only configure one, but an admin should be able to configure a template **per session**.

**Fix: object-first IA.** The admin works on **sessions** (and, secondarily, reusable **templates**). Routing / members / prompts / template-binding are **configuration *of a specific session***, not top-level tools.

## 2. Goal & primary job-to-be-done
- **Primary (this dashboard exists for this):** **operate live sessions** — see at a glance that running multi-agent teams are healthy, find the one to change, and adjust it (members, routing) with authorized, audited actions.
- **Secondary (lower priority, may defer):** **author reusable blueprints** (session/agent templates). Partially native (SessionTemplate authoring is caller-threaded; AgentTemplate `create` has a backend gap — §7).
- **Success:** an admin lands, knows in one screen whether everything's healthy, drills into a session in ≤2 clicks, and makes one authorized change with a dual-principal audit trail.

## 3. Information architecture
**Agent Console local navigation (3 items):**

| nav | role | entry |
|---|---|---|
| **Overview** | landing / health summary | first screen on open |
| **Sessions** | the operate workspace (primary) | list → session detail |
| **Templates** | the blueprint library (secondary) | **view-only** catalog (decided — name = "Templates") |

- **No top-level "Observability"** (would imply a metrics/traces suite we don't have a backend for). Instead **Overview is the lightweight landing** = cross-session health + recent-activity audit feed. Per-session audit lives inside the session detail.
- **Migrate, prompt/legend/rule editors are NOT top-level** — they live inside a session's detail (they belong to that session).
- This rail is **local to the new `agent_console` world surface**. It must not rewrite existing world navigation. `docs/guide/world-coordination.md` allows a new additive surface; restructuring shared world nav is a separate discuss-first change.

**Session detail = a "Chrome Settings"-style page:** one session, a **left anchor nav** that jump-scrolls, and a **right long page**. The section model should be operational, not another flat tool list:

| section | purpose | backend grounding | MVP behavior |
|---|---|---|---|
| **Health** | live status, orchestrator, last activity, failure state | session entity + the `world/admin_data.ex` data shape | authorized read-only |
| **Topology** | members / agent instances / source templates | session slice `:members` | authorized read-only |
| **Routing policy** | routing rules + legends + prompt templates that affect routing | `RuleStore` + session slice `:legends` / `:prompt_templates` | authorized read-only + **one** `routing-rule-add` action |
| **Template provenance** | source template, working copy, version/snapshot path | session entity + template content tools | authorized read-only |
| **Audit** | operator/execution trail for changes | target schema from Manage-gate proposal | visible in demo; backend gated |
| **Advanced** | migrate/session workflow and high-risk operations | `migrate_session` workflow | hidden/disabled in MVP |

This keeps Team / Prompts / Legends visible where operators expect them, but avoids promoting each tool into a peer top-level page.

> Naming: the secondary library is **"Templates"** (decided 2026-06-23).

## 4. The simplest complete user journey (MVP)
```
Overview（首屏：都健康吗？）
   │  点「进入」一个活会话
   ▼
Session 设置页（仿 Chrome Settings：左锚点 / 右长页）
   │  左锚点跳到「Routing policy」段 → 点「+ 规则」
   ▼
加规则表单（matcher / receiver）
   │  receiver 必须选择本 session 的 live member role
   │  提交 → Manage-gate 两阶段（operator 授权 → orchestrator 执行；缺 cap → fail-closed）
   ▼
停留在 Session 设置页 → Audit 段出现一行「alice (operator) → orchestrator (execution) · add rule · ok」
   │
   ▼
Overview 的最近操作 feed 也能看到同一条跨会话审计摘要
```
This journey is also the **MVP slice**: authorized read topology + **one** manage-authorized live command = **routing-rule-add**.

Why `routing-rule-add`, not `add-member`: `routing-rule-add` proves the hot CapBAC path while only requiring the orchestrator's within-session cap. `add-member` also touches worker lifecycle / `spawned_by` semantics / compensation and should remain post-MVP.

The demo must show the live-command failure states on this same operation, not on add-member:
- `{:error, :manage_unauthorized}` — Phase-1 Manage gate fails closed; retain operator identity for audit.
- `{:error, {:unknown_member_role, role_name}}` — receiver is not a current live member role for this session.
- `{:error, :session_not_live}` or equivalent binding/liveness failure — session/orchestrator binding cannot be re-verified.

## 5. Wireframes

### 5.1 Overview (首屏)
```
┌ Agent Console rail ┬──────────────────────────────────────────┐
│●Overview│  Overview（首屏）                                      │
│ Sessions│  ┌ 活会话 2 ┐ ┌ 在线成员 6 ┐ ┌ 异常 0 ┐   ← 一眼健康   │
│ Templates  └──────────┘ └────────────┘ └────────┘                │
│         │  活会话（点「进入」直达会话设置页）                     │
│         │   running · storefront-7f3a · 3 人          [进入]      │
│         │   running · storefront-91c0 · 3 人          [进入]      │
│         │  最近操作（跨会话审计 feed；target schema）              │
│         │   14:02  alice → orchestrator · add rule @storefront · ok│
└─────────┴────────────────────────────────────────────────────────┘
```

### 5.2 Sessions (全部会话)
```
┌ Agent Console rail ┬──────────────────────────────────────────┐
│ Overview│  Sessions（全部会话）       [全部│running│stopped] 筛选 │
│●Sessions│  会话              状态     成员  来源模板               │
│ Templates  ─────────────────────────────────────────────         │
│         │  storefront-7f3a   running  3    storefront@a1b2c3 [进入]│
│         │  storefront-91c0   running  3    storefront@a1b2c3 [进入]│
│         │  demo-x            stopped  0    storefront@7e6d5c       │
│         │  点一行 → 进入该会话设置页（5.3）                        │
└─────────┴────────────────────────────────────────────────────────┘
```

### 5.3 Session settings page (会话设置页 · 仿 Chrome Settings)
**Two-level nav:** the **Agent Console rail** (Overview/Sessions/Templates, with Sessions active) shows you're inside the console; the **session anchor nav** (Health/Topology/Routing policy/…) jump-scrolls the right long page.
```
┌Console rail┬──────────────────────────────────────────────────────┐
│ 总览 │ 会话 › storefront-7f3a                  ← 面包屑              │
│[会话]│ ┌ storefront-7f3a · running ──────────────────────────────┐ │
│ 模板 │ │ session://acme/storefront/storefront-7f3a · running       │ │
│      │ │ template://acme/session/storefront@a1b2c3d4               │ │
│      │ └─────────────────────────────────────────────────────────┘ │
│      │ ┌会话锚点───┬─────────────────────────────────────────────┐ │
│      │ │ [Health]  │ # Health  状态 / orchestrator / last activity │ │
│      │ │ Topology  │ # Topology（成员 = 该会话的 agents）           │ │
│      │ │ Routing   │   role      agent 实例     source    alive     │ │
│      │ │ Template  │   greeter   doorman-7f3a   doorman   online    │ │
│      │ │ Audit     │   triage    triage-7f3a    triage    online    │ │
│      │ │ Advanced  │ # Routing policy（属于本会话）                 │ │
│      │ │           │   {from:greeter}→triage · legends @导购 …      │ │
│      │ │           │   [+ 规则]                                        │ │
│      │ │           │   receiver: live member role only              │ │
│      │ │           │   [+ legend disabled]  [+ prompt disabled]         │ │
│      │ │           │ # Template provenance · # Audit · # Advanced   │ │
│      │ └──────────┴──────────────────────────────────────────────┘ │
└──────┴─────────────────────────────────────────────────────────────┘
  左：Agent Console rail（Sessions 高亮）· 中：会话锚点（Health 高亮，点击跳段）· 右：整页可滚
```

### 5.4 Templates (次要 · 蓝图库)
```
┌ Agent Console rail ┬──────────────────────────────────────────┐
│ Overview│  Templates    [ Session 模板 │ Agent 模板 ]            │
│ Sessions│   Session: storefront @a1b2c3d4 current(3) · @7e…(4)    │
│●Templates  Agent:   doorman(cc) · triage(cc) · probe(curl) · …    │
│         │  点一个 → 只读详情（契约三层 + provenance + sessions）   │
│         │  写动作 Create/Fork/Tag/版本发布：disabled/post-MVP      │
└─────────┴────────────────────────────────────────────────────────┘
```

## 6. MVP scope (from the handoff §6)
**Demo target (first step, no backend connection):** standalone static demo in `apps/ezagent_web/priv/static/agent-console-demo/`. It reflects real Kind/URI/tool mapping and includes a filled authorization matrix beside the relevant panels. The real `agent_console` in-world surface is Phase 1+ after design confirmation.

Authority classes are **COLD**, **LIVE-CapBAC**, and **LIVE-workflow**. Do not collapse them into a binary hot/cold label.

Required matrix columns:

`operation → UI state → authority class → Phase-1 ctx.caller/operator → Phase-1 gate cap → Phase-2 ctx.caller/execution → Phase-2 execution caps → backend function/tool → failure state(s) → audit fields`.

Minimum rows the demo must pre-fill:

| operation | UI state | authority class | Phase-1 ctx.caller / gate cap | Phase-2 ctx.caller / execution caps | backend function/tool | failure state(s) | audit fields |
|---|---|---|---|---|---|---|---|
| `read_topology` | Health / Topology / Routing policy / Template provenance read | LIVE-CapBAC read (PROPOSED) | operator · proposed `Behavior.Manage :read_topology` over the session | TBD by read-side authority decision; no backend-connected read until §6.1 closes | target: authorized snapshot over session slice + `RuleStore`; current world raw reads are shape references only | `:manage_unauthorized`, `:session_not_live` / binding failure | target/demo: operator + request id; no mutation audit |
| `routing-rule-add` | enabled MVP write in Routing policy | LIVE-CapBAC | operator · proposed `Behavior.Manage :routing` over the session | orchestrator · projected held `{:within_session, session}` cap only | `Ezagent.Orchestrator.Tools.define_rule_set_rule/3` | `:manage_unauthorized`, `{:unknown_member_role, role_name}`, matcher normalization error, session/orchestrator liveness failure | `authorized_operator_uri`, `execution_principal_uri`, matched cap identity/provenance, `request_id` |
| `templates-read` | Templates catalog/detail, view-only | COLD / authorized read | operator · template/catalog read authority TBD | n/a for demo; no write delegation | `Templates.list_templates` / `read_template_content` shape only | template read unauthorized / not found | target/demo read event only if product chooses to show it |
| `migrate_session` | disabled under Advanced | LIVE-workflow | not invokable in MVP | would require orchestrator + `within_session` + `spawned_by` + Template caps | `migrate_session` workflow | disabled/post-MVP | none in MVP |

**MVP in:** **Overview** (health + target audit feed) · **Sessions** list (browse/filter all) · Session detail **authorized read topology** (Health/Topology/Routing policy/Template provenance sections render the live config) · **one** manage-authorized live command = **routing-rule-add** (proves the Manage-gate end-to-end + dual-principal audit) · **Templates view-only** catalog (read list + detail/provenance, no writes).

**Out (follow-ups):** add/remove member, define prompt/legend writes, `migrate_session`, full routing/legend/prompt **editors**, template **authoring** (Create/Fork/Tag/write-version paths), the AgentTemplate `create/3` backend gap.

### 6.1 Blockers before backend-connected MVP
The read-only demo can land before these, but backend-connected Agent Console cannot:

1. **Manage-gate §10 decisions:** gate target, owner authority, non-forgeable ToolRunner/front doors, read-side authority, and audit schema.
2. **Authorized read path:** current world code has raw reads into session slices / `RuleStore`. Agent Console must not normalize that into the new surface; read topology needs an explicit authority story.
3. **Audit schema:** the UI requires dual-principal rows (`operator` + `execution/orchestrator`). Existing audit is single-caller, so the feed is target/demo UI until schema lands.
4. **No UI-minted caps:** the console must submit `{session_uri, op, args}` to the gate. Cap construction stays behind `Ezagent.Identity.Grant` / orchestrator-owned authority.

## 7. Backend grounding (verified against `origin/main`)
- **Routing IS session-owned:** `RuleStore` rows carry `created_by` = the session URI; rules filter by it (`routing/rule_store.ex`). Allen's point confirmed.
- **A live session's config:** the session slice holds `:members` (each member = an agent instance with a `source_template_uri`), `:legends`, and prompt_templates; routing rules live in `RuleStore` scoped by session. These are exactly the detail-page sections.
- **Session ↔ template:** the session entity and `template_working_copy` carry template provenance (`source_template_uri`, `orchestrator_template_uri`, version/snapshot context). `read_template_content` + `save_template_as` (snapshot live→template) + `migrate_session` exist, but migration is a multi-step workflow and not MVP.
- **Session list + health:** `world/admin_data.ex` already computes `alive` (`is_pid && Process.alive?`) per session. This is a **data-shape reference**, not the approved authorized read path; the real Agent Console still needs §6.1's read-side authority.
- **Template authoring:** SessionTemplate `create/fork/persist_version` are caller-threaded (native). **AgentTemplate has only `persist_version_as_system` + `fork` — no caller-threaded `create` (gap).** → Templates read-only is the safe MVP.
- **URI shape:** examples must use current workspace-first URI shape: `entity://<workspace>/<type>/<name>`, `template://<workspace>/<type>/<name>`, `session://<workspace>/<template>/<name>`. If the demo shows an orchestrator, use `entity://<workspace>/agent/<orchestrator-name>`; do not copy stale type-first examples from older notes/skills.
- **Important caveat:** existing world read helpers prove data availability, not authorization correctness. The Agent Console must be wired through explicit read/write authority, otherwise it risks becoming a new silent bypass around CapBAC.

## 8. Decisions (resolved 2026-06-23)
1. **Library name → "Templates".** ✅
2. **Templates in MVP → yes, view-only** (read catalog + detail; no authoring writes). ✅
3. **Both Sessions + Overview** in MVP. ✅ Overview = health landing; Sessions = browse/filter all.
4. **Agent Console local rail shown on every Agent Console screen** (Overview/Sessions/Templates) — incl. the session detail (which nests its own anchor nav). ✅ This is not a shared world-nav rewrite.
5. **Manage-gate §10 blocks backend-connected MVP**, not just writes. ✅ Read-only topology still needs read-side authority; audit feed needs schema.
6. **MVP live command = `routing-rule-add`.** ✅ It is the smallest hot CapBAC proof because it stays within an existing live session.
7. **Demo landing shape = standalone static Phase-0 refresh.** ✅ The design-confirmation demo stays under `apps/ezagent_web/priv/static/agent-console-demo/`; the real `agent_console` typed-slot world surface is Phase 1+.
8. **Demo language = Chinese primary UI.** ✅ Design-review copy is Chinese; backend/tool identifiers, URI examples, cap names, and audit field names stay in English for code grounding. No bilingual toggle in the static demo.

## 9. Relationship to existing artifacts
- The **Manage-gate proposal** (authority model) is unchanged and still the backend design for the one live command.
- The **Phase-0 demo** keeps its authority-matrix value; its navigation and matrix correctness are what this PRD redesigns. The next step is to rebuild that static demo to this IA before backend-connected work.
- **world-coordination:** Phase 0 static demo touches no world files. The real surface stays additive in Phase 1+ (`agent_console` `*.tsx` + `*_data/*_actions` + a `world_live.ex` route clause), shadcn-shaped, and must pass the typed-slot layout gate (`SlotRegistry`, checked-in `slots.manifest.json`, route clause, and renderer-family case if needed). Any change to existing world navigation or cross-surface shell behavior is discuss-first and out of this PRD.
