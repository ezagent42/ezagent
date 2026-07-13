# Canary agent-callability verification

Status: **CORE CALL PATH PASS; PTY UI LIMITATION FOUND**

This evidence set covers the 2026-07-13 `gagameow` task defined in
`docs/together/2026-07-13/gagameow-agent-callable-canary-task-analysis.md`.

## Environment and identities

- Endpoint: `https://canary.ezagent.chat`
- Application SHA: `a915343de2c9e2ba36f2395670562495b7fd57fd`
- Test window: 2026-07-13 07:00:04Z–07:13:22Z
- Tester: authenticated user `entity://ezagent/user/huang_jiajia`
- Workspace: `workspace://ezagent`
- Socialware: `orchestrator` (`Orchestrator`)
- Expected role/recipe: `orchestrator`
- Actual flavor: `cc-deepseek`
- Session:
  `session://ezagent/socialware-install-orchestrator/acc-20260713t065612z-79e83afd`
- Agent: `entity://ezagent/agent/5825561c-cbd6-433e-a1ea-b45d681371b6`

## Steps and actual results

1. Magic-link authentication was recovered after the separately authorized
   PAT-pepper deployment correction. A fresh authenticated browser loaded the
   Sessions product surface.
2. The browser selected the formal `default` session template and the catalog
   `orchestrator` socialware, then submitted the real create form. The
   LiveView create operation returned in 912 ms and the complete interaction
   in 4,503 ms, without reproducing the old five-second timeout.
3. A fresh page reload found the exact session URI. The UI showed two members,
   an empty transcript, and the real message composer.
4. The installed role materialized as one online, PTY-backed agent with role
   `orchestrator`; there were no unfilled agent-role slots or degraded operates
   edges. Agent detail reported flavor `cc-deepseek`, lifecycle `alive`, child
   phase `running`, and cwd `/home/ezagent/.ezagent/orchestrator`.
5. Sanitized file logs showed the agent chat bridge joined at 07:00:14.870Z and
   the orchestrator MCP bridge joined at 07:00:15.225Z. The agent detail state
   showed the development-channel prompt fired and the Claude surface reported
   experimental messages from `server:esr-bridge`.
6. The real chat UI sent two distinct `@orchestrator` nonce probes. The same new
   agent returned the exact requested ACK for both (5.895 s and 3.335 s by
   durable message timestamps).
7. The same UI and agent identity received a minimal development-planning task.
   It returned `ACCEPTED`, a concrete scope, a three-step plan, and `Plan ready —
   no files edited.`

## Expected versus actual

- Session create/readback: **PASS**.
- Correct new agent, role, recipe/socialware, and flavor: **PASS**.
- Agent chat bridge and orchestrator bridge joins: **PASS**.
- Development-channel injection and actual message handling: **PASS**, proven by
  the fired channel prompt, the visible channel status, three correlated inbound
  deliveries, and three agent tool calls/replies.
- Two independent nonce replies: **PASS**.
- Minimal kanban-style task acceptance: **PASS**.
- Terminal process existence and callable readiness: **PASS**; the agent is
  alive and completed all three calls.
- Terminal tab rendering: **FAIL (separate UI serialization defect)**. Opening
  the Terminal tab deterministically terminates that LiveView because
  `agent_status.detail.exec_pid` is a PID and `push_world_state/2` passes it to
  `Jason.encode!/1`. This does not interrupt the agent or either bridge, but the
  Terminal view cannot currently render. Evidence and reproduction are in
  `05-pty-and-bridge-join.log`.

## Conclusion

The canary-hosted Orchestrator is genuinely callable through the product chat
path and is ready for the next kanban-to-agent chain test. The result is not a
claim that the full hello→kanban→PR demo is complete. The downstream test must
carry one explicit limitation: operator PTY inspection through the Terminal tab
is broken until the PID serialization defect is fixed, deployed, and rechecked.

No session cleanup or deployment change was performed during this product
verification. Those remain separate authorization gates.

## Evidence files

- `01-deploy-baseline.txt` — health, deployed SHA, and required commit baseline.
- `02-auth-blocker.txt` — sanitized authentication failure diagnosis.
- `03-auth-recovery.txt` — sanitized authorized configuration correction.
- `02-session-created.png` — product UI after durable session readback.
- `03-orchestrator-replied.png` — real task instruction and agent response.
- `04-transcript.txt` — durable sender/message/time/nonce transcript.
- `05-pty-and-bridge-join.log` — sanitized lifecycle, channel, join, delivery,
  and PTY UI failure evidence.
- `06-kanban-dispatch-readiness.txt` — downstream handoff and limitation.
