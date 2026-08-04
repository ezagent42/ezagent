# Session-local PTY credential respawn design

## Problem

An admitted Codex agent can complete interactive authentication in its PTY, but
the next chat completion may still fail with
`{:generation_failed, :no_credential_source}`. The initial template resolution
correctly marks the session-local PTY credential as optional. The respawn
snapshot drops that boolean, and the runtime rehydration path consequently
defaults it back to required when it heals or starts the subprocess bridge.

Separately, the Hello Page view can disappear when a long-lived runtime is not
aligned with capability data recreated by a database reset. The persisted admin
self-license and its authority key currently verify successfully, so this repair
does not change the Page authorization model.

## Decision

Persist `credential_required?` in the plain-data `cascade_resolution` respawn
snapshot. Preserve only boolean values; do not persist runtime functions,
credential material, or reusable credential-source references. For an admitted
session-local PTY agent, `false` therefore survives subprocess healing and keeps
the resolver on its existing keyless path.

Do not bypass cascade resolution and do not convert the interactive PTY login
into a shared credential source. Both alternatives broaden credential lifetime
and violate the session-local isolation boundary.

After deploying the change, restart the development service so capability
caches, live Kinds, and session view projections are rebuilt from the current
database. Page visibility remains governed by the existing Hello view capability
check.

## Data flow

1. Session admission creates the Codex agent with
   `credential_source_policy: :session_local` and
   `credential_required?: false`.
2. Template spawn sanitizes the cascade into the durable respawn data.
3. The snapshot retains the optional-credential boolean alongside the existing
   owner, workspace, session, policy, and layer URIs.
4. A later completion request may heal the subprocess bridge.
5. `CascadeRuntime` rehydrates the snapshot and passes
   `credential_required?: false` to the resolver.
6. The resolver permits the agent's already-authenticated local config home and
   the completion proceeds without looking for a reusable source.

## Error handling and safety

- Missing legacy snapshot fields keep the existing fail-closed default of
  `credential_required?: true`.
- Only literal booleans are serialized; malformed values are omitted and retain
  the fail-closed default.
- Required-credential agents and sourced cascades are unchanged.
- No secrets or authentication files are copied into the snapshot.

## Verification

- Add a focused regression test proving that sanitization retains both `true`
  and `false` boolean values and ignores malformed values.
- Add or extend a runtime rehydration test proving that a persisted `false`
  avoids `:no_credential_source`.
- Run the focused domain-agent/core tests, relevant admission tests, and
  `mix precommit`.
- Restart the service on port 10042 and verify health, Hello Page authorization,
  and a completion request from `hello-codex-2`.

## Scope

This change repairs credential-state persistence and refreshes the current
development runtime. It does not redesign admission UI, credential sharing,
Hello Page authorization, or database-reset tooling.
