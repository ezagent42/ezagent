# Template Member Roster Convergence Design

## Goal

Make template-role materialization report success only after every declared
role is present in the session roster, even when its LLM transport is
credentialless, logged out, or otherwise unavailable. A transport failure must
never delay the agent Kind's membership identity; a materialization failure must
leave no newly created worker, capability binding, lineage, workspace binding,
or configuration directory behind.

## Decision

The agent Kind's lifecycle readiness and the LLM transport's availability are
separate states. `ReadyGate` means that the Kind can receive its normal
identity and membership work; it does not mean that a bridge/PTY has an active
provider login. CC and custom-backend templates must therefore make the agent
Kind ready after its durable state and identity behavior are initialized, then
continue bridge login/startup asynchronously. The bridge exposes its own
transport status and generation continues to fail with the flavor's existing
structured credential or transport error until configured.

The existing holder-driven member-cap model remains authoritative:

1. `session.join` issues the tier-1 member cap and records the role facet as
   join intent.
2. The ready agent absorbs that cap and the existing `MembershipConvergence`
   dispatch performs holder-authenticated `session.add_self`.
3. `DefinitionAgents` treats the join acknowledgement as provisional. It waits
   for `SessionBehavior.role_name_to_uri/2` to resolve the role to the planned
   URI before adding the role to `satisfied`.

This preserves cap-as-truth: the Session does not directly write a roster
entry before the member actually holds the tier-1 cap.

## Failure Handling and Compensation

Role materialization has one commit point: roster convergence for its planned
URI. A timeout, `add_self` authorization failure, binding failure, or join
failure is a materialization error, not a successful-but-invisible member.

For a fresh worker, compensation uses a readiness-independent lifecycle
rollback rather than `sandbox.destroy` over the normal dispatch path. The
rollback must:

- terminate the Kind with a result checked by the caller;
- remove the workspace binding and agent lineage created for this spawn;
- delete the template class's config directory via its existing cleanup hook;
- tombstone or remove the recipe-cap binding created for this attempt; and
- surface an error if any required cleanup cannot be confirmed.

An existing/reused worker is never terminated by this compensation path. Its
pre-existing binding and lifecycle remain intact.

## Scope Boundaries

`credential_optional` and `session_template_member` remain scoped to fresh
`DefinitionAgents` role materialization. Explicit agent creation, unknown
providers, malformed templates, ordinary custom-agent startup, and all
non-credential spawn failures remain fail-closed. A keyless custom backend
gets an agent member and a reachable PTY/configuration surface, but it does
not get a provider token or permission to generate.

No direct Session roster write, no capability bypass, and no `PubSub` side
channel is introduced. Member projection continues through the existing
holder-authenticated `session.add_self` action.

## Tests

The invariant test uses a real template class whose bridge intentionally stays
transport-unavailable after the Kind becomes ready. Materialization must return
`{:ok, %{satisfied: [role], skipped: []}}` and
`role_name_to_uri(members, role)` must equal the planned URI without any
provider key.

Compensation tests inject failures after fresh spawn at each boundary (recipe
cap bind, join, and roster-convergence wait). They assert that the worker is
not alive, no active recipe-cap binding or lineage remains, and its config
directory is gone. A parallel reuse test asserts that the pre-existing agent
survives a failed refresh/join.

CC custom and headless tests retain strict unflagged missing-key assertions,
verify the scoped keyless environment omits `ANTHROPIC_AUTH_TOKEN`, and add a
cold-restart test proving `session_template_member` remains in respawn data.
