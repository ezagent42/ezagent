# Unified Kind Creation via Templates — Design

**Date:** 2026-06-01
**Status:** Draft (brainstorm output, pending codex adversarial review + Allen approval)
**Author:** Claude (with Allen)

## 1. Problem & context

A design discussion on team-routing "management authority" (who may edit a Kind / its
routing rows) surfaced a deeper structural problem, confirmed by a read-only audit of
every Kind creation path:

- There **is** a mechanical single-spawn chokepoint — `Ezagent.Kind.spawn/2`
  (`apps/ezagent_core/lib/ezagent/kind.ex:294`) → `Kind.Server.init/1`
  (`server.ex:104`) → `KindRegistry.put_new/2` (`kind_registry.ex:42`) — enforced by
  `single_spawn_entry_test.exs` + `kind_provenance_test.exs`. **But it is
  authorization-free and owner-free**: it only does URI→pid registration.
  **Registration ≠ authorized creation.**
- Authorization is bolted on **only at dispatch of wrapped create actions**
  (`workspace.create_agent`, `workspace.create_session`,
  `workspace_user_admin.create_user`). Any path calling `SpawnRegistry.spawn/1` /
  `Kind.spawn/2` directly bypasses authz by construction.
- The audit found **~7 ad-hoc creation paths**. Worst (external-reachable, fresh
  unowned create, invisible to the only CI gate): the **agent-bridge channel join**
  (`apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge/channel.ex:146` —
  `SpawnRegistry.spawn(agent_uri)` materializes a fresh, unowned Agent; uses a
  variable arg so `agent_create_single_path_test.exs` doesn't see it). Also
  `Workspace.create/2` (`workspace.ex:62`, no CapBAC).
- The **owner-cap-at-creation pattern already exists piecemeal** for Sessions
  (`owner_uri` create-arg + `grant_first_join_owner_cap` + `OrchestratorAdmin
  :restart`) and Templates (`grant_{agent,session}_template_owner_cap`), and the
  `OwnedBehavior` test idiom documents "spawning X grants the X→X data-owner cap"
  (`apps/ezagent_core/test/support/owned_behavior.ex`). It is **not** wired into the
  mechanical chokepoint, **not** present for Agents (lineage only, not a cap),
  Workspaces (no owner at all), or Users.

Allen's directive (2026-06-01): **introduce a Template concept for ALL Kinds and
funnel all creation (and modification) through one authorized chokepoint that threads
`created_by` and grants a management capability at creation.** Do this foundational
unification FIRST — it removes a class of "hackable creation" bugs and is the natural
home for the management-cap that the team-routing work needs.

R/B/K = Router / Behavior / Kind is the internal engine; Lifecycle
(`use Ezagent.Lifecycle`) is the public developer API (ARCHITECTURE.md:1158, §153).
A **Template** is the double-layer model already in the codebase (GLOSSARY §64/§114):
a **Template Class** (developer-written module implementing the `Ezagent.Kind.Template`
behaviour) + a **Template Instance** (the runtime Kind it produces). This design
**generalizes** that pattern; it does not invent one.

## 2. Goals / non-goals

**Goals**
1. Every Kind type (Session, Agent, Workspace, User, AgentTemplate, SessionTemplate)
   is created through a **Template Class** via a single **authorized** entry.
2. That entry threads `created_by` (the authenticated caller) and, on **fresh create
   only**, grants `cap(:<kind>, Ezagent.Behavior.Manage, :manage, instance)` to
   `created_by`.
3. **Modification** (`reconfigure` / `delete`) is unified through a `Manage` behavior
   on every Kind, gated by the manage-cap, and is **lifecycle-consistent**: a config
   change re-materializes the **live** Kind preserving identity + runtime state, never
   destroy+recreate.
4. The ~7 ad-hoc creation paths are converged onto the chokepoint (or explicitly
   refuse to create).
5. CI invariants make a future bypass fail loudly.

**Non-goals (this spec)**
- The routing-row edit authz that *consumes* the manage-cap (`{:manages}` →
  `cap(:<kind>, Manage, :manage, ref)`) — that is the team-routing continuation, a
  follow-up spec. This spec only *produces* the cap.
- Versioned/blueprint template synthesis (Phase 8+).
- Re-modelling Behaviors or the Lifecycle engine.

## 3. Design

### 3.1 Template Class for every Kind

The `Ezagent.Kind.Template` behaviour (`apps/ezagent_core/lib/ezagent/kind/template.ex`)
is the Class contract. Today's required callbacks:

```
@callback template_name() :: String.t()
@callback validate(template_data()) :: :ok | {:error, term()}
@callback instantiate(template_name(), template_data(), workspace_uri :: URI.t()) ::
            {:ok, [URI.t()]} | {:ok, [URI.t()], %{optional(:fresh?) => boolean()}} | {:error, term()}
```

`instantiate/3` **already returns** `%{fresh?: boolean()}` — `true` iff THIS call
started the worker (vs adopting/rehydrating a pre-existing one). This is the exact
signal the manage-cap grant keys off (§3.3); no Class signature change is required for
the grant.

Concrete Classes today: `Ezagent.Template.GenericSession` (sessions), `Entity.Agent`
flavor classes (cc/codex/curl/echo/np), `AgentTemplate`, `SessionTemplate`. **New in
this spec:** a **Workspace Template Class** (§3.6) and a **User Template Class** (§3.7).

Invariant: **every Kind type has exactly one registered Template Class** that is its
sole creation path (CI §6).

### 3.2 Unified, authorized create chokepoint

All creation flows through a single dispatched action — **`template.instantiate`** —
carried on the `Ezagent.Behavior.Template` behaviour (which already hosts
fork/create-shaped actions). Because it is **dispatched**, it passes through
`Kind.Runtime` step 5.5 CapBAC and carries an **authenticated `ctx.caller`** = the
`created_by` principal.

- Authorization to *create* is the existing per-scope create cap (e.g. a workspace
  admin cap to instantiate within a workspace). This spec does not widen who may
  create; it makes the authz *uniform and unavoidable* (no direct-`spawn` bypass).
- The action resolves the target Template Class, runs `validate/1`, then the Class's
  `instantiate/3`, then the **core post-instantiate grant step** (§3.3).
- `created_by` is `ctx.caller` (authenticated on external paths via token →
  `Entity.authenticate/2`; trusted in-VM). It is **never** read from `template_data`
  (no forge surface).

`Ezagent.Kind.spawn/2` / `SpawnRegistry.spawn/1` remain the **mechanical** primitive
(used by rehydrate/boot), but **fresh creation** is only legitimate through
`template.instantiate`. The CI invariant (§6) forbids new direct-spawn fresh-create
call sites outside the allowlisted engine + rehydrate paths.

### 3.3 Manage-cap grant — a CORE post-instantiate step (keeps auth in core)

The grant is **core infrastructure**, not plugin Class code (north-star: plugin
authors stay out of the auth path). After the Class's `instantiate/3` returns
`{:ok, uris, %{fresh?: true}}`, the `Ezagent.Behavior.Template` handler (core/domain,
trusted) grants, for each fresh URI:

```
cap(kind_of(uri), Ezagent.Behavior.Manage, :manage, instance: uri)  → granted to ctx.caller
```

- On `fresh?: false` (rehydrate/adopt) the grant is **skipped** — the durable cap
  already exists (caps survive restart; rehydrate reloads them). Granting is therefore
  idempotent across restart by construction.
- The grant uses `created_by` = `ctx.caller`. A Class CANNOT influence the grantee —
  it only reports `fresh?` + the URIs.
- The existing piecemeal owner-cap grants (Session `owner_uri`/restart-cap, Template
  `grant_*_owner_cap`) are **folded into** this single core step (one grant shape, one
  place), removing the per-Kind divergence.

**Why this closes the authority hole cleanly:** the manage-cap lives on the **`:<kind>`
axis** (`:agent` / `:session` / `:workspace` / `:user`), and the baseline cap every
user receives (`User.default_caps/1` = `cap(:session, :any, :any)`) is **kind
`:session`** — it cannot match a `:agent`/`:workspace`/`:user` manage-cap, and for
`:session` it is *behavior-* and *action-*scoped to a different shape. An ordinary user
therefore does not implicitly hold `:manage` on resources they did not create. (This
is the lesson from the abandoned PR-5b-i cap gate, where anchoring on a session-scoped
op let the session wildcard satisfy it.)

### 3.4 `Ezagent.Behavior.Manage` — uniform management surface on every Kind

A single new behaviour `Ezagent.Behavior.Manage` (core), registered against **every**
Kind via `CapabilityRegistry.register(<Kind>, <action>, Ezagent.Behavior.Manage)` in
the owning Application boot (same mechanism as
`CapabilityRegistry.register(Session, :join, Chat)`).

Actions:
- `:reconfigure` — args `%{template_data: map}` → re-materialize live (§3.5).
- `:delete` — permanent removal (maps to the Lifecycle `destroy/2`).
- `:transfer` *(optional, deferred)* — grant the manage-cap to another principal /
  revoke. Out of scope v1 unless trivial; flagged as future.

All `Manage` actions require `cap(:<kind>, Ezagent.Behavior.Manage, :manage, instance)`
(`required_caps[:reconfigure] = required_caps[:delete] = cap(:any, Manage, :manage)`,
resolved against the target instance at dispatch). The cap shape is uniform across
Kinds — `behavior` is fixed to `Manage`, self-documenting, and not subsumed by user
session wildcards (§3.3).

### 3.5 Modification = lifecycle-consistent re-materialization (D2)

`manage.reconfigure` does NOT destroy+recreate. It:
1. Validates the new `template_data` via the Kind's Template Class `validate/1`.
2. Writes the new durable spec into the Kind's persistent `state` (the slice that
   carries its template params) — the Kind stays alive, same URI, same identity.
