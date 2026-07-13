# Canary agent-callability verification

Status: **BLOCKED at interactive authentication**

This evidence set tracks the 2026-07-13 `gagameow` task defined in
`docs/together/2026-07-13/gagameow-agent-callable-canary-task-analysis.md`.

## Current result

- Canary HTTP liveness is green through the tailnet endpoint.
- The public health endpoint does not expose a release revision, so the deployed
  application SHA is not yet verified.
- A fresh magic link for the verified `huang.jiajia@ezagent.chat` account reached
  the consume endpoint, but login stopped after token consumption with:

  ```text
  Sign-in token service is unavailable. Please try again.
  ```

- The failure occurs after `MagicLinkToken.consume/2`, while
  `PatDelivery.issue/3` rotates the interactive-login PAT. The controller does
  not expose the underlying `Entity.Token.rotate_label/3` error.
- Product verification has therefore **not** created a session, sent an
  `@orchestrator` message, or claimed that the agent chain works.

## Required unblock

The deployment owner must provide, without revealing secret values:

1. the current canary application SHA;
2. `SET/MISSING` for `EZAGENT_PAT_DIGEST_VERSION` and the selected
   `EZAGENT_PAT_PEPPER_V<n>` (pepper length must be at least 32 bytes);
3. the container log entry for the failed magic-link request around
   `2026-07-13T04:24Z`, including the internal PAT rotation reason but excluding
   tokens, cookies, authorization headers, and secret values;
4. after correcting deployment configuration if needed, a newly minted magic
   link, because the link used in this attempt was single-use.

## Evidence files

- `01-deploy-baseline.txt` — health, connectivity, Git/deploy visibility.
- `02-auth-blocker.txt` — sanitized reproduction and code-path diagnosis.

The remaining planned screenshots, transcript, PTY/bridge evidence, and minimal
task-dispatch result cannot be produced until authentication and release
baseline checks are unblocked.
