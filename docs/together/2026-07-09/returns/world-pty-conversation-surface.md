# Return — world PTY conversation surface

> **Task:** world-pty-conversation-surface
> **Branch:** `fix/world-template-ux-1270-1273`
> **PR:** #1276
> **Dev:** claude
> **returned_at:** 2026-07-09 17:21 +0800
> **deadline:** 2026-07-09 23:59 +0800
> **deadline_status:** out_of_scope

## What is done

- `Conversation` now renders the PTY terminal surface inline when the active view is `pty`, and the PTY tab/button paths jump into the live terminal instead of dropping back to the generic view switch.
- Session member data now carries `pty_alive` so the UI can surface PTY-capable agents directly in the conversation panel.
- The world event handler now resolves PTY input against both the dedicated PTY terminal component and the conversation surface's active PTY agent URI.
- The world slot mount gate now explicitly allows `Conversation.tsx` to own `PtyTerminalSurface` as a marked subcomponent.

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | PTY terminal is reachable from the conversation surface and agent rows expose PTY entry points | met | [Conversation.tsx](/home/lenovo/workspace/ezagent/apps/ezagent_plugin_world/assets/src/components/Conversation.tsx:758) + [conversation_data.ex](/home/lenovo/workspace/ezagent/apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex:186) |
| 2 | PTY input dispatch works from both the dedicated PTY view and the conversation inline view | met | [world_live.ex](/home/lenovo/workspace/ezagent/apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex:273) |
| 3 | renderer-gate / mount rules remain green after the new PTY subcomponent path | met | [slot_mount_gate_test.exs](/home/lenovo/workspace/ezagent/apps/ezagent_plugin_world/test/ezagent/world/slot_mount_gate_test.exs:20); `POSTGRES_PORT=5432 mix test apps/ezagent_plugin_world/test/ezagent/world/slot_mount_gate_test.exs` |
| 4 | frontend bundle still builds | met | `npm --prefix apps/ezagent_plugin_world/assets run build` |

**Method friction:** the existing renderer gate treats a direct import of `PtyTerminalSurface` inside `Conversation.tsx` as a bypass, so the implementation had to be made explicit with a subcomponent marker and allowlist entry. That constraint was not obvious from the UI requirement alone.

## Merge request

This change is stacked on the same PR #1276 and the same branch `fix/world-template-ux-1270-1273`. It is independent of the earlier session-create return and was committed as `e085237f`.
