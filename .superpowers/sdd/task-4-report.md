# Task 4 Report: `agents.delete` dispatch + bound-session gate

## Status

GREEN — all tests pass. Implementation complete.

## Summary

Added the `agents.delete` dispatch path to the world plugin's LiveView:
- `handle_event` clause routing `"agents.delete"` to `dispatch_agent_delete/2`
- `dispatch_agent_delete/2`: parse URI → check bound-session gate → dispatch
  `manage.delete` via `Invocation.dispatch/1` → navigate or surface error
- `push_agent_action_error/2`: no-silent-drop error surface via `world:state` push
  (mirrors `push_agent_create_error/2` exactly)
- `action_error_message/1`: operator-facing Chinese strings for all observed error atoms
- Test file: 3 integration cases asserting backend state

---

## Cap-denial reason shape — OBSERVED runtime value

The brief guessed `:cap_denied`. The actual runtime errors are:

- **`:cross_workspace_denied`** — when caller (e.g. `entity://system/user/admin`,
  workspace `system`) dispatches to an agent in a **different workspace** (e.g.
  `workspace://delete-dispatch-N`) with empty caps. The workspace isolation check fires
  **before** the cap check and returns `{:error, :cross_workspace_denied}`.

- **`:unauthorized`** — when caller and target share the same workspace but caller
  lacks the manage-cap.

Both are mapped in `action_error_message/1`:

```elixir
defp action_error_message(:unauthorized), do: "没有删除权限（需要 manage 权限）"
defp action_error_message(:cross_workspace_denied), do: "跨工作区操作被拒绝"
```

The test's cap-denial case asserts `actual_reason in [:unauthorized, :cross_workspace_denied]`
and that the agent is still alive — the key invariant is no silent destroy.

---

## Deviation from brief: dispatch return value

The brief's code pattern matched `{:ok, %{deleted: true}}`. The actual runtime return
differs.

`Manage.handle_delete/2` returns `{:ok, {:ok, :deleted}, [effect]}`. Kind runtime
extracts `result = {:ok, :deleted}` and Kind.Server replies
`{:reply, {:ok, {:ok, :deleted}}, state}`. The dispatch caller receives
`{:ok, {:ok, :deleted}}`.

Implementation uses the correct pattern (real file wins over brief):

```elixir
{:ok, {:ok, :deleted}} <-
  Invocation.dispatch(%Invocation{...})
```

---

## Async destroy timing

`Manage.schedule_delete/1` spawns a detached Task with `Process.sleep(20)` before
calling `Lifecycle.destroy/2`. The happy-path test polls with a `wait_until/2` helper
(100 × 20ms ≈ 2s max) rather than asserting immediate termination.

---

## Files changed

- `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex`
- `apps/ezagent_plugin_world/test/ezagent/world/agent_delete_dispatch_test.exs` (new)

---

## Test results

```
3 tests, 0 failures  (agent_delete_dispatch_test.exs)
37 tests, 0 failures (full ezagent_plugin_world suite)
237 tests, 0 failures (umbrella)
32 tests, 0 failures  (CLI)
```

---

## Blocking concerns

None. All invariants respected: P14 (dispatch only path), Invariant #9 (no silent drops),
`action_error_message/1` maps observed runtime atoms not fabricated ones.
