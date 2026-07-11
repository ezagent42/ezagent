# Unified Grant Chokepoint — design (rev 2)

> **⚠️ RECONCILED to Phase-3 (cbac-done-right, landed main `fa72d36ba` 2026-07-12).** This spec's
> chokepoint (`Ezagent.Identity.Grant`) still exists and is still the sole grant/revoke
> constructor. What changed: a grant is **no longer** a single issuer→grantee dispatch that
> writes the grantee's `:caps` slice (the model described below). It is now **ISSUE → STORE →
> VERIFY** — the grantor ISSUEs a provenance-stamped artifact at `Ezagent.Cap.issue/3` (routed
> by this same chokepoint), the grantee STOREs it itself (`create/1` self-store or `:vm_internal`
> `absorb_cap`), and load boundaries VERIFY via `Ezagent.Cap.verify/1`. The **I12
> paradigm-lock** now forbids issuer→grantee grant dispatch. Where this doc describes the grant
> as "one dispatch that mutates the grantee slice", read it as the pre-Phase-3 model. **Current
> source of truth:** `.claude/skills/ezagent-developer/references/capbac.md` §4.5 + GLOSSARY
> Decision #162. The rest of this spec (three-role separation, `ctx.caps` as authorizer,
> `granted_by` = accountable entity, the tag set) is unchanged and correct.

**Status:** spec rev 3 — APPROVED to implement (rev 1 RECONSIDER → rev 2 addressed 3
BLOCKERs → 2nd subagent review SHIP-WITH-CHANGES → rev 3 applies the 3 must-fixes +
should-fixes). Ready for PR-1.
**Decision basis:** GLOSSARY Decision #154 ("no unowned permissions") + #153 (grant
authorizer {self, admin, manager-of-target}).
**Program:** CapBAC "no unowned caps" step ③ — chokepoint first, update test gate, then
migrate the conversions (template-materialize family, feishu-binding-policy) through it.

---

## 1. Problem

A capability grant has **three distinct roles** the current code conflates:

| role | meaning | mechanism today |
|------|---------|-----------------|
| **caller** | the code path that invokes the grant (HTTP handler, reconciler, assembly effect — often not a person) | `ctx.caller` |
| **authorizer** | *what makes the grant permitted* | **`ctx.caps`** — the cap set the dispatch carries (NOT `ctx.caller`; verified: `check_grant_authorized/2` + `holds_admin_caps?`/`holds_manage_over_target?`/`require_workspace_admin` all read `ctx.caps`; `ctx.caller` is used only for the `caller == owner` self-check) |
| **granter** (`granted_by`) | the real accountable entity recorded on the cap | `granter_from_ctx(ctx)` → `ctx.caller`, fallback admin |

**Two structural problems:**

