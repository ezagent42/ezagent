# Agent Console Parallel Work Plan

> Date: 2026-07-02
> Base: latest `main` at `adf5fad5`
> Owner: gaga coordination
> Purpose: split Agent Console follow-up into three independent sessions plus a
> shared current-state handoff, so work can proceed without route/UI conflicts.

## Current Anchor

Agent Console on `main` is no longer a static demo. The shipped slice is the
World `Agents` surface:

- list/filter agents;
- create agent;
- view agent detail;
- edit config;
- view/update API keys where authorized;
- view extensions;
- view caps;
- open terminal;
- delete agent with live-session guard.

The remaining work is not one task. It splits into:

1. PR #1112 / Overview convergence;
2. session delete/archive lifecycle design;
3. route-level test coverage;
4. current-state documentation for cross-session sync.

## Workstream A — PR #1112 Overview / IA Convergence

### Goal

Make the #1112 direction mergeable or explicitly reduce it to docs-only. The
core question is whether the World default route `/` should become an Overview
landing page or remain Chat/Sessions.

### Starting Point

- PR: https://github.com/ezagent42/ezagent/pull/1112
- Branch: `origin/fix/agent-console-completeness-0630`
- Latest lead review says the PR still has real arch-gate failures after rebase:
  duplicate function body, URI query scan, and related failures.
- Current `main` has an `Overview` slot/component, but route tests assert `/`
  resolves to Chat/Sessions.

### Owned Surfaces

Primary:

- `apps/ezagent_plugin_world/assets/src/components/Overview.tsx`
- `apps/ezagent_plugin_world/lib/ezagent/world/admin_data.ex`
- `apps/ezagent_plugin_world/lib/ezagent/world/routes.ex`
- `apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs`
- optional: `apps/ezagent_plugin_world/test/ezagent/world/admin_data_test.exs`

Avoid touching:

- `Identities.tsx`
- `AgentActions`
- session lifecycle or CapBAC code
- broad navigation renames such as `Identities -> Roster`

### Discuss-First Decision

Before changing behavior, get an explicit answer:

> Should World `/` route change from Chat/Sessions to Overview?

If yes:

- update `Routes.route_for/2`;
- update route tests;
- ensure top nav active state still makes sense;
- make Overview payload useful enough to be a default landing page.

If no:

- keep `/` as Chat/Sessions;
- either close #1112 as docs/prototype input or keep Overview as a non-default
  surface only if there is a clear route to it.

### Definition of Done

- The route semantic decision is recorded in PR body or return doc.
- Any retained code passes:
  - `mix test apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs`
  - `node apps/ezagent_plugin_world/assets/test/world_ui_structure_test.mjs`
  - relevant `AdminData` / Overview tests if `admin_data.ex` changes
  - architecture gate that previously failed, at minimum the failing subset
- PR #1112 is either:
  - merge-ready with green gates; or
  - clearly closed/superseded with docs preserved.

### Return Artifact

Write:

`docs/together/2026-07-02/returns/agent-console-overview-convergence.md`

Include route decision, files changed, tests run, and whether #1112 should merge,
be replaced, or close.

## Workstream B — Session Delete / Archive Lifecycle Spec

### Goal

Turn the remaining F7 gap into a design spec. Do not implement destructive UI or
authority changes in this workstream.

### Problem

Agent Console can remove participants and delete agents with guards, but it does
not have a safe session delete/archive model. This is not a missing button. It
touches:

- live Session process;
- SessionManager;
- orchestrator agent;
- orchestrator-spawned members;
- routing rows;
- working copy / template links;
- ExternalMirror bindings;
- public/socialware surfaces;
- message history;
- audit/provenance;
- CapBAC authority.

### Owned Surfaces

Docs only:

- `docs/superpowers/specs/2026-07-02-agent-console-session-lifecycle.md`
  or
- `docs/together/2026-07-02/handoffs/agent-console-session-lifecycle.md`

Do not edit code.

### Questions To Answer

1. Is the product operation `delete`, `archive`, `end session`, or multiple
   operations?
2. What remains visible after archive/delete?
3. What happens to live members and orchestrator-spawned agents?
4. What happens to routing rules, external mirror bindings, public links, and
   working-copy state?
5. Who is authorized: owner, admin, manage-cap holder, session member, or
   explicit new authority?
6. Does execution run under the operator's caps or under reconstructed
   orchestrator/session-manager authority?
7. What audit fields are required? At minimum consider:
   - `authorized_operator_uri`
   - `execution_principal_uri`
   - target session URI
   - lifecycle action
8. What is the safe first implementation slice?

### Definition of Done

- The spec separates product semantics from implementation steps.
- It does not smuggle in a CapBAC decision without lead approval.
- It proposes one minimal first slice and one explicit deferred list.
- It names required invariant tests before implementation.

### Return Artifact

Write:

`docs/together/2026-07-02/returns/agent-console-session-lifecycle.md`

