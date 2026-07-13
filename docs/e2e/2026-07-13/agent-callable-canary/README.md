# Canary agent-callability verification

Status: **CORE CALL PATH PASS; PTY PID SERIALIZATION PASS ON CANARY; XTERM RUNTIME FAIL**

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

Post-deploy repair revalidation:

- PR: `#1367`, merged as `760a86c7a6468e7cb64c1af7a1284ecabf1d5e80`
- Running image: `ezagent:760a86c7a`
- Test window: 2026-07-13 10:53:17Z–10:58:00Z
- Session:
  `session://ezagent/socialware-install-orchestrator/acc-postdeploy-20260713T105317Z-27310`
- Agent: `entity://ezagent/agent/9ddf0b1c-6179-4681-95d4-11f1adb37502`

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
- Three-state message screenshots: **PARTIAL**. The evidence includes the
  pre-send session state and the final instruction-plus-reply state, but not a
  separate screenshot captured after send and before the reply. The durable
  transcript preserves that intermediate timing, but it does not replace the
  strict screenshot requirement.
- Terminal process existence and callable readiness: **PASS**; the agent is
  alive and completed all three calls.
- Config-home materialization before PTY spawn: **PASS after deployment**. The
  new agent's completion marker has mtime `10:53:22.339105512Z`; the first PTY
  spawn log is `10:53:22.502941888Z`, 163 ms later. The earlier activation log
  explicitly deferred launch while the home was incomplete.
- Terminal PID serialization: **PASS after deployment**. Opening the Terminal
  tab no longer terminates the LiveView. The browser state contains
  `exec_pid` as a string, `cwd` as a string, and `os_pid` as a number; the PTY
  panel remains visible with `active_view=pty`, `Kind alive`, and `PTY running`.
- Interactive xterm rendering: **FAIL (separate client-runtime defect)**. The
  stable Terminal surface displays `xterm runtime is not loaded.` and an empty
  terminal canvas. A second 10-second reproduction produced no console error,
  page error, failed request, or HTTP 4xx/5xx. Source inspection shows the World
  React component expects `window.Terminal` and `window.FitAddon`, while the
  World package neither imports nor declares xterm dependencies. This defect is
  outside PR #1367's server-side scalar serialization repair.

## Post-deploy steps and actual results

1. Verified the healthy Canary container was running `ezagent:760a86c7a`, the
   merge commit for PR #1367.
2. Re-authenticated through the email magic-link product path and opened
   `/sessions`; no credential or token value was retained in this evidence.
3. Created one fresh Orchestrator session through the real create form. The
   create operation returned in 875 ms (3,625 ms total navigation), with no
   form error or browser console error. A product readback showed two members,
   the new agent online with PTY alive, no unfilled role slots, and no degraded
   operates edges.
4. The config-complete marker preceded the first PTY spawn, and both the
   orchestrator and agent bridges joined for the new agent. The first Claude
   subprocess exited during auto-prompt handling; the supervised retry started
   PID 9140, joined both bridges, and served the successful call below.
5. Sent one post-deploy unique nonce through the real chat UI. The sent-only
   screenshot was captured 340 ms after send; the exact agent ACK arrived about
   7.3 seconds after send. The reply came from the new agent and the browser
   reported no console errors.
6. Opened Terminal. The repaired server state serialized successfully and the
   LiveView stayed alive, proving PR #1367's regression is fixed on Canary. The
   visual inspection also exposed the separate xterm runtime failure described
   above.

## Conclusion

The canary-hosted Orchestrator remains genuinely callable through the product
chat path, and PR #1367 fixes the Terminal-opening LiveView crash on the deployed
Canary image. The full hello→kanban→PR demo is not claimed here. Downstream may
continue chat-based chain testing, but operator PTY inspection is still not
usable because the World client does not load the xterm runtime. This is a new,
separate frontend failure and must not be reported as fixed by PR #1367.

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
- `07-postdeploy-session-created.png` — fresh create operation before any chat
  message (captured while the UI still showed the short `creating` transition).
- `08-postdeploy-message-sent.png` — post-deploy nonce visible before reply.
- `09-postdeploy-orchestrator-replied.png` — exact ACK from the new agent.
- `10-postdeploy-terminal.png` — stable Terminal surface, scalar crash gone,
  with the separate xterm runtime error visible.
- `11-postdeploy-transcript.txt` — timestamps, identities, nonce, and reply.
- `12-postdeploy-pty-and-bridge.log` — sanitized marker, spawn, bridge, type,
  and client-runtime diagnostics.
