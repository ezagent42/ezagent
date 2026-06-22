# Proposal (BLOCKING — needs Allen): the Manage-gate for operator-driven live session management

> **Date:** 2026-06-22 · **Author:** Claude (with the dev) · **Tracking:** task #84
> **Status:** PROPOSAL — blocks the Agent Console MVP. Needs Allen's sign-off on the protocol + the open decisions (§8) before any LIVE-side implementation.
> **Branch:** `agent-console` (doc only; no mechanism code until approved).
> **Referenced by:** `docs/superpowers/specs/2026-06-22-agent-console-demo-design.md`.
> **Inputs:** handoff `2026-06-22-agent-console-in-world-handoff.md` §1/§4/§5, research note `2026-06-22-agent-console-backend-research.md` §5, independent review (2026-06-22), and the code verification below. Sits squarely in CapBAC / Decision #154 territory — Allen's review surface.

## 0. Why this is a separate doc
This is the one genuine **architecture decision** in the Agent Console work — it changes how `Behavior.Manage` authority is used, requires server-side authority reconstruction, and needs an audit-schema change. It is deliberately split out of the demo/IA spec so the ask to Allen is crisp and so it lands as its own Decision-Log entry. The demo spec references it; the MVP assumes it is resolved.

## 1. The gap (code-verified)
An operator (a human in the world Console, e.g. the session **owner**) wants to manage a **running** session — add a member, add a routing rule. Today this is impossible without forging authority:

- LIVE tools authorize on the **orchestrator's** `{:within_session, S}` cap (`orchestrator/tools.ex:37`; preflight `tools.ex:878`). Only the orchestrator holds it.
- The session **owner** holds `cap(:agent, Manage, :any, <orchestrator_uri>, ws)` — `action: :any`, **over the orchestrator agent** (`session_creator/materializer.ex:117`), plus `OrchestratorAdmin :restart` (`materializer.ex:74`). Neither covers the session-management **tool surface**.
- So `Tools.add_managed_member(args, caps: operator_caps)` → `:unauthorized` for the operator.

**Runtime authorization is `ctx.caps` OR `holds_cap(caller)`** (`kind/runtime.ex:404-412`) — both checked. So the gap is real for the operator (they hold neither shape for the live tool locks).

