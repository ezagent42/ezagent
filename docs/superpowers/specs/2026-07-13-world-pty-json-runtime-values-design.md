# World PTY JSON runtime-value normalization design

## Context

Canary verification on 2026-07-13 proved that a newly materialized
`cc-deepseek` Orchestrator can receive and answer product-chat calls. The same
verification found a separate operator-UI defect: dispatching
`session.pty.open` terminates the LiveView before the Terminal panel renders.

`Ezagent.Domain.Agent.lifecycle_status/1` returns diagnostic detail containing
an `exec_pid` PID for a running PTY. `Ezagent.World.ConversationActions` places
that status in world state after passing it through its private `jsonable/1`
normalizer. The normalizer recursively handles structs, maps, lists, dates,
URIs, and atoms, but returns other values unchanged. `push_world_state/2` then
passes the PID to `Jason.encode!/1`, which raises `Protocol.UndefinedError`.

## Goal

Make the public `session.pty.open` LiveView path safely serialize runtime-only
BEAM values while preserving useful diagnostic information. Opening Terminal
must push PTY state instead of terminating the LiveView.

## Selected approach

Keep normalization at the World JSON boundary. Extend the final fallback of
`ConversationActions.jsonable/1` so a value that is not already JSON-safe is
converted with `inspect/1`.

The intended outcomes are:

- PID values become readable strings such as `#PID<...>`;
- the same boundary also safely handles future Port, Reference, function, or
  other runtime-only diagnostic values;
- existing JSON-safe strings, numbers, booleans, and `nil` retain their native
  JSON types;
- existing recursive handling of URI, date/time, struct, map, list, and atom
  values remains unchanged;
- no lifecycle, PTY, dispatch, CapBAC, or agent readiness behavior changes.

This matches the defensive fallback already used by other World projection
modules such as `IdentityData` and `AdminData`.

## Alternatives rejected

### PID-only normalization

Adding only an `is_pid/1` branch would fix the observed value but leave Port,
Reference, and similar runtime diagnostics able to crash the same JSON
boundary. The broader fallback is equally local and more robust.

### Normalize inside `Domain.Agent.lifecycle_status/1`

Changing the domain function would impose a JSON projection concern on every
consumer of lifecycle status and could remove native runtime values from
internal callers. The defect belongs at the World serialization boundary.

## Verification design

Follow red-green-refactor:

1. Extend the existing World conversation LiveView coverage for
   `session.pty.open` so the lifecycle status supplied by a running/test agent
   contains a PID.
2. Assert the public hook does not terminate the LiveView and pushes
   `active_view=pty`, the selected agent URI, and a JSON-safe string for the
   nested `exec_pid` field.
3. Run the focused test before production changes and confirm it fails with the
   current Jason PID encoding error.
4. Implement only the fallback normalization and rerun the focused test.
5. Run the surrounding World conversation test file, formatter, and repository
   `mix precommit` gate.

If producing a real lifecycle status with a PID through existing public test
helpers proves impractical, extract the existing private normalizer into a
focused internal World projection module and test that module plus the existing
LiveView PTY event. This fallback keeps behavior at the same architectural
boundary; it must not introduce a test-only production hook or mock domain
lifecycles.

## Error handling and compatibility

The World projection must never raise merely because diagnostic state contains
a runtime-only term. `inspect/1` is deliberately lossy for transport purposes:
the browser only displays the diagnostic value and must not use it as a process
handle. Native internal lifecycle consumers continue receiving the original
term.

No API field is removed. Consumers that previously could not receive
`agent_status` at all when it contained a PID will instead receive the field
with a readable string value.

## Non-goals

- Do not change PTY spawning, restart, config-home materialization, onboarding,
  bridge joins, or channel registration.
- Do not address the unrelated legacy `test-zyli-cc-1` crash loop observed in
  Canary logs.
- Do not deploy or restart Canary as part of the local fix.
- Do not clean up the test session or agent.
- Do not generalize all project JSON encoding in this change.

## Deployment and revalidation boundary

The local code fix and tests do not prove the deployed Terminal path is fixed.
After review and merge, a Canary deployment/restart requires separate explicit
authorization. Post-deployment verification should reopen Terminal for the
recorded test session or a fresh equivalent session and confirm the PTY panel
renders without a LiveView exception.
