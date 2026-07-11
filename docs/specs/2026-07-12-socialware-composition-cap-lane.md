# SPEC — Socialware composition-cap lane

> **Status:** SPEC (architecture-level, pre-implementation). Design for Allen to approve, then
> codex to implement. This doc resolves mechanism at the DESIGN level; incidental file:line is
> demoted to impl-constraint notes (§8) — the code wins.
> **Baseline:** `origin/main` @ `fa72d36ba` (cbac Phase-3 **merged** — the 13 stage commits
> `dec0bc134`…`46f26a3b3` are in history below the S8 tip). Every file:line below re-verified on
> that tree.
> **Read before implementing:** `.claude/skills/ezagent-developer/references/capbac.md` (the three
> roles caller/authorizer/granter, the grant tag set, `rule_cap_bounded?`, Decision #154), plus the
> merged seam modules named in §0.
> **Origin:** jjkysy PR #1355 (`docs/authz-composition-cap-gap`) — handoff
> `docs/together/2026-07-11/handoffs/socialware-composition-cap-gap.md`. §5 below answers that
> handoff's §五 拍板项 verbatim.

---

## 0. Foundation — the merged cbac ISSUE / STORE / VERIFY seam this lane builds on

cbac Phase-3 is **merged on `fa72d36ba`**. The composition-cap lane mints through the same seam
every other cap now flows through:

- **ISSUE — `Ezagent.Cap.issue/3`** (`apps/ezagent_core/lib/ezagent/cap.ex:30`). Takes an
  **authorization tag** — the closed set `{:held_by, actor}` / `{:admin, admin}` / `{:rule, name,
  configurer}` / `{:genesis, owner}` (`cap.ex:19-23,78-99`) — a **holder** URI, and a proposed
  `%Capability{}`. It authorizes the issuer via `CapabilityRegistry.authorize_grant/3`
  (`capability_registry.ex:371`), stamps `granted_by` = the tag's accountable **entity** (validated
  `%URI{scheme:"entity"}`, else `{:granter_not_entity, _}`, `cap.ex:67-76`), and returns the
  artifact. **Owner-as-granter (#154) is expressed directly as `{:rule, name, owner}`.** The grant
  chokepoint `Ezagent.Identity.Grant.grant_cap` now routes through `Cap.issue` (`grant.ex:232`); the
  orchestrator lane calls `Cap.issue` directly (`caps.ex:90`).
- **STORE (self-absorb) — `Ezagent.Identity.absorb_cap/2`** (`identity.ex:259`). The **holder**
  self-stores an already-issued, `Cap.verify`-checked artifact into its own `:caps` slice.
  Authorization is already complete at ISSUE; absorb only persists. This is the store path for a
  **live** holder (the orchestrator uses it, `caps.ex:103`).
- **STORE (durable pre-issue) — `Ezagent.Identity.RecipeCapBinding.issue_and_upsert/4`**
  (`recipe_cap_binding.ex:56`). A materializer issues a not-yet-live agent's **own** recipe caps
  before the agent exists and commits them to a durable, versioned binding the agent reads from its
  Identity `create/1` lifecycle. **This path is SELF-SCOPED by construction:** `validate_artifact/4`
  (`:187-195`) hard-rejects any artifact whose `kind ≠ :agent` (`:kind_mismatch`), whose `instance`
  is not the grantee **itself** (`:target_mismatch`), or whose `granted_by` is not the issuer; and
  it issues under a hardcoded `{:admin, issuer}` tag (`:144`). **A cross-instance cap cannot pass
  it** — decisive for §3.2.
- **VERIFY — `Ezagent.Cap.verify/1`** (`cap.ex:44`) + `verified_set/1` (`:56`). Load boundaries
  filter to entity-provenance artifacts; `CapAbsorbAwait` (`identity/cap_absorb_await.ex`) gates a
  cold target on its pending self-store.

> **Correction (supersedes an earlier draft of this spec):** a prior revision claimed Phase-3 was
> unmerged and anchored the design on the pre-cbac `Identity.Grant`/`grant_cap` shim. That was a
> stale-tree read (the author's working branch predated cbac). **Retracted.** cbac IS merged; this
> revision anchors the mint on `Cap.issue` + `absorb_cap`, and the brief's symbol names
> (`bind_recipe_caps`, `propose_recipe_caps`, `proposal_cap`, `instance_overrides`) are all correct
> on `fa72d36ba`.

The lane needs **no new** issue/store/verify primitive — only a declaration, materialize wiring
that calls the existing seam, and a Kind-axis decision.

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
| **orchestrator** | → session members | `grant_orchestrator_scoped_caps` mints owner-granted cross-instance caps via `Cap.issue` + `absorb_cap` — but reachable only through a hook **hardcoded to the orchestrator role** (`definition_agents.ex` `orchestrator_recipe_slot?`). | ⚠ the right mechanism, wrong reach |

`docs/together/contributing/socialware-data-deployment-boundary.md:48-49`:
> "any need to … hand-write working-copy bindings **is treated as evidence that a supported
> install/runtime path is missing**."

The four fallbacks are that evidence. The ISSUE/STORE seam (`Cap.issue` + `absorb_cap`), the
target-scoping seam (`instance_overrides`), and the granter rule (#154) all exist; what is missing
is (a) a **declaration** of the relationship, (b) the **materialize wiring** that mints the cap,
and (c) a decision on the **Kind axis**.

---

## 2. The model this lane preserves: can-FIND ≠ can-OPERATE

The lane must **not** lighten the dispatch guardrail. Two layers are deliberately separate:

- **can-FIND (routing / addressing).** `routing_rules` + `legends` (`definition.ex:23,25`) + the URI
  schemes decide **who a message reaches**. Being routable to B, or able to construct B's URI, is
  NOT authority over B.
- **can-OPERATE (authorization).** Dispatch step 5.5 (`kind/runtime.ex`, the sole Behavior×Entity
  chokepoint, grep-gated by `cap_check_only_at_chokepoint_test.exs`) derives the **needed** cap by
  substituting the target's **concrete instance URI** (`resolve_required_cap` →
  `Ezagent.URI.instance(target)`) and matches it against the caller's held caps by **exact instance
  equality** (`capability/match.ex`). A cap that points at *self* structurally cannot open
  *another agent's* lock.

This split is a real confused-deputy / workspace-isolation defense: "can address B ≠ can operate
B." **The lane adds a narrow can-OPERATE cap; it changes nothing about can-FIND, and never relaxes
the exact-instance match.** A composed-in socialware must NOT be able to operate a member it was
not declared to operate.

---

## 3. Design: the composition-cap lane

Three parts — a declaration field, materialize wiring, and the granter — riding on the merged seam
of §0. The **orchestrator lane is the exact precedent**: a *live holder* absorbing a *cross-instance*
cap issued under *owner* authority.

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
        action: mutate         # a CONCRETE action (not :any) — see §3.3
```

Semantics: *"the member filling `kanban-assistant` may dispatch `behavior.action` to the member
filling role `board`."* Each entry names a **target role in the same Definition** — never a URI
(the `Definition` never carries instance URIs; `reject_participant_instance_uris`,
`definition.ex:85`). Directed and per-source, co-located with the role that receives the cap.

Validation extends `role_slot/1` (`definition.ex:280`) with an optional `operates` list, each entry
requiring a non-empty `role` (string), a `behavior` (module), and a concrete `action` atom. The
current validator **silently drops unknown keys** (it reconstructs a fixed-key map, `:291`), so an
authored `operates` today is discarded — the field must be parsed explicitly.

Alternative (documented, not recommended): a top-level `compositions: [%{from:, to:, behavior:,
action:}]`. Equivalent power; `operates`-on-role_slot preferred for locality. Either way it is a
NEW field — the fixed point is *directed, concrete-action, references a role name*.

**Consequence — composition targets must be materialized roles.** `operates.role` resolves to a
live member URI at materialize time via `Members.role_name_to_uri/2`
(`behavior/session/members.ex:84`, already used by `definition_agents.ex`). So the **target must be
a role slot**. This is the "data-as-a-role" model (§3.3/§6): the kanban board and the autoservice
kb become **agent role slots** so `role_name_to_uri` resolves them — which is exactly what makes
the cap mintable.

### 3.2 Materialize wiring — mint via `Cap.issue` + `absorb_cap` (the orchestrator path), NOT RecipeCapBinding

The socialware recipe-cap path (`definition_agents.ex` `bind_recipe_caps`, `:617` →
`GrantRecipeCaps.propose_recipe_caps`, `:621` → `RecipeCapBinding.issue_and_upsert`, `:623`) is
**self-scoped by construction**: it issues under `{:admin, admin}` (`:618`) and RecipeCapBinding
rejects any cross-instance or non-`:agent` artifact (§0). **A composition cap — held by the source
member, pointing at the *target* member — cannot flow through it** (`:target_mismatch`).

The correct path is the one the orchestrator already runs
(`Orchestrator.Caps.grant_orchestrator_scoped_caps`): a live holder absorbing a cross-instance,
owner-issued cap. Add a **composition step** to socialware materialize (sibling to the
orchestrator-only hook) that, for every role carrying `operates`:

1. **Resolve** each `operates.role` → target member URI (`Members.role_name_to_uri/2`), after that
   target's member has joined. Fail LOUD if unresolved (fail-closed, no partial).
2. **Build** the concrete composition cap:
   `Ezagent.Capability.cap(kind, behavior_module, action, Ezagent.URI.instance(target_uri),
   Ezagent.Capability.workspace_of(target_uri))` — `kind` per §3.3, `behavior`/`action` from the
   entry (concrete), `instance` = the **target's** concrete URI. (This is the same cross-instance
   scoping the `instance_overrides` seam computes — `proposal_cap`, `grant_recipe_caps.ex:304-319`;
   the lane reuses that *scoping idea* but mints on the owner path, not the admin recipe path.)
3. **ISSUE** under owner authority:
   `Ezagent.Cap.issue({:rule, :socialware_composition, owner}, source_member_uri, cap)` — `owner`
   is the session owner `granted_by`, already threaded through
   `materialize_definition_agents/4` (`:91,:94`). The **holder** arg is the **source member**.
4. **STORE (self-absorb):** `Ezagent.Identity.absorb_cap(source_member_uri, artifact)` — the source
   member self-stores the issued artifact (mirrors `caps.ex:101-108`; `absorb_cap` does not require
   `instance == holder`, which is why the orchestrator can hold `{:within_session}` caps and the
   source member can hold a target-scoped cap).

Complete all ISSUE authorizations before the first absorb (all-or-nothing ordering — same discipline
as `grant_recipe_caps.ex:331-334` and `caps.ex:82-84`).

The design's fixed points: **cross-instance, owner-granted, concrete, issued via `Cap.issue`,
self-absorbed by the source member.** Whether codex reuses `grant_recipe_caps/4`'s
`instance_overrides` parameter (which would additionally need an owner tag + a Kind knob) or writes
a dedicated composition mint modelled on `Orchestrator.Caps` is an impl choice (§8) — the design
recommends the dedicated `Cap.issue`/`absorb_cap` path because it is owner-granted and Kind-flexible
natively, and it leaves the self-scoped recipe path untouched.

### 3.3 Granter = the owner, via the `{:rule, :socialware_composition, owner}` issue tag

Per Decision #154 (capbac.md §1/§4): an auto-grant is driven by a RULE, and the granter is the
entity that **configured the rule** — here the **owner** who installed the socialware / owns the
session (in hand as `granted_by`). Not admin, not a `system://` principal.

Pass `{:rule, :socialware_composition, owner}` as the `Cap.issue` authorization tag (a new named
rule, mirroring the orchestrator's `{:rule, :template_materialize, owner}`, `caps.ex:162`).
`CapabilityRegistry.authorize_grant/3` admits it because a composition cap is **rule-eligible**:
`rule_cap_bounded?` (capbac.md §5) requires `kind ≠ :any`, `behavior ≠ :any`, and (concrete action
**or** scope-bounded instance) — the §3.1 shape (concrete action) satisfies it. This is why §3.1
mandates a concrete action. `Cap.issue` stamps `granted_by = owner` and validates it is an entity
URI.

---

## 4. Invariants

1. **Least-privilege, never wildcard.** Every composition cap is concrete on all five axes
   (`kind`, `behavior`, `action` concrete; `instance` = target's concrete URI; `workspace_uri`
   concrete). It does not relax `no_wildcard_system_principals_test` /
   `no_unowned_system_principal_grant_test`, and a dispatch to an **unrelated** instance is denied
   (exact-instance match fails). The `admin_genesis_cap` wildcard fallback is retired for these
   paths, not generalized.
2. **`granted_by` = a real owner entity** (`%URI{scheme:"entity"}`), via `{:rule,
   :socialware_composition, owner}`. Never admin-as-granter, never a `system://` principal (#154);
   enforced by `Cap.issue`'s entity validation.
3. **can-FIND unchanged.** No change to `routing_rules`, `legends`, URI schemes, or routing.
4. **Dispatch guardrail intact.** Step 5.5, `resolve_required_cap`, and the exact-instance
   `match.ex` untouched. The lane satisfies the guardrail with a correctly-scoped cap; it does not
   bypass or soften it.
5. **Declared-only.** A member may operate another **only** where the Definition declares it. No
   `operates` ⇒ no cross-member cap (self-scoped recipe caps only, as today).
6. **Fail-closed, no partial.** An unresolvable target role or unloaded behavior fails LOUD,
   issuing/absorbing nothing (never a silently-dead cap); all ISSUE before any absorb.
7. **Issued + verifiable.** Every composition cap goes through `Cap.issue` (entity provenance) and
   passes `Cap.verify` — a first-class cbac artifact, not a hand-built grant.
8. **Idempotent** on repair/re-materialize (mirror `cap_equal_ignoring_metadata?`, `caps.ex`), and
   revocable via the orchestrator's `revoke` inverse pattern (`caps.ex:129`).

---

## 5. Answers to jjkysy PR #1355 §五 (拍板项)

> Verbatim decisions from `socialware-composition-cap-gap.md` §五. Recommendations follow; the two
> genuine forks are re-surfaced in §6.

**决策 1 — Is the gap worth a proper lane (vs tolerating admin/script fallback)?**
**Recommend: YES.** Four shipped socialware fall back; the boundary doc names hand-written bindings
as a missing-path signal; kanban assistant→board and autoservice→kb have **no** correct path
without it (data hosts can't self-execute — §6). The mint seam (`Cap.issue`+`absorb_cap`) and the
target-scoping seam already exist; the orchestrator already proves the exact pattern. Filling it
converges toward #154 (retire the `system://`/admin fallbacks).

**决策 2 — (a) declaration, (b) granter, (c) extend Kind axis to session?**
- **(a) Declaration:** a **NEW directed field**, `operates` on the agent role_slot (§3.1). **Not**
  legend/routing reuse. Concrete action, references a role name.
- **(b) Granter:** the **owner** via the `{:rule, :socialware_composition, owner}` `Cap.issue` tag
  (§3.3) — #154-clean, mirrors the orchestrator. (Fork vs the recipe path's `{:admin, admin}` —
  §6.2.)
- **(c) Kind axis:** **prefer data-as-agent so the common path is `kind: :agent`; support
  `kind: :session` only where the action host is naturally a session** — reachable *for free* on the
  direct `Cap.issue` path (the orchestrator already issues `kind: :session` `{:within_session}`
  caps). Do NOT force session-host actions through the agent-only `proposal_cap`/RecipeCapBinding
  seam. (Genuine fork — §6.1.)

**决策 3 — Also lift kanban assistant→board from fallback to the proper lane?**
**Recommend: YES.** Model the board as a **data-as-agent** role slot; declare `kanban-assistant
operates board`; delete the admin/owner master-key path. jjkysy's judgment (§三.3, §五.3) — the
board is a passive data host that can't self-execute, so this is its **only** correct path — holds
against the code. This is the reference implementation.

---

## 6. Open questions / forks for Allen

### 6.1 Kind axis — the genuine fork (resolved-with-recommendation)

The self-scoped recipe seams force `kind: :agent` (`proposal_cap`, `grant_recipe_caps.ex:318`;
`RecipeCapBinding.validate_artifact` `:kind_mismatch`). But the **direct `Cap.issue` path imposes no
such limit** — `authorize_grant`/`rule_cap_bounded?` admit `kind: :session`, and `absorb_cap` stores
it (the orchestrator does exactly this). Options:

- **(a)** Parameterize the recipe seam (`proposal_cap`) to emit non-`:agent` kinds.
- **(b)** Mint the composition cap on the **direct `Cap.issue` + `absorb_cap`** path (§3.2), which
  emits any Kind (incl. `kind: :session` via a `{:within_session}` scope tuple) with no seam change.
- **(c)** "Data-as-a-standalone-agent" — make board/kb **agent** role slots so every target is
  `kind: :agent`.

**Recommendation: (c) as the default target model + (b) as the mint path.** Data hosts become agent
roles (kanban board, autoservice kb) → the common cap is `kind: :agent`; and because we mint via
direct `Cap.issue` (b), the rare session-host action (dealscout `crawl_now`) is supported by a
`kind: :session` scope-tuple cap **without** touching the agent-only recipe seams. Do **not** force
session-host actions through `proposal_cap`/RecipeCapBinding — that agent-only self-scope is the
double-mismatch that dead-ends dealscout (§1). dealscout defers via **lane ①** (role
self-execution + routing) short-term; not a blocker.

### 6.2 Granter — `{:admin, admin}` (today's recipe path) vs `{:rule, :socialware_composition, owner}`

Recipe caps issue under `{:admin, admin}` (`bind_recipe_caps` `:618`; `RecipeCapBinding` `:144`).
The lane proposes owner-as-granter via `{:rule, …, owner}` (§3.3) — #154-clean, matching the
orchestrator's owner tags (`caps.ex:149-162`). **Recommendation: owner via `{:rule,
:socialware_composition, owner}`.** Confirm with Allen (it adds a named rule to the `{:rule, …}` set
and sets the accountable granter on these caps to the owner). Scope: **composition** caps only;
self-scoped recipe caps stay `{:admin, admin}` (separate concern).

### 6.3 Declaration placement — `operates` on role_slot vs top-level `compositions`

Recommended `operates` on role_slot (§3.1) for locality; top-level `compositions` is the alternative
if Allen prefers a single relationship table. Cosmetic vs the design's fixed point.

---

## 7. Answering the coordinator's integration question directly

*"Does `RecipeCapBinding.issue_and_upsert` go through `instance_overrides`, or should the composition
cap be minted via a direct `Cap.issue(...)`?"*

**Direct `Cap.issue` + `absorb_cap`.** `RecipeCapBinding` is the **self-scoped** durable home for a
not-yet-live agent's *own* recipe caps: `validate_artifact/4` (`recipe_cap_binding.ex:187-195`)
structurally rejects any cap whose `instance ≠ the grantee itself` or whose `kind ≠ :agent`, and it
issues under `{:admin, issuer}`. A composition cap is cross-instance (held by the source member,
`instance` = the target member) — it **cannot** pass RecipeCapBinding. The `instance_overrides` seam
(`grant_recipe_caps.ex:304-319`) *computes* a cross-instance-scoped cap shape, but its host
(`proposal_cap`) still stamps `kind: :agent` and its callers route to either RecipeCapBinding
(self-scoped) or an `{:admin, admin}` absorb — neither is owner-granted. The composition lane
therefore mints on the **same path the orchestrator uses for its cross-instance delegation caps**:
`Cap.issue({:rule, :socialware_composition, owner}, source_member, cap)` → `absorb_cap(source_member,
artifact)`. This IS the merged cbac paradigm (issue at the `Cap.issue` chokepoint, holder
self-stores), applied to a target-scoped cap.

---

## 8. Impl-constraints (for codex — not design decisions)

- **Declaration parse:** extend `role_slot/1` (`definition.ex:280`) — the validator reconstructs a
  fixed-key map (`:291`) and drops unknown keys, so `operates` must be parsed + validated
  explicitly (non-empty `role` string; `behavior` a loadable module; `action` a concrete atom,
  reject `:any`). Reject any `operates.role` not present in `roles`.
- **Target resolution:** reuse `Members.role_name_to_uri/2` (`behavior/session/members.ex:84`). Fail
  LOUD if a declared target has no live member.
- **Mint:** `Ezagent.Cap.issue({:rule, :socialware_composition, owner}, source_member_uri, cap)`
  then `Ezagent.Identity.absorb_cap(source_member_uri, artifact)` (`cap.ex:30` / `identity.ex:259`).
  Do **not** route composition caps through `RecipeCapBinding.issue_and_upsert` (self-scoped) or the
  pre-cbac `Identity.grant_cap` shim. Build the cap with `Ezagent.Capability.cap/5`.
- **Ordering:** resolve+mint **after** the target role's member has joined; a post-batch pass (once
  all roles are materialized) is safer than inline, since a composition may point at a role that
  materializes later. Complete all ISSUE before the first absorb (all-or-nothing).
- **Granter threading:** thread `granted_by` (owner) from `materialize_definition_agents/4`
  (`:91,:94`) into the composition mint. Model the step on `Orchestrator.Caps`
  (`caps.ex:85-108,149-162`).
- **Kind:** default `:agent` (data-as-agent targets). Any `kind: :session` sub-lane uses a
  `{:within_session, session_uri}` scope tuple (as `build_desired_caps`, `caps.ex:177+`).
- **`rule_cap_bounded?` reachability:** a concrete-`%URI{}` + concrete-action cap passes the
  wildcard gate before the rule branch (capbac.md §5) — it does, being non-`action:any`.
- **Idempotency + revoke:** reuse `cap_equal_ignoring_metadata?` to skip re-grants on repair; add a
  revoke inverse (`caps.ex:129` pattern) for rollback.
- **Gates to run:** the cbac invariant gates (`recipe_cap_binding_invariant_test`,
  `cap_absorb_reachability_test`), `grant_dispatch_chokepoint_test`,
  `no_wildcard_system_principals_test`, `no_unowned_system_principal_grant_test`,
  `mix ezagent.check_invariants`, `mix ezagent.socialware.check`, touched-app tests + full suite
  before merge.

---

## 9. Staged PR plan

1. **PR-1 — declaration field.** Add + validate `operates` on the agent role_slot
   (`definition.ex`). Manifest schema doc + `mix ezagent.socialware.check` awareness. Round-trip
   test (authored `operates` survives `Definition.new/1`). No behavior yet. *(pure schema)*
2. **PR-2 — materialize wiring.** Resolve `operates` targets → URIs; mint target-scoped composition
   caps via `Cap.issue({:rule, :socialware_composition, owner}, source, cap)` + `absorb_cap`
   (`kind: :agent`). Fail-closed, all-or-nothing, idempotent. Integration test proving a source
   member holds a target-scoped cap and can dispatch to it while an unrelated instance is denied
   (the §2 invariant, as a failing-without-the-lane test).
3. **PR-3 — lift kanban + delete autoservice hand-grant.** Model kanban `board` as a data-as-agent
   role slot; declare `kanban-assistant operates board`; remove the admin/owner master-key path.
   Convert autoservice kb to a role slot; declare `orchestrator operates kb`; **delete
   `scripts/autoservice_tier1_seed.exs`**'s `kb.query` hand-grant. E2e: assistant→board and
   orchestrator→kb both authorized by the minted narrow cap, no fallback.
4. **Deferred — `kind: :session` sub-lane + dealscout + hello.** Only if/when a session-host action
   host is needed (via a `{:within_session}` composition cap on the direct `Cap.issue` path).
   dealscout uses **lane ①** short-term. hello front-desk→builder migrates onto the lane in a
   follow-up (retire its `admin_genesis_cap` relay) once PR-2 lands.

---

## 10. Primary evidence (re-verified on `fa72d36ba`)

- **Merged cbac seam:** `apps/ezagent_core/lib/ezagent/cap.ex` — `issue/3` `:30`, tag set `:19-99`,
  `verify/1` `:44`, provenance `:67-76`. `apps/ezagent_core/lib/ezagent/capability_registry.ex` —
  `authorize_grant/3` `:371`, `rule_cap_bounded?` rule branch. `identity.ex:259` `absorb_cap/2`.
  `grant.ex:232` (`grant_cap` → `Cap.issue`). cbac stage commits `dec0bc134`,`d4c28f7a9`,
  `af8ad54e5`,`915c0bc49`,`9f883f139`,`28493a56f`,`46f26a3b3` in `origin/main` history.
- **RecipeCapBinding (self-scoped store):**
  `apps/ezagent_domain_identity/lib/ezagent/identity/recipe_cap_binding.ex` — `issue_and_upsert/4`
  `:56`, `Cap.issue({:admin, issuer})` `:144`, `validate_artifact/4` self-scope enforcement
  (`kind==:agent`, `instance==agent_uri`, issuer match) `:187-195`. `CapAbsorbAwait`
  `apps/ezagent_domain_identity/lib/ezagent/identity/cap_absorb_await.ex`.
- **Orchestrator precedent (cross-instance, owner-granted, Cap.issue+absorb):**
  `apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator/caps.ex` — `issue_scoped_caps`
  (`Cap.issue(grant_tag_for(cap, owner), target, cap)`) `:85-99`, `absorb_scoped_caps`
  (`absorb_cap`) `:101-108`, `grant_tag_for` (`{:genesis, owner}` / `{:rule, :template_materialize,
  owner}`) `:149-162`, `build_desired_caps` `kind: :session` `{:within_session}` cap `:177+`.
- **Socialware materialize + self-scoped recipe path:**
  `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex`
  — `materialize_definition_agents/4` `:91` (owner `granted_by` `:94`), `bind_recipe_caps` `:617`
  (issuer=admin `:618`), `propose_recipe_caps` call `:621`, `RecipeCapBinding.issue_and_upsert`
  `:623`, orchestrator-only hook `orchestrator_recipe_slot?`.
- **`instance_overrides` scoping seam:**
  `apps/ezagent_domain_agent/lib/mix/tasks/ezagent.agent.grant_recipe_caps.ex` — `grant_recipe_caps/4`
  `:166`, `propose_recipe_caps` `:205`, `proposal_cap/3` (hardcoded `kind: :agent`) `:304-319`,
  `issue_all` (`Cap.issue({:admin, issuer})`) `:334`, `absorb_all` (`absorb_cap`) `:351`.
  `PmCoordinatorSeed` **referenced** (`:116`, `default_agent_seed.ex:8`) but **never defined**.
- **Declaration schema:** `apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex` — struct
  fields `:12-29` (`roles`,`routing_rules`,`legends`); `role_slot/1` `:280-308` (fixed-key
  reconstruct `:291`, no `operates`); `reject_participant_instance_uris` `:85`.
- **Target resolver:** `Members.role_name_to_uri/2`
  `apps/ezagent_domain_session/lib/ezagent/behavior/session/members.ex:84`.
- **Wildcard fallback:** `admin_genesis_cap/0` `apps/ezagent_core/lib/ezagent/capability.ex:244`
  (all-5-axes `:any`).
- **Fallback apps:** `apps/ezagent_web/priv/socialware_seed/{hello,kanban,autoservice}/manifest.yaml`
  (kanban board is NOT a role slot — two agent roles only; hello builder/responser/viewer;
  autoservice one role). autoservice hand-grant: `scripts/autoservice_tier1_seed.exs:21`.
- **Boundary principle:** `docs/together/contributing/socialware-data-deployment-boundary.md:48-49`.
