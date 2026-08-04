# Session-Scoped Agent Admission Reconciliation Design

**Date:** 2026-08-04

**Status:** approved

## Problem

A PTY-backed admission can remain in `authenticating` after the user has
successfully logged in. The current supervised admission sweeper expires timed
out attempts and revalidates joined agents, but it never checks whether an
active provisional agent has become authenticated. World exposes
`session.agent_admission.complete`, but the conversation client never invokes
it for a PTY admission.

This leaves the session role unfilled even though the provisional agent owns a
valid credential. If the user then cancels, cancellation removes the admission's
candidate association. A later `Connect Codex` creates a fresh provisional
agent with a fresh credential home and therefore presents the login flow again.

## Goal

Complete a PTY-backed admission automatically when its provisional agent
becomes authenticated, while preserving the same agent, session-local
credential isolation, and an explicit recovery path in the conversation view.

Reconciliation is scoped by `session_uri`. It inspects only active admission
rows owned by that session. It does not scan arbitrary agents, credential homes,
or candidates belonging to other sessions.

## Invariants

1. An admission candidate belongs to exactly one session and role.
2. Reconciliation accepts a `session_uri` and reads only that session's
   `agent_admissions` working-copy state.
3. Within the session, every `authenticating` or `materializing` candidate may
   be reconciled; candidates from another session are never inspected.
4. Successful authentication joins the same provisional agent. It never
   creates a replacement agent or publishes a reusable credential source.
5. A missing or temporarily unreadable credential is pending state, not an
   authentication failure, and must not retire the candidate.
6. Completion, cancellation, and timeout serialize through the admission lock.
7. Cancellation or timeout performs a final credential probe before cleanup.
   An authenticated candidate completes admission instead of being destroyed.
8. Repeated reconciliation and repeated client actions are idempotent.

## Options Considered

### 1. Explicit completion button only

Add an `I have logged in` action that calls the existing completion endpoint.
This is simple, but completion remains dependent on the browser, users can
forget the extra step, and the current destructive authentication-failure path
would still make an early click unsafe.

### 2. Automatic reconciliation only

Let the backend detect credentials and complete admission without any client
action. This gives the shortest successful flow, but a delayed state push or a
temporarily unavailable terminal leaves the user without a recovery control.

### 3. Automatic reconciliation with session-scoped recovery controls

Selected. The backend owns completion, while the conversation view exposes
`Continue login` and `Check connection status` for the current candidate. This
keeps correctness independent of the browser and gives the user a deterministic
way to resume or request an immediate check.

## Architecture

The Session domain remains the owner of admission state transitions. It exposes
a session-scoped reconciliation operation whose input is `session_uri` and
whose candidates come exclusively from that session's durable admission rows.
World remains a transport and projection layer; React does not infer
authentication from PTY output or inspect credential files.

The existing supervised admission process invokes reconciliation per session.
An immediate reconciliation can also be requested for the session currently
shown by World. Both paths call the same domain operation and therefore share
locking, authorization context, credential probing, and idempotency semantics.

Reconciliation is not a global credential-directory scan. The supervisor may
discover sessions through the existing session registry, but each invocation is
bounded to one `session_uri` and its admission rows.

## State Flow

For each active candidate in a session:

1. Acquire the session admission lock and re-read the current row.
2. Confirm that its role, attempt ID, provisional agent URI, declaration, and
   template revision still match the session working copy.
3. Read credential status from that provisional agent using the provider
   profile frozen in the admission row.
4. On `authenticated`, transition through `materializing`, bind the declared
   recipe and capabilities, join that same agent, and persist `joined`.
5. On `missing` or `unknown`, preserve the active row and return a pending
   outcome without cleanup.
6. On a terminal materialization error, use the existing explicit failure and
   compensation path and publish the failure state.

The normal successful user journey becomes:

1. `Connect Codex` creates one provisional agent and opens its PTY.
2. The user completes the normal Codex login.
3. Session-scoped reconciliation detects the credential and joins that same
   agent.
4. The conversation projection removes the admission prompt and shows the
   joined member. No second Connect action is required.

## Cancellation and Timeout Races

Cancellation means aborting a still-pending login. Before destructive cleanup,
the operation acquires the same admission lock and performs a final credential
probe:

- `authenticated`: completion wins and the same agent joins the session;
- `missing` or `unknown`: cancellation records `connection_cancelled` and
  retires the provisional candidate;
- stale attempt: return the existing stale-attempt result without touching a
  newer candidate.

Timeout uses the same rule. At the deadline it probes under the admission lock
before expiring the row. This prevents a credential written just before the
deadline from being destroyed by a concurrent sweep.

## Conversation Experience

While an admission remains active, the conversation card shows:

- `Continue login`, which reopens the PTY of the admission's existing
  `provisional_agent_uri`;
- `Check connection status`, which requests immediate reconciliation for the
  current session; and
- `Cancel`, which follows the race-safe cancellation semantics above.

The client never calls `begin` merely to reopen an active candidate. `begin`
remains idempotent as defense in depth, but PTY recovery uses the existing
candidate URI directly. After completion, normal session state publication
causes the member to appear. If a live update is missed, rebuilding or refreshing
the conversation projection still reads the durable `joined` state.

## Error Handling

- Credential `missing` and `unknown` are non-destructive pending outcomes.
- A malformed or unrelated provisional URI fails closed and cannot expose a
  PTY or join an agent.
- A stale role declaration or attempt cannot mutate the current admission.
- Reconciliation failures are logged with session URI, role, and attempt ID;
  secrets and credential contents are never logged.
- A transient sweep failure leaves the durable active row available for the
  next reconciliation pass.
- Existing joined-agent credential revalidation remains unchanged.

## Testing and Acceptance

Regression coverage must prove:

1. reconciliation checks all active candidates in one requested session and no
   candidates in another session;
2. a credential changing from `missing` to `authenticated` automatically joins
   the original provisional agent;
3. `missing` and `unknown` preserve the attempt ID, provisional agent URI, PTY,
   and active state;
4. cancellation after authentication completes admission rather than retiring
   the candidate;
5. timeout after authentication completes admission rather than expiring the
   candidate;
6. cancellation and timeout still clean up candidates that remain unauthenticated;
7. repeated reconciliation, cancel, timeout, and completion races do not create
   a second agent or duplicate membership;
8. `Continue login` opens the existing candidate PTY without calling `begin`;
9. `Check connection status` reconciles only the current session; and
10. automatic completion updates the conversation projection so the joined
    member appears without a second Connect action.

Runtime acceptance uses a fresh Hello Codex session: connect once, complete the
login in PTY, return to the conversation, observe the same agent join, and
confirm that no additional login flow is shown.

## Relationship to Existing Designs

This design amends
`2026-08-03-pty-credential-admission-bootstrap-design.md`: PTY completion is no
longer exclusively an explicit user action, and active credential checks are
now introduced. It preserves the isolation invariants in
`2026-08-03-session-agent-credential-isolation-design.md` and the PTY view
projection rules in `2026-08-04-codex-admission-pty-view-design.md`.
