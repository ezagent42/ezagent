# Phase 3 cbac-done-right — S8 live E2E

Date: 2026-07-11 (Asia/Shanghai)

## Verdict

PASS. All five PLAN S8 flows completed through the real World UI with
`agent-browser`; every checkpoint has a screenshot. Read-only PostgreSQL and
bridge-log inspection supplements the UI evidence. It does not replace it.

S8 itself adds no production code. The first orchestrator tool attempt exposed
a real cold-rebuild gap (`:orchestrator_not_registered`). That production-flow
gap was fixed and reviewed in PR #1353, merged into the integration branch,
then retested here on a cold restart before S8 was accepted.

## Environment

- Integration branch: `feat/cbac-done-right`
- Product tree under test: `8ce414eeda12bd455a98ce8d1cbe38b3a7471a82`
  (merge of S7 follow-up PR #1353)
- Evidence branch: `feat/cbac-done-right-s8`
- Disposable PostgreSQL database: `ezagent_phase3_s8_20260711_1948`
  (`127.0.0.1:55432`)
- Isolated runtime home:
  `/tmp/ezagent-phase3-s8-20260711-1948/home`
- Isolated empty Codex home:
  `/tmp/ezagent-phase3-s8-20260711-1948/codex-empty`
- Phoenix: `http://world.localhost:10045`
- World Vite: `http://localhost:5185`
- Driver: `agent-browser 0.26.0`, session `phase3-s8`
- Runtime: Elixir 1.19.5 on Erlang/OTP 28

The database and runtime home were created empty for this run. The same
disposable stack was stopped and cold-restarted on the final integration tree
after PR #1353; no shared development database or long-lived agent state was
used.

## Required checkpoints

| # | Phase 3 acceptance | Live result | Evidence |
|---|---|---|---|
| 0 | Login and fresh seeded stack | Admin is logged in to `workspace://system`; the fresh UI initially has no sessions. | `01-login.png` |
| 1 | Session create → agent spawn/materialize | Created `session://system/socialware-install-hello/phase3-s8-hello-1948`; role agent `entity://system/agent/65862808-5e71-4877-85ca-7a2e73240418` materialized and was live after the final-tree cold restart. Its `np` recipe has an empty recipe-cap set; the same materialize path with a non-empty recipe-cap set is proved by the orchestrator role in checkpoint 4 and the create-time evidence below. The member panel also shows unrelated unavailable roles without blocking the session. | `02-session-materialized.png` |
| 2 | `@mention` delivery + visible reply | Selected the real `responser` mention in autocomplete, sent `3+5 # @responser`, and received visible reply `= 8.0`. | `03-mention-reply.png` |
| 3 | Cap-gated ISSUE → self-STORE → VERIFY | Agent `entity://system/agent/phase3-s8-cap-probe-1948` received the requested session capability. UI shows issuer `entity://system/user/admin`; audit row 276 is `cap_granted` with `via_absorb:true`. | `04-cap-self-store.png` |
| 4 | Orchestrator-scoped caps + bounded operation | Orchestrator `entity://system/agent/c84d5606-a6e8-4512-bd2e-824172ce8c6f` received four scoped artifacts via absorb. After a cold restart, both bridges joined; `define_rule_set_rule` returned `{"id":4}` and created only the requested session/workspace-scoped rule. | `05-orchestrator-scoped-caps.png`, `06-orchestrator-scoped-op.png` |
| 5 | Session remains usable without its agent | `entity://system/agent/fea37eac-0616-4688-b73b-cea492f73367` has a durable member snapshot but is absent from the live Agents directory. Its session stayed alive and Admin successfully sent a visible owner message. | `07a-unavailable-agent-directory.png`, `07-usable-without-agent.png` |

## Message and authorization evidence

### Mention round-trip

- Request message: `482acd7a71c78c8a`, sender
  `entity://system/user/admin`, mentions exactly
  `entity://system/agent/65862808-5e71-4877-85ca-7a2e73240418`.
- Reply message: `cdae5a2686df20ec`, body `= 8.0`, with
  `ref_id=482acd7a71c78c8a`.
- Audit rows 860/861 (`session.send`), 870 (`agent.receive`), and 874/876
  (agent `session.send`) all have `authz=granted` and no exception.

### Cap self-store

Audit row 276 records the cap absorbed by
`entity://system/agent/phase3-s8-cap-probe-1948`:

```text
kind=:session
behavior=Ezagent.ActionSet.Session
action=:any
instance=:any
workspace_uri=:any
granted_by=entity://system/user/admin
via_absorb=true
```

The UI issuer column agrees with the audit row. The grantee did not become the
issuer.

### Create-time recipe self-store

The orchestrator is also a session role agent, so it exercises the non-empty
form of checkpoint 1's recipe-cap requirement. Its durable recipe binding was
inserted at `2026-07-11 12:19:28.383394Z`, before the agent's first snapshot at
`2026-07-11 12:19:28.424203Z`. The binding holds four self-scoped Template
artifacts (`read`, `write`, `instantiate`, `fork`), all issued by Admin.

Read-only decoding of that durable snapshot shows the same four caps in the
agent's identity slice and the same four identity keys in
`recipe_binding_keys`, with `recipe_binding_version=1`. The initial
`snapshot.written` audit is row 624; no `identity.grant_cap` dispatch targeting
the role exists before it. This is the observable ordering for binding →
`create/1` self-store, rather than a post-spawn issuer-to-grantee cap write.

### Recipe and orchestrator artifacts

The durable recipe binding for orchestrator `c84d5606-...` is version 1,
untombstoned, with `issuer_uri=entity://system/user/admin`. It contains four
self-scoped Template artifacts (`read`, `write`, `instantiate`, `fork`) whose
`granted_by` is the same admin issuer.

Audit rows 644–647 record the four delegated orchestrator artifacts. Every row
has `via_absorb:true` and `granted_by=entity://system/user/admin`:

```text
{:within_workspace, workspace://system}  session_template / Template / :any
{:within_workspace, workspace://system}  agent_template   / Template / :any
{:within_session, session://system/socialware-install-orchestrator/Phase3-S8-Orch-Ready-2018}
                                          session          / :any     / :any
{:spawned_by, entity://system/agent/c84d5606-a6e8-4512-bd2e-824172ce8c6f}
                                          agent            / :any     / :any
```

On the final-tree cold restart, the orchestrator bridge logged
`join ok; orchestrator MCP transport ready` at 21:29:38.853. The successful
tool call produced routing rule 4:

```text
matcher_data={"type":"text_contains","arg":"phase3-s8-route-probe"}
receivers={entity://system/agent/c84d5606-a6e8-4512-bd2e-824172ce8c6f}
created_by=session://system/socialware-install-orchestrator/Phase3-S8-Orch-Ready-2018
workspace_uri=workspace://system
rule_set=phase3-s8
position=0
```

Invocation audit rows 815/816 are `routing.add_rule` with the orchestrator as
caller, the current session as target, `authz=granted`, and no exception.

### Usable without agent

The unavailable member's complete audit history is rows 385–391: initial
snapshot writes plus self `reconcile_cascade` only. Across the retained run it
has zero bridge/ready/activated/send/receive audit events, and its durable
snapshot never changed after `2026-07-11 12:08:46.143025Z`. Thus
`fea37eac-...` never joined a transport or became a live agent during this E2E,
not merely at the instant of the screenshot.

The owner-only operation on
`session://system/socialware-install-orchestrator/phase3-s8-orch-1948`
completed later at `2026-07-11 13:36:47Z`. Audit rows 843/844 record Admin's
`session.send` with `authz=granted` and no exception. The real Agents UI,
filtered by that exact member URI, returned `No agents in this workspace.`
Database timestamps in this section are UTC; the World UI renders the same
events in Asia/Shanghai (UTC+8), hence `13:36:47Z` appears as `21:36:47` in
the screenshot.

## Regression caught and closed during S8

The first real orchestrator tool attempt failed because lazy MCP context
rebuild understood only the legacy OTU representation and did not restore the
session-owned executor for an ordinary durable role/member binding. PR #1353
closed that product-flow gap by:

- rebuilding context from the exact durable orchestrator member binding;
- registering context, then starting the executor, then exposing scoped caps;
- preserving legacy OTU compatibility and fail-closed checks; and
- adding repair-order, rollback, durable snapshot, port, and architecture
  regressions.

The follow-up passed 79 targeted tests, a full native `mix ci.local`, the
remote deterministic gate, and an independent static review. S8 then proved
the fix through the real MCP subprocess and UI, rather than accepting the unit
tests as a substitute.

## Final gate

- S7 follow-up native `mix ci.local`: PASS, exit 0.
- S8 final low-load gate:
  `ERL_FLAGS='+S 2:2' MIX_ENV=test MIX_TEST_PARTITION=phase3s8_final_serialish_2202 mix ci.local`:
  PASS, exit 0 (ExUnit `max_cases: 4`).
- Three high-load retries exposed only known #108-class sandbox/async timing
  flakes. Each implicated file passed immediately in a fresh isolated
  partition: transport readiness 20/20, session-create decoupling 5/5, and
  default session-template seed 9/9. No product code was changed for them.
- S8 production-code diff: none.

## Cleanup

Phoenix, Vite, bridge, and browser processes are stopped after final evidence
capture. The disposable database and isolated runtime home may be retained
temporarily for coordinator reproduction; neither is used by a shared dev
stack or committed to git.
