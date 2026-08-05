# Task 2 report — Publish PTY view and activation atomically

## RED → GREEN

- RED: extended `PR-4: switching to a member PTY records the active agent` to
  require the pushed `world:state` to include an enumerated `pty` view. The
  focused test failed as expected because the successful PTY payload had no
  `"views"` key.
- GREEN: `switch_to_pty/3` now passes `session_uri` to `push_pty_view/3`, which
  rebuilds `ConversationData.session_views(session_uri, caller)` with the
  socket's current entity before publishing the complete PTY state.

## Changes

- Added LiveView payload regression coverage for the caller-scoped PTY view.
- Kept PTY read authorization and membership checks unchanged; the new view
  list reuses the existing caller-authorized registry projection.
- Added the React contract test proving that an enumerated active PTY selects
  `PtyTerminalSurface`.

## Verification

- `mix test apps/ezagent_web/test/ezagent_web/world_conversation_test.exs:827` — RED, then GREEN (1 test, 0 failures)
- `mix test apps/ezagent_plugin_world/test/ezagent/world/pty_read_exits_test.exs` — 7 tests, 0 failures
- `mix test apps/ezagent_plugin_world/test/ezagent/world/view_cap_gate_regression_test.exs` — 6 tests, 0 failures
- `mise exec node@22.13.0 -- pnpm --dir apps/ezagent_plugin_world/assets test -- Conversation.test.tsx` — 10 files / 46 tests, 0 failures
- `mise exec node@22.13.0 -- pnpm --dir apps/ezagent_plugin_world/assets typecheck` — passed
- `mix format --check-formatted` for both touched Elixir files — passed
- `git diff --check` — passed

The default Node 20.19.4 could not start pnpm 11 (`node:sqlite` unavailable).
The repository declares Node 22.13.0, so verification used that existing mise
toolchain. The focused LiveView test emits an existing Phoenix warning about
`start_async` copying the socket; on one post-commit run its test cleanup also
printed non-failing DB ownership/snapshot-write logs. The test itself completed
with 0 failures, and this task does not touch those paths.

## Self-review / concerns

- The production delta is limited to the requested three files and preserves
  the existing view-cap gate by calling `ConversationData.session_views/2`.
- No `mix precommit` was run, per task instruction.
- Commit: `b8c3ee85f fix(world): enter Codex admission terminal`.

## Follow-up: workspace-locality gate fixup

- RED: with the original `socket.assigns.current_entity_uri` expression, the
  focused locality gate exited 2: worklist (A) reported
  `:unknown_value.current_entity_uri/0` in `push_pty_view/3`, and census (B)
  also changed.
- GREEN: `push_pty_view/3` now destructures
  `%{assigns: %{current_entity_uri: caller}}` in its function head. This keeps
  the same caller-scoped view projection while providing the static scanner a
  data-shaped receiver; no baseline, allowlist, or dynamic apply changed.
- `mix test apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs --trace` — exit 0; 3 tests, 0 failures.
- Re-ran Task 2 focused checks: LiveView (1), PTY read exits (7), view cap-gate
  (6), React contract (46), and TypeScript typecheck all exited 0.
- The Elixir test environment continues to print unrelated delivery/DB
  ownership cleanup logs, but the listed commands exited 0 after the fix.
- Fixup commit: `96f21a5cc fixup! fix(world): enter Codex admission terminal`.
