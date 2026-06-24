# Agent Config Frontend Contract Draft

> Date: 2026-06-24
> Branch: `feat/agent-config-backend`
> Audience: backend (@黄佳佳) + frontend (@戴明)
> Status: draft for immediate alignment. Backend implementation should follow this after confirmation.

## Scope

This contract covers the agent config editor backend used by the agent console.

It is runtime-agent config, not cold `AgentTemplate` authoring. It does not change `create_agent/3`, `AgentManifest`, caps, or UI routes.

First version supports:

- read full editable cascade;
- update a config body via patch;
- delete a field/path from a config body;
- repoint/rollback to an existing config object.
- check whether an agent is currently bound to any live session before deletion.

First version does not support:

- physical deletion of historical config objects;
- whole-key pointer clearing;
- treating `null`/`nil` as delete;
- editing create-form fields such as `name` or `cwd`.

## Backend Facade

Backend will expose a domain facade:

```elixir
Ezagent.AgentConfig.read_cascade(agent_uri, opts \\ [])
Ezagent.AgentConfig.apply_delta(agent_uri, caller, caps, attrs)
Ezagent.AgentConfig.delete_path(agent_uri, caller, caps, attrs)
Ezagent.AgentConfig.repoint(agent_uri, caller, caps, attrs)
```

All mutations dispatch to the target agent's existing `ConfigEvolve` actions and require the target agent manage-cap.

## Suggested World Dispatch Actions

If the frontend calls through `world:dispatch`, use these action names:

| UI action | world action | Backend facade |
|---|---|---|
| Read config editor state | `agents.config.read` | `Ezagent.AgentConfig.read_cascade/2` |
| Save patch | `agents.config.update` | `Ezagent.AgentConfig.apply_delta/4` |
| Delete field/path | `agents.config.delete_path` | `Ezagent.AgentConfig.delete_path/4` |
| Rollback/repoint | `agents.config.repoint` | `Ezagent.AgentConfig.repoint/4` |

The backend branch does not implement UI wiring, but these names are the proposed frontend/backend contract.

## Defaults

- `layer`: `"user"`
- `key`: `"advisor.behavior"`
- `turn_id`: optional from frontend. If omitted, backend generates `console:<uuid>`.

Supported layers:

```json
["workspace", "user", "session"]
```

First implementation should let the frontend edit the `user` layer. Other layers can be rendered read-only until the UI decides to expose them.

## Read Request

Action:

```json
{
  "action": "agents.config.read",
  "agent_uri": "entity://team_alpha/agent/demo"
}
```

Optional:

```json
{
  "action": "agents.config.read",
  "agent_uri": "entity://team_alpha/agent/demo",
  "keys": ["advisor.behavior"]
}
```

## What "Full Config" Means In V1

There is no fixed agent config schema registry on current `main`.

Config keys are dynamic: they exist when a `ConfigPointer` exists for the agent/layer/key tuple. The only built-in/default key in the current config-evolve path is:

```json
"advisor.behavior"
```

Therefore V1 defines "full config" as:

- every distinct config `key` currently present in `ConfigPointer` for this agent across supported layers;
- plus the default key `advisor.behavior`, even if no pointer exists yet.

The backend should expose this through one `read_cascade` call. Frontend should not need to call `list_keys` and then batch `resolve` per key.

If product later requires "full config" to mean a fixed, known schema of every possible agent setting, that is a separate schema/manifest design. It is not present in the current backend.

## Read Response

Success:

```json
{
  "ok": true,
  "agent_uri": "entity://team_alpha/agent/demo",
  "workspace_uri": "workspace://team_alpha",
  "default_key": "advisor.behavior",
  "layer_order": ["workspace", "user", "session"],
  "keys": [
    {
      "key": "advisor.behavior",
      "effective_body": {
        "tone": "decisive",
        "soul_md": "# Agent soul"
      },
      "editable": true,
      "editable_layer": "user",
      "layers": {
        "workspace": null,
        "user": {
          "layer": "user",
          "config_id": "8c70d2bf-6f12-44b5-a778-1e11a8ed5c1b",
          "previous_config_id": null,
          "object_uri": "resource://team_alpha/socialware-config-object/...",
          "body": {
            "tone": "decisive",
            "soul_md": "# Agent soul"
          },
          "source_turn_id": "console:...",
          "updated_at": "2026-06-24T12:00:00Z"
        },
        "session": null
      }
    }
  ]
}
```

Empty config still returns stable shape:

```json
{
  "ok": true,
  "agent_uri": "entity://team_alpha/agent/demo",
  "workspace_uri": "workspace://team_alpha",
  "default_key": "advisor.behavior",
  "layer_order": ["workspace", "user", "session"],
  "keys": [
    {
      "key": "advisor.behavior",
      "effective_body": {},
      "editable": true,
      "editable_layer": "user",
      "layers": {
        "workspace": null,
        "user": null,
        "session": null
      }
    }
  ]
}
```

## Update Request

Action:

