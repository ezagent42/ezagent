# PRD: Agent Console — admin dashboard (operate-first IA + MVP)

> **Date:** 2026-06-23 · **Author:** Claude (with the dev, PM-framed) · **Tracking:** task #84
> **Supersedes the IA of:** the Phase-0 demo (`apps/ezagent_web/priv/static/agent-console-demo/`, landed `798f46bd`). The demo's *authority model* + cold/hot split stand; its **flat, tool-first navigation is redesigned here** per Allen's feedback.
> **Companion:** `2026-06-22-agent-console-manage-gate-proposal.md` (the authorization protocol — unchanged).
> **Inputs:** Allen's IA critique (2026-06-23), the handoff `2026-06-22-agent-console-in-world-handoff.md`, `docs/guide/world-coordination.md`, and a backend verification pass (§7).

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
**Top navigation (3 items):**

| nav | role | entry |
|---|---|---|
| **Overview** | landing / health summary | first screen on open |
| **Sessions** | the operate workspace (primary) | list → session detail |
| **Templates** | the blueprint library (secondary) | **view-only** catalog (decided — name = "Templates") |

- **No top-level "Observability"** (would imply a metrics/traces suite we don't have a backend for). Instead **Overview is the lightweight landing** = cross-session health + recent-activity audit feed. Per-session audit lives inside the session detail.
- **Migrate, prompt/legend/rule editors are NOT top-level** — they live inside a session's detail (they belong to that session).

**Session detail = a "Chrome Settings"-style page:** one session, a **left anchor nav** that jump-scrolls, and a **right long page** with every config section. Sections: Overview / Team (members = the session's agents) / Routing / Prompts / Template & version / Migrate (advanced).

> Naming: the secondary library is **"Templates"** (decided 2026-06-23).

## 4. The simplest complete user journey (MVP)
```
Overview（首屏：都健康吗？）
   │  点「进入」一个活会话
   ▼
Session 设置页（仿 Chrome Settings：左锚点 / 右长页）
   │  左锚点跳到「Routing」段 → 点「+ 规则」
   ▼
加规则表单（matcher / receiver）
   │  提交 → Manage-gate 两阶段（operator 授权 → orchestrator 执行；缺 cap → fail-closed）
   ▼
回 Overview → 最近操作 feed 出现一行「alice (operator) → orchestrator (execution) · add rule · ok」（双主体闭环）
```
This journey is also the **MVP slice**: read-only topology + **one** manage-authorized live command = **routing-rule-add** (smallest attack surface — only needs the orchestrator's within-session cap).

## 5. Wireframes

### 5.1 Overview (首屏)
```
┌ 总导航 ─┬──────────────────────────────────────────────────────┐
│●Overview│  Overview（首屏）                                      │
│ Sessions│  ┌ 活会话 2 ┐ ┌ 在线成员 6 ┐ ┌ 异常 0 ┐   ← 一眼健康   │
│ Templates  └──────────┘ └────────────┘ └────────┘                │
│         │  活会话（点「进入」直达会话设置页）                     │
│         │   running · storefront-7f3a · 3 人          [进入]      │
│         │   running · storefront-91c0 · 3 人          [进入]      │
│         │  最近操作（跨会话审计 feed）                            │
│         │   14:02  alice → add member @storefront-7f3a · ok       │
└─────────┴────────────────────────────────────────────────────────┘
```

### 5.2 Sessions (全部会话)
```
┌ 总导航 ─┬──────────────────────────────────────────────────────┐
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
**Two-level nav:** the **global left rail** (总览/会话/模板, with 会话 active) shows you're inside Sessions; the **session anchor nav** (Overview/Team/Routing/…) jump-scrolls the right long page.
```
┌总导航┬─────────────────────────────────────────────────────────────┐
│ 总览 │ 会话 › storefront-7f3a                  ← 面包屑              │
│[会话]│ ┌ storefront-7f3a · running ──────────────────────────────┐ │
│ 模板 │ │ 来源模板 storefront@a1b2c3d4 · orch cc_orchestrator-7f3a  │ │
│  ↑   │ └─────────────────────────────────────────────────────────┘ │
│ 总导航│ ┌会话锚点─┬───────────────────────────────────────────────┐ │
│ 会话  │ │ Overview │ # Overview  状态 / 来源模板 / orchestrator     │ │
│ 高亮  │ │ [Team]   │ # Team（成员 = 该会话的 agents）                │ │
│      │ │ Routing  │   role      agent 实例     source    alive      │ │
│      │ │ Prompts  │   greeter   doorman-7f3a   doorman   online     │ │
│      │ │ Template │   triage    triage-7f3a    triage    online     │ │
│      │ │ Migrate  │   [+ 成员][更新模板][移除][+ participant]        │ │
│      │ │ (高级)   │ # Routing（属于本会话）                          │ │
│      │ │          │   {from:greeter}→triage · legends @导购 …       │ │
│      │ │          │   [+ 规则][+ legend][+ prompt]                   │ │
│      │ │          │ # Template & 版本 · # Migrate（高级，MVP 后置）  │ │
│      │ └──────────┴──────────────────────────────────────────────┘ │
└──────┴─────────────────────────────────────────────────────────────┘
  左：总导航（会话高亮）· 中：会话锚点（Team高亮，点击跳段）· 右：整页可滚
```

### 5.4 Templates (次要 · 蓝图库)
```
┌ 总导航 ─┬──────────────────────────────────────────────────────┐
│ Overview│  Templates    [ Session 模板 │ Agent 模板 ]            │
│ Sessions│   Session: storefront @a1b2c3d4 current(3) · @7e…(4)    │
│●Templates  Agent:   doorman(cc) · triage(cc) · probe(curl) · …    │
│         │  点一个 → 详情（契约三层）+ 动作 Fork/版本/Tag           │
│         │  ⚠ MVP 倾向只读目录；新建 AgentTemplate 有后端 gap       │
└─────────┴────────────────────────────────────────────────────────┘
```

## 6. MVP scope (from the handoff §6)
**In:** **Overview** (health + audit feed) · **Sessions** list (browse/filter all) · Session detail **read-only topology** (Overview/Team/Routing/Prompts sections render the live config) · **one** manage-authorized live command = **routing-rule-add** (proves the Manage-gate end-to-end + dual-principal audit) · **Templates view-only** catalog (read list + detail, no writes).
**Out (follow-ups):** the other live write commands (add/remove member, define prompt/legend), `migrate_session`, full routing/legend/prompt **editors**, template **authoring** (Create/Fork/Tag write paths), the AgentTemplate `create/3` backend gap.

## 7. Backend grounding (verified against `origin/main`)
- **Routing IS session-owned:** `RuleStore` rows carry `created_by` = the session URI; rules filter by it (`routing/rule_store.ex`). Allen's point confirmed.
- **A live session's config:** the session slice holds `:members` (each member = an agent instance with a `source_template_uri`), `:legends`, and prompt_templates; routing rules live in `RuleStore` scoped by session. These are exactly the detail-page sections.
- **Session ↔ template:** the session carries `source_template_uri` / `orchestrator_template_uri`; `read_template_content` + `save_template_as` (snapshot live→template) + `migrate_session` exist.
- **Session list + health:** `world/admin_data.ex` already computes `alive` (`is_pid && Process.alive?`) per session.
- **Template authoring:** SessionTemplate `create/fork/persist_version` are caller-threaded (native). **AgentTemplate has only `persist_version_as_system` + `fork` — no caller-threaded `create` (gap).** → Templates read-only is the safe MVP.

## 8. Decisions (resolved 2026-06-23)
1. **Library name → "Templates".** ✅
2. **Templates in MVP → yes, view-only** (read catalog + detail; no authoring writes). ✅
3. **Both Sessions + Overview** in MVP. ✅ Overview = health landing; Sessions = browse/filter all.
4. **Global left rail shown on every screen** (总览/会话/模板) — incl. the session detail (which nests its own anchor nav). ✅
5. *Still gating any write command:* the Manage-gate §10 decisions (gate target / owner authority / runner / read-side / audit schema) — see the proposal. These don't block the read-only MVP surfaces, only the one live write command.

## 9. Relationship to existing artifacts
- The **Manage-gate proposal** (authority model) is unchanged and still the backend design for the one live command.
- The **Phase-0 demo** keeps its authority matrix + cold/hot value; its navigation is what this PRD redesigns. Whether to rebuild the demo to this IA, or go straight to the real `agent_console` world surface, is the next planning step.
- **world-coordination:** the real surface stays additive (`agent_console` `*.tsx` + `*_data/*_actions` + a `world_live.ex` route clause), shadcn-shaped.
