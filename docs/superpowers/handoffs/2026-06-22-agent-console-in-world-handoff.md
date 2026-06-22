# Handoff (codex-reviewed + Allen-directed — pending final confirm): Agent Console in `world`

> **Date:** 2026-06-22 · **From:** Claude (with Allen) · **To:** an independent developer (human + cc/codex)
> **Tracking:** task #84 · **Base:** `origin/main` @ `469f107b`
> **Status:** Allen-confirmed 2026-06-22 (codex-reviewed; principal = manage authority via (i) extend `Behavior.Manage` for MVP; demo merges + served on Tailnet). Research: `docs/superpowers/notes/2026-06-22-agent-console-backend-research.md`. Follows `docs/guide/world-coordination.md`.

## 0. Mission & the demo-first mandate

An **Agent Console** in `world` — an operator UI uniting templates (create/fork/version/tag), team management (members + roles), routing (rules / rule-sets / legends / prompt-templates), and session migration. It aggregates the agent contract + team routing + session templates into one surface.

**First deliverable = a DEMO PAGE for design confirmation, not code.** A code-grounded mockup of the whole Console, **merged into the repo** and **served on an internal Tailnet address (`100.64.0.27`)** so everyone can view it directly. Confirm the overall design before implementation.

## 1. Authorization is the crux — and the answer is "the manage authority" (Allen)

Per Allen: **the Console operator's permission = the SessionManager / SessionTemplate Manager authority.** Code reality (codex-verified), split by half:
- **Cold / template side — the authority already exists.** `SessionTemplate.create/3`/`fork/3`/`persist_version/3` already authorize on a `Behavior.Template` cap, caller-threaded (HIGH-9). The "SessionTemplate Manager" is real and UI-ready.
- **Live / session side — the authority exists but the operator doesn't hold it yet.** The live tools (members/routing/migrate) authorize on the **orchestrator's `{:within_session}` cap** (`orchestrator/caps.ex:157-177`). The session **owner** only holds a `Behavior.Manage` cap over the orchestrator *agent* (`:delete`/`:reconfigure` — `manage.ex:10,17`; granted `session_creator/materializer.ex:117-147`) — which does **not** cover the session-management tool surface. So `Tools.add_managed_member(args, caps: operator_caps)` fails for the owner today.

**Decision (Allen-directed): make the Console run under the manage authority, by extending the existing owner manage-cap to cover the live session-management tool surface** (reuse the manage role; complete its scope) rather than inventing a parallel cap. Confirm the exact mechanism with Allen (§4).

**Audit is mandatory (codex):** any operator-authorized action that executes under session/orchestrator authority must record BOTH `authorized_operator_uri` and `execution_principal_uri`, and **fail closed** if the manage cap is absent — otherwise telemetry sees only the orchestrator and the operator identity is lost (`session_manager.ex:372`; `runtime.ex:204,223`).

## 2. Backend reality — THREE categories (codex-corrected)
- **COLD — template authoring** (durable snapshots; caller-threaded, ready): `SessionTemplate.create/fork/persist_version`, `AgentTemplate.fork`, `TemplateTags` tagging, `list_templates`. *(Gap: AgentTemplate needs a caller-threaded `create/3` — only a system path exists.)*
- **LIVE CapBAC commands** (need a running session; read the live members slice): `add_managed_member`, `update_member_template`, `remove_member`, `add_participant`, `define_rule_set_rule` (resolves role names vs live members — `tools.ex:617,924`), `define_prompt_template` (`{body}` required — `tools.ex:670`), `define_legend`. Same-URI regenerate unsupported (`member_template.ex:175`).
- **LIVE WORKFLOW — `migrate_session`** (multi-step stateful, NOT a plain function): reads target template, diffs live members, writes a ledger, regenerates members, replaces rule-sets/prompts/legends/working-copy (`migration.ex:12,17-26,271,285,321`). Needs a dry-run / plan / progress UI and its own care.

## 3. Phase 0 — the DEMO PAGE + AUTHORITY MATRIX (merges to repo, served on Tailnet)
A design-confirmation demo, code-grounded, not wired to mutations.
- **Grounded in real concepts + data shapes** — cite the real slices/URIs/tools (§2). No invented data model or permissions.
- **Show the whole IA:** Template Studio (cold) ↔ Session Console (live); team view (members by role_name); routing view (rule-sets / `{from:X}→Y` chains / legends / prompt-templates); the migrate plan/diff flow; observability.
- **Include an "authority matrix" beside every panel** (codex): per operation — required cap / principal, live-vs-cold, backend function, failure modes, and **which URI is `ctx.caller` at dispatch** (the runtime records/uses it — `runtime.ex:150,204`). Where an op executes under the manage→orchestrator authority, say so ("authorized by Alice, executed under session manage authority").
- **Model real failure states:** unknown role rejected (`tools.ex:617`), `{body}` required (`tools.ex:670`), same-URI regenerate unsupported (`member_template.ex:175`), session-not-live behavior.
- **Merge + serve:** the demo merges into the repo (its own task/preview branch → Allen merges) and runs on the Tailnet address for stakeholder review. Deliverable = demo + one-page IA write-up + authority matrix.

