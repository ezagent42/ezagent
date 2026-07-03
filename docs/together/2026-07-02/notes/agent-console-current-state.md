# Agent Console Current State

> Date: 2026-07-02
> Base: latest `main` at `adf5fad5`
> Purpose: shared current-state handoff for sessions taking over Agent Console.

## One-Line Status

Agent Console on `main` is a real World `Agents` surface, not a static demo. The
shipped slice covers Agent CRUD/config operations. The broader original Agent
Console vision, especially Template Studio and live Session Console, is still
mostly unbuilt.

## PR Lineage

| PR | Status | Contribution |
|---|---|---|
| #994 | merged | Agent Console M1-M4: detail config fields, config schema, structured config editor, dynamic create form |
| #1033 | merged | QA F1-F7 fixes: flavor filter, not-found detail, session-create error surfacing, delete error banner, py script gate, cap instance display |
| #1112 | open | Overview / IA convergence; not merge-ready per lead comments because arch gates still fail |
| #1122 | merged | project_cwd defaulting to per-agent config_dir; allowed cwd roots in create form; full-height shell surfaces |

## Current Routes

Agent-related routes are resolved in:

`apps/ezagent_plugin_world/lib/ezagent/world/routes.ex`

| Route | Component | Meaning |
|---|---|---|
| `/identities` | `identities` | mixed identity directory |
| `/identities/users` | `users_table` | users list |
| `/identities/users/new` | `user_new_form` | create user |
| `/identities/users/:uri` | `user_detail` | user detail |
| `/identities/users/:uri/caps` | `entity_caps` | user caps |
| `/identities/agents` | `agents_table` | agent directory |
| `/identities/agents/new` | `agent_new_form` | create agent |
| `/identities/agents/:uri` | `agent_detail` | agent overview/detail |
| `/identities/agents/:uri/config` | `agent_config` | config editor |
| `/identities/agents/:uri/api-keys` | `agent_api_keys` | API keys |
| `/identities/agents/:uri/extensions` | `agent_extensions` | extensions |
| `/identities/agents/:uri/caps` | `entity_caps` | agent caps |
| `/identities/agents/:uri/terminal` | `pty_terminal` | PTY terminal |

Current `main` route tests assert `/` resolves to Chat/Sessions, not Overview.
Any change to make Overview the default landing page is a product route decision,
not a cleanup.

## Current Implementation Map

| Layer | File |
|---|---|
| route resolution | `apps/ezagent_plugin_world/lib/ezagent/world/routes.ex` |
| LiveView shell / event router | `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex` |
| agent data payloads | `apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex` |
| agent mutations | `apps/ezagent_plugin_world/lib/ezagent/world/agent_actions.ex` |
| React renderer | `apps/ezagent_plugin_world/assets/src/components/Identities.tsx` |
| Overview renderer | `apps/ezagent_plugin_world/assets/src/components/Overview.tsx` |
| typed slot registry | `apps/ezagent_plugin_world/lib/ezagent/world/slot_registry.ex` |
| React slot manifest | `apps/ezagent_plugin_world/assets/src/slots.manifest.json` |

## Current Capability Matrix

| Capability | Status | Notes |
|---|---|---|
| agent list/filter | shipped | `/identities/agents`, flavor filter and live counts |
| agent create | shipped | dynamic flavor fields; project cwd can default to config_dir |
| agent detail | shipped | phase, flavor, cwd, config_dir, source template, bridge, caps, config fields |
| config read/edit | shipped | `/config`, update/delete_path/repoint dispatch via Agent config facade |
| API keys | shipped | read and put key where authorized |
| extensions | shipped | reads config_dir-backed extensions, degrades on no config_dir |
| caps view | shipped | entity caps surface |
| terminal | shipped | PTY terminal route and input path |
| agent delete | shipped | guarded by live-session binding check and manage dispatch |
| remove session participant | shipped elsewhere | part of conversation/session UI, not the agent detail page |
| session delete/archive | missing | design problem; do not add button without lifecycle spec |

## Known Gaps

### 1. Overview / IA Convergence

PR #1112 tries to make Overview more actionable with recommended next steps,
available sessions, and template names. It is still open. Lead comments say gate
failures are real. It also conflicts conceptually with current `main` route
tests, which keep `/` as Chat/Sessions.

Decision needed:

> Should World `/` route become Overview, or should Chat/Sessions remain the
> default landing page?

### 2. Session Delete / Archive Lifecycle

The remaining F7 issue is not a small control. It needs a lifecycle and authority
decision covering live processes, spawned members, routing rows, external mirrors,
history retention, public links, and audit provenance.

### 3. Route-Level Tests

Existing coverage is mostly data/action seam tests. More LiveView/route-level
coverage is needed around:

- `/identities/agents`
- `/identities/agents/new`
- `/identities/agents/:uri`
- `/identities/agents/:uri/config`
- bound-agent delete error surfacing

### 4. Original #84 Scope Still Mostly Deferred

The original Agent Console vision included:

- Template Studio;
- Session Console;
- live team topology;
- add/update/remove managed members;
- rule-set / legend / prompt-template editors;
- migration dry-run/progress UI;
- manage-authority provenance.

Those are not covered by the shipped Agent CRUD/config slice.

## Verification Snapshot

Recently run on latest `main`:

```bash
mix test apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs
node apps/ezagent_plugin_world/assets/test/world_ui_structure_test.mjs
```

Results:

- `routes_test.exs`: 10 tests, 0 failures
- `world_ui_structure_test.mjs`: passed

Full `mix precommit` was not run for this handoff.

## Recommended Next Work

1. Workstream A: resolve PR #1112 and Overview route semantics.
2. Workstream B: write session delete/archive lifecycle spec.
3. Workstream C: add route-level Agent Console tests.

See:

`docs/together/2026-07-02/handoffs/agent-console-parallel-work.md`

