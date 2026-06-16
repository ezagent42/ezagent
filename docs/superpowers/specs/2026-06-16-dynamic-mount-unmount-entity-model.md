# Dynamic capability + behavior mount/unmount as the entity model

> Design spec. Bottom-up model converged with Allen 2026-06-16 (Feishu). Supersedes
> the "#54 deferral(1) is speculative" framing in `docs/notes/54-d1-caps-behaviors-spawn.md`
> — the consumer is real (the orchestrator's session-management caps, today granted by a
> bespoke path), and the right model is general, not role-specific.
> `file`/symbol citations are point-in-time — verify against current code (code-wins).

## Problem

An entity's authority (**caps**) and capabilities (**behaviors**) should be composable
*after* spawn, dynamically and uniformly, by an authorized principal. Today:

- **caps** already mount/unmount dynamically post-spawn — `Ezagent.Behavior.Identity`
  exposes cap-gated runtime actions `:grant_cap` (`handle_grant_cap`) and `:revoke_cap`
  (`handle_revoke_cap`). The orchestrator's session-management caps are granted *post-spawn*
  this way (`Ezagent.Entity.Session.Orchestrator.Caps.grant_orchestrator_scoped_caps/3`,
  create §4 step 6). So "spawn → mount caps" is already the de-facto model.
  **Gap:** the *authorizer* set at the `grant_cap` chokepoint is `{self, admin}` only
  (`behavior/identity.ex` `check_grant_authorized`: `caller == owner OR holds_admin_caps?`
  else `:grant_not_owner`). A **creator/manager cannot equip what it created** — forcing
  bespoke workarounds (`Orchestrator.Caps` grants via `system://template-materialize` with
  `owner` as caller instead of the natural "I manage this, I equip it" authority).

- **behaviors** do NOT mount/unmount dynamically — fixed at `Kind.spawn`
  (`Ezagent.Kind.BehaviorSet.init_set/2`, intersected with the Kind's declared `behaviors/0`
  superset). There is no add/remove path. So a role (or anything) cannot contribute
  behaviors after spawn.

