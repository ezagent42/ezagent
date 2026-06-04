# Workspace = Deployment Unit

> **Status (2026-05-20)**: Descriptive + roadmap. Documents both what
> `workspace://` is today and where we're taking it. Read top-to-bottom.

## TL;DR

**A workspace is the deployment unit for ezagent.**

- **Today (Phase 8c)**: workspace is the configuration bundle a session
  belongs to — members, session templates, routing rules. Sessions
  inherit workspace context for routing; entities (users, agents) are
  global.
- **Goal (Phase 9+)**: workspace becomes the full isolation boundary —
  per-workspace entities, per-workspace capabilities, cross-workspace
  dispatch policy. The deployment unit is also the auth/isolation unit.

This doc replaces the partial conceptions of "workspace" scattered
across earlier phase notes. **"Deployment unit"** is the preferred term;
"tenant" and "namespace" are valid English alternatives that mean the
same thing in this codebase.

---

## What workspace is today

Concretely, a workspace is a record in
[`Ezagent.Workspace.Store`][workspace-store] with these fields:

| Field | Meaning |
|---|---|
| `name` | Short string identifier (`default`, `team-alpha`) |
| `uri`  | Computed: `workspace://<name>` |
| `members` | List of entity URIs allowed to participate in workspace sessions |
| `session_templates` | Map of `<template_name>` → template config |
| `routing_rules` | Per-workspace mention / session-receive rules |

A session is created via [`Ezagent.Entity.Session.spawn_from_template/2`][session-spawn]
or `EzagentDomainInstanceMessage.create_session/2`. The flow:

1. Spawn the Session Kind into KindRegistry
2. Bind it to a workspace via [`Ezagent.WorkspaceRegistry.bind/2`][workspace-registry]
   — this is the **runtime lookup** ("which workspace owns this session?")
3. Join the creator entity as a member
4. Templates and routing rules from the bound workspace apply to subsequent dispatch

`workspace://default` is the implicit owner for sessions that don't
specify a workspace at creation time. It is **persisted** (Phase 8c PR-M
added the boot-time `Ezagent.Workspace.create("default", %{})` idempotent
seed) so it shows up in `/workspaces` like any other.

**What workspace already isolates**:

- ✅ Session ownership (`WorkspaceRegistry` 1-to-many session→workspace)
- ✅ Routing rules (per-workspace MentionRouting / SessionRouting tables)
- ✅ Session templates (per-workspace declaration of what kinds of session can be spawned)
- ✅ Workspace members list (declared participants)

**What workspace does NOT yet isolate** (the 30% gap):

