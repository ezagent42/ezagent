# Session Agent Credential Isolation

**Date:** 2026-08-03

**Status:** approved

## Goal

Every credential-requiring agent materialized for a newly created Session must
use a fresh, session-local agent and complete a fresh credential connection for
that Session. Credentials configured for an earlier Session must never suppress
the new Session's connection prompt or flow into its agent.

This rule applies to every socialware Session role whose registered flavor
declares a credential connection, including PTY login and API-key connections.
It is not specific to Hello or Curl.

## Invariants

1. Each Session role is materialized at a fresh agent URI. An agent that belongs
   to one Session is never joined to another Session.
2. A credential-requiring Session role always starts in durable
   `pending_auth`, even when a user-default or workspace-shared credential
   source exists.
3. Starting admission creates one provisional agent for that attempt. Refreshing
   or reopening the same Session is idempotent and does not create another
   provisional agent.
4. Credentials are configured only on the provisional agent. Successful
   validation joins that same agent to the current Session.
5. Successful Session admission does not create, replace, or otherwise mutate a
   user-default or workspace-shared credential source.
6. Cancelled, failed, or expired admission retires the provisional agent. A
   retry creates a fresh provisional agent and requires fresh authentication.
7. Existing credential-source pointers may continue to serve explicit,
   non-Session agent workflows, but Session role materialization ignores them.
8. Existing joined Session agents are not evicted or forced to authenticate
   again. The rule applies when a new Session role is materialized and when an
   unfilled role is retried.

## Design

The Session domain owns the enforcement boundary. It derives whether a role
requires authentication from the flavor's `CredentialConnection` descriptor,
not from an optional template hint alone. A role with a PTY or API-key
descriptor is always routed through `AgentAdmission`; `:immediate` cannot bypass
the policy for a credential-requiring flavor. A flavor declaring
`:not_required` retains immediate materialization.

The initial materialization path does not consult `UserDefaultSource`,
`WorkspaceSharedSource`, host-login adoption, or the credential cascade for a
credential-requiring Session role. It records `pending_auth` directly. The
admission flow then creates a fresh provisional agent with no membership edge,
exposes the flavor-owned connection surface, validates that provisional
agent's credential status, and joins it only after successful validation.

Admission completion stops after binding the recipe/capabilities and joining
the provisional agent. The current default-source transaction is removed from
this path, including its rollback/reapply machinery, because a Session-owned
credential must not become input to a later Session.

## Failure and recovery

- Unsupported or malformed credential descriptors fail closed and leave the
  role unfilled with a retryable error; they do not fall back to credential
  reuse.
- Authentication failure keeps the role absent and presents the existing retry
  path.
- Cancellation and timeout clean up the provisional agent without changing any
  pre-existing default credential pointer.
- An obligation retry for an unfilled credential-requiring role recreates or
  preserves `pending_auth`; it never retries an unauthorized old source.

## Verification

Regression coverage must prove:

- an existing user-default source does not bypass `pending_auth`;
- an existing workspace-shared source does not bypass `pending_auth`;
- two Sessions produce different agent URIs and two independent authentication
  attempts;
- successful admission does not create or change a default-source pointer;
- reopening one Session does not duplicate its active attempt;
- cancel, failure, timeout, and retry preserve cleanup and isolation;
- credential-free roles still materialize immediately;
- PTY and API-key descriptors follow the same isolation policy.