Because of these two gaps, "role over flavor" (#54) cannot contribute caps/behaviors
uniformly, and the orchestrator's authority lives in a bespoke module rather than its role.

## Model (bottom-up)

`spawn-bare → mount-caps → mount-behaviors`. Mount/unmount is a **general entity
primitive** — every entity is a potential consumer; a *role* is just one consumer (the
orchestrator role is the first live one). This is NOT a role-specific feature.

## Existing infrastructure to REUSE (do not reinvent)

- **`Ezagent.Behavior.Manage`** (#533) — the uniform management surface on *every* Kind
  (`:manage` state slice; actions `:delete`/`:reconfigure`/`:any` = "any management action
  on this instance"). This is the "manager attribute."
- **`Ezagent.CreatorGrant.manage_cap(kind, instance, ws, creator_uri)`** — at create, the
  creator is granted a `Manage` cap over the created instance (`behavior: Manage`,
  `action: :any`, `instance:` the creation, `granted_by: creator_uri`). So **the creator
  relationship already exists** as the Manage-cap the creator holds. No new `creator` Kind
  attribute is needed. (For agents, `Ezagent.AgentLineage` additionally records
  `agent → spawned_by`.)

## Design

### 1. caps — creator/manager-delegated grant (option A)

Extend the `grant_cap` authorizer (`behavior/identity.ex` `check_grant_authorized`) to:

```
caller == owner            -> :ok    # self (unchanged)
holds_admin_caps?(ctx)     -> :ok    # admin (unchanged)
caller holds a Manage cap over the target  -> :ok    # NEW: manager/creator
true                       -> {:error, :grant_not_owner}
```

Bounded, fail-closed — but the delegation bound is NOT inherited and MUST be added
explicitly (codex P1):
- **Delegation (NEW, explicit at the `grant_cap` chokepoint — codex P1).** `grant_cap`
  /`IdentityAdmin.handle_grant_cap/2` today runs ONLY the wildcard-action guard + owner/admin
  authorization; `Role.CapMint`'s delegation policy is NOT on this runtime path. So adding
  `manager` to the authorizer WITHOUT a held-cap check would let a manager grant arbitrary
  concrete-action caps it does not hold (escalation). PR-a MUST, for the manager case, add an
  explicit check: the cap-to-grant must `Capability.matches?` a cap the **caller itself
  holds** before any write (a manager grants only caps it holds whose scope covers the
  target). `Capability.Match` is asymmetric — a concrete held cap never authorizes a wildcard
  request, so a manager cannot fabricate authority it lacks; `{:spawned_by, mgr}` /
  `{:within_workspace, ws}` / `:any` / concrete instance scopes bound *which* targets a held
  cap reaches. Fail-closed (`:grant_not_delegable`) if no held cap matches.
- **Wildcard-action** grants still require admin
  (`check_action_wildcard_grant_authorized`, unchanged).
- **Audit**: record manager-provenance on the grant (`granted_by` = the manager + a
  `via_manage` marker) so a manager-delegated grant is distinguishable from a self/admin
  grant in audit/telemetry. (This gives option (b)'s only real advantage without a second
  chokepoint.)

`grant_cap` stays the single cap-write chokepoint. **First migration consumer:**
`Orchestrator.Caps`. **Prerequisite within PR-a (codex P2):** the orchestrator spawn path
(`Session.ensure_orchestrator` → `Agent.spawn_from_template_content/5`) does NOT currently
grant the owner a Manage cap over the orchestrator — it bypasses `CreatorGrant` /
`Workspace.grant_creator_manage_cap/4`. So the owner is NOT yet a manager of the
orchestrator, and a naive migration would fail (`:grant_not_owner`). PR-a must FIRST wire the
owner's Manage cap at orchestrator spawn (route through `grant_creator_manage_cap/4` or grant
the `CreatorGrant.manage_cap` there). THEN `Orchestrator.Caps` grants via the
manager-delegated `grant_cap` path instead of the `template-materialize`+owner-caller
workaround. (Migration parity test must still hold — same resulting caps.)

### 2. behaviors — dynamic mount/unmount (the genuinely new capability)

Make `BehaviorSet` mutable, gated as a **Manage** action (symmetric with caps — a manager
mounts/unmounts behaviors on its managed instance):

- `mount_behavior` / `unmount_behavior` — **only within the Kind's declared `behaviors/0`
  superset** (you cannot add a behavior the Kind does not declare — that would be a
  different Kind). Fail-closed (`{:error, :not_in_superset}`) otherwise; idempotent.
- **Slice lifecycle + persisted membership (codex P2 — REQUIRED).** Mounting (a) adds the
  behavior to the persisted `:kind_base` behavior list AND (b) initializes its state slice
  (`init_slice`); unmounting removes it from `:kind_base` AND drops the slice. The runtime
  derives the active behavior set after load via `BehaviorSet.effective_set/2` from the
  persisted `:kind_base` slice — so the `:kind_base` update is NOT optional: without it a
  mounted behavior vanishes on reload and an unmounted one is re-enumerated from the stale
  set. Keep minimal: mount = add-to-kind_base + ensure slice; unmount = remove-from-kind_base
  + drop slice. Already-mounted / already-absent = no-ops.
- Authorized by the same `{self, admin, manager}` set (the manager holds the target's
  Manage cap). Cap-gated, audited.

### 3. role as a consumer

A `Role` recipe `%{caps, behaviors, content}` becomes, applied to an instance by its
manager: mount the role's behaviors (within the Kind superset) + grant the role's caps
(manager-delegated) + install content (already done for skills via #803). The
**orchestrator role** is the first consumer: its caps (currently `Orchestrator.Caps`) and
any behaviors flow through the role recipe + this model.

## Decision (ambient-authority — GLOSSARY Decision Log)

> **A creator/manager may grant a managed instance any capability the manager itself holds
> whose scope covers the instance, and may mount/unmount behaviors within the instance's
> Kind superset — bounded by delegation (no authority the manager lacks), wildcard-action
> still admin-only, audited with manager provenance.** This expands the cap-grant and
> behavior-mount authorizer set from `{self, admin}` to `{self, admin, manager-of-target}`.

This is an ambient-authority expansion; it is recorded as a Decision Log entry (Allen
approved option A, 2026-06-16).

## Sequencing (re-plan of #54 / #807 / #58)

- **PR-a — caps creator/manager-delegation.** `grant_cap` accepts Manage-holders
  (delegation + wildcard guard + manager provenance). Migrate `Orchestrator.Caps` to this
  path as the validating consumer. (This is #807 done right; #58-adjacent.)
- **PR-b — behaviors dynamic mount/unmount.** Mutable `BehaviorSet` + slice lifecycle +
  Manage-gated `mount/unmount_behavior`, superset-bounded.
- **PR-c — role consumes both.** Role recipe → manager mounts behaviors + grants caps;
  wire the orchestrator role; retire the bespoke pieces.
- Then **#58** (repoint session default → persisted `template://system/role/orchestrator`
  + cc-absent edge), **#48-G1-b** (vertical seed-flow), **#34** (advisor live E2E) build on
  the persisted role Template + this model.

## Scope guard (keep it thin)

- caps PR-a is small (one authorizer branch + reuse the existing delegation + provenance).
- behaviors PR-b is the only genuinely new mechanism — keep the slice lifecycle minimal
  (mount = init slice; unmount = drop), superset-bounded, no speculative config.
- Do not generalize the creator relationship beyond what's needed (agents: AgentLineage;
  managed entities: the Manage cap). A non-agent general "creator registry" is out of scope
  until a non-agent consumer needs it.

## Acceptance / invariants

- **Caps fail-closed**: a manager-delegated grant of a cap the manager does not hold is
  rejected before any write; a wildcard-action grant by a non-admin manager is rejected.
- **Behaviors bounded**: mounting a behavior not in the Kind's superset is rejected;
  unmount then mount round-trips the slice.
- **Migration parity**: the orchestrator, after `Orchestrator.Caps` is migrated to PR-a,
  holds exactly the same management caps it does today (proven by the existing orchestrator
  cap test).
- Per-PR: full gate suite (`arch.scan`, `check_invariants`+`.lifecycle`, `doc.scan`, tests)
  + `/codex:adversarial-review`.
