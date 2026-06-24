# Agent Config Backend Delivery

> Date: 2026-06-24
> Branch: `feat/agent-config-backend`
> Scope: task 2 backend implementation, no UI wiring.

## Delivered Backend Surface

- `Ezagent.AgentConfig.read_cascade/2`
  - Reads all editable config keys for one agent.
  - V1 key universe is all dynamic `ConfigPointer` keys for the agent plus default `advisor.behavior`.
  - Returns effective body, per-layer body, source config id, previous config id, source turn id, object URI, and updated timestamp.
- `Ezagent.AgentConfig.read_key/3`
  - Reads one config key with the same cascade shape.
- `Ezagent.AgentConfig.apply_delta/4`
  - Writes a shallow patch through `ConfigEvolve.apply_config_delta`.
  - Defaults to layer `user`, key `advisor.behavior`, and generated `console:<uuid>` turn id.
  - Keeps existing manage-cap and subject-self gates.
- `Ezagent.AgentConfig.delete_path/4`
  - Deletes one JSON field path from a selected layer/key body.
  - Implements delete as a new immutable `ConfigObject` plus pointer advance.
  - Does not physically delete historical config objects.
- `Ezagent.AgentConfig.repoint/4`
  - Rolls a selected layer/key pointer back or forward to an existing valid config object.
- `EzagentDomainInstanceMessage.agent_live_sessions/1`
  - Lists live session URIs that currently include an agent member.
- `EzagentDomainInstanceMessage.agent_in_live_session?/1`
  - Boolean helper for delete-agent blocking.

## Store And Behavior Changes

- `Ezagent.Socialware.ConfigStore.list_keys_for_subject/1`
  - Lists distinct dynamic config keys for a subject across all layers.
- `Ezagent.Socialware.ConfigStore.layer_objects_for_key/2`
  - Returns pointer plus config object per layer for one subject/key.
- `Ezagent.Behavior.ConfigEvolve.apply_config_delta`
  - Keeps existing `patch` shallow-merge behavior.
  - Adds internal `replace_body` support used by `delete_path/4`.

## Frontend Contract

Frontend should use the contract in:

```text
docs/together/2026-06-24/agent-config-frontend-contract.md
```

Important v1 decisions:

- "Full config" is dynamic pointer keys plus `advisor.behavior`; there is no fixed schema registry on current `main`.
- `nil`/`null` is a value, not delete.
- Field delete uses `delete_path`; whole-key pointer clearing is deferred.
- Mutations return config ids; frontend should call read again to refresh cascade.
- Agent deletion should be blocked when `agent_live_sessions/1` returns a non-empty list.

## Tests

Focused task-two tests:

```bash
mix test apps/ezagent_domain_identity/test/ezagent/agent_config_test.exs apps/ezagent_domain_identity/test/ezagent/behavior/config_evolve_test.exs
mix test apps/ezagent_domain_session/test/ezagent_domain_instance_message/uri_query_resolvers_test.exs
```

Coverage currently proves:

- empty agents still return stable default-key cascade;
- dynamic keys are discovered from pointers;
- user-layer patch writes are readable through the facade;
- shallow merge preserves existing body fields;
- path delete creates a new object and retains the old object;
- repoint can roll back to the previous object;
- unauthorized writes are rejected;
- manage-cap for another agent is rejected by subject-self protection;
- `soul_md` config still materializes into `CLAUDE.md`;
- session domain can find live sessions containing an agent.

## Known Non-Goals

- No UI implementation in this task.
- No physical deletion of config history.
- No fixed config schema registry.
- No world route/action wiring yet; proposed world action names remain in the frontend contract.
