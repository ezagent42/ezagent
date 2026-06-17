# Unified Grant Chokepoint — design

**Status:** spec (Allen-approved direction 2026-06-17; awaiting spec-review gate)
**Decision basis:** GLOSSARY Decision #154 ("no unowned permissions") + #153 (grant
authorizer {self, admin, manager-of-target}).
**Program:** CapBAC "no unowned caps" step ③ — build the chokepoint first, update the
test gate, then migrate the remaining conversions (feishu-binding-policy,
template-materialize/cap#2) through it.

---

## 1. Problem

A capability grant has **three distinct roles** that the current code collapses into one
`ctx.caller` / `granter_uri` value:

| role | meaning | today |
|------|---------|-------|
| **caller** | the code path that mechanically invokes the grant (an HTTP handler, a boot reconciler, an orchestrator-assembly effect — often not a person) | `ctx.caller` |
| **authorizer** | the basis the grant is permitted on: a held cap, admin status, manager-delegation, **or a rule** | `check_grant_authorized/2` reads `ctx.caller` |
| **granter** (`granted_by`) | the real, accountable entity the cap is recorded under | `granter_from_ctx(ctx)` = `ctx.caller` (fallback admin) |

In the manual case (an owner grants a member a cap) all three coincide, so the conflation
is invisible. It breaks for **rule-driven auto-grants**: the caller is an automated path
with no business being the accountable entity, and the authorizer is a *rule* (e.g.
`public_view == true`), not the caller's held caps. The accountable entity is whoever
*configured the rule* — the session owner. This is precisely the `#808` anon-access and the
`feishu-binding-policy` / `template-materialize` cases.

The structural problem: **there is no single grant chokepoint.** ~13 sites
(`grep "action: :grant_cap" / ":identity, :grant_cap"`) each independently construct the
grant-dispatch envelope and each independently decide the granter. Every new site can
re-introduce the `granter = caller` trap. The `no_unowned` ratchet gate (#812) catches
*system-principal* minters but does not stop a fresh hand-rolled grant site from stamping a
non-entity / wrong granter.

## 2. Goal

One chokepoint that **all** grant sites route through, whose API makes `granter = caller`
**structurally impossible to express**:

- `granted_by` is never defaulted from the caller. It is **derived from an explicit,
  tagged authorization basis** — the dev cannot omit it.
- The authorization basis is one of a small closed set, each of which fixes the granter:
  - `{:held_by, actor_uri}` — `actor_uri` holds the cap / is the target's owner /
    is manager-delegated (the #811 path). `granted_by = actor_uri`.
  - `{:admin, admin_uri}` — admin authority. `granted_by = admin_uri`.
  - `{:rule, rule_name, configurer_uri}` — a rule-driven auto-grant; `rule_name` is the
    rule (e.g. `:public_view`, `:feishu_binding`, `:orchestrator_template`),
    `configurer_uri` is whoever configured it. `granted_by = configurer_uri`.
- The chokepoint **rejects a non-entity granter at runtime** (`granted_by` MUST be
  `%URI{scheme: "entity"}`; a `system://…` granter is refused) — Decision #154 enforced on
  the runtime grant path, not just the static Catalog audit.
- A **grep invariant gate** forbids constructing an `:identity, :grant_cap` dispatch
  envelope anywhere except the chokepoint module.

Non-goals: changing the *authorization* semantics for the existing held/admin/manager
branches (those are #811, unchanged); changing create-time `caps_json` seeding (a different
mechanism — #808's anon path; already #154-compliant); a UI.

## 3. Design

### 3.1 The chokepoint module — `Ezagent.Identity.Grant`

Lives in `ezagent_domain_identity` (it dispatches `identity.grant_cap`, the same domain as
`Ezagent.Identity.grant_cap/3` today). Two faces, because grant sites split into imperative
callers and behavior handlers that *return* an effect:

```elixir
@type authorization ::
        {:held_by, URI.t()}
        | {:admin, URI.t()}
        | {:rule, atom(), URI.t()}

# Imperative — for plain callers (workspace.ex, feishu binding_policy, liveview,
# orchestrator tools). Builds the dispatch + sends it the same way Identity.grant_cap/3
# does today.
@spec grant_cap(target :: URI.t() | String.t(), Ezagent.Capability.t() | map(), authorization) ::
        {:ok, term()} | {:error, term()}
def grant_cap(target, cap, authorization)

# Effect constructor — for behavior handlers that return a dispatch effect
# (template.ex, membership.ex, orchestrator/caps.ex, materializer.ex, session_template.ex).
# Returns the canonical `{:dispatch, target, %{action: :grant_cap, cap: ...}, opts}` effect
# (exact effect shape per the dispatch-returning-effect SPEC), never hand-rolled.
@spec grant_cap_effect(target :: URI.t(), Ezagent.Capability.t() | map(), authorization) ::
        Ezagent.Effect.t()
def grant_cap_effect(target, cap, authorization)
```

Both call one private `build/3` that:
1. derives `granted_by` from the authorization tag (`held_by`→actor, `admin`→admin,
   `rule`→configurer);
2. **validates** `granted_by` is `%URI{scheme: "entity"}` — else `{:error,
   {:granter_not_entity, granted_by}}` (fail-closed; the runtime #154 guard);
3. stamps `granted_by` onto the cap (`Capability.normalize!/2`);
4. sets the dispatch `ctx` so the downstream authz check sees the right basis:
   - `:caller` carries the actor (for `held_by`/`admin` — the existing
     `check_grant_authorized/2` branches are unchanged);
   - for `{:rule, rule_name, _}` the ctx carries `authorization_rule: rule_name`, which
     activates a **new rule branch** in `check_grant_authorized/2` (3.2).
5. records `authorization` (the tag) + `granted_by` on the `:cap_granted` emit for audit
   (extends the existing `via_manage` provenance field).

`Ezagent.Identity.grant_cap/3` becomes a thin back-compat shim that maps the old
`granter_uri` 3rd arg to `{:held_by, granter_uri}` (preserving today's behavior) and
delegates to `Grant.grant_cap/3`. It is deprecated in favor of the explicit-authorization
arity; the grep gate (3.3) does not flag it because it routes through the chokepoint.

### 3.2 The rule branch in `check_grant_authorized/2`

A new clause: when `ctx[:authorization_rule]` is set (only the chokepoint sets it, only for
`{:rule, …}`), authorization is granted on the rule's assertion — the caller is responsible
for having verified the rule's precondition before calling (e.g. `PublicView.public_view?/1`
returned true). The cap is **still** subject to `check_action_wildcard_grant_authorized/2`
(a rule may NOT mint a full-wildcard cap; rule-granted caps must be scope-bounded or
concrete-instance). The rule name is recorded for audit. This is the same structural
authorization branch #808 introduced for `public_view`, generalized so every rule-driven
grant expresses itself uniformly.

### 3.3 The grep invariant gate

`apps/ezagent_core/test/invariants/grant_dispatch_chokepoint_test.exs` (modeled on the
existing `no_unowned_system_principal_grant_test.exs` / `undeclared_umbrella_dep_test`
ratchet pattern):

- scans every non-test `apps/**/*.ex` for a grant-dispatch construction signature
  (`action: :grant_cap` in a dispatch map, or `with_action(_, :identity, :grant_cap)`);
- the allowlist is the chokepoint module file only (`…/identity/grant.ex`);
- **teeth:** (1) every match is either in the chokepoint or in the allowlist; (2) the
  allowlist is shrink-only (a CI-checkable constant); (3) a new bypass site fails the gate.

A second tooth, the runtime #154 guard: a unit test that `Grant.build/3` refuses a
`{:rule, _, system_uri}` / any non-entity granter.

### 3.4 Migration (the ~13 sites)

PR-1 introduces the module + gate and migrates every **currently-correct** site to call it,
seeding the allowlist at the chokepoint only (all real sites move through it the same day):

| site | today's basis | new authorization |
|------|---------------|-------------------|
| `identity.ex:grant_cap/3` | `granter_uri` | shim → `{:held_by, granter_uri}` |
| `workspace.ex:874/917` (member create-session cap; creator manage cap) | caller=owner/admin | `{:held_by, caller}` |
| `liveview entity_caps_live.ex:34` | admin UI | `{:held_by, admin}` |
| `session_creator/materializer.ex:95` (owner orchestrator Manage, #811) | owner | `{:held_by, owner}` |
| `behavior/template.ex:731`, `session/membership.ex:209` | effect, owner | `grant_cap_effect` `{:held_by, owner}` |
| `entity/session_template.ex:671`, `orchestrator/tools/templates.ex:135` | owner | `{:held_by, owner}` |

The two **conversions** ride later PRs (their authorization tag is the whole point):

| site | today (violation) | conversion |
|------|-------------------|-----------|
| `orchestrator/caps.ex:63` (cap#2 worker-spawn) | `system://template-materialize` | `{:rule, :orchestrator_template, owner}` — removes `template-materialize` from the `no_unowned` allowlist |
| `feishu binding_policy.ex:253` | `system://feishu-binding-policy` | `{:rule, :feishu_binding, binding_configurer}` (the admin who configured the binding, NOT the bound user) — removes `feishu-binding-policy` |

When both convert, the `no_unowned` allowlist reaches 0 and the chokepoint allowlist is the
single module — both gates closed.

## 4. PR sequence

- **PR-1** chokepoint module + rule branch + grep gate + runtime #154 guard + migrate all
  currently-correct sites. No `no_unowned` change (no system principal converted yet); the
  new grep gate goes green at allowlist=1.
- **PR-2** convert `orchestrator/caps.ex` cap#2 → `{:rule, :orchestrator_template, owner}`;
  shrink `no_unowned` allowlist (drop `template-materialize`).
- **PR-3** convert `feishu binding_policy.ex` → `{:rule, :feishu_binding, configurer}`;
  shrink `no_unowned` allowlist to 0.

Each PR: TDD, full gate suite, `/codex:adversarial-review`, admin-merge.

## 5. Testing

- `grant_dispatch_chokepoint_test.exs` — the grep ratchet (3.3).
- `Grant` unit tests — each authorization tag derives the correct `granted_by`; non-entity
  granter refused; `{:rule, …}` activates the rule branch; a rule cannot mint a wildcard
  (goes through `check_action_wildcard_grant_authorized`).
- the existing `no_unowned_system_principal_grant_test.exs` stays green throughout; shrinks
  in PR-2/PR-3.
- per-site: the migrated sites keep their existing behavior tests green (the shim + tag
  mapping is behavior-preserving for the held/admin sites).

## 6. Acceptance

(1) `grant_dispatch_chokepoint_test` passes with allowlist = the chokepoint module only;
(2) no non-test file outside the chokepoint constructs an `:identity, :grant_cap` dispatch;
(3) every `:cap_granted` emit carries an `authorization` tag + an entity `granted_by`;
(4) after PR-3 the `no_unowned` allowlist is empty.
