# Scenario 32: Feishu @-mention orchestrator → dispatch (create agent / modify routing / notify)

**Category**: 3 — Session flows (orchestration)
**Status**: 🚧 not-implemented (gate for the orchestrator-chain dev round, 2026-05-31)
**Author**: Claude, per Allen Feishu directive 2026-05-31 ("把 orch 加入 member，
用户通过 mention orch 让其创建新 agent、修改路由关系或直接通知对应 agent")

## Intent

The orchestrator is a **member** of its session. A user drives it by **@-mentioning
it** from the bound Feishu group; the mentioned message is delivered to the
orchestrator's live claude, which uses its MCP tools to do one of three things,
and the result is visible back in the Feishu group.

## Pre-conditions

- Phx running at `http://100.64.0.27:10042` (proxy live; orchestrator config has the
  startup-dialog-skip keys so its claude is non-interactive — see
  [[project_headless_claude_startup_dialogs]]).
- A session created via the atomic `create_session` whose template carries an
  orchestrator, with the **orchestrator joined as a member** (`session_member_uris`
  includes the orchestrator URI).
- The session's orchestrator reaches `:ready` (bridge `join ok`, registered, 7 tools).
- A Feishu group bound to that session (ExternalMirror, adapter `feishu`).

## Actors

- **Caller**: a Feishu user (admin / a test user).
- **Target**: the orchestrator (mentioned `@cc_orchestrator-<disc>`), a session member.
- **Behavior**: mention-routing (`Behavior.Chat :send` → `Routing.Resolver` + `$mentions`)
  delivers the message to the orchestrator; the orchestrator's MCP tool surface
  (spawn/create-agent, routing CRUD, notify) performs the action.

## Steps (the three capabilities Allen specified)

1. **Create agent** — user sends in Feishu: `@orch 创建一个 echo agent，名叫 worker-a`.
   → message routes to the orchestrator (member + mention) → orchestrator calls its
   create-agent tool → a new agent `worker-a` joins the session → orchestrator
   replies a confirmation → confirmation mirrors back to the Feishu group.
2. **Modify routing** — user sends: `@orch 把路由改成：只有 worker-a 收消息`.
   → orchestrator calls its routing-CRUD tool → the session's routing rule is
   updated → confirmation mirrors back.
3. **Notify an agent** — user sends: `@orch 通知 worker-a 说 hello`.
   → orchestrator notifies `worker-a` → `worker-a` receives (`chat.receive`) and
   replies → its reply mirrors back to the Feishu group.

## Expected outcomes (the GATE — all must hold on the LIVE system)

- **G1 (membership)**: after create, `session_member_uris(session)` includes the
  orchestrator URI (the create-flow join populates members — currently a bug:
  members is empty).
- **G2 (delivery)**: the @-mention message is DELIVERED to the orchestrator's live
  claude (its esr-bridge receives the routed message; the orchestrator acts — not
  just keepalive).
- **G3 (create)**: a new agent `worker-a` exists + is a session member after step 1.
- **G4 (routing)**: the session's routing rule reflects the step-2 change.
- **G5 (notify)**: `worker-a` gets a `chat.receive` invocation from step 3 and its
  reply is observable.
- **G6 (mirror)**: each step's result is mirrored OUT to the Feishu group
  `oc_83a4f1ff…` (the user sees the round-trip).

## Verification (two tiers — both required for the gate)

- **Automated invariant test** (`apps/ezagent_domain_chat/test/e2e/scenario_32_*`):
  asserts G1 (orch is a member after create), G2 (a mention to the orch routes a
  `chat.receive`/delivery to the orchestrator URI — not just session-level), G3/G4/G5
  by dispatching the orchestrator's tool actions and asserting their durable effects,
  and G6 by asserting an ExternalMirror outbound publish. (Does NOT require a live
  claude — exercises the mechanism deterministically.)
- **Live runbook** (this scenario, run on the branch): a real `@orch` Feishu message
  → the orchestrator's live claude actually performs the action and the result
  appears in the Feishu group. Verified per `feedback_esr_e2e_standards`
  (agent-browser screenshot of the Feishu round-trip). This is the true end-to-end —
  the automated test alone is NOT sufficient to claim "solved" (lesson 2026-05-31).

## Known blockers this scenario gates the fix for

1. **Readiness gate (mine, #504)**: relies on a fire-once `McpChannel.join` PubSub
   broadcast the create process misses → false timeout kills a working orchestrator.
   Fix: poll a live-connected state, not the fire-once broadcast.
2. **Membership / delivery**: create-flow join leaves `members` empty → the
   orchestrator (though registered) receives no session messages. Fix: the atomic
   create's join step must add the orchestrator (and owner) as members so
   mention-routing delivers to it.
3. **Worker config**: agents the orchestrator spawns (`worker-a`) stall on the same
   "Allow external CLAUDE.md imports?" dialog. Fix: `cc_agent` config-dir creation
   writes `hasClaudeMdExternalIncludesApproved` + `hasTrustDialogAccepted` +
   `enableAllProjectMcpServers` + `hasCompletedOnboarding` for EVERY agent.

## Cross-references

- Builds on Scenario 10 (mention-gated-routing) + 22 (routing-crud) + 13 (feishu-inbound).
- SPEC: `docs/superpowers/specs/2026-05-31-orchestrator-startup-atomicity-and-slice-unwrap.md`
  (registration fix, merged #504) — this scenario covers the LIVE chain the spec's
  §9 e2e described but did not codify.
