# Socialware 基座化 (im→session→agent) — live E2E validation (2026-06-15)

Closes out the live-tier validation for **#63** (the socialware 基座化 / 3-domain split,
`#53`). The refactor was already structurally validated (PR-9a/9b/9c merged; the
im→session→agent acyclic arch-fitness invariant green at allowlist 0). This note records the
**live** end-to-end run on the disposable docker stack (`ezagent-disp`, host `:10044`,
`docker/docker-compose.disp.yml`) and the bug + provisioning gaps it surfaced.

## Result: the refactor is validated live (3/3 core tiers)

On a **fresh** stack (`down -v` → boot → admin login), exercised through the production UI:

1. **Orchestrator readiness** — `create_session(default)` brings the cc orchestrator up:
   `/sessions` shows `session://system/default/main` with the ORCHESTRATOR panel **alive**,
   `cc_orchestrator-main` **online**, **1 bridge connected**. Logs:
   `orchestrator_not_registered`=0, `did NOT join`(90s timeout)=0, `orch:bridge JOINED`=1,
   `create_session granted`=1. (This required the fix below — pre-fix the orchestrator
   90s-timed-out and the create rolled back.)
2. **session→agent transport (the refactored path)** — a chat message to
   `@cc_orchestrator-main` routes `session.send` (granted) → `agent.receive` (granted) with the
   orchestrator's `last_activity` updated. The im→session→agent transport delivers inbound.
3. **cc reply roundtrip** — the orchestrator's claude processed the message and replied
   `READY-E2E-OK4` **back into the session chat** (green bubble, sender
   `entity://system/agent/cc_orchestrator-main`). Full chain: admin → transport → claude →
   reply tool → session. This is the `feedback_esr_e2e_standards` gold standard (cc reply via
   the channel).

Evidence screenshots were captured via agent-browser (sent to the operator):
sessions/orchestrator-alive, the PTY attach, and the reply bubble.

## The bug that blocked tier 1 (fixed + merged: PR #783)

Deterministic ordering deadlock: the durable session→orchestrator binding
(`template_working_copy.orchestrator_uri`) was written at step 6
(`store_session_orchestrator_uri`), **after** the step-5 readiness gate — but that gate polls
for the live orchestrator's MCP join, and the join self-registers by lazily rebuilding its
context from that very binding (`McpServer` read-through cache). The write the join needs was
gated behind the gate that waits for the join. Fix: pre-persist the deterministic *planned*
orchestrator URI **before** the gate, on the fresh-create path (where any failure rolls the
whole session back). Full write-up + the repair-path / readiness-field-overload follow-up:
[2026-06-15-live-orchestrator-mcp-registration-bug.md](2026-06-15-live-orchestrator-mcp-registration-bug.md).
The deterministic suite masked it (test-mode signals readiness without a live MCP join).

## Provisioning gaps surfaced (NOT the refactor — disposable-stack / #17 cascade)

The live run also surfaced three **credential/provisioning** gaps. All are stack-seeding /
credential-cascade (#17) concerns, orthogonal to the im→session→agent refactor (which works):

1. **admin create-cap — NOT a bug.** The fresh-stack `create_session :unauthorized` seen first
   was the **unauthenticated public landing form** (`/`) creating "as admin" with no loaded
   caps (correct fail-closed). The documented flow works: `mix ezagent.user.set_password` →
   log in at `/login` with the FULL admin URI → caps load → create succeeds.
2. **per-agent claude login.** The orchestrator's claude reported `Not logged in · Please run
   /login` → 401 → no reply, even with `.credentials.json` in its `CLAUDE_CONFIG_DIR`. claude
   reads its **login** from the container HOME `/home/ezagent/.claude/.credentials.json`; the
   stack only seeds `/secrets/cc`. Provisioning a **fresh** host token there (OAuth ~1h) +
   restarting claude fixed it → the reply roundtrip then worked.
3. **Feishu outbound-sync bind.** Binding a session → Feishu chat
   (`/admin/sessions/<uri>/external_mirror`) silently no-ops because
   `FeishuAdapter.caller_open_id/1` requires the **caller** to have a Feishu identity
   (`feishu_user_bindings` row); the fresh-stack admin has none. (The dedicated app
   `cli_a97ae5a8d4e39bdd` is in the Feishu group "Ezagent测试群",
   `oc_8fb7b3327ab3e3e45dce125b9160962c`.) Also: the silent no-flash failure is a UX gap.

**Recommendation:** fix these in the credential cascade / disposable-stack seeding (#17), not
by hand-working-around them per E2E run. See memory `project_disposable_stack_e2e` for the
operational details + workarounds.

## Status

- #63 **core refactor: VALIDATED LIVE** (tiers 1-3 above).
- Feishu outbound group-sync: the one remaining tier, **gated on provisioning gap #3**
  (operator Feishu identity) — a stack/#17 decision, not a refactor defect.
