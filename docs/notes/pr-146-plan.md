# PR #146 — Query-string action syntax (`/behavior/X/Y` → `?action=X.Y`)

Per SPEC v2 §5.2 — actions move from path suffix to query string. **LARGEST CODE CHANGE of the SPEC v2 migration**.

## Scope

~43 source/test files reference `/behavior/`. Plus implicit references in:
- `Ezagent.URI.behavior_action/1` (parser)
- `Ezagent.Invocation.dispatch/1` (consumer)
- Every test fixture that builds `target: URI.parse("...")` with `/behavior/...` paths
- Every docstring example
- Audit log writes (target stored as string)
- Routing rule receivers (when they include action targets — most are just instance URIs)

## Mapping

| Old | New |
|---|---|
| `entity://user/X/behavior/identity/check` | `entity://user/X?action=identity.check` |
| `entity://agent/cc_X/behavior/chat/receive` | `entity://agent/cc_X?action=chat.receive` |
| `session://main/behavior/chat/send` | `session://main?action=chat.send` |
| `workspace://default/X/behavior/workspace/instantiate` | `workspace://default/X?action=workspace.instantiate` |

## Parser update

`Ezagent.URI.behavior_action/1` already parses query string in the path. Update to read from `URI.query` field instead:

```elixir
def behavior_action(%URI{query: query}) when is_binary(query) do
  decoded = URI.decode_query(query)
  case Map.get(decoded, "action") do
    "" -> {:error, :missing_action}
    nil -> {:error, :missing_action}
    action_str ->
      case String.split(action_str, ".", parts: 2) do
        [behavior, action] -> {:ok, {String.to_atom(behavior), String.to_atom(action)}}
        _ -> {:error, :malformed_action}
      end
  end
end
def behavior_action(_), do: {:error, :missing_action}
```

`Ezagent.URI.instance/1` no longer needs the special 2-segment split logic for actions — actions are in query, path is identity. Simplifies to:

```elixir
def instance(%URI{} = uri), do: %URI{uri | query: nil, fragment: nil}
```

But still need to handle the type/name split for ENTITY shape (instance is host + path[0], where path[0] is the name). Actually under SPEC v2 §5.1 instance = `<scheme>://<type>/<name>` (2-segment always). The split happens inside Behavior dispatch, not in URI parser. So instance/1 just strips query+fragment.

## Migration strategy

This is mostly mechanical text-replace + tests. The biggest source of subtle bugs is fixtures that construct URIs by string concatenation. Sweep:

1. Grep all `URI.parse("...behavior/...")` → rewrite to `?action=...`
2. Grep all `URI.new!("...behavior/...")` → same
3. Grep all `"#{...}/behavior/#{...}"` interpolated strings → rewrite
4. Update routing rule receivers (most are instance URIs without /behavior/; few exceptions)
5. Update audit-log assertions in tests

## Files touched (estimate from grep)

~43 source/test files. Many are docstring examples (low risk). The structural touches are:

- `apps/ezagent_core/lib/ezagent/uri.ex` — parser
- `apps/ezagent_core/lib/ezagent/invocation.ex` — dispatch (verify it reads behavior_action correctly under new shape)
- `apps/ezagent_core/lib/ezagent/kind/runtime.ex` — runtime dispatch examples
- `apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex` — chat dispatch targets
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex` — Echo button target, manual dispatch placeholder
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin/debug_panel.ex` — manual dispatch placeholder
- Plus ~37 other files (mostly tests + docstrings)

## Audit log impact

The audit log stores target URIs as strings. After PR #146, NEW writes use query-string format. EXISTING rows (from before) have path-style format. Since this is wipe-rebuild (§5.11), no migration needed — drop the invocations table on db.reset.

## Verification

- All 12 app tests pass
- Echo button → dispatch goes through; audit row shows `entity://agent/echo_default?action=echo.say`
- Chat send → dispatch goes through; audit row shows `session://X/main?action=chat.send`
- LV admin manual-dispatch form accepts new shape (update placeholder text)

## Scope

DO: Path → query string for actions across all 43 files + parser update.
DO NOT: Touch AgentTypeRegistry removal (#147). Don't rename Message.uri (#147).

## Estimated effort

LARGE — ~6-8 hours for a subagent + ~1-2 hours for verification. May need to split into sub-batches by file group.