3. Re-applies the materialization side-effects against the **live** Kind: re-bind /
   re-grant / re-apply routing rules — the idempotent subset of what `instantiate`
   does, expressed as Lifecycle effects.
4. For Kinds whose config change requires a subprocess restart (cc PTY, np Python),
   the existing `Ezagent.Kind.Template.ensure_subprocess_alive/2` /
   `start_python` hooks (GLOSSARY §128) are invoked to relaunch the subprocess against
   the new config — runtime conversation/snapshot state is preserved by the existing
   two-container Lifecycle model (`state` persists; `transients` rebuilt by
   `activate/2`).

Runtime state survives because reconfigure is a **state mutation through the
Lifecycle**, not a Kind teardown. (`Snapshot.load_or_init` create/rehydrate semantics
are untouched.)

### 3.6 Workspace Template Class (proposed)

`Ezagent.Template.Workspace` (workspace domain). `template_data`:
- `name` (workspace short name) — drives the `workspace://<name>` URI.
- `owner` — the principal that will hold the manage-cap (defaults to `created_by`).
- `default_agent_template` — the AgentTemplate to seed the per-user `<username>-default`
  cc agent from (ties into the existing `<username>-default` flow, memory
  `project_username_default_agent`).
- `default_caps_policy` *(optional)* — baseline caps minted for members.

