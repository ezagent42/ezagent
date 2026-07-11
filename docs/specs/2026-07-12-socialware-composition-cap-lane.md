# SPEC — Socialware composition-cap lane

> **Status:** SPEC (architecture-level, pre-implementation). Design for Allen to approve, then
> codex to implement. This doc resolves mechanism at the DESIGN level; incidental file:line is
> demoted to impl-constraint notes (§9) — the code wins.
> **Baseline:** `origin/main` @ `fa72d36ba`. Every file:line below re-verified on that tree.
> **Read before implementing:** `.claude/skills/ezagent-developer/references/capbac.md` (the three
> roles caller/authorizer/granter, the `Ezagent.Identity.Grant` chokepoint, the tag set,
> `rule_cap_bounded?`, Decision #154).
> **Origin:** jjkysy PR #1355 (`docs/authz-composition-cap-gap`) — handoff
> `docs/together/2026-07-11/handoffs/socialware-composition-cap-gap.md`. §7 below answers that
> handoff's §五 拍板项 verbatim.

---

## 0. Baseline correction (read first — the brief's cbac primitives are unmerged)

The task brief frames this lane as "building on cbac Phase-3" and names `Ezagent.Cap.issue/3`
(`cap.ex:30`), `RecipeCapBinding.issue_and_upsert` / `create/1` self-store, and `CapAbsorbAwait`
as **already provided**. **Re-verified on `fa72d36ba`: none of these exist as merged code.**

- The Phase-3 HEAD commit `fa72d36ba` ("test(e2e): prove Phase 3 cap self-store flows") adds
  **only** screenshots + a README under `docs/together/2026-07-11/phase3-cbac-done-right/` — zero
  `lib/` changes.
- `grep -rn 'def issue' apps/ezagent_core/lib/ezagent/capability.ex` → no match; there is no
  `ezagent/cap.ex` (only `capability.ex`). `grep -rln 'RecipeCapBinding\|CapAbsorbAwait' apps` → no
  match. No `Cap.issue`/`Cap.verify` non-test caller.
- `Cap.issue`/`RecipeCapBinding`/`CapAbsorbAwait` appear only in the **unmerged** spec
  `docs/specs/2026-07-10-cap-self-store-unification-phase3.md`. That is the ISSUE/STORE/VERIFY
  design; it has not landed.

**Consequence for this spec:** the composition-cap lane is designed on the machinery that IS
merged and verified present:

1. `Ezagent.Identity.Grant` — the single grant/revoke chokepoint (`grant.ex`), with the closed
   tag set `{:held_by,·}` / `{:admin,·}` / `{:rule, name, owner}` / `{:genesis, owner}`. This is
   the real ISSUE seam. Owner-as-granter (#154) is already expressible via `{:rule, name, owner}`.
2. The **`instance_overrides` seam** on `GrantRecipeCaps.grant_recipe_caps/4`
   (`ezagent.agent.grant_recipe_caps.ex:137-233`) — the code's own `★core gap★` (:118-135) with
   zero production caller.
3. The **orchestrator precedent** — `Ezagent.Entity.Session.Orchestrator.Caps.build_desired_caps/4`
   (`caps.ex:148`) + `grant_tag_for/2` (:120): a working lane that mints scope-bounded caps under
   `granted_by: owner_uri` via `{:rule, :template_materialize, owner}` / `{:genesis, owner}`, and
   already emits `kind: :session` via `{:within_session, session_uri}`.

STORE and VERIFY, on merged main, are simply: the grant chokepoint dispatches into the target
entity's `:caps` slice (durable via the `caps_json` projection), and dispatch step 5.5 reads it
back. This spec needs no new store/verify primitive. If Phase-3's `Cap.issue`/self-store later
merges, the lane's mint call re-points at it with no change to the declaration or wiring design.

> **Action for the coordinator:** the brief was written against the Phase-3 spec's vocabulary, not
> merged code. This spec substitutes the verified-present equivalents. Flag if Phase-3 was expected
> to be merged first — the lane does not depend on it, but the framing differs.

---

## 1. Problem

A socialware `Definition` can declare that role **A** should be able to operate role **B**'s
action **X** ("the kanban-assistant drives the board; the autoservice orchestrator queries the
kb"). The platform has **no supported lane** to turn that declared relationship into a **narrow
capability that points at B's live instance**. Every shipped socialware that needs cross-member
operation falls back:

| socialware | cross-member need | how it "works" today | verdict |
|---|---|---|---|
| **kanban** | assistant → board | docstring promises `EzagentPluginKanban.PmCoordinatorSeed` mints a board-scoped cap — **that file does not exist on main** (`grep -rn 'defmodule.*PmCoordinatorSeed'` → none; only two docstring *references*). E2e runs on admin/owner master-key. | ❌ fallback |
| **autoservice** | orchestrator → kb | hand-written `scripts/autoservice_tier1_seed.exs` explicitly grants `kb.query` (:21). | ❌ fallback — the exact "hand-write bindings" smell the boundary doc names |
| **hello** | front-desk (responser) → builder | `Ezagent.Capability.admin_genesis_cap()` — a 5-axis wildcard (`capability.ex:244`, `kind/behavior/action/instance/workspace = :any`). | ❌ fallback (privileged relay) |
| **dealscout** | assistant → data host | copies kanban's shape; dead-ends (kind + instance double-mismatch, §6). | ❌ wall |
| **orchestrator** | → session members | `grant_orchestrator_scoped_caps` mints owner-granted `{:within_session}` caps — but a hook **hardcoded to the orchestrator role** (`definition_agents.ex:352-354` `orchestrator_recipe_slot?`). | ⚠ half-right; unreachable by ordinary socialware |

`docs/together/contributing/socialware-data-deployment-boundary.md:48-49` states the principle:
> "any need to … hand-write working-copy bindings **is treated as evidence that a supported
> install/runtime path is missing**."

The four fallbacks are that evidence. The engine seam (`instance_overrides`) and the granter rule
(#154) already exist; what is missing is (a) a **declaration** of the relationship, (b) the
**materialize wiring** that drives the seam, and (c) a decision on the **Kind axis**.

---

## 2. The model this lane preserves: can-FIND ≠ can-OPERATE

The lane must **not** lighten the dispatch guardrail. Two layers are deliberately separate:

- **can-FIND (routing / addressing).** `routing_rules` + `legends` (`Definition` fields
  `definition.ex:23,25,51,53`) + the URI schemes decide **who a message reaches**. This is a
  discovery/delivery concern. Being routable to B, or being able to construct B's URI, is NOT
  authority over B.
- **can-OPERATE (authorization).** Dispatch step 5.5 (`kind/runtime.ex`, the sole
  Behavior×Entity chokepoint, grep-gated by `cap_check_only_at_chokepoint_test.exs`) derives the
  **needed** cap by substituting the target's **concrete instance URI**
  (`resolve_required_cap` → `Ezagent.URI.instance(target)`) and matches it against the caller's
  held caps by **exact instance equality** (`capability/match.ex`). A cap that points at *self*
  structurally cannot open *another agent's* lock.

This split is a real confused-deputy / workspace-isolation defense: "can address B ≠ can operate
B." **The lane adds a narrow can-OPERATE cap; it changes nothing about can-FIND, and it never
relaxes the exact-instance match.** Composition is orthogonal to authorization by design — a
composed-in socialware must NOT be able to operate a member it was not declared to operate.

---

## 3. Design: the composition-cap lane

Three parts — a declaration field, materialize wiring, and the granter — riding on the
verified-present machinery of §0.

### 3.1 Declaration (a NEW directed field — not routing/legend reuse)

Add a minimal **directed** relationship to the socialware `Definition`. **Do NOT reuse
`routing_rules` or `legends`** — those are can-FIND; folding can-operate into them collapses the
§2 split (jjkysy §四.1 flags the same trap).

**Recommended shape — `operates` on the agent role_slot:**

```yaml
roles:
  - role_name: kanban-assistant
    fill: agent
    recipe: kanban-assistant
    flavor: cc-headless
    operates:
      - role: board            # a target ROLE NAME in this same Definition
        behavior: Ezagent.ActionSet.Kanban
        action: mutate         # a CONCRETE action (not :any) — see §5
```

Semantics: *"the member filling `kanban-assistant` may dispatch `behavior.action` to the member
filling role `board`."* Each entry names a **target role in the same Definition** — never a URI
(the `Definition` never carries instance URIs; `reject_participant_instance_uris`
`definition.ex:85`). Directed and per-source: it reads as "this role operates …", co-located with
the role that receives the cap.

Validation extends `role_slot/1` (`definition.ex:280`) with an optional `operates` list, each entry
requiring a non-empty `role` (string), a `behavior` (module, via the existing `behavior_list`
validator style), and a concrete `action` atom. The current validator **silently drops unknown
keys** (it reconstructs a fixed-key map at :291), so an authored `operates` today is discarded —
the field must be parsed explicitly.

Alternative (documented, not recommended): a top-level `compositions: [%{from:, to:, behavior:,
action:}]`. Equivalent expressive power; `operates`-on-role_slot is preferred for locality. Either
is a NEW field — the design's fixed point is *directed, concrete-action, references a role name*.

**Consequence — composition targets must be materialized roles.** `operates.role` is resolved to a
live member URI at materialize time via `Members.role_name_to_uri/2`
(`behavior/session/members.ex:84`, already used by `definition_agents.ex:601`). Therefore the
**target must be a role slot** in the Definition. This is the "data-as-a-role" model (§5/§6): the
kanban board and the autoservice kb become **agent role slots** so `role_name_to_uri` resolves
them — which is exactly what makes the cap mintable.

### 3.2 Materialize wiring (drive the seam under owner authority)

Today's socialware materialize (`SessionCreator.DefinitionAgents.materialize_definition_agents/4`,
`definition_agents.ex:85`) already threads `granted_by` (the **session owner**) end-to-end and
resolves role_name→URI. The gap: the per-agent recipe-cap grant (`grant_recipe_caps/2`, :550 →
`GrantRecipeCaps.grant_recipe_caps/3`, :551) passes **no** `instance_overrides` (every recipe cap
self-scoped, :217) and issues under **admin** authority (`grant_all` uses
`Ezagent.Entity.User.admin_uri()` :210 via `Ezagent.Identity.grant_cap/3`, the back-compat shim →
`{:held_by, admin}` per capbac.md §4 — *not* `{:admin, admin}`; brief wording corrected here).

**Wiring:** after each role's members are joined, add a composition step that, for every role
carrying `operates`:

1. resolves each `operates.role` → target member URI (`Members.role_name_to_uri/2`);
2. builds the **target-scoped** map `%{behavior_module => target_uri}` — the exact shape the
   `instance_overrides` seam consumes (`ezagent.agent.grant_recipe_caps.ex:124-135`,:217);
3. mints one **concrete** cap per `operates` entry — `kind` per §5, `behavior` = the entry's
   module, `action` = the entry's concrete action, `instance` = `URI.instance(target_uri)`,
   `workspace_uri` = `Capability.workspace_of(target_uri)` — and grants it to the **source** member
   under owner authority (§3.3).

The cap is minted at the source member's URI, scoped to the target's instance — the same
target-scoping the `instance_overrides` seam expresses. Whether codex implements this by
parameterizing `grant_recipe_caps/4`'s granter/kind and feeding it the resolved overrides, or as a
sibling owner-authority mint modelled on the orchestrator lane, is an impl choice (§9) — the design
fixes only: **target-scoped, owner-granted, concrete, minted at the source member.**

### 3.3 Granter = the owner, via `{:rule, :socialware_composition, owner}`

Per Decision #154 (`GLOSSARY` #154; capbac.md §1/§4): an auto-grant is driven by a RULE, and the
granter is **whoever configured the rule** — here the **owner** who installed the socialware /
owns the session (already in hand as `granted_by`). Not admin, not a `system://` principal.

Use the tag `{:rule, :socialware_composition, owner}` (a new named rule, mirroring the
orchestrator's `{:rule, :template_materialize, owner}`, `caps.ex:133`). A composition cap is
**rule-eligible** because `rule_cap_bounded?` (`behavior/identity.ex`, capbac.md §5) admits a
concrete-`%URI{}` instance with a **concrete action** (`kind ≠ :any`, `behavior ≠ :any`,
`action ≠ :any`) — which is exactly the §3.1 shape. This is why §3.1 requires a concrete action.

`granted_by` is validated `%URI{scheme: "entity"}` at the chokepoint; the owner entity passes.

---

## 4. Invariants (what CI / the design must hold)

1. **Least-privilege, never wildcard.** Every composition cap is concrete on all five axes
   (`kind` concrete, `behavior` concrete, `action` concrete, `instance` = target's concrete URI,
   `workspace_uri` concrete). It does **not** relax `no_wildcard_system_principals_test` or
   `no_unowned_system_principal_grant_test`, and a dispatch to an **unrelated** instance is denied
   (the exact-instance match fails). The `admin_genesis_cap` wildcard fallback is retired for these
   paths, not generalized.
2. **`granted_by` = a real owner entity** (`%URI{scheme: "entity"}`), via `{:rule,
   :socialware_composition, owner}`. Never admin-as-granter, never a `system://` principal
   (#154). Enforced by the chokepoint's entity validation.
3. **can-FIND unchanged.** No change to `routing_rules`, `legends`, URI schemes, or the routing
   layer. The lane only adds a can-OPERATE cap.
4. **Dispatch guardrail intact.** Step 5.5, `resolve_required_cap`, and the exact-instance
   `match.ex` are untouched. The lane satisfies the guardrail with a correctly-scoped cap; it does
   not bypass or soften it.
5. **Declared-only.** A member may operate another **only** where the Definition declares it. No
   `operates` entry ⇒ no cross-member cap (self-scoped recipe caps only, as today).
6. **Fail-closed, no partial** — inherit `grant_recipe_caps`'s existing contract: an unresolvable
   target role (no live member for `operates.role`) or unloaded behavior fails LOUD, granting
   nothing (never a silently-dead cap).
7. **Chokepoint-only.** Every mint goes through `Ezagent.Identity.Grant` (grep-gated by
   `grant_dispatch_chokepoint_test.exs`). No hand-built grant dispatch.
8. **Idempotent** on the repair/re-materialize path (mirror `cap_equal_ignoring_metadata?`,
   `caps.ex:200`).

---

## 5. Answers to jjkysy PR #1355 §五 (拍板项)

> Verbatim decisions from `socialware-composition-cap-gap.md` §五. Recommendations follow; the two
> genuine forks are re-surfaced in §6 for Allen.

**决策 1 — Do we accept the gap is worth a proper lane (vs tolerating admin/script fallback)?**
**Recommend: YES.** Four shipped socialware fall back today; the boundary doc names hand-written
bindings as a missing-path signal; kanban assistant→board and autoservice→kb have **no** correct
path without it (data hosts can't self-execute — §6). The engine seam already exists and is
labelled `★core gap★` with zero callers. Filling it converges toward Decision #154 (retire the
`system://`/admin fallbacks), not away.

**决策 2 — (a) how to declare, (b) how to pick the granter, (c) extend Kind axis to session?**
- **(a) Declaration:** a **NEW directed field**, `operates` on the agent role_slot (§3.1). **Do
  not reuse legend/routing** (that collapses can-find vs can-operate). Concrete action, references
  a role name.
- **(b) Granter:** the **owner** (session owner / installer) via `{:rule, :socialware_composition,
  owner}` (§3.3) — #154-clean, mirrors the orchestrator precedent. (Fork vs today's `{:held_by,
  admin}` — §6.2.)
- **(c) Kind axis:** **prefer data-as-agent so the common path stays `kind: :agent`; support
  `kind: :session` only as a second, deferred sub-lane where the action host is naturally a
  session.** Do NOT force session-host actions through the agent-only `grant_all` seam. (This is a
  genuine fork — §6.1.)

**决策 3 — Also lift kanban assistant→board from fallback to the proper lane?**
**Recommend: YES.** Model the board as a **data-as-agent** role slot; declare
`kanban-assistant operates board`; delete the admin/owner master-key path. jjkysy's judgment
(§三.3, §五.3) — this is the board's **only** correct path (the board is a passive data host that
cannot receive chat and self-execute) — holds against the code. This is the reference
implementation of the lane.

---

## 6. Open questions / forks for Allen

### 6.1 Kind axis — the genuine fork (resolved-with-recommendation)

`grant_all` hardcodes `kind: :agent` (`ezagent.agent.grant_recipe_caps.ex:223`). Three options:

- **(a)** Extend the recipe-cap seam to emit non-`:agent` kinds (parameterize `grant_all`).
- **(b)** Mint the composition cap directly on the orchestrator's scope-bounded path (which already
  emits `kind: :session` via `{:within_session}`, `caps.ex:161-169`), bypassing `grant_all`.
- **(c)** "Data-as-a-standalone-agent" — make board/kb **agent** role slots so every composition
  target is `kind: :agent` and the existing seam fits unchanged.

**Recommendation: (c) as the default + (b) as a bounded second sub-lane.** Make data hosts agent
roles (kanban board, autoservice kb) → the common lane needs **no** kind change and reuses the seam
as-is. Reserve `kind: :session` (via the orchestrator's scope-tuple path) for the rare case where
the action genuinely lives on the session host (dealscout `crawl_now`); **do not** force
session-host actions through the agent-only seam (that's the double-mismatch that dead-ends
dealscout — §1). dealscout defers via **lane ①** (role self-execution + routing) short-term and is
not a blocker.

### 6.2 Granter — `{:held_by, admin}` (today) vs `{:rule, :socialware_composition, owner}` (proposed)

Today the recipe-cap grant runs under admin (`grant_all` :210, `{:held_by, admin}`). The lane
proposes owner-as-granter via `{:rule, …, owner}` (§3.3), which is #154-clean and matches the
orchestrator precedent. **Recommendation: owner via `{:rule, :socialware_composition, owner}`.**
Confirm with Allen (it changes the accountable granter on these caps and adds a named rule to the
`{:rule, …}` set). Note: this granter change is scoped to **composition** caps; self-scoped recipe
caps may stay as-is or move to owner separately (out of scope here).

### 6.3 Declaration placement — `operates` on role_slot vs top-level `compositions`

Recommended `operates` on role_slot (§3.1) for locality. Top-level `compositions` is the
alternative if Allen prefers a single relationship table. Cosmetic vs the design's fixed point.

---

## 7. Impl-constraints (for codex — not design decisions)

- **Declaration parse:** extend `role_slot/1` (`definition.ex:280`) — the validator reconstructs a
  fixed-key map (:291) and silently drops unknown keys, so `operates` must be parsed and validated
  explicitly (non-empty `role` string; `behavior` a loadable module; `action` a concrete atom,
  reject `:any`). Reject any `operates` entry that names a `role` not present in `roles`.
- **Target resolution:** reuse `Members.role_name_to_uri/2` (`behavior/session/members.ex:84`), the
  same resolver `definition_agents.ex:601` uses. Fail LOUD if a declared target role has no live
  member (fail-closed, no partial — mirror `grant_recipe_caps` :207/:230).
- **Ordering:** mint composition caps **after** the target role's member has joined (the target URI
  must exist). Slot into `materialize_one`/`materialize_fresh_agent` after `join_or_cleanup`, or as
  a post-batch pass once all roles are materialized (a composition may point at a role that
  materializes later in the batch — a post-batch pass is safer).
- **Granter threading:** `granted_by` (session owner) is already a parameter of
  `materialize_definition_agents/4` (:88) — thread it to the composition mint. Tag `{:rule,
  :socialware_composition, owner}` via `Ezagent.Identity.Grant` (never `Identity.grant_cap/3`, the
  admin shim).
- **Kind:** default `:agent` (data-as-agent targets). Any `kind: :session` sub-lane follows
  `Orchestrator.Caps.build_desired_caps` (`caps.ex:148-185`) — scope-tuple `{:within_session,·}`
  with `{:genesis, owner}`/`{:rule, …, owner}` per `grant_tag_for/2` (:120).
- **`rule_cap_bounded?` reachability:** a concrete-`%URI{}` + concrete-action cap must pass
  `check_action_wildcard_grant_authorized/2` **before** the rule branch is reached (capbac.md §5) —
  it does, because it is not an `action:any` grant.
- **Idempotency:** reuse `cap_equal_ignoring_metadata?` (`caps.ex:200`) to skip re-grants on
  repair.
- **Gates to run:** `grant_dispatch_chokepoint_test`, `no_wildcard_system_principals_test`,
  `no_unowned_system_principal_grant_test`, `mix ezagent.check_invariants`,
  `mix ezagent.socialware.check`, plus touched-app tests + full suite before merge.

---

## 8. Staged PR plan

1. **PR-1 — declaration field.** Add + validate `operates` on the agent role_slot
   (`definition.ex`). Manifest schema doc + `mix ezagent.socialware.check` awareness. Round-trip
   test (authored `operates` survives `Definition.new/1`). No behavior yet. *(pure schema)*
2. **PR-2 — materialize wiring.** Resolve `operates` targets → URIs, mint target-scoped composition
   caps under `{:rule, :socialware_composition, owner}` in socialware materialize (`kind: :agent`).
   Fail-closed + idempotent. Unit + a socialware-materialize integration test proving a source
   member holds a board-scoped cap and can dispatch to the board while an unrelated instance is
   denied (the §2 invariant, as a failing-without-the-lane test).
3. **PR-3 — lift kanban + delete autoservice hand-grant.** Model kanban `board` as a data-as-agent
   role slot; declare `kanban-assistant operates board`; remove the admin/owner master-key path.
   Convert autoservice kb to a role slot; declare `orchestrator operates kb`; **delete
   `scripts/autoservice_tier1_seed.exs`**'s `kb.query` hand-grant. E2e: assistant→board and
   orchestrator→kb both authorized by the minted narrow cap, no fallback.
4. **Deferred — `kind: :session` sub-lane + dealscout.** Only if/when a session-host action host is
   needed. dealscout uses **lane ①** (role self-execution + routing) short-term; not a blocker.
   hello front-desk→builder can migrate onto the lane in a follow-up (retire its
   `admin_genesis_cap` relay) once PR-2 lands.

---

## 9. Primary evidence (re-verified on `fa72d36ba`)

- Declaration schema: `apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex` — struct
  fields `:12-29` (`roles`, `routing_rules`, `legends`); `role_slot/1` validator `:280-308`
  (fixed-key reconstruct at :291, no `operates`).
- The `★core gap★` + `instance_overrides` seam:
  `apps/ezagent_domain_agent/lib/mix/tasks/ezagent.agent.grant_recipe_caps.ex` — docstring
  `:118-135`, `grant_recipe_caps/4` `:137-146`, `grant_all/3` `:209-233` (self-scope default :217,
  admin granter :210, hardcoded `kind: :agent` :223). `PmCoordinatorSeed` **referenced** at :116
  and `default_agent_seed.ex:8` but **never defined** (`grep 'defmodule.*PmCoordinatorSeed'` → 0).
- Socialware materialize:
  `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex`
  — `materialize_definition_agents/4` `:85` (threads `granted_by` owner :88), recipe-cap grant with
  no overrides `:252,:550-555`, orchestrator-only hook `orchestrator_recipe_slot?` `:352-354`,
  `role_name_to_uri` use `:601`.
- Orchestrator precedent:
  `apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator/caps.ex` —
  `build_desired_caps/4` `:148`, `{:within_session}` cap `:161-169`, `grant_tag_for/2` `:120`
  (`{:genesis, owner}` / `{:rule, :template_materialize, owner}`), `cap_equal_ignoring_metadata?`
  `:200`.
- Grant chokepoint + tags: `apps/ezagent_domain_identity/lib/ezagent/identity/grant.ex`;
  `rule_cap_bounded?` in `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex`
  (capbac.md §5).
- Target resolver: `Members.role_name_to_uri/2`
  `apps/ezagent_domain_session/lib/ezagent/behavior/session/members.ex:84`.
- Wildcard fallback: `admin_genesis_cap/0`
  `apps/ezagent_core/lib/ezagent/capability.ex:244` (all-5-axes `:any`).
- Fallback apps' declarations: `apps/ezagent_web/priv/socialware_seed/{hello,kanban,autoservice}/manifest.yaml`
  (kanban board is NOT a role slot — two agent roles only; hello has builder/responser/viewer;
  autoservice one role). autoservice hand-grant: `scripts/autoservice_tier1_seed.exs:21`.
- Phase-3 not-merged: `git show --stat fa72d36ba` = 9 files, all png/README, 0 `lib/`. No
  `Cap.issue`/`RecipeCapBinding`/`CapAbsorbAwait` in `apps/`.
- Boundary principle: `docs/together/contributing/socialware-data-deployment-boundary.md:48-49`.
