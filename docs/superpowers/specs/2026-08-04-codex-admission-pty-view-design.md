# Codex Admission PTY View Design

**Date:** 2026-08-04

**Status:** approved

## Problem

Clicking `Connect Codex` successfully starts a provisional Codex agent and its
PTY, but World remains on the conversation view and exposes no Terminal entry.

The server pushes `active_view: "pty"`, while the caller-authorized `views`
projection still excludes `pty`. The React conversation renderer accepts an
active view only when its id is present in `views`, so it immediately falls back
to the first available view. The Terminal SessionView currently considers only
joined session members; an authenticating provisional agent is deliberately not
a member yet, so recomputing the existing projection alone cannot expose it.

## Goal

When a session owner starts a PTY-backed credential admission:

1. the provisional agent and PTY are created through the existing admission
   path;
2. World immediately switches to that agent's terminal;
3. Terminal remains an enumerated session view while the current admission
   candidate has a live PTY; and
4. cancellation, failure, timeout, or successful completion returns view
   availability to the normal session-member-derived state.

No new terminal route, duplicate terminal component, or client-side permission
bypass is introduced.

## Options Considered

### 1. Extend the SessionView projection and refresh it atomically (selected)

Teach the shared Terminal SessionView that a session has a terminal when either
a joined member or the current authenticating/materializing admission candidate
owns a live PTY. When World opens that PTY, include a freshly computed `views`
projection in the same `world:state` update as `active_view` and the terminal
agent URI.

This keeps `SessionViewRegistry` as the source of truth, preserves the existing
React allowlist, and makes refreshes and direct transitions agree.

### 2. Let React render `pty` even when it is absent from `views`

Rejected because it makes the client override the server's caller-scoped view
projection and weakens the view authorization contract.

### 3. Add a standalone global Terminal link

Rejected because it duplicates navigation without fixing the broken admission
transition and asks the user to locate a provisional URI manually.

## Architecture and Data Flow

The existing flow remains authoritative:

`session.agent_admission.begin`
→ `AgentAdmission.begin/4`
→ provisional agent spawn
→ flavor-owned PTY start
→ `ConversationActions.switch_to_pty/3`.

Two projection changes complete that flow:

1. `EzagentDomainUi.Pty.TerminalView.applies_to?/1` checks both joined session
   members and current admission candidates in active statuses. Only candidates
   with a valid URI and a live `Ezagent.Domain.Pty` server qualify.
2. `ConversationActions.push_pty_view` recomputes
   `ConversationData.session_views/2` for the current caller after the PTY is
   known live, and pushes those views together with `active_view: "pty"`,
   `active_pty_agent_uri`, liveness, phase, and initial buffer.

React remains unchanged: it continues to render only server-enumerated views.
The existing PTY read gate and session-related-target validation remain before
subscription and state publication.

## Failure and Recovery

- If provisional agent or PTY creation fails, admission retains its existing
  failure state and World does not enumerate Terminal.
- Invalid or unrelated candidate URIs remain rejected by the existing
  `session_pty_target_unrelated` path.
- A candidate whose PTY has stopped does not make Terminal applicable.
- Cancellation and timeout retire the provisional agent; the next state rebuild
  naturally removes Terminal unless another joined PTY-backed member exists.
- Successful admission joins the same agent, so Terminal remains available via
  the ordinary joined-member path.

## Testing and Acceptance

Regression tests must prove:

1. a live PTY belonging to an active provisional admission makes the Terminal
   SessionView applicable before the agent joins;
2. inactive, malformed, or stopped candidates do not expose Terminal;
3. the World PTY transition publishes a `views` projection containing `pty` in
   the same update as `active_view: "pty"`; and
4. the React renderer enters the PTY surface when that atomic state arrives.

Verification will run the focused Domain UI, World Elixir, and World asset
tests, followed by `mix precommit`. Runtime acceptance uses a real
`hello-codex` admission to confirm the provisional agent and PTY are alive, the
server projection contains `pty`, and the browser exposes and enters Terminal.