`instantiate/3` = `Workspace.Store.create/2` (persist row) + `Kind.spawn(Workspace)` +
return `{:ok, [workspace_uri], %{fresh?: true}}`. The current `Workspace.create/2`
(`workspace.ex:62`) becomes a thin wrapper that dispatches `template.instantiate`
(authorized) or is removed in favor of it.

### 3.7 User Template Class (proposed)

Users are "created" at registration (external identity), not user-chosen instantiation.
The **User Template Class models the registration/materialization spec** — almost all
users use one default user-template. `Ezagent.Template.User` (identity domain).
`template_data`:
- `username` — drives `entity://user/<ws>/<username>`.
- `initial_caps` — merged with `User.default_caps/1`.
- `default_workspace` — the workspace to bind into.
- `default_agent_spec` — the `<username>-default` cc agent to fork at registration.

`instantiate/3` = `Users.create/3` (persist row + `caps_json = default_caps ++ initial`)
+ workspace bind + fork the `<username>-default` agent (itself via
`template.instantiate`) + return `{:ok, [user_uri | agent_uri], %{fresh?: true}}`.

**manage-cap recipients for a User (Allen-approved):** the user holds `:manage` on
**itself** (self-ownership), AND the **admin/registrar that created it** also holds
`:manage` on the user (so an admin can administer accounts). Both grants happen at the
fresh-create step (§3.3): the core step grants `created_by`; the User Class
additionally self-grants the user. (The only Kind with a 2-recipient grant; documented
as such.)

