# Hello: reuse a user-owned LLM agent and route through Session ingress

## Status

Proposed and approved for planning. This document describes the target behavior;
it does not authorize a compatibility bypass for arbitrary agent recipes.

## Problem

Creating a `session.hello` currently materializes both `front-desk` and `llm`
agents. The former is a deterministic chat-to-Session-action relay, while the
latter may be created without the creating user's already authenticated agent.
This produces avoidable agent identities and can require a new login.

## Decisions

1. A Hello **template** describes the team shape only. It must not persist a
   user agent URI or credentials.
2. A Hello **session creation** selects the LLM agent. The form supports every
   LLM flavor supported by Hello, then lists only agents that the current user
   can manage, are ready/authenticated, use the selected flavor, and have the
   `hello.llm` recipe. `codex` is one example, not a special case.
3. The selected agent is frozen into that session's `hello` install config as
   the `llm` role choice:

   ```elixir
   %{role_name: "llm", install_mode: :reuse, reuse_agent_uri: agent_uri, flavor: selected_flavor}
   ```

   It is joined as a session member; it is never recreated, re-authenticated,
   or retired by that session.
4. `front-desk` is removed as a Hello role and is not materialized. Its
   deterministic routing and controlled outbound-message responsibilities move
   to the Hello Session.

## Architecture

### Generic Session ingress

The domain-session layer gains a generic, declarative Session-ingress delivery
mechanism. A socialware definition may name a registered Session action as an
inbound message handler. The generic mechanism resolves and invokes that
action, but contains no Hello-specific branch.

Hello declares its ingress handler in its socialware definition. The Hello
plugin action invokes the existing intent and ownership routing logic, then
dispatches `rebuild`, `answer`, `share`, `publish`, or `delegate_to_kanban` on
the Session. This replaces the current route-to-agent-then-AgentBridge path.

Session-originated output replaces every use of `front-desk` as an actor for
generated-page narration, concierge replies, and sharing. Sender identity must
remain session-scoped and auditable; no synthetic agent identity is introduced.

### Domain boundary cleanup

The existing role-slot override and reuse machinery is already generic and
remains in the domain. This change must not add `hello` conditions to it.

The following existing production special cases are removed or generalized:

- the domain-agent `"hello" -> :hello_sync_result` AgentBridge return-action
  mapping, which exists only for the retiring front-desk agent;
- the domain-agent-bridge `hello_completion_request_id` payload key, which
  becomes a generic completion request identifier.

`Ezagent.Socialware.Demo.Hello` is test-fixture support for loading the shipped
manifest, not a production Hello behavior. It may be relocated later, but is
not part of the runtime ingress/reuse design.

### Reuse safety

The candidate list is a convenience only. The creation command independently
revalidates the selected URI immediately before install:

- the URI is an agent the caller manages in the selected workspace;
- the live/durable agent reports the selected flavor and a ready credential
  status;
- its durable recipe is exactly `hello.llm`.

The established reuse path remains responsible for joining and binding the
already compatible recipe. A flavor match by itself is insufficient: flavor
answers how an agent executes; recipe defines its role, sandbox configuration,
skills, and authorization contract.

## Errors and lifecycle

- No candidate: disable submission and explain that the user must create or
  authenticate a compatible `hello.llm` agent.
- Invalid, stale, unauthorized, unready, or incompatible selection at submit:
  reject creation with a typed, user-visible error. Never fall back to a fresh
  credentialless LLM agent.
- Removing or deleting the Hello session removes only the membership edge. The
  reused agent, its credentials, and its original ownership remain intact.
- Existing sessions retain their materialized `front-desk` members. Migration,
  if needed, is an explicit follow-up and must preserve message routing while
  the session is upgraded.

## Verification

Tests must prove:

1. the selector supports every Hello LLM flavor and returns only caller-managed, ready agents with matching flavor
   and `hello.llm` recipe;
2. a selected `codex` agent is reused as `llm`, while no new LLM agent is
   spawned;
3. a missing or invalid selection fails visibly and does not fall back;
4. a newly created Hello session has no `front-desk` member, yet a user message
   reaches the declared Session ingress and performs the same guarded action;
5. Session deletion or member removal leaves the reused agent alive and keeps
   its ownership and credentials unchanged;
6. authorization and anti-loop behavior remain fail-closed.