1. **No single chokepoint.** 15 grant-dispatch sites each independently build the envelope,
   each independently pick `ctx.caps` (the authorizer) AND `granted_by` (the granter). Every
   new site can re-introduce a wrong/non-entity granter. The `no_unowned` gate (#812) only
   catches *Catalog* minters, not a fresh hand-rolled grant site.
2. **The dominant real authorizer is a `system://` principal in `ctx.caps`** while
   `granted_by` is set separately — and at several sites `granted_by` is *itself* a
   non-entity `system://` URI (e.g. `behavior/workspace.ex:776`,
   `session_template.ex`, `template.ex`), directly violating Decision #154 **today**.

This is the heart of Decision #154: the *granter* (provenance) must be a real entity even
when the *authorizer* (the caps that let the grant through the boundary) is, transitionally,
a system principal. The end state removes the system principal as authorizer too (shrinking
`no_unowned` to 0); the chokepoint is what makes that migration safe and prevents regression.

## 2. Goal

One chokepoint all grant/revoke dispatches route through, whose API makes the three roles
**explicit and independently named**, so `granter = caller` is impossible to express and a
non-entity granter is refused:

- The **authorization basis is a closed tagged set**; each tag fixes BOTH which caps load
  into `ctx.caps` (the authorizer) AND the derived `granted_by` (a real entity):

  | tag | `ctx.caps` (authorizer) | `ctx.caller` | derived `granted_by` |
  |-----|-------------------------|--------------|----------------------|
  | `{:held_by, actor}` | `read_caps(actor)` — actor's real cap slice | `actor` | `actor` |
  | `{:admin, admin}` | `read_caps(admin)` (must contain admin authority) | `admin` | `admin` |
  | `{:rule, name, configurer}` | `[]` + `ctx.authorization_rule = name` (rule branch, §3.3) | `configurer` | `configurer` |
  | `{:system, principal, granted_by}` *(transitional)* | `Catalog.caps(principal)` | `principal` | `granted_by` (MUST be entity) |

  `{:held_by, actor}` subsumes self (actor == target owner), admin (actor holds admin
  caps), and **#811 manager-delegation** (actor holds a Manage cap over target) — all decided
  by `ctx.caps` exactly as today. `{:admin, _}` is a convenience alias when the actor is
  known to be admin. `{:system, …}` is the **transitional** tag: it preserves today's
  system-principal *authorization* while forcing `granted_by` to a real **entity** — so
  PR-1 fixes the #154 granter violations everywhere without changing authorization
  semantics. PR-2/PR-3 convert `{:system, …}` calls to `{:rule, …}`/`{:held_by, …}` and the
  principal leaves the Catalog (shrinking `no_unowned`).

- **`granted_by` is derived from the tag** — never a parameter the caller can set to the
  caller, never silently inherited. The chokepoint **explicitly overwrites** the cap's
  `granted_by` (struct update — NOT via `normalize!/2`, which returns a `%Capability{}`
  unchanged and would drop the derived granter) and then **validates it is
  `%URI{scheme: "entity"}`**, else `{:error, {:granter_not_entity, uri}}` (the runtime #154
  guard; fail-closed).

- A **grep invariant gate** forbids constructing a grant/revoke dispatch (literal OR
  variable action) anywhere except the chokepoint module.

Non-goals: changing authorization *semantics* of the held/admin/manager branches (#811,
unchanged); create-time `caps_json` seeding (#808's anon path — a different mechanism,
already #154-compliant); a UI.

## 3. Design

### 3.1 The chokepoint module — `Ezagent.Identity.Grant` (in `ezagent_domain_identity`)

Dep-safe: `ezagent_domain_workspace`, `ezagent_domain_session`, `ezagent_plugin_feishu`,
`ezagent_plugin_liveview` already declare `{:ezagent_domain_identity, in_umbrella: true}` —
routing grants through it creates **no new umbrella edge** (verified; the acyclic/undeclared-
dep gate won't fire).

The sites use **three** dispatch mechanisms (verified), so the chokepoint owns one private
`prepare/3` plus a thin wrapper per mechanism (revoke twins included so the variable-action
builder lives here too):

```elixir
@type authorization ::
        {:held_by, URI.t()}
        | {:admin, URI.t()}
        | {:rule, atom(), URI.t()}
        | {:system, URI.t(), URI.t()}   # {principal, granted_by_entity} — transitional

# CORE — derives ctx.caps + granted_by + rule flag from the tag, overwrites the cap's
# granted_by (struct update), validates it is an entity URI. Returns the canonical
# {target_with_action, cap', ctx'} or {:error, _}. The ONLY place granted_by is derived.
@spec prepare(target :: URI.t(), Ezagent.Capability.t(), authorization, action :: :grant_cap | :revoke_cap) ::
        {:ok, {URI.t(), Ezagent.Capability.t(), map()}} | {:error, term()}
defp prepare(target, cap, authorization, action)

# Imperative wrappers (build envelope + send):
def grant_cap(target, cap, authorization)              # Invocation.dispatch  (mode :call)
def grant_cap_via_router(target, cap, authorization, reply_mode \\ :async)  # Router.dispatch %Cmd
def revoke_cap(target, cap, authorization)             # symmetric

# Effect-constructor wrappers (return effect tuples for behavior handlers):
def grant_cap_effect(target, cap, authorization)       # {:dispatch, %Cmd{}}
def grant_cap_returning_effect(target, cap, authorization, bind_as)  # {:dispatch_returning, %Cmd{}, bind_as:}
def revoke_cap_returning_effect(target, cap, authorization, bind_as) # the security-revoke twin
```

`prepare/3` is the single source of truth; all wrappers delegate to it. `granted_by`
derivation lives **only** in `prepare/3`. **Error policy (rev 3, LOW-N5):** the imperative
wrappers (`grant_cap`, `grant_cap_via_router`, `revoke_cap`) return `prepare/3`'s
`{:error, _}`; the effect-constructor wrappers (`grant_cap_effect`,
`grant_cap_returning_effect`, `revoke_cap_returning_effect`) **raise** on a `prepare/3`
error — an effect site cannot return an `{:error}` tuple as an effect, and a non-entity
granter on a `{:system, p, entity}` tag is a compile-fixed programmer error (fail-fast,
let-it-crash). (System-principal caps are read via `Ezagent.SystemPrincipal.caps/1` /
`Catalog.caps_for!/1` — the §2 table's `Catalog.caps(principal)` is shorthand.) `Ezagent.Identity.grant_cap/3` becomes a
back-compat shim: `grant_cap(e, c, granter_uri)` → `Grant.grant_cap(e, c, {:held_by,
granter_uri})` (behavior-preserving — it already loads `read_granter_caps(granter)` into
`ctx.caps`, which is exactly `{:held_by, actor}`'s semantics).

### 3.2 `prepare/3` details (addresses HIGH-1, MEDIUM-1)

1. derive `ctx.caps`, `ctx.caller`, `granted_by`, and `authorization_rule` per the §2 table;
2. **overwrite** the cap: `cap = %{cap | granted_by: granted_by, granted_at: now}` (explicit
   struct update — `normalize!/2` is NOT used for granter stamping; it ignores the granter
   for a `%Capability{}` and would leave a pre-existing system-principal `granted_by` in
   place);
3. **validate** `match?(%URI{scheme: "entity"}, granted_by)` else `{:error,
   {:granter_not_entity, granted_by}}`. (`Ezagent.Entity.User.admin_uri/0` =
   `entity://system/user/admin` *is* entity-scheme, so the admin fallback passes.)
   **Scope of the `system://bootstrap` fallback removal (rev 3, MEDIUM-N3):** there are
   THREE `bootstrap_granter`-family functions; remove ONLY the one on the grant-handler
   path — `IdentityAdmin.granter_from_ctx`'s `bootstrap_granter_uri`
   (`behavior/identity.ex:479-492`), whose fallback becomes unreachable once `prepare/3`
   always sets `ctx.caller` to an entity. Do NOT touch (a) the create-time self-cap stamper
   `behavior/identity.ex:205` (create-time caps_json seeding — a §2 NON-GOAL, not a grant
   dispatch) or (b) `capability_registry.ex:441`'s `Code.ensure_loaded?` hedge — that hedge
   is a load-bearing umbrella-dep boundary (core has no compile edge to `domain.identity`;
   removing it crashes core-only/test builds). The let-it-crash applies only to (the
   grant-path) case once it is provably reachable only with an entity caller.
4. record `authorization` (the tag, minus secrets) + `granted_by` on the `:cap_granted`
   emit (extends the existing `via_manage` provenance field).

### 3.3 The rule branch in `check_grant_authorized/2` (addresses HIGH-2)

A new clause fires only when `ctx[:authorization_rule]` is set (only `prepare/3` sets it,
only for `{:rule, …}`). It authorizes on the rule's assertion (the caller verified the rule
precondition before the call — e.g. `PublicView.public_view?/1`). **Structural bound (the
fix for HIGH-2):** a rule grant is rejected unless the cap is **concrete-scoped** —

```
rule_cap_bounded?(cap) :=
  cap.kind != :any and cap.behavior != :any and
  (scope_bounded_instance?(cap.instance) or
   (match?(%URI{}, cap.instance) and Capability.action_of(cap) != :any))
```

i.e. a rule may NOT mint `kind: :any` / `behavior: :any`; and an `action: :any` cap is
allowed ONLY when the instance is scope-bounded (`{:within_session/within_workspace/
spawned_by, %URI{}}`). Else `{:error, :rule_grant_must_be_concrete_scoped}`.

**Reachability fix (rev 3, addresses the BLOCKER-1 residue):** `check_action_wildcard_grant_
authorized/2` runs BEFORE `check_grant_authorized/2`, so with `ctx.caps = []` an `action:
:any` rule cap whose instance is a *concrete `%URI{}`* (not scope-bounded) would be rejected
by the wildcard gate before the rule branch is reached. `rule_cap_bounded?` above is
therefore written to **match the wildcard gate's existing logic exactly** — it never permits
the unreachable shape (`action: :any` requires a scope-bounded instance, identical to
`check_action_wildcard_grant_authorized`'s `scope_bounded_instance?` branch). A
scope-bounded cap (e.g. `Session/:any-action/{:within_session, _}`) passes both gates; a
concrete-`%URI{}` instance is allowed only with a concrete action. No change to
`check_action_wildcard_grant_authorized` is needed; the two predicates are consistent by
construction. The rule name is recorded for audit.

**NOTE (rev 4 — code wins, security-review FINDING 1):** orchestrator cap#1/#2
(`agent/_/{:spawned_by}`) are `behavior: :any`, so `rule_cap_bounded?` REJECTS them
(behavior `:any` is not concrete) — they are rule-INELIGIBLE and the implementation
routes them via `{:system, bootstrap, owner}` (genesis authority — same shape as the
owner→orchestrator Manage grant), NOT `{:rule,…}`. Only concrete-`behavior` template caps
(`Template/{:within_workspace}`, orchestrator `:restart`, member create-session) take the
`{:rule,…}` tag. An earlier draft wrongly listed cap#2 under `{:rule}`; do not "fix" the
code back to it.

### 3.4 The grep invariant gate (addresses BLOCKER-3, NIT on teeth)

`apps/ezagent_core/test/invariants/grant_dispatch_chokepoint_test.exs` (ratchet idiom from
`no_unowned_system_principal_grant_test` / `undeclared_umbrella_dep_test`):

- scans every non-test `apps/**/*.ex` for a grant/revoke dispatch construction:
  - literal: `action: :grant_cap` / `action: :revoke_cap` inside a `%Cmd{}`/`%Invocation{}`
    /effect map;
  - **variable** (the BLOCKER-3 evasion): a function whose body builds a `%Cmd{action:
    <var>}` / `%Invocation{}` where the var is constrained `when action in [:grant_cap,
    :revoke_cap]`, and any `with_action(_, :identity, :grant_cap|:revoke_cap)`;
- allowlist = the chokepoint module file ONLY;
- **teeth:** (1) every match is in the chokepoint; (2) allowlist is shrink-only (compile-
  time constant); (3) a new bypass site (literal or variable-action) fails the gate.
- second tooth (runtime #154 guard): a unit test that `prepare/3` refuses any non-entity
  derived `granted_by` (incl. `{:system, p, system://…}` → refused — the granted_by arg of
  `{:system, …}` must be an entity).

### 3.5 Complete site inventory (addresses BLOCKER-2, BLOCKER-3, MEDIUM-3)

15 sites, corrected imperative-vs-effect classification and real authorizer:

| # | site | dispatch API | authorizer today (`ctx.caps`) | PR-1 tag |
|---|------|--------------|-------------------------------|----------|
| 1 | `identity.ex:206` grant_cap/3 | Router %Cmd | granter's real caps | shim → `{:held_by, granter}` |
| 2 | `workspace.ex:874` member create-session cap | Invocation | (verify) | `{:held_by, caller}` or `{:system,…}` |
| 3 | `workspace.ex:917` creator manage cap | Invocation | **bootstrap wildcard** (`Manage :any` needs admin) | `{:admin, creator?}` / `{:system, bootstrap, creator}` |
| 4 | `behavior/workspace.ex:726-794` member-cap **grant+revoke** (variable action, BLOCKER-3) | effect `{:dispatch}` / `{:dispatch_returning, bind_as}` | **`system://template-materialize`**, granted_by **non-entity** | `grant_cap_effect` / `revoke_cap_returning_effect` `{:system, template-materialize, <member's workspace owner entity>}` |
| 5 | `liveview entity_caps_live.ex:34` | Invocation | admin UI caps | `{:held_by, admin}` |
| 6 | `materializer.ex:95` owner orchestrator-Manage (#811) | Invocation | `system://template-materialize` | `{:system, template-materialize, owner}` |
| 7 | `orchestrator/caps.ex:63` cap#1-#4 (incl cap#2 worker-spawn) | Invocation | `system://template-materialize` | `{:system, template-materialize, owner}` |
| 8 | `entity/session_template.ex:671` | Invocation | `system://template-materialize` | `{:system, template-materialize, owner}` |
| 9 | `behavior/template.ex:728` fork owner cap | Router %Cmd (imperative, NOT effect) | `system://template-materialize` | `{:system, template-materialize, owner}` |
| 10 | `behavior/session/membership.ex:207` | Router %Cmd (imperative) | (verify) | `{:held_by, owner}` / `{:system,…}` |
| 11 | `orchestrator/tools/templates.ex:135` | Invocation | (verify) | `{:held_by, owner}` |
| 12 | `feishu binding_policy.ex:253` | Invocation | `system://feishu-binding-policy` | `{:system, feishu-binding-policy, <configurer entity>}` |
| 13 | `rollback.ex:112` revoke (Invocation) | Invocation `:call` | `system://template-materialize` | `revoke_cap` `{:system, template-materialize, owner}` |
| 14 | `orchestrator/caps.ex:120` `revoke_orchestrator_scoped_caps` | Invocation `:call` | `system://template-materialize` | `revoke_cap` `{:system, template-materialize, owner}` |

(PR-1 implementation re-verifies each "(verify)" basis from the live `ctx.caps` before
choosing the tag. #13/#14 are imperative revokes — caught by the literal `action:
:revoke_cap` grep tooth — and route through the `revoke_cap/3` imperative wrapper.) **Every site's `granted_by` becomes a real entity in PR-1** via the tag's
derived granter — fixing BLOCKER-3's and the other non-entity granters immediately, with
authorization semantics unchanged (the `{:system, …}` tag keeps the principal as authorizer).

## 4. PR sequence

- **PR-1** (mechanical, behavior-preserving): introduce `Ezagent.Identity.Grant` (prepare +
  6 wrappers) + the rule branch + the grep gate + the runtime entity guard; migrate ALL 15
  sites to call it; the `{:system, principal, entity}` tag keeps each site's authorization
  identical while forcing an entity `granted_by`. Grep gate green at allowlist=1.
  `no_unowned` **unchanged** (no principal removed yet). Acceptance: gate green; every grant
  site routes through the chokepoint; every `:cap_granted` emit has an **entity** granted_by.
- **PR-2 (as implemented, rev 4)** demote `template-materialize` from a grant MINTER:
  drop its `grant_cap`/`revoke_cap` (and grant-path `Workspace:any`) caps — it stays in the
  Catalog as a NON-minter for its legitimate `template.read`/write dispatch authority, so it
  falls out of the `no_unowned` minter set. Each grant/revoke site picks its tag by cap shape:
  concrete-`behavior` caps (`Template/{:within_workspace}`, orchestrator `:restart`, member
  create-session — sites #4/#8/#9/#11/#13) → `{:rule, :template_materialize/:workspace_membership,
  owner|admin}`; `behavior: :any` orchestrator cap#1/#2 + the owner→orchestrator Manage (sites
  #6/#7) → `{:system, bootstrap, owner}` (genesis — rule-ineligible). `granted_by` is the owner
  (or admin extreme-fallback) entity in every case. Then shrink the `no_unowned` allowlist
  (drop `template-materialize`, leaving only `feishu-binding-policy`).
- **PR-3** convert `feishu binding_policy` (#12) → `{:rule, :feishu_binding, configurer}`.
  The configurer URI (the bind operator, `admin_uri`) is **already threaded** to the call
  site — `binding_policy.apply(user_uri, admin_uri)` carries it down to the grant
  (`binding_policy.ex:87 → 199 → 252`) where it is currently *discarded* as `_admin_uri`
  (rev 3 correction, MEDIUM-N2: no new plumbing needed — PR-3 just stops dropping it and
  passes `{:rule, :feishu_binding, admin_uri}`). Remove `feishu-binding-policy` from the
  Catalog → `no_unowned` allowlist reaches **0**.

Each PR: TDD, full gate suite, **subagent adversarial-review** (NOT codex — Allen 2026-06-17),
admin-merge.

## 5. Testing

- `grant_dispatch_chokepoint_test.exs` — the grep ratchet (3.4), incl. variable-action teeth.
- `Grant` unit tests: each tag derives correct `ctx.caps` + `granted_by`; non-entity granter
  refused (incl. `{:system, p, system://…}`); a `%Capability{}` arriving with
  `granted_by: system://…` is **overwritten** to the entity (HIGH-1 regression); `{:rule,…}`
  sets the rule flag; `rule_cap_bounded?` rejects kind/behavior/instance `:any` (HIGH-2);
  the `{:held_by, manager}` path still authorizes a #811 manager-delegated grant.
- existing `no_unowned_system_principal_grant_test.exs` stays green; shrinks in PR-2/PR-3.
- per-site behavior tests stay green (PR-1 is behavior-preserving by the `{:system,…}` tag).

## 6. Acceptance

Program-level (after PR-3): (1) grep gate passes, allowlist = chokepoint only; (2) no
non-test file outside the chokepoint constructs a grant/revoke dispatch (literal or
variable); (3) every `:cap_granted` emit carries an `authorization` tag + an **entity**
`granted_by`; (4) `no_unowned` allowlist empty. PR-1 satisfies (1)(2)(3); (4) lands in PR-3.