`Entity.ensure_spawned/1` (login demand-spawn) is a **rehydrate** of an
already-created user — `fresh?: false`, no re-grant.

### 3.8 Converging the ad-hoc creation paths

| Path | Today | After |
|---|---|---|
| agent-bridge channel join (`channel.ex:146`) | `SpawnRegistry.spawn` creates fresh unowned Agent | **Refuse to create on join** — require the Agent Kind to pre-exist (created via `template.instantiate`); join only *attaches* to a live/rehydratable Kind. A join for a non-existent agent is an error, not a silent create. |
| `Workspace.create/2` (`workspace.ex:62`) | plain fn, no CapBAC | dispatch `template.instantiate` (Workspace Template), authorized |
| plugin Class `instantiate/3` (cc/np/curl/echo/codex) | already via instantiate, but no `created_by`/cap | unchanged Class code; the **core wrapper** (§3.3) grants the cap using `ctx.caller` |
| `Agent.spawn_fresh/4` / `spawn_from_template_content/4` | records lineage, no cap | the core wrapper grants the manage-cap; lineage stays (orthogonal provenance-of-creation) |
| boot `Workspace.Loader` / BootReconciler | rehydrate | unchanged — `fresh?: false`, reload durable caps |
| mix tasks / demo seeds | direct spawn (operator-local) | route through `template.instantiate` for parity; lowest priority |

### 3.9 Component summary (isolation boundaries)

- `Ezagent.Kind.Template` (core) — Class contract (unchanged signatures).
- `Ezagent.Behavior.Template` (core/domain) — hosts `template.instantiate`; **owns the
  core post-instantiate manage-cap grant** keyed off `fresh?` + `ctx.caller`.
- `Ezagent.Behavior.Manage` (core) — `:reconfigure` / `:delete`; registered on every
  Kind; gated by the manage-cap.
- `Ezagent.Template.Workspace` (workspace domain) — new Class.
- `Ezagent.Template.User` (identity domain) — new Class.
- CI invariants (test) — §6.

## 4. Data flow

**Create:** caller → dispatch `template.instantiate` (CapBAC: create cap) → resolve
Class → `validate/1` → `instantiate/3` → `{:ok, uris, %{fresh?}}` → **core grant step**
(if `fresh?`, grant `cap(:<kind>, Manage, :manage, uri)` to `ctx.caller`) → return uris.

**Modify:** caller → dispatch `manage.reconfigure` (CapBAC:
`cap(:<kind>, Manage, :manage, instance)`) → `validate/1` → write new spec to durable
`state` → re-apply idempotent materialization effects on the live Kind → (if needed)
`ensure_subprocess_alive/2`.

**Rehydrate (boot/login/bridge-attach):** `SpawnRegistry.spawn(uri)` →
`Snapshot.load_or_init` finds a row → rehydrate (`fresh?: false`) → durable manage-cap
already present, no grant.

## 5. Error handling