## 4. The authority mechanism to confirm with Allen (the one open sub-decision)
Allen set the direction (Console = manage authority). The implementation choice:
- **(i)** Extend `Behavior.Manage`'s authorized actions so the owner's existing manage-cap covers the session-management tool surface (smallest change; reuses the granted cap).
- **(ii)** Grant the manage-cap holder a `{:within_session}` authority equal to the orchestrator's (broader; mirrors the orchestrator exactly).
- **(iii)** A dedicated `cap(:session, ConsoleManage, :manage, session_uri, workspace_uri)` (most explicit; closest to the deferred #533 provenance model).
**Decision (Allen): (i)** — extend `Behavior.Manage`'s authorized actions to cover the session-management tool surface (MVP-sufficient) + the audit fields.

**Open research item (Allen): Manage-cap granularity.** Does ALL management belong in ONE `Behavior.Manage` cap, or should it split into **per-concern manage caps** (e.g. routing-manage, agent-manage, member-manage, template-manage)? Splitting **touches core** (the cap model + the grant sites). Research the management concerns and decide before broadening past MVP — (i) (one Manage cap, scope completed) is the MVP path; the per-concern split is the question for the next increment.

## 5. The shared backend seam (codex)
Extract a **pure `ToolRunner.invoke(tool, args, opts)`** taking already-derived `%{caller, caps, session_uri, workspace_uri, owner, ...}` (reusable normalization + `Tools.*` call = `run_tool_op/3`, `session_manager.ex:382-467`). Keep **two front doors**: the cc bridge (bridge-token + orchestrator binding) and the world Console (operator manage-authority + operator provenance). Do **not** have world call `SessionManager.run_tool/4` (its bridge-token + live-process coupling).

## 6. MVP after the demo (codex-trimmed)
With the principal decided, MVP = **read-only team + routing topology + template catalog**, plus the **manage-authorized** member-add (or routing-rule add) on a running session — proving the manage-authority path end-to-end on one low-risk command + the audit fields. **Defer `migrate_session` and the full routing/legend/prompt editors** to follow-ups. Fix the existing shortcuts as part of this (don't replicate them): `save_session_template` synthesizes its own write cap (`workspace_plugin_actions.ex:202`); routing dispatch sends `caps: MapSet.new()` (`conversation_actions.ex:711,718`).

## 7. world-coordination (mandatory)
New additive `agent_console` surface → follow `docs/guide/world-coordination.md`: additive `*.tsx` + `*_data/*_actions` + a `world_live.ex` route clause; in-flight registry row; shadcn/`@json-render`-shaped (table/form-heavy → a down-payment on world→hello); coordinate the shared additive files + route clause with the active world-dev.

## 8. Merge model & gates
- **Merge model (Allen's standing rule):** split into PRs as needed; all PRs (incl. the demo) merge into this task's branch (e.g. `agent-console`), never `main`; keep rebased on `main`; Allen merges the task branch → `main`.
- Phase 1+ : full gates (`arch.scan`/`doc.scan`/`uri_query.scan`/`check_invariants`/`format`/`test`/`:ezagent_plugin_check`); CapBAC never bypassed; behaviors via `use Ezagent.Lifecycle`. Load skills `ezagent-developer` + `ezagent-session-orchestrator`.

## 9. Residual questions for Allen
1. **Manage-cap granularity** (§4 open research item) — one `Behavior.Manage` cap vs per-concern split (touches core); resolve before broadening past MVP.
2. Demo's authority-matrix exhaustiveness.
3. MVP's one live command — member-add vs routing-rule-add (Allen to pick).

---
*Allen-confirmed 2026-06-22: principal = manage authority via (i) extend `Behavior.Manage`'s scope over the live tool surface, with operator+execution-principal audit, fail-closed (Manage-cap granularity = an open research item); backend = cold / live-CapBAC / live-workflow; demo carries an authority matrix, merges to repo, served on Tailnet. Ready for an independent dev (Phase 0 demo first).*