Include recommendation and open decisions for Allen.

## Workstream C — Agent Console Route-Level Test Coverage

### Goal

Add route/LiveView-level coverage around the already-shipped Agent Console
surface, because current tests mostly cover data/action seams.

### Owned Surfaces

Primary:

- `apps/ezagent_web/test/ezagent_web/world_*_test.exs`
- `apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs`
- targeted test helpers only if needed

Avoid touching product code unless a test reveals a real bug. If a real bug is
found, stop and return it as a finding unless it is a tiny obvious fix.

### Candidate Tests

Prioritize tests that do not conflict with Workstream A:

1. `/identities/agents` resolves/renders agent list state.
2. `/identities/agents/new` exposes create state and dynamic flavor fields.
3. `/identities/agents/:uri` detail includes config fields, granted caps, and
   config path.
4. `/identities/agents/:uri/config` resolves to config editor state.
5. delete-bound-agent failure pushes the error to the detail route, not the list.

Defer root `/` route tests until Workstream A decides whether `/` is Overview or
Chat/Sessions.

### Definition of Done

- Adds focused tests that fail on route wiring regressions.
- Does not duplicate lower-level data/action tests unless needed for setup.
- Keeps test fixtures minimal and uses existing sanctioned dispatch/world test
  helpers.
- Runs the added tests plus:
  - `mix test apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs`

### Return Artifact

Write:

`docs/together/2026-07-02/returns/agent-console-route-tests.md`

Include tests added, what they protect, and any found bugs.

## Workstream D — Current-State Documentation

### Goal

Create a concise current-state handoff that future sessions can read before
touching Agent Console.

### Owned Surface

Write:

`docs/together/2026-07-02/notes/agent-console-current-state.md`

### Required Content

- Latest `main` anchor commit.
- PR lineage:
  - #994
  - #1033
  - #1112
  - #1122
- Current route map.
- Current capabilities matrix:
  - create
  - list
  - detail
  - config
  - API keys
  - extensions
  - caps
  - terminal
  - delete
- Known gaps:
  - #1112 Overview route/gate decision
  - session delete/archive lifecycle
  - route-level tests
  - original #84 Template Studio / Session Console / migration scope
- File map for new contributors.

### Definition of Done

- A new session can read the doc and know where to start.
- It distinguishes shipped Agent CRUD/config from the broader unshipped Agent
  Console vision.
- It does not claim full `mix precommit` was run unless it was.

## Conflict Map

| Workstream | Likely files | Conflict risk |
|---|---|---|
| A | `Overview.tsx`, `admin_data.ex`, `routes.ex`, route tests | Medium |
| B | docs only | Low |
| C | tests only, possibly route tests | Medium with A if root route is touched |
| D | docs only | Low |

Rules:

- A owns `/` route semantics.
- C must not assert `/` semantics until A decides it.
- B must not implement UI or CapBAC.
- D should not edit code.

## Suggested Session Prompts

### Session A

```text
You are handling Agent Console Workstream A on latest main.

Read:
- docs/together/2026-07-02/handoffs/agent-console-parallel-work.md
- PR #1112 and its lead comments
- apps/ezagent_plugin_world/lib/ezagent/world/routes.ex
- apps/ezagent_plugin_world/test/ezagent/world/routes_test.exs
- apps/ezagent_plugin_world/assets/src/components/Overview.tsx

Goal: make the #1112 Overview/IA convergence mergeable or explicitly reduce it
to docs-only. First answer whether `/` should become Overview. Do not touch
Agent CRUD/config code or session lifecycle.
```

### Session B

```text
You are handling Agent Console Workstream B on latest main.

Read:
- docs/together/2026-07-02/handoffs/agent-console-parallel-work.md
- docs/superpowers/handoffs/2026-06-22-agent-console-in-world-handoff.md
- docs/superpowers/notes/2026-06-22-agent-console-backend-research.md
- PR #1033 body, especially deferred F7

Goal: write the session delete/archive lifecycle spec. Docs only. Do not change
code, CapBAC, session membership, or UI.
```

### Session C

```text
You are handling Agent Console Workstream C on latest main.

Read:
- docs/together/2026-07-02/handoffs/agent-console-parallel-work.md
- apps/ezagent_plugin_world/lib/ezagent/world/routes.ex
- apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex
- apps/ezagent_plugin_world/lib/ezagent/world/agent_actions.ex
- existing tests under apps/ezagent_plugin_world/test/ezagent/world/

Goal: add route/LiveView-level tests for Agent Console. Avoid root `/` route
assertions until Workstream A decides Overview vs Chat.
```

## Recommended Merge Order

1. D docs can merge anytime.
2. B spec can merge anytime.
3. C tests should merge before or after A depending on whether they touch
   `routes_test.exs`; avoid conflicting root-route assertions.
4. A should merge only after the route decision and arch-gate fixes are complete.

