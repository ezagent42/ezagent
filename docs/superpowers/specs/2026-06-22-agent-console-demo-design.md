# Spec: Agent Console — Phase 0 demo design (design-confirmation, no backend)

> **Date:** 2026-06-22 · **Author:** Claude (with the dev) · **Tracking:** task #84
> **Branch:** `agent-console` (never `main`) · **Base:** `origin/main` @ `17830f1d`
> **Authoritative inputs:** `docs/superpowers/handoffs/2026-06-22-agent-console-in-world-handoff.md` (Allen-confirmed), `docs/superpowers/notes/2026-06-22-agent-console-backend-research.md`, `docs/guide/world-coordination.md`.
> **Status:** brainstorm-approved 2026-06-22, then **revised after independent review (2026-06-22)** — see §0a. The authority half of the demo is being corrected; the Manage-gate is now a separate blocking proposal.
> **Companion (blocking):** `docs/superpowers/specs/2026-06-22-agent-console-manage-gate-proposal.md` — the authorization protocol the LIVE half depends on. Needs Allen's sign-off; the MVP assumes it is resolved.

## 0a. Post-review revision (2026-06-22)

An independent review (verified against code) found the first demo's **authority modelling** unfit as a confirmation basis. The IA (cold/hot split) stands; the authority matrix + failure states are being corrected. Recorded here so the doc stays honest ahead of the demo-HTML rework:

- **Manage-gate split out** → `…-manage-gate-proposal.md` (the two-phase protocol: operator Manage gate → reconstruct orchestrator authority server-side → dispatch → dual-principal audit). Blocks the LIVE half; Allen to sign off.
- **Matrix: split Held vs Needed.** The held authority `{:within_session,S}` is NOT the needed lock — runtime substitutes a concrete session URI as the needed `instance` (`runtime.ex` `resolve_required_cap`). Show two cap columns.
- **Matrix: two callers.** `authorization ctx.caller` = operator (Phase-1 gate); `execution ctx.caller` = orchestrator (Phase-2 dispatch). A single "caller" column is wrong (review A3).
- **granter = `granted_by`, with evidence.** Not "always the operator" — a cold op's Template cap may have been granted by owner/admin/rule-configurer. Worked example should use an owner-granted-cap case so cold≠"three coincide" is honest.
- **Failure states: replace fabricated/misattributed ones** with code-verified reality: `add_managed_member` has no "unknown role" failure (role_name is a NEW alias); `unknown_member_role` belongs to `define_rule_set_rule` receiver resolution (`tools.ex:619`); `remove_member` unknown role → `{:ok, :already_removed}` (idempotent, not a reject); same-URI → `:same_member_uri_use_reconfigure` (`member_template.ex:429`); `define_legend` does NOT validate member_set/bound_rule_set (a gap to label, not a failure to demo); there is no unified `session-not-live` error.
- **Tag is ungated.** `TemplateTags` has `put/5`/`move/5` (not `tag/3`) and is an **unconditional DB write with no cap gate** — show it as a gap (result `ok` / authz `not_checked`), not a fabricated `Template :write`. Tag is **SessionTemplate-only** (no AgentTemplate Tag).
- **Add the missing cross-boundary ops** to the matrix: instantiate / create-session (cold→hot) and `update_template` / `save_template_as` (hot→cold).
- **Agent contract: three layers.** Show stored fields / resolved effective contract / source file — do not invent a `soul` data column; surface role/tools/soul as they actually live (flavor extras + referenced config).
- **Security panel.** cap grant/revoke + API-key status belong in an Agent-detail Security summary, not in team routing; never show secrets; the orchestrator has no `grant_cap` tool.
- **Read-side authority** matters even for MVP's read-only topology (reads need an authorized path, not raw `Kind.get_slice`/`RuleStore.list`).
- **capbac.md clarification** queued (pending explicit go): the dispatch path is `ctx.caps` OR `holds_cap(caller)`; "empty caps fails closed" is chokepoint-specific.

