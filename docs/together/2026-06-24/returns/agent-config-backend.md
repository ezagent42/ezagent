# Return: agent-config backend

> **Task:** agent config backend completeness (2026-06-24 PM track)
> **Dev:** gagameow (@黄佳佳)
> **PR:** not opened yet · **Branch:** `feat/agent-config-backend`
> **returned_at:** 2026-06-24 (PM) · **deadline_status:** on_time
> **Status:** DONE — backend contract, domain facade, focused tests, and frontend alignment docs landed.

## Summary

Completes the backend side of agent config editing for the console contract. The frontend can now depend on one backend facade for reading a full agent config cascade, writing config changes, deleting config paths with versioned semantics, and repointing config history. The session domain also exposes an agent live-session occupancy check for delete-agent blocking.

This task does not include UI wiring.

## What Landed

- **Agent config facade** — `Ezagent.AgentConfig`
  - `read_cascade/2`
  - `read_key/3`
  - `apply_delta/4`
  - `delete_path/4`
  - `repoint/4`
- **Full config read support**
  - `ConfigStore.list_keys_for_subject/1`
  - `ConfigStore.layer_objects_for_key/2`
- **Versioned delete**
  - `delete_path/4` writes a new immutable `ConfigObject` with the selected path removed.
  - Existing config history is retained; no physical delete is introduced.
- **ConfigEvolve extension**
  - `apply_config_delta` keeps current shallow-merge patch semantics.
  - Adds internal `replace_body` support for versioned delete.
- **Live-session delete gate**
  - `EzagentDomainInstanceMessage.agent_live_sessions/1`
  - `EzagentDomainInstanceMessage.agent_in_live_session?/1`
- **Frontend contract docs**
  - `docs/together/2026-06-24/agent-config-frontend-contract.md`
  - `docs/together/2026-06-24/agent-config-backend-delivery.md`

## CRUD Coverage

- **Read:** full cascade and single-key reads, including empty default shape and dynamic pointer keys.
- **Create:** first `apply_delta/4` creates a config object and pointer for a layer/key.
- **Update:** later `apply_delta/4` writes a new object with shallow-merge semantics and keeps `previous_config_id`.
- **Delete:** `delete_path/4` removes a field path by creating a new config object and advancing the pointer.
- **Repoint:** `repoint/4` rolls a pointer back to an existing in-scope config object.

## Verification

Focused task tests passed:

```bash
mix test apps/ezagent_domain_identity/test/ezagent/agent_config_test.exs apps/ezagent_domain_identity/test/ezagent/behavior/config_evolve_test.exs
mix test apps/ezagent_domain_session/test/ezagent_domain_instance_message/uri_query_resolvers_test.exs
mix ezagent.doc.scan
```

Observed results:

- `25 tests, 0 failures`
- `13 tests, 0 failures`
- `ezagent.doc.scan` passed: `undocumented_public_defs: 391/392`

`mix precommit` was run. It did not finish green because of existing repository issues unrelated to this task: retired/plugin directories without `mix.exs` still trip core plugin-wire gates, and one session integration path hit a sandbox owner/environment failure during the umbrella run. The task-specific focused tests above pass.

## Remaining Boundaries

- No world action wiring yet; proposed actions remain:
  - `agents.config.read`
  - `agents.config.update`
  - `agents.config.delete_path`
  - `agents.config.repoint`
- No fixed config schema registry; v1 "full config" is dynamic pointer keys plus default `advisor.behavior`.
- No whole-key pointer clearing.
- No physical deletion of config history.