```json
{
  "action": "agents.config.update",
  "agent_uri": "entity://team_alpha/agent/demo",
  "layer": "user",
  "key": "advisor.behavior",
  "patch": {
    "tone": "decisive"
  },
  "turn_id": "console:optional-client-generated-id"
}
```

Notes:

- `patch` is a map.
- First implementation uses shallow merge semantics, matching current `ConfigStore.merge_delta/5`.
- `null` is a value, not delete.
- To delete a field, call `agents.config.delete_path`.

## Delete Path Request

Action:

```json
{
  "action": "agents.config.delete_path",
  "agent_uri": "entity://team_alpha/agent/demo",
  "layer": "user",
  "key": "advisor.behavior",
  "path": ["tone"],
  "turn_id": "console:optional-client-generated-id"
}
```

Semantics:

- Deletes a field/path from the selected layer/key body.
- Produces a new immutable config object.
- Advances the pointer to the new object.
- Does not physically delete any historical object.

Example:

Before:

```json
{"tone": "decisive", "soul_md": "# Agent soul"}
```

Delete path:

```json
["tone"]
```

After:

```json
{"soul_md": "# Agent soul"}
```

## Repoint Request

Action:

```json
{
  "action": "agents.config.repoint",
  "agent_uri": "entity://team_alpha/agent/demo",
  "layer": "user",
  "key": "advisor.behavior",
  "config_id": "8c70d2bf-6f12-44b5-a778-1e11a8ed5c1b"
}
```

Semantics:

- Rolls the selected `{layer, key}` pointer to an existing config object.
- The target object must belong to the same agent/workspace/key.
- Requires the same manage-cap as update.

Frontend can defer this UI. Backend will test it as part of the contract.

## Delete Agent Live-Session Gate

Agent deletion must be blocked while the target agent is currently a member of any live session.

This check should live in the session domain, not in world UI code. The frontend/world layer should not scan `KindRegistry` directly.

Proposed backend helpers:

```elixir
EzagentDomainInstanceMessage.agent_live_sessions(agent_uri)
EzagentDomainInstanceMessage.agent_in_live_session?(agent_uri)
```

Suggested return shapes:

```elixir
{:ok, [%URI{}, ...]}
```

or:

```elixir
{:ok, %{bound?: true, sessions: ["session://team_alpha/chat/main"]}}
```

Existing building blocks are:

- `EzagentDomainInstanceMessage.list_sessions/0`
- `EzagentDomainInstanceMessage.list_sessions/1`
- `Ezagent.Entity.Session.session_member_uris/1`

The new helper centralizes the definition of "live session membership" in the session domain. The world delete path should call this helper and block deletion when the result is non-empty.

## Mutation Response

Success:

```json
{
  "ok": true,
  "agent_uri": "entity://team_alpha/agent/demo",
  "layer": "user",
  "key": "advisor.behavior",
  "config_id": "new-config-id",
  "previous_config_id": "old-config-id",
  "cascade": {
    "...": "same shape as read response, optional"
  }
}
```

Preferred frontend flow:

1. submit mutation;
2. backend returns `config_id` and `previous_config_id`;
3. frontend calls `agents.config.read` again to refresh.

Returning full `cascade` in mutation response is optional. If frontend wants fewer round trips, backend can include it.

## Error Response

All errors should be returned as JSON-friendly reason codes:

```json
{
  "ok": false,
  "error": "unauthorized",
  "message": "missing manage-cap for this agent",
  "details": {}
}
```

Initial error codes:

| Code | Meaning |
|---|---|
| `unauthorized` | Caller lacks target agent manage-cap. |
| `agent_not_found` | Target agent URI does not resolve to a running/known agent. |
| `invalid_agent_uri` | Malformed or non-agent URI. |
| `invalid_layer` | Layer is not `workspace`, `user`, or `session`. |
| `invalid_key` | Key is missing, blank, or not a string. |
| `invalid_patch` | Patch is missing or not a map. |
| `invalid_path` | Delete path is missing or invalid. |
| `config_not_found` | Repoint target object does not exist. |
| `cross_tenant_target` | Repoint target object does not belong to this agent/workspace/key. |
| `subject_not_self` | Request attempted to mutate a different subject than the target agent. |

## Frontend Questions To Confirm

1. Is the V1 definition of "full config" acceptable: all existing pointer keys plus default `advisor.behavior`, with no fixed schema registry yet?
2. Will the editor be full JSON editing, key/value editing, or path-based field editing?
3. Is field/path delete enough for v1, with whole-key delete deferred?
4. After mutation, should backend include refreshed cascade, or should frontend call read again?
5. Are reason codes enough for the UI, or does frontend need localized/user-facing messages from backend?
6. For delete-agent blocking, is `agent_live_sessions/1` returning the session URI list enough for the UI copy?

## Backend Implementation Notes

- Do not mutate config rows directly from world code.
- Do not use `%{"field" => nil}` as delete.
- Keep `ConfigObject` append-only.
- Keep all writes manage-cap gated.
- Keep `ConfigEvolveTest` for behavior internals; add `AgentConfigTest` for this facade contract.
