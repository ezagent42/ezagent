# Capability/Auth Follow-up Design

## Context

PR #1402 closes the AgentRuntime ARB-0/ARB-1 boundary and fixes the immediate
LiveAuth hot-state divergence. The canary investigation also exposed independent
authentication, capability durability, reader consistency, display, provenance,
and operational follow-ups. They must not be combined into one authority rewrite.

The baseline is `origin/main@be23fcf97`, which contains PR #1375, #1379, #1399,
#1400, and #1401. New capability artifacts are receiver-bound Ed25519 signed, but
production remains in dual-read mode while `require_signature: false` accepts
legacy unsigned artifacts with telemetry.

## Decision

Deliver the work as a dependency-ordered PR queue:

1. Fix the independent `HomeLive` identity-escalation path first.
2. Consume, rather than duplicate, the lead-locked `Ezagent.EntityCaps` facade.
3. Migrate LiveAuth to that facade and prove online/cold/restart behavior.
4. Converge the remaining non-authorizer readers and UI projections.
5. Decide the email inbound exception explicitly.
6. Complete no-tail signing migration before enabling signature enforcement.
7. Continue AgentRuntime debt reduction as separate shrink-only PRs.
8. Finish creator Terminal canary acceptance after deployable code lands.

## Architectural constraints

- User durable capability storage remains `users.caps_json`; Agent durable storage
  remains the Identity snapshot. `Ezagent.EntityCaps` is the common API, not a
  third physical store.
- Authorization consumers use receiver-aware verified capability readers.
- Malformed, stale, missing, or wrong-kind identity input fails closed. It never
  substitutes the admin principal.
- Grant/revoke durability must guarantee that a revoked capability does not
  reappear after stop/restart.
- `Ezagent.Cap.issue/3` remains the issuance chokepoint. No caller fabricates
  provenance or signatures.
- `require_signature: true` is forbidden until the authorizer-cap audit reports
  unsigned count zero.
- Every PR is independently revertible and has a closed-set DoD.
- Canary mutation requires a backup, a rollback command, and a post-operation
  data-integrity check. Local tests must not use canary databases.

## PR boundaries

### PR A — AUTH-FAIL-1

`EzagentWeb.HomeLive` rejects malformed, stale, and non-entity identity cookies.
The authenticated mount must halt and redirect to login (or the existing
authentication route), without parsing fallback to `Entity.User.admin_uri/0`.

### Upstream dependency — EntityCaps A/D

Track the lead-owned facade and durable grant/revoke work. Do not reimplement it
locally. Required semantic surface: receiver-aware `load`, durable `persist`, and
grant/revoke operations whose restart behavior is tested for both User and Agent.

### PR B — LiveAuth final convergence

Replace the temporary `Identity.read_entity_caps/1` dependency with the landed
`EntityCaps` facade. Cover User and Agent principals across online, cold,
grant, revoke, stop, and restart transitions.

### PR C — member-cap reader

Remove the raw Identity snapshot capability read in `Session.MemberCap`. The
idempotency check consumes a verified nonblocking reader and cannot be reused as
an authorization source without failing an invariant.

### PR D — World cap-count projection

Compute `cap_count` from the common verified read model rather than
`Users.get_by_uri/1`'s raw `caps_json` projection. This is display consistency,
not an authorization change.

### PR E — email inbound authority boundary

Decide between a narrowly pinned ephemeral self-authority exception and formal
issuance. Whichever is selected must preserve one concrete session, one concrete
workspace, and only the required send action.

### PR F — signing no-tail and enforcement

Re-derive or reissue stored User capabilities through `Cap.issue/3`, audit every
authorizer-bearing store, prove unsigned count zero, and only then flip
`require_signature: true`.

### Independent tracks

ARB-2..ARB-5 reduce the AgentRuntime allowlist one ownership slice per PR.
Creator Terminal acceptance records product call, authenticated credential
status, and restart persistence after the relevant code is deployed.

## Verification contract

Every code PR runs its focused red/green regression, touched-app tests,
`mix ezagent.arch.scan`, `mix ezagent.doc.scan`, `mix ezagent.uri_query.scan`,
`mix ezagent.check_invariants`, and `SHELL=/bin/bash mix precommit`. A reviewer
must report no Critical or Important issue before push/PR handoff.