**The demo HTML now matches §0a** (3rd-review fidelity pass landed). §0a + the demo + the **Manage-gate proposal v2** are the living truth. The original §1–§8 below are kept for history but are **SUPERSEDED wherever they conflict with §0a** (notably: §1's URI examples were type-first; §3/§4 used the single-cap model, the `manage→orchestrator` agent-Manage framing, and `reject_same_uri_swap`/old failure atoms). Read §0a + the proposal, not the stale specifics below.

## 0. Scope of THIS spec

This spec covers **only the Phase-0 demo page** — a code-grounded, *non-wired* mockup of the whole Agent Console, merged to the `agent-console` branch and served on the internal Tailnet address (`100.64.0.27`) for stakeholder design confirmation. It is **not** the implementation spec for the Console itself; that follows after the demo is confirmed.

Per the handoff, the demo's job is to confirm the **information architecture** and the **authority model** before any code is wired. The deliverable is: the demo page + this one-page IA write-up + the authority matrix.

Non-goals (deferred to post-demo MVP / follow-ups, per handoff §6): wiring any mutation; `migrate_session`; full routing/legend/prompt editors; the Manage-cap granularity decision (open research item, handoff §4); fixing the `save_session_template` / routing-`caps: MapSet.new()` shortcuts.

## 1. Vehicle & serving

- **A single self-contained static page** (hand-written HTML + CSS + vanilla JS). No build step. Mirrors world's `world-screen` shell + a shadcn-shaped card/table/badge look so the confirmed layout ports directly to the real `agent_console` `.tsx` surface later.
- **Zero collision:** does NOT touch `world_live.ex`, `styles.css`, or the world React bundle. This honors `world-coordination.md` (those are the highest-collision artifacts).
- **Served on Tailnet** at a stable URL via a minimal static mount (exact mount resolved against the live endpoint config at build time; candidates: a `Plug.Static` path under the world plugin's `priv/`, or a 3-line demo route). Demo-only; removed/replaced when the real surface lands.
- **All data is code-grounded mock:** real **workspace-first** URI shapes (`entity://<ws>/<type>/<name>`, `template://<ws>/session/<name>@<hash>`, `session://<ws>/<template>/<name>` — per `uri.ex`), real flavors (cc/codex/curl/echo), real cap 5-axis shapes, real tool names + `file:line` citations. No invented data model or permissions.

## 2. Information architecture (left sidebar sections)

Cold/live split mirrors the handoff's Template Studio ↔ Session Console.

1. **Template Studio (COLD / templates)**
   - *Agent Templates* — list → detail (flavor, project_cwd/cwd, config_dir, settings_path, mcp_config_path, default_caps, desired_skills). Actions (mock): Fork, Tag. **Gap callout:** AgentTemplate has no caller-threaded `create/3` (system path only — research note §1).
   - *Session Templates* — list → detail (name, description, members[], legends, routing_rules, orchestrator_template_uri, version_hash/tag, public_view). Actions (mock): Create(root), Fork, Persist version, Tag "current".
2. **Session Console (LIVE / running session)** — a workspace overview lists live sessions → drill into one:
   - *Team panel* — members table keyed by `role_name` (role_name, source_template_uri, uri, provenance, alive?). Actions (mock): Add member, Update member template, Remove member, Add participant.
   - *Routing panel* — rule-sets list; `{from:X}→[Y]` relay-chain visualization; legends (name → member_set / bound_rule_set / fold); prompt-templates (name → body, `{var}` substitution). Actions (mock): define_rule_set_rule, define_legend, define_prompt_template.
3. **Migrate (LIVE / workflow)** — select target SessionTemplate → dry-run plan/diff (members new/updated/removed) → ledger progress (pending/done/failed). Tagged **"deferred past MVP"** (shown for design, not built in MVP).
4. **Observability** — operator-action audit feed; every row foregrounds the **dual principal**: `authorized_operator_uri` + `execution_principal_uri`, cold/live, result/failure, timestamp.

## 3. Authority matrix (the core deliverable)

> **SUPERSEDED in part — read §0a + Manage-gate proposal v2 for the corrected model.** The shipped matrix splits **Held authority vs Needed lock** and shows **two callers** (operator at the Phase-1 gate, orchestrator at execution); the `manage.*` gate actions are **PROPOSED** (§7 of the proposal). The "authorized by Alice … executed under session manage authority" phrasing below predates the two-phase split.

Two complementary presentations:

- **Inline per action** — an `ⓘ Authority` expander beside every action ("beside every panel"): required cap (kind/behavior/action/instance) · cold/live · backend fn `file:line` · which URI is `ctx.caller` at dispatch · failure modes. Where the op executes under the manage→orchestrator authority, label it explicitly: *"authorized by Alice (operator manage-cap), executed under session manage authority."*
- **A dedicated "Authority Matrix" section** — one full table; the UI form of Allen's required one-page matrix. Columns: Operation | Backend fn (file:line) | Cold/Live | Required cap | Principal + execution note | Failure modes | Audit fields.

### 3a. The cap model the matrix encodes (5 axes + 3 roles)

A capability (`apps/ezagent_core/lib/ezagent/capability.ex`) is a key cut with **5 identity axes** + 2 provenance fields. Matching is **asymmetric**: a held `:any`/scope-tuple axis matches a needed concrete axis, never the reverse.

| axis | meaning |
|---|---|
| `kind` | which Kind class (`:session`, `:agent`, `:session_template`, …) or `:any` |
| `behavior` | the Behavior module (`Ezagent.Behavior.Session`, …) or `:any` |
| `action` | the concrete action (`:join`, `:add_rule`, …) or `:any` |
| `instance` | a concrete `%URI{}`, `:any`, or a scope tuple `{:within_session, S}` / `{:within_workspace, W}` / `{:spawned_by, A}` |
| `workspace_uri` | a concrete `%URI{}` or `:any` |
| provenance | `granted_by` (a real `entity://` URI — Decision #154) + `granted_at` (not matched) |

Three roles the matrix keeps separate (capbac.md §1):
- **caller** — the code path that mechanically dispatches → `ctx.caller`.
- **authorizer** — what makes it permitted = **`ctx.caps`** (the cap set the dispatch carries). The runtime checks `ctx.caps`, not `ctx.caller`.
- **granter** — the accountable entity recorded on the minted cap → `granted_by`.

### 3b. The crux — cold vs live authority (handoff §1, research note §5)

- **COLD (template authoring)** authorizes on the operator's **own** `Behavior.Template` cap, caller-threaded. caller = authorizer's holder = granter = operator. Simple, UI-ready today.
- **LIVE (session management)** authorizes on the **orchestrator's** `{:within_session, S}` cap (`tools.ex:37`, preflight `tools.ex:878`). The session owner only holds a `Behavior.Manage` cap over the orchestrator *agent* (`:delete`/`:reconfigure` — `manage.ex:44,53`; `required_caps` `cap(:any, Manage, :any, instance)` at `manage.ex:65`), granted at session creation (`.../session_creator/materializer.ex`). That cap does **not** cover the session-management tool surface, so `Tools.add_managed_member(args, caps: operator_caps)` fails for the owner today.
- **Allen's decision (i):** extend `Behavior.Manage`'s authorized actions to cover the live session-management tool surface. The Console then runs LIVE ops as: *authorized by the operator's Manage cap, executed under the reconstructed session/orchestrator authority.*
- **Dual-principal audit (mandatory):** every operator-authorized LIVE action records BOTH `authorized_operator_uri` and `execution_principal_uri`, and **fails closed** if the Manage cap is absent (otherwise telemetry sees only the orchestrator and the operator identity is lost — `session_manager.ex:372`).

## 4. Real failure states (interactive mock)

Clicking an action surfaces the **real** rejection, not a placeholder:

| trigger | result | citation |
|---|---|---|
| **define_rule_set_rule** with a dangling receiver role | `{:unknown_member_role, r}` (NOT add_managed_member — role_name there is a new alias) | `tools.ex:619` (`resolve_role_receiver`) |
| define_prompt_template missing `{body}` | `{:error, :body_placeholder_required}` | `tools.ex:669` |
| Update member to the same URI | `{:error, :same_member_uri_use_reconfigure}` | `member_template.ex:429` |
| Remove member with an unknown role | `{:ok, :already_removed}` — **idempotent, not a reject** | `tools.ex:413` |
| define_legend with empty/invalid member_set | **written anyway** (backend does NOT validate) — a gap, not a reject | `tools.ex:705` |
| Manage cap absent (Phase-1 gate) | **fail-closed** (`{:error, :manage_unauthorized}` PROPOSED), operator identity preserved in audit | `session_manager.ex:372` |

## 5. "Read this matrix" legend (in-demo)

A first-class legend block on the demo explaining, in plain language (with a key/lock analogy), the 5 axes, the 3 roles, the cold-vs-live authority difference, and the dual-principal audit — so a non-code stakeholder viewing on Tailnet understands the matrix without reading source.

## 6. world-coordination compliance

- New **additive** surface intent → add an in-flight registry row to `docs/guide/world-coordination.md` §5 (Agent Console / this effort / `agent_console` surface (demo first) / in progress).
- Demo is static + isolated → touches none of the collision hotspots.
- Built in shadcn/`@json-render` shape (table/form-heavy) — a down-payment on world→hello convergence.

## 7. Deliverables & merge

- **Deliverables:** the static demo page; this spec (= the IA write-up + authority matrix model); the in-demo authority matrix + legend.
- **Merge model (Allen's standing rule):** all PRs (incl. this demo) → the `agent-console` task branch, never `main`; keep rebased on `main`; Allen merges the task branch → `main`.
- **Confirmation gate:** demo served on `100.64.0.27`, stakeholders confirm the IA + authority model, *then* the implementation spec + MVP build proceed.

## 8. Open items carried to Allen (not blocking the demo)

1. Manage-cap granularity — one `Behavior.Manage` cap vs per-concern split (touches core); decide before broadening past MVP (handoff §4 / §9.1).
2. MVP's single live command — member-add vs routing-rule-add (Allen to pick — handoff §9.3).
3. Authority-matrix exhaustiveness sign-off (handoff §9.2).
