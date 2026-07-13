# Canary agent-callability verification

Status: **BLOCKED at interactive authentication**

This evidence set tracks the 2026-07-13 `gagameow` task defined in
`docs/together/2026-07-13/gagameow-agent-callable-canary-task-analysis.md`.

## Current result

- Canary HTTP liveness is green through the tailnet endpoint.
- Read-only deployment-host inspection verifies canary is running application
  SHA `a915343de2c9e2ba36f2395670562495b7fd57fd`; #1294, #1326, #1332, and #1333
  are all present.
- A fresh magic link for the verified `huang.jiajia@ezagent.chat` account reached
  the consume endpoint, but login stopped after token consumption with:

  ```text
  Sign-in token service is unavailable. Please try again.
  ```

- The failure occurs after `MagicLinkToken.consume/2`, while
  `PatDelivery.issue/3` rotates the interactive-login PAT. The controller does
  not expose the underlying `Entity.Token.rotate_label/3` error.
- A controlled retry consumed a newly minted link in approximately 40 seconds
  and reproduced the same PAT-delivery error. Normal link expiry is therefore
  ruled out for this blocker.
- Read-only presence inspection confirms the selected PAT pepper is missing or
  shorter than the required 32 bytes. This is the root cause of the PAT delivery
  failure; no secret value was read or recorded.
- Product verification has therefore **not** created a session, sent an
  `@orchestrator` message, or claimed that the agent chain works.

## Required unblock

The deployment owner must, only after explicit user approval:

1. set a valid `EZAGENT_PAT_PEPPER_V<n>` matching the configured digest version;
2. refresh/redeploy the canary application so it receives the corrected secret;
3. request a newly minted magic link, because links used in prior attempts are
   single-use.

## Online-access authorization

The deployment host and formal canary container have now been located. Remote
access remains strictly read-only. Any action that changes online state —
including configuration, container lifecycle, deployment, database data,
accounts, session creation, message sending, agent invocation, or cleanup —
requires explicit user approval before execution.

## Evidence files

- `01-deploy-baseline.txt` — health, connectivity, Git/deploy visibility.
- `02-auth-blocker.txt` — sanitized reproduction and code-path diagnosis.

The remaining planned screenshots, transcript, PTY/bridge evidence, and minimal
task-dispatch result cannot be produced until authentication and release
baseline checks are unblocked.
