# Ghost session route handoff

- **Task:** `ghost-session-route`
- **Branch:** `codex/ghost-session-route`
- **Base:** `main` at `90de06be8` (`ci(socialware): require manifest release acknowledgement (#1642)`)
- **Status:** implementation complete; caller-visible route and switch guards added with regression tests (local Mix validation blocked by missing worktree dependencies)
- **Observed URL:** `/sessions?session=session%3A%2F%2Fsystem%2Fdefault%2Fdefault-3`

## Finding

`default-3` is not being created by URL navigation. It is a syntactically valid
session URI, and the world URL router deliberately parses it without querying
the registry or authorizing the caller:

- `Ezagent.World.Routes.route_for/2` turns every valid `session://...` query
  value into `%{component: "conversation", session_uri: uri}`.
- `WorldLive` then renders that conversation route, subscribes to its topic and
  attempts `self_join`.
- `ConversationData.state_for/2` reads through the caller-authorizing
  `Ezagent.Socialware.SessionReads` chokepoint. A nonexistent session has no
  live `:session` slice, so `Membership.authorize/4` fails closed.

The resulting state has `access_denied: true`, empty messages, empty members,
and no privileged session data. This is covered by
`malformed_session_input_test.exs`. It is therefore a **ghost UI shell / UX
problem**, not proof that a new session exists or that conversation content is
disclosed.

The React `Conversation` component does not consume `access_denied`; it still
renders its normal conversation shell, deriving a display title from the forged
URI. That makes the denied state look like a real `default-3` session.

## Required behaviour

A forged, malformed, nonexistent, cross-workspace, or non-visible session
deep-link must produce the same outcome: return the caller to `/sessions` and
show only the caller-visible session rail. Do not distinguish "does not exist"
from "exists but is private"; distinguishing them would create an existence
oracle.

## Recommended implementation

Keep `Ezagent.World.Routes.route_for/2` pure; it should only parse URL syntax.
Put the visibility check at the World conversation boundary instead:

1. Add a small helper in `Ezagent.World.ConversationSessionState` that accepts
   `(workspace_uri, caller_uri, session_uri)` and checks membership in the
   existing caller-authorized `list_sessions/2` result.
2. Use that helper before `WorldLive` calls `maybe_set_current_session/2`, so
   an invalid deep-link never subscribes, calls `self_join`, or produces a
   conversation state.
3. On failure, `push_patch` to `/sessions` (or replace the route with the
   sessions-table route) with no reason-specific flash.
4. Use the same helper in the forged-client `session.switch` path. That event
   currently accepts any syntactically valid `session://` URI before calling
   `ConversationSessionState.switch_session/2`.
5. Retain `SessionReads` and its `access_denied` state as the read-plane
   defence-in-depth boundary. Do not turn a missing session into a permissive
   empty session, and do not move authorization into the pure route parser.

## Tests to add

- A WorldLive route test for a valid but nonexistent
  `session://system/default/default-3` deep-link. Assert navigation resolves
  to `/sessions`, no conversation topic is subscribed, and the pushed state is
  `sessions_table` rather than `conversation`.
- The same test shape for a real session outside the caller's visible session
  list; assert the identical `/sessions` outcome (no existence oracle).
- A `world:dispatch` `session.switch` test with a syntactically valid but
  non-visible URI; assert it cannot change `current_session_uri` or push a
  conversation state.
- Preserve the existing `ConversationData` denial tests. They prove that a
  race or another caller bypassing the route guard still receives no content.

## Verification

Run the focused world tests first, then `mix precommit`:

```bash
mix test apps/ezagent_plugin_world/test/ezagent/world/malformed_session_input_test.exs
mix test apps/ezagent_plugin_world/test/ezagent/world/conversation_data_visibility_test.exs
mix test apps/ezagent_plugin_world/test/ezagent/world/conversation_actions_test.exs
mix precommit
```

Manual acceptance: while authenticated, edit a session URL to a made-up but
valid URI. The app must land on `/sessions`; it must not render a conversation
header or shell named after the made-up URI.