- `template.instantiate` for an already-existing URI → `{:error, {:already_started, _}}`
  (current `Workspace.create` behavior, generalized).
- `validate/1` failure → `{:error, {:invalid_template_data, _}}` (fail loud, no
  partial spawn — existing contract, GLOSSARY §128).
- agent-bridge join for a non-existent Agent → `{:error, :agent_not_created}` (NOT a
  silent create).
- manage action without the manage-cap → `{:error, :unauthorized}` (standard step-5.5).
- grant failure after a fresh spawn → treat as create failure; roll back the spawn
  (mirror `create_session` rollback). The grant is part of the create's atomic unit.

## 6. Testing / CI invariants

- **Single authorized create path** (strengthen `agent_create_single_path_test.exs`):
  detect **variable-argument** `SpawnRegistry.spawn` / `Kind.spawn` fresh-create calls
  (not just literal `entity://agent/` strings) across **all** schemes
  (`session://`, `workspace://`, `entity://user`, `template://`); allowlist only the
  engine + rehydrate sites. The agent-bridge join (`channel.ex:146`) must NOT be on the
  create allowlist.
- **Grant-at-create invariant:** a freshly created owned Kind carries
  `cap(:<kind>, Manage, :manage, self)` for its `created_by` (assert via the
  `OwnedBehavior`-style harness, generalized).
- **Template Class coverage:** every Kind type has a registered Template Class
  (`TemplateRegistry`), and `Ezagent.Behavior.Manage` is registered on every Kind
  (`CapabilityRegistry`).
- **Reconfigure preserves identity + state:** `manage.reconfigure` keeps the same URI
  and a representative runtime-state field across a config change (per Kind with state:
  Session members, Agent conversation/PTY-alive).
- **Rehydrate does not re-grant / does not duplicate:** restart of an owned Kind
  reloads the durable manage-cap without a second grant.
- **No external forge of `created_by`:** a non-allowlisted caller cannot set
  `created_by` (it is `ctx.caller`, authenticated) — assert the create authz + that
  `template_data` cannot carry `created_by`.

## 7. Out of scope (this spec)

- Routing-row edit authz consuming the manage-cap (team-routing continuation).
- `manage.transfer` ownership transfer (flagged; v1 may omit).
- Versioned/blueprint templates.
- Multi-owner sets beyond the User self+admin case (general co-management is future;
  expressed naturally as additional manage-cap grants when needed).

## 8. Decisions (Allen-approved 2026-06-01)

1. **D1:** Template concept for ALL Kinds (incl. Workspace + User); unified create
   chokepoint.
2. **D2:** Modification = rewrite template params → lifecycle-consistent
   re-materialization preserving identity + runtime state (NOT destroy+recreate).
3. **Manage surface:** a dedicated `Ezagent.Behavior.Manage` registered on every Kind
   (not a vague "primary behavior"); manage-cap = `cap(:<kind>, Manage, :manage,
   instance)`.
4. **User manage-cap recipients:** the user (self) + the creating admin/registrar.
5. **Grant location:** core post-`instantiate` step keyed off `fresh?` + `ctx.caller`
   (plugin Classes unchanged — auth stays in core).

## 9. Open questions

- **OQ-1:** Does `template.instantiate` need a new dedicated create-cap shape per Kind,
  or do existing per-scope create caps (`workspace.create_agent` etc.) become the
  authz, with the Template behavior reusing them? (Lean: reuse existing create caps;
  the Template behavior is the *dispatch surface*, the cap is per-scope.)
- **OQ-2:** Migration/cutover — existing live Kinds created before this change have no
  manage-cap. Backfill at next rehydrate (grant on first post-deploy activate if
  absent) vs a one-shot migration. (Lean: backfill-on-activate, idempotent.)
- **OQ-3:** `Workspace`/`User` reconfigure scope — which params are reconfigurable vs
  immutable (e.g. a user's username / a workspace's name are likely immutable identity).
