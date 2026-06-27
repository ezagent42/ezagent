# Agent Config Backend Contract Plan

> Date: 2026-06-24
> Branch: `feat/agent-config-backend`
> Scope: task 2 only. Backend/domain contract for agent config cascade CRUD. No UI work.

## Goal

Build the backend contract that the agent console can call to inspect and mutate a runtime agent's config cascade.

This work should expose the real domain behavior already present in `ConfigEvolve` and `ConfigStore`, while filling the missing console-facing API shape and delete semantics. Mutations must continue to go through cap-checked dispatch to the target agent. Do not add a parallel config store, direct GenServer poke, or raw DB write path for production mutations.

## Current State

The existing config backend is versioned and pointer-based:

- `Ezagent.Socialware.ConfigObject`
  - Immutable append-only config object.
  - Stores `workspace_uri`, `subject_uri`, `key`, `body`, `created_by`, `source_turn_id`.
  - Historical objects are intentionally retained forever for rollback, replay, and idempotency.

- `Ezagent.Socialware.ConfigPointer`
  - Mutable pointer keyed by `{layer, workspace_uri, subject_uri, key}`.
  - Supported layers: `workspace`, `user`, `session`.
  - Points at the current immutable `ConfigObject`.
  - Stores `previous_config_id` as rollback ledger.

- `Ezagent.Behavior.ConfigEvolve`
  - Agent-owned behavior.
  - `apply_config_delta` writes a new object and advances the pointer.
  - `repoint_config` advances the pointer to an existing in-scope object.
  - Both require the target agent's manage-cap.
  - Defaults to user layer and key `agent.soul`.
  - Binds `subject_uri` and `workspace_uri` to the receiving agent to prevent cross-agent confused-deputy writes.

- `Ezagent.Socialware.ConfigProjection`
  - Materializes a config object URI into a transient config dir.
  - Current projection is soul-scoped:
    - `body["soul_md"]` is emitted verbatim as `CLAUDE.md`.
    - Otherwise the body is rendered as sorted key/value lines in `CLAUDE.md`.

## Key Finding: Delete

There are two different delete concerns:

1. Historical object deletion
   - This is intentionally unsupported.
   - `ConfigObject` is append-only by design.
   - Physical deletion would break rollback, replay, object-existence idempotency, and auditability.

2. Config field/key deletion
   - This is not currently implemented.
   - `ConfigStore.merge_delta/5` currently uses `Map.merge(base, patch)`.
   - Passing `%{"field" => nil}` only stores `nil`; it does not remove the field.
   - Treating `nil` as delete would be an implicit fake delete and should not be used as the console contract.

Therefore task 2 should add explicit delete semantics as a versioned mutation: read current body, remove the requested field/path, write a new immutable object, and repoint the pointer to it through the same manage-cap-gated action path.

## Proposed Public Contract

Add a small backend facade in identity domain:

`apps/ezagent_domain_identity/lib/ezagent/agent_config.ex`

The facade should be JSON-friendly for the world/console caller, but keep domain return tuples:

```elixir
Ezagent.AgentConfig.read_cascade(agent_uri, opts \\ [])
Ezagent.AgentConfig.read_key(agent_uri, key, opts \\ [])
Ezagent.AgentConfig.apply_delta(agent_uri, caller, caps, attrs)
Ezagent.AgentConfig.delete_path(agent_uri, caller, caps, attrs)
Ezagent.AgentConfig.repoint(agent_uri, caller, caps, attrs)
```

Recommended attrs:

```elixir
%{
  layer: :user | :workspace | :session,
  key: "agent.soul",
  patch: %{},
  path: ["tone"],
  turn_id: "console:<uuid>"
}
```

Rules:

- Public output should stringify URIs.
- Mutating functions must dispatch to `config_evolve.apply_config_delta` or `config_evolve.repoint_config`.
- No production mutation should call `ConfigStore.write_and_point/1` directly from the facade.
- `turn_id` should be caller-supplied for idempotency when available; otherwise generate a `console:<uuid>` id.
- Default layer remains `:user`.
- Default key remains `agent.soul`.

## Read Shape

`read_cascade/2` should return a stable shape even when no config exists:

```elixir
{:ok,
 %{
   agent_uri: "entity://team_alpha/agent/demo",
   workspace_uri: "workspace://team_alpha",
   default_key: "agent.soul",
   keys: [
     %{
       key: "agent.soul",
       effective_body: %{},
       layers: %{
         workspace: nil,
         user: nil,
         session: nil
       },
       editable: true
     }
   ]
 }}
```