## 2. Rejected alternatives (and why)
- **Give the operator the orchestrator's `{:within_session,S}` cap.** Over-broad and permanent: "may manage the team" silently becomes "may do anything the orchestrator can in this session," with no checkpoint and hard to revoke.
- **Route operator intent through the orchestrator (chat / @-mention).** Verified NOT a viable Console path:
  - The orchestrator is **not an authorization boundary** — `Session.handle_send` (`behavior/session.ex:432`) gates only on the sender's `:send` cap and never checks the sender's Manage/owner authority; the orchestrator then acts under **its own** `{:within_session}` caps (`session_manager.ex:352`). So management would be gated on "is a session member" + "can convince the LLM," not "holds Manage authority."
  - It is an **LLM** — non-deterministic; wrong basis for a reliable admin button.
  - **Audit collapses to the orchestrator** — operator identity is lost.
  - (Separately worth flagging to Allen: today LIVE management is protected only by the orchestrator LLM's discretion against non-owner session members — a soft guardrail, notably weak for socialware/public sessions.)

## 3. Decision (Allen-directed, mechanism (i)): the Manage-gate
Run the Console under the **manage authority**, with authorization and execution **kept separate**:

> The operator is **authorized** by their Manage cap; the tool **executes** under the reconstructed session/orchestrator authority; the action is recorded with **both** principals; absence of the Manage cap **fails closed**.

This is a *gate* (a checkpoint), not a new god-key. It is the two-phase protocol in §4.

## 4. The two-phase protocol (the part that was missing — needs Allen sign-off)
```
operator action (world Console, structured args)
        │
  [PHASE 1 — AUTHORIZATION GATE]  ctx.caller = operator
        │  verify the operator holds a Manage cap that covers THIS operation
        │  on THIS session (see §5 — enumerated Manage actions, not action:any)
        │  + verify the live session ↔ orchestrator binding (the operator is
        │    managing a real, running session whose orchestrator we will borrow)
        │  ── missing/!covered → FAIL CLOSED ({:error, :manage_unauthorized}),
        │     operator identity preserved in the audit
        ▼
  [PHASE 2 — EXECUTION]  ctx.caller = orchestrator
        │  server-side reconstruct the orchestrator's caps
        │  (Identity.list_caps_for(orchestrator_uri) — the existing seam,
        │   session_manager.ex:352); world NEVER supplies execution caps
        ▼
  Tools.<op>(args, caller: orchestrator, caps: reconstructed, session_uri, ...)
        │
  [AUDIT]  record BOTH: authorized_operator_uri (Alice) + execution_principal_uri
        │  (orchestrator) + a correlation id linking the gate to every child dispatch
```
Non-negotiables:
- **Two distinct `ctx.caller`s** (review A3): operator at the gate, orchestrator at the underlying dispatch. The matrix/audit must show both.
- **World never assembles or forwards execution caps/principal** (review F — confused-deputy): the runner derives `{caller, caps, session_uri, owner}` **server-side from the session↔orchestrator binding**, never from world action args or client input.
- **Fail-closed** when the Manage cap is absent/insufficient — the operator identity is still recorded.

## 5. Manage scope & granularity — the open core question (handoff §4)
Mechanism (i) = "extend `Behavior.Manage`'s authorized actions to cover the session-management tool surface." The sharp risk (review A5, verified): the owner's held Manage cap is **`action: :any`** scoped to the orchestrator instance (`materializer.ex:117`). So naively "adding Manage actions" makes that one `action:any` key **auto-cover all of them** — every added action silently widens the owner's authority.

Therefore:
- **Do NOT** expose a generic `execute_tool(tool_name)` or rely on `action: :any`.
- The gate authorizes a **specific, enumerated, session-scoped Manage action** per operation, checked against a **server-side allowlist**.
- **Before opening a second management concern**, migrate the owner grant from `action: :any` to **enumerated action caps** (so authority is additive-by-choice, not automatic).
- The "one `Behavior.Manage` cap vs per-concern split (routing-manage / member-manage / template-manage)" question (handoff §4) does **not** require a new cap **axis** — the `action` axis already expresses concern. It does touch the **grant sites + `Manage.required_caps`** (domain). MVP path = one Manage behavior with **enumerated** actions + allowlist; per-concern split is the next-increment decision.

## 6. Audit schema change (required; cannot be mocked away)
Current `Audit.build_row/3` records a **single `caller`** and `trace_id: nil` (`core/.../audit.ex`). Dual-principal + correlation needs a real schema change:
- add `authorized_operator_uri`, `execution_principal_uri`, `front_door` (cc-bridge | world-console), and a `request_id`/`trace_id` linking the gate to every child dispatch;
- record the Manage-cap identity/provenance that authorized it;
- arguments recorded as **summaries only** — never API keys, prompt secrets, or path credentials.

## 7. The shared seam: `ToolRunner` (review F, handoff §5)
Extract a pure `ToolRunner.invoke(op, args, derived)` where `derived = %{caller, caps, session_uri, workspace_uri, owner}` is produced by a server-side resolver, reusing `run_tool_op/3`'s normalization (`session_manager.ex:382-467`). **Two front doors, shared execution kernel, NOT shared authentication:**
- **cc bridge** — bridge-token + orchestrator binding (existing `run_tool/4`).
- **world Console** — the Phase-1 Manage gate + operator provenance.
World must NOT call `SessionManager.run_tool/4` (its bridge-token + live-process coupling).

## 8. Open decisions for Allen (blocking the LIVE half)
1. **Approve the two-phase protocol** (§4) as the authority mechanism for the Console's LIVE operations.
2. **Manage granularity (§5):** one enumerated-action `Behavior.Manage` for MVP, migrating owner grant off `action: :any` before a second concern? Or go straight to per-concern caps?
3. **Audit schema (§6):** approve the dual-principal + correlation fields and the migration.
4. **Read-side authority:** even MVP's read-only topology needs an authorization contract for the reads (review C3) — confirm reads go through an authorized data path, not raw `Kind.get_slice`/`RuleStore.list`.
5. **Fix the existing forged-authority shortcuts now or separately?** `save_session_template` mints its own write cap (`world/workspace_plugin_actions.ex:188`); routing dispatch sends empty `ctx.caps` (`world/conversation_actions.ex:711`) — the latter is contract drift (runtime falls back to `holds_cap(caller)`), not a live bypass, but both should be retired, not replicated.

## 9. Must-not-violate (existing invariants)
- All grants stay at the `Ezagent.Identity.Grant` chokepoint; `granted_by` is a real entity (Decision #154). The gate adds **no** new `system://` principal.
- CapBAC is never bypassed; the gate is an **additional** authorization step in front of the existing dispatch authz, not a replacement.
- `world-coordination.md`: the Console surface stays additive.

## 10. Also (reference hygiene)
`references/capbac.md` §3 reads as if an empty `ctx.caps` always fails closed; the dispatch path is actually `ctx.caps` **OR** `holds_cap(caller)` (`runtime.ex:404-412`) — the "fails closed" statement is specific to the **grant chokepoint**. Clarify the reference so the protocol's fail-closed claim (which is enforced at the Phase-1 gate, not assumed from empty caps) is precise.
