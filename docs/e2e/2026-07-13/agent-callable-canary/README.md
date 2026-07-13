# Canary agent-callability verification

Status: **IN PROGRESS — interactive authentication unblocked**

This evidence set tracks the 2026-07-13 `gagameow` task defined in
`docs/together/2026-07-13/gagameow-agent-callable-canary-task-analysis.md`.

## Current result

- Canary HTTP liveness is green through the tailnet endpoint.
- Read-only deployment-host inspection verifies canary is running application
  SHA `a915343de2c9e2ba36f2395670562495b7fd57fd`; #1294, #1326, #1332, and #1333
  are all present.
- Before the deployment correction, fresh magic links for the verified
  `huang.jiajia@ezagent.chat` account stopped after token consumption with:

  ```text
  Sign-in token service is unavailable. Please try again.
  ```

- The failure occurred while `PatDelivery.issue/3` rotated the interactive-login
  PAT. Controlled reproduction and presence-only configuration inspection
  established that the selected PAT pepper was absent from the application
  container.
- With explicit user approval, the existing pepper was moved from the Compose
  substitution file into the service `env_file`, preserving the exact value.
  Only the canary application service was recreated. The original files are
  backed up outside Git and an exact rollback command is recorded in the
  local-only deployment note.
- Post-change checks confirmed a healthy container, successful HTTP health,
  and a selected PAT pepper of valid length inside the canary application.
- A newly minted magic link then redirected to `/login/token`, and the same
  authenticated session fetched `/sessions` with HTTP 200. The former
  authentication blocker is therefore resolved.
- Product verification has still **not** created a session, sent an
  `@orchestrator` message, or claimed that the agent chain works. Those online
  writes require their own explicit authorization.

## Next authorization gate

Before continuing the product proof, obtain explicit permission to create one
new orchestrator session, allow its agent materialization, and send the two
nonce probes plus one minimal development-task instruction.

## Online-access authorization

Remote access is read-only by default. The user explicitly authorized the
single PAT-pepper configuration correction and canary application recreation;
that authorization does not implicitly cover session creation, message sending,
agent invocation, cleanup, or unrelated deployment changes.

## Evidence files

- `01-deploy-baseline.txt` — health, connectivity, Git/deploy visibility.
- `02-auth-blocker.txt` — sanitized reproduction and code-path diagnosis.
- `03-auth-recovery.txt` — sanitized correction and fresh-login verification.

The remaining planned screenshots, transcript, PTY/bridge evidence, and minimal
task-dispatch result await the product-write authorization described above.