When a layer has a pointer:

```elixir
%{
  layer: "user",
  config_id: "...",
  object_uri: "resource://team_alpha/socialware-config-object/...",
  body: %{"tone" => "decisive"},
  source_turn_id: "console:...",
  updated_at: "..."
}
```

Effective body should be computed by layer order. Proposed order for the console view:

1. `workspace`
2. `user`
3. `session`

Higher layers override lower layers with a shallow merge for the first implementation, matching current `Map.merge` semantics. If nested delete/path mutation is added, nested merge behavior must be explicit and tested.

## Delete Semantics

### First Implementation: Field/Path Delete

`delete_path/5` should remove a field from the selected config object's body and write a new version.

Example:

Current `agent.soul` user body:

```elixir
%{"tone" => "decisive", "soul_md" => "# persona"}
```

Delete:

```elixir
Ezagent.AgentConfig.delete_path(agent, caller, caps, %{
  layer: :user,
  key: "agent.soul",
  path: ["tone"],
  turn_id: "console:delete-tone"
})
```

Resulting body:

```elixir
%{"soul_md" => "# persona"}
```

This produces a new immutable `ConfigObject` and advances the user-layer pointer. Old objects remain intact.

### Out of Scope for First Implementation

- Physical deletion of `ConfigObject`.
- Deleting config history.
- Clearing an entire pointer row to expose only lower-layer inheritance.
- Treating `nil` as delete.

If whole-key deletion is required later, model it explicitly as either:

- pointer clear: remove the layer override so lower layers show through, or
- tombstone object: point at an object that intentionally shadows lower layers.

This needs a separate design decision because it changes cascade inheritance semantics.

## Runtime Consumption

The backend contract must prove that writes are not just stored but consumable by the existing runtime path.

At minimum tests should cover:

- apply `%{"soul_md" => "# New Soul"}` through `apply_config_delta`;
- read back the current object through `ConfigStore`;
- build its `ConfigProjection.object_uri/2`;
- call `ConfigProjection.resolve_config_dir/1`;
- assert `CLAUDE.md` contains the new soul exactly.

This pins the currently implemented runtime consumption path: config object body to projected `CLAUDE.md`.

## Tests

Add domain tests under:

`apps/ezagent_domain_identity/test/ezagent/agent_config_test.exs`

Required cases:

- `read_cascade/2` returns a stable empty shape for an agent with no config pointer.
- `apply_delta/5` creates a new user-layer `agent.soul` object through dispatch.
- `apply_delta/5` updates an existing key and preserves previous fields under current merge semantics.
- `delete_path/5` removes a field and persists a new object.
- `delete_path/5` does not physically delete old config objects.
- `repoint/5` rolls back to a previous object.
- mutation without the agent manage-cap returns `{:error, :unauthorized}`.
- mutation with a manage-cap for another agent is denied.
- `soul_md` write materializes to `CLAUDE.md` through `ConfigProjection`.

Existing `ConfigEvolveTest` should remain focused on behavior internals: authorization, idempotency, sandbox projection, boot reconciliation. The new `AgentConfigTest` should focus on the console-facing contract.

## Contract With Frontend

The world/console frontend should call the facade, not `ConfigStore` directly.

Proposed frontend assumptions:

- It receives all URI values as strings.
- It edits map bodies by `layer`, `key`, and `path`.
- It sends explicit delete operations, not `nil` patches.
- It treats `config_id` as an opaque version id.
- It can show history/rollback later using `previous_config_id`, but first implementation only needs current values.

## Non-Goals

- No UI or LiveView work.
- No `AgentManifest` schema changes.
- No `create_agent/3` input expansion.
- No physical config object deletion.
- No new cap model.
- No direct DB mutation path for production console writes.
- No promise that every arbitrary config key has runtime semantics. The storage layer can read/write arbitrary keys, but current runtime consumption is primarily `agent.soul` projected into `CLAUDE.md`.

## Implementation Order

1. Add `Ezagent.AgentConfig` read facade with stable cascade shape.
2. Add dispatch-backed `apply_delta/5`.
3. Add explicit field/path delete as versioned write.
4. Add dispatch-backed `repoint/5`.
5. Add domain tests for the full contract.
6. Run `mix precommit` and fix issues.