- ❌ Entities (`entity://user/admin` is global, not `entity://workspace/team-alpha/user/admin`)
- ❌ Capabilities (cap grants are per-entity globally, not scoped per-workspace)
- ❌ Cross-workspace dispatch (no enforcement that workspace A's session can't dispatch to workspace B's entity)
- ❌ Persistence isolation (one shared SQLite DB; no per-workspace tablespace)

## Why "deployment unit"

A workspace is the smallest unit you would meaningfully **deploy
independently**. Two workspaces could:

- Run on different hosts (multi-tenant SaaS) — different DBs, different
  Phoenix endpoints, different routing rules.
- Coexist on the same host (single-tenant operator with multiple
  environments — staging, prod, demo) — separate workspace records,
  shared backend.
- Be backed up / restored / migrated independently — workspace export
  bundles `members + session_templates + routing_rules + sessions + messages`.

Calling it a "tenant" leans too SaaS-y for single-operator deployments;
"namespace" leans too Kubernetes-y. **"Deployment unit"** captures the
operational property: this is the unit you scale, isolate, and
operate-against as a coherent whole.

## Why the 30% gap is acceptable today

The remaining tenant-ness (per-workspace entity scoping + caps +
dispatch enforcement) is **Phase 9 work**. Today's gap is acceptable
because:

1. **Single-operator deployments dominate**. Most users run one ezagent
   instance with one workspace. The 30% gap is invisible to them.
2. **Per-workspace entity scoping is a hard distributed-systems
   problem**. It interacts with URI scheme design, dispatch
   resolution, snapshot keyspaces, auth tokens. Phase 8c is not the
   place.
3. **The 70% we have is the foundation**. Routing scoping (PR #146-149)
   and session-to-workspace binding (PR-M) are the harder pieces.
   Adding entity scoping later is a backend-only change — no UI rework.

## What the 30% will eventually look like (roadmap)

These are sketches, not commitments. Phase 9 SPEC will refine.

### Per-workspace entity URIs

Two options under discussion:

**Option A — workspace name as a path segment** (Allen 2026-05-20 preferred shape):
```
entity://user/team-alpha/admin
entity://user/team-beta/admin
entity://agent/team-alpha/cc_demo
```
Scheme stays `entity://`; host stays the kind (`user` / `agent`); workspace
name is the **first path segment**, the existing entity name shifts to
become the second.
- ✅ Smallest delta from today's `entity://user/admin` — migration is
  literally "prepend workspace name as a path segment"
- ✅ Matches the agent flavor-prefix convention's spirit (path layered
  by qualifiers, not authority)
- ✅ Globally unique, self-describing
- ❌ Existing URIs need a migration pass (path layout change)
- ❌ Snapshot keys change; entity rehydrate logic touches every domain

System-scoped (cross-workspace) entities need a sentinel path
segment — likely `_system` or just the legacy two-segment form
(`entity://user/admin` continues to mean implicit `workspace://default`).
Decision deferred to the Phase 9 SPEC.

**Option B — workspace context in dispatch envelope**:
```
URI unchanged: entity://user/admin
Dispatch ctx: %{workspace: workspace://team-alpha, ...}
```
- ✅ Existing URIs work as-is
- ✅ Same entity can be member of multiple workspaces (entity sharing
  intentional)
- ❌ Auth + caps lookup becomes 2-key: (entity, workspace)
- ❌ Cross-workspace data leak risk if dispatch ctx isn't validated

Option A is closer to "the URI tells you everything" (no hidden
ambient context to forget about). Option B is closer to how routing
rules work today (URI is workspace-agnostic; the rule itself is
workspace-scoped). Phase 9 SPEC will pick one — current lean is
toward Option A for explicitness.

### Per-workspace capability grants

Today: `Ezagent.Identity.grant_cap(entity_uri, cap, granter)` — single
table, no workspace dimension.

Tomorrow: `Ezagent.Identity.grant_cap(entity_uri, cap, granter, workspace: ws_uri)`
— caps scoped to the workspace they apply within. An admin in workspace
A is just a member in workspace B.

### Cross-workspace dispatch policy

Today: dispatch.ex resolves target → checks caps → fires. No
workspace check.

Tomorrow: a CapBAC-style step inserts a workspace-isolation check:
"caller's workspace must equal target's workspace, OR caller has
`cross-workspace:dispatch` cap." Most dispatches are intra-workspace;
the rare cross-workspace case is explicitly granted (e.g. a sysadmin
agent that operates across all workspaces).

### Tenant-aware auth

Today: login determines `current_entity_uri` only. The LV
`live_session :require_entity` on_mount sets that assign.

Tomorrow: login determines `current_entity_uri` + `current_workspace_uri`.
The avatar dropdown's workspace selector (PR-L) becomes the workspace
context switcher — and dispatch contexts pick up the active workspace
automatically.

---

## Practical implications for current development

**When writing new code now (Phase 8c)**, follow these rules so the
Phase 9 transition is mechanical, not architectural:

1. **Sessions always go through `Ezagent.Entity.Session.spawn_from_template/2`**
   (or `EzagentDomainInstanceMessage.create_session/2` which wraps it). Never
   directly spawn into `EzagentDomainInstanceMessage.SessionSupervisor`. This
   guarantees workspace binding.
2. **Entities (User / Agent) always go through their standard create APIs**
   (`Ezagent.Users.create/3`, `Ezagent.SpawnRegistry.spawn/1` + `Identity.grant_cap`).
   Never static supervisor children. This was the PR-M cleanup.
3. **Caps always granted via `Ezagent.Identity.grant_cap/3`**, never
   manually inserted. When per-workspace caps land, the API gains an
   optional workspace argument and call sites stay backward-compatible.
4. **Routing rules always per-workspace** (`workspace_uri` field on
   each rule). Already the case post-PR #146-149.
5. **UI always shows workspace context** in the top-left dropdown
   (Phase 8c PR-L). When the active workspace becomes a server-side
   concept (Phase 9), the dropdown becomes the actual context switcher.

These five rules are the **invariants** that make the 70%→100% Phase 9
transition safe. Memory `feedback_let_it_crash_no_workarounds` applies:
don't add per-call workspace shims; do the structural fix.

---

## References

- **Phase 8c PRs that touched workspace concept**:
  - PR-E (`1e39b48`): WorkspaceRegistry `default_workspace_uri/0` +
    sessions_have_workspace_test invariant
  - PR-F (`563c458`): top-left `ezagent / <workspace-name>` display
  - PR-L (`7f38ef8` + `59ab87d`): workspace dropdown + Manage workspaces…
  - PR-M (`d7cc887`): standardize 3 built-in entity creation (the move
    that motivated this doc)

- **Code**:
  - [`Ezagent.WorkspaceRegistry`][workspace-registry] — session↔workspace ETS binding
  - [`Ezagent.Workspace.Store`][workspace-store] — DB persistence
  - [`Ezagent.Entity.Session.spawn_from_template/2`][session-spawn] — canonical session creator
  - `EzagentDomainInstanceMessage.create_session/2` — the user-facing facade
  - `apps/ezagent_core/test/invariants/sessions_have_workspace_test.exs` — enforces the binding invariant

- **Glossary**:
  - **Workspace** = deployment unit (this doc)
  - **Session** = a conversation, bound to one workspace
  - **Entity** = a participant (user or agent); today global, Phase 9 will scope per-workspace
  - **Capability (cap)** = a permission grant on a (kind, action) pair;
    today per-entity, Phase 9 will add per-workspace dimension

[workspace-store]: ../../apps/ezagent_domain_workspace/lib/ezagent/workspace/store.ex
[workspace-registry]: ../../apps/ezagent_core/lib/ezagent/workspace_registry.ex
[session-spawn]: ../../apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex
