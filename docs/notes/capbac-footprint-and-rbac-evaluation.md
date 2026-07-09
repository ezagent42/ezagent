# CapBAC footprint & RBAC evaluation

**Date:** 2026-07-09 · **Status:** Design research (no implementation) · **For:** Allen
**Question (Allen's hypothesis to test):** the current CapBAC model is over-complex;
today's recurring problems are caused by it; would classic RBAC (roles→permissions) be
simpler/better for *this* system?

> Bilingual mirror: [`capbac-footprint-and-rbac-evaluation.zh_cn.md`](./capbac-footprint-and-rbac-evaluation.zh_cn.md).
> Method: measure first (numbers, gate-authoritative), then attribute today's bugs from
> evidence (MEMORY + forensic notes, not commit titles), then evaluate RBAC against the
> system's *real* requirements, then separate accidental from essential complexity. The
> model was a deliberate choice (Decision #154); this note understands the WHY before judging.

---

## TL;DR (headline verdict)

1. **Footprint is small and centralized, not sprawling.** The tight cap *mechanism* is
   **~2.1 % of prod LOC** (~2,650 / 127,813); the full CapBAC *surface* (mechanism +
   `required_caps` declarations + identity-domain authz + all check/grant sites) is
   **~7 %** — and that 7 % is Allen's own ROI-study number, not a fresh estimate. The
   authorization decision lives at **exactly two grep-gated chokepoints** (dispatch step 5.5
   for checks; `Ezagent.Identity.Grant.prepare/4` for grants), each enforced by a CI gate.
   Authority is **CENTRALIZED**, not diffuse.

2. **Today's recurring bugs are mostly NOT cap-caused.** Of 8 named problem classes, **5 are
   unrelated to the auth model** (sync-dispatch / deploy-seed / read-model), **1 is a real
   requirement where CapBAC is the *solution* not the cause** (#161 credential isolation),
   and **2 are genuine cap-ergonomics friction** (admin?/1, self-read #56) — and both of
   those are *bounded over-application*, already being trimmed. **~2 of 8 (~25 %) are
   cap-caused**, none in the per-instance core. **The hypothesis is largely refuted for the
   operational bug stream, partially supported for coarse-authority ergonomics.**

3. **RBAC would regress on exactly what #154/#161 just bought.** RBAC's "admin role has all
   permissions" IS the god-boolean the team deliberately rejected; per-tenant per-instance
   scoping forces RBAC into per-object ACLs (= caps re-invented); delegation lineage
   (`granted_by`) has no RBAC analog. **Recommendation: KEEP the cap core, formalize the
   coarse layer as explicit roles (HYBRID — the system is already ~85 % there), continue the
   #154 trim. Do NOT migrate to RBAC.**

---

## Part 1 — MEASURE

### 1.1 Denominator

| metric | value | source |
|---|---|---|
| Prod LOC (`apps/*/lib/**/*.ex`, excl. test/deps) | **127,813** | `find … \| xargs wc -l` |
| Prod `.ex` files | 562 | — |
| Umbrella apps | 23 (`ezagent_core` + 9 domain + 12 plugin + web/cli) | — |
| Test LOC | ~123 K (≈ 1:1 with prod) | ROI note 2026-06-20 |

### 1.2 CapBAC footprint — a band with the boundary named

The honest number is a **band**, because "CapBAC" can mean the primitive mechanism or the
whole authorization surface. Both are reported so the headline survives "what did you count."

| layer | files | LOC | % prod | what it is |
|---|---|---|---|---|
| **Tight core mechanism** | 13 | **~2,650** | **~2.1 %** | `capability.ex` (590) + `capability/{match,normalize,parser,scope,unauthorized}.ex` + `capability_registry{,/defaults,/subjects}.ex` (1,791 for the `capability/` cluster) + `system_principal{,.ex,/catalog.ex}` (~570) + `identity/grant.ex` (296) |
| **+ declarations** | +32 | +~34 one-liner `required_caps/0` | | co-located on Behaviors — the model *working as designed*, not scatter |
| **+ identity-domain authz logic** | +~6 | (`behavior/identity.ex`, `admin_authority.ex`, `identity.ex`, membership grant) | | the "authorization" concern |
| **Full CapBAC surface** | — | — | **~7 %** | **Allen's ROI study (2026-06-20): "Authorization (CapBAC) ~7 % — thin but pervasive cross-cutting"** |

**Boundary named:** tight primitives ~2.1 %; add the co-located declarations + the
identity-domain authz logic + every check/grant site and you reach Allen's ~7 %. Either way
CapBAC is a **thin slice** of a 128 K-LOC codebase — for comparison, the bespoke Kind/Behavior
*runtime* is ~30 %, business logic ~46 %.

### 1.3 Check-site concentration — CENTRALIZED (gate-authoritative)

This is the crux of the "over-complex?" question, and it is settled by CI gates, not by
counting.

**The authorization CHECK is at ONE chokepoint.** `Ezagent.Kind.Runtime.handle_dispatch/4`
**step 5.5** (cap check) + **step 5.6** (workspace check) is the sole place a dispatch is
authorized. The gate `apps/ezagent_core/test/invariants/cap_check_only_at_chokepoint_test.exs`
runs **12+ regex probes** (`Capability.matches?`, `list_caps_for`, `grant_cap`,
hand-written cap predicates, ambient `caller:/caps:` ctx, manual workspace comparison, …),
each with a **narrow path allowlist**. Anything matching outside the chokepoint fails CI. So:

| signal | prod call sites | reading |
|---|---|---|
| `Capability.matches?/2` | 21 | 1 is the chokepoint authz; the rest are the **core primitive itself** + **read-only** preflight/display/filter (external_mirror gates, orchestrator tool display, credential resolver, CLI) — all allowlisted as "legitimate impl OR documented exemption." **None is scattered business-logic authz.** |
| `holds_cap` | 36 | routed through `Kind.holds_cap?/3`, consumed by the chokepoint |
| `required_caps/0` **declarations** | 34 across 32 files | **declarative** co-located one-liners — how you DECLARE a needed action, not an imperative check |

**Grant CONSTRUCTION is at ONE chokepoint.** `Ezagent.Identity.Grant.prepare/4` is the only
place a `grant_cap`/`revoke_cap` dispatch is built. Gate
`grant_dispatch_chokepoint_test.exs` pins `@allowlist_size = 1` (literal + variable-action +
legacy-URI shapes all scanned). **The 80 `grant_cap` references are wrapper CALLS into that
one chokepoint, not 80 construction sites.**

**Verdict: authority is CENTRALIZED** at two grep-gated chokepoints. The invariant
`cap_check_only_at_chokepoint` is not aspirational — it is a passing CI gate with an
enumerated exemption list. This is the opposite of "sprinkled through business logic."

### 1.4 Counts & distribution

| axis | count | note |
|---|---|---|
| distinct Behaviors | ~53 | `use Ezagent.Lifecycle`/`Behavior` |
| distinct declared actions | ~26 | `action: :x` axis |
| system principals | 15 (+ genesis) | **closed** Catalog, ratcheting → genesis-only |
| unowned-authority minters | **0** | achieved PR #824 (#154's original goal DONE) |
| cap grant sites | 80 wrapper calls | 1 construction chokepoint |
| cap check sites | 1 authz chokepoint | + read-only exemptions |

**Distribution of `Capability` references (771 refs / 158 files):**

| app / layer | refs | % | tier |
|---|---:|---:|---|
| `ezagent_core` | 440 | 57 % | core (the mechanism) |
| `ezagent_domain_identity` | 248 | 32 % | domain (authz owner) |
| `ezagent_domain_session` | 168 | 22 % | domain (membership/join) |
| `ezagent_domain_workspace` | 68 | | domain |
| `ezagent_domain_external_mirror` | 54 | | domain |
| `ezagent_domain_agent` | 51 | | domain |
| every **plugin** (cc/world/feishu/email/np/…) | 5–24 each | **~5 % total** | plugin |

**Key finding:** the cap weight sits in **core + the three authority-owning domains**
(identity/session/workspace). Plugins — where business logic lives — barely touch it (5–24
refs each). **The model does NOT bleed into plugin business logic.** That is the intended
three-tier boundary holding.

---

## Part 2 — ATTRIBUTE today's problems (evidence-based, honest)

Attribution from Allen's own forensic record (MEMORY + `docs/notes/`), not commit titles.
Classes: **(a)** caused by CapBAC complexity · **(b)** friction the cap-model imposes for a
real requirement · **(c)** unrelated to the auth model (sync-dispatch / deploy-shape /
migration / read-model).

| # | problem class | class | root cause (evidence) |
|---|---|:--:|---|
| 1 | **create_session timeout** | **(c)** | Cold `uv` provision of the `np` recipe's numpy/sympy (**measured 9.6 s cold**) + a **sync `ReadyGate.await(5_000)`** on the create critical path (`template_spawn.ex:640`, `mode: :call`). Nothing to do with auth. Fixed by `mode: :call → :cast` (PR #1202). *(golive memory)* |
| 2 | **skill packaging** | **(c)** | Deploy/seed shape — `SkillRegistry` + seed lane + materialization fold (#1266). Distribution, not authz. |
| 3 | **seed three-state** | **(c)** | Migration/read-model — `ConfigStore` three-state seed contract + CI reflow gate (#1242); idempotent upgrade on unique `source_turn_id`. Not authz. |
| 4 | **cold-boot listing** | **(c)** | Read-model/projection — durable session listing (#1257) + the **cold-agent flavor wall** (flavor resolves only from in-memory ETS populated at spawn; a cold agent reads `:none`). Hydration/projection, not authz. |
| 5 | **environment-shape family** | **(c)** | Deploy shape — 2-element `instantiate` shape in `create_session_via_class`, deterministic default-template name resolution (#1244). Not authz. |
| 6 | **#161 credential isolation** | **(b)** | A **real** multi-tenant requirement: can co-tenant B pull A's credentialed agent into B's session and spend A's creds? **CapBAC was the SOLUTION**, not the cause: member-cap held on `ctx.caller` + an **admission gate at the one `handle_join` chokepoint** (R1.1 roster⟂authz ⇒ no member-cap ⇒ no `:receive` ⇒ no credential spend), + cascade-notify to manage-cap holders (PR #1178). The residual (URI-baked socialware templates → *indirect* pull) is a **data-modeling** issue → really (c), fixed by the role-slot model, not by touching the auth primitive. |
| 7 | **admin?/1 confusion** | **(a)** partial | `Identity.AdminAuthority.admin?/2` is a **4-predicate UNION** (bootstrap-wildcard ∪ cross-workspace-admin-cap ∪ `home_is_system?` ∪ `member_of_system?`); codex flagged its **placement twice** (r3 layer violation, r4 policy-on-Behavior). This is real friction — the cap model applied to a **coarse** "is this caller an operator-admin?" question. **But it is evidence the coarse layer wants to be a ROLE**, i.e. it argues for the hybrid, not against caps per se. |
| 8 | **self-read workaround (#56)** | **(a)** already-trimmed | A Kind reading its own/sibling slice was going to need a cap-check primitive (`authorize_in_process`). Allen ruled **decision B**: an intra-Kind sibling read is **structurally authorized — NO runtime cap check**, replaced by a **static gate** (`sensitive_slice_read_test.exs`). The primitive was **never built**. Over-application caught and removed **without changing models**. |

### Verdict (Part 2)

- **5 / 8 (63 %) are (c)** — unrelated to the auth model (sync-dispatch, deploy-seed,
  read-model). The operational bug stream is not a CapBAC problem.
- **1 / 8 is (b)** — #161, where CapBAC is the *mechanism that closed the vector*, not the
  cause. Per-instance member authority + delegation is exactly what a credential-isolation
  requirement needs.
- **2 / 8 (25 %) are (a)** — admin?/1 and self-read #56. Both are **bounded over-application**
  of an otherwise-sound model, and **both are already being trimmed** (#56 done; admin?/1 is
  the coarse layer the hybrid formalizes). Neither touches the per-instance core.

**The lead's hypothesis is largely REFUTED for today's recurring bugs (they are deploy/sync/
read-model, not auth) and PARTIALLY SUPPORTED for coarse-authority ergonomics** — which is
precisely the seam the hybrid recommendation addresses.

---

## Part 3 — CapBAC vs RBAC against this system's real requirements

The system is multi-tenant, spawns **agents that hold credentials**, needs **per-instance**
authority (this cap on THIS session/agent), **delegation chains** (`granted_by` lineage, #161
no-unowned), **workspace scoping**, and the **#154 goal of eliminating god-mode system
principals**.

### What CapBAC buys that RBAC can't express cleanly

| capability | how CapBAC does it | RBAC equivalent |
|---|---|---|
| **per-instance scope** | `instance:` axis = concrete `%URI{}` or scope tuple `{:within_session, uri}` / `{:spawned_by, uri}` | none — roles are subject-global; per-object needs a per-object ACL |
| **owner-delegation lineage** | `granted_by` (entity), #153 manager-delegation, #154 no-unowned | none — RBAC has no "who granted this and are they accountable" |
| **action axis** | `action:` axis, matched with `:any` wildcard | role→permission can approximate, but not per-instance |
| **credential-isolation vectors (#161)** | member-cap on `ctx.caller` + admission gate keyed on held caps | a role can't encode "held authority over THIS specific agent instance" |

### What RBAC would SIMPLIFY

The **coarse** cases. The admin discussion just concluded "**admin = config-role, business =
member**" — which is *role-shaped*. Bootstrap/operator/config authority and the operator-
listing `admin?/1` question are naturally roles, not per-instance caps. RBAC would make those
readable in one place.

### Where RBAC would REGRESS

1. **"admin role has all permissions" IS the god-boolean the team just rejected.** #154's
   whole program is *eliminating* god-mode system principals (`no_wildcard_system_principals`
   gate, minters → 0). A blanket admin role re-introduces exactly that.
2. **Per-tenant per-instance scoping forces RBAC into per-object ACLs — which are caps
   re-invented.** *(This is the discriminating question.)* RBAC cannot say "this authority on
   THIS session" without attaching a permission to an object; do that per object and you have
   rebuilt the cap `instance:` axis under a worse name.
3. **Delegation chains have no RBAC analog.** `granted_by` lineage, manager-delegation,
   "who manages X → cascade-notify" (#161 B) all depend on a per-grant accountable entity.
   Roles are memberships, not grants; there is nowhere to record the granter.

### The honest HYBRID — and the system is already ~85 % there

Coarse **roles** for config/bootstrap/operator authority **+ caps only where per-instance or
delegation is genuinely needed** (session participation, agent manage-cap, credential
admission). Evidence the system already trends there:

- `User.default_caps/1` now returns **`[]`** — no standing broad caps; participation is
  granted **per-session at join** by the session owner.
- `ActionSet.Manage` + `CreatorGrant.manage_cap` — the creator gets
  `cap(:<kind>, Manage, :any, instance)` at create (owner-of-instance = role-ish authority,
  instance-scoped cap).
- The Catalog is a **closed, shrinking** allowlist (15 → genesis-only), minters already 0.

The **one concrete move the numbers support**: retire the `admin?/1` 4-predicate union into an
**explicit named admin role**, capturing RBAC's readability exactly where the authority *is*
coarse — while keeping caps for the instance/delegation core that RBAC can't express.

---

## Part 4 — ACCIDENTAL vs ESSENTIAL complexity

Separate from the RBAC question: which cap complexity is **accidental** (over-application) and
trimmable **without changing models**?

| accidental complexity | status | quantified |
|---|---|---|
| **self-read #56** | **already trimmed** | intra-Kind sibling reads are structurally authorized (decision B); the `authorize_in_process` primitive was never built; replaced by one static gate. |
| **broad `default_caps` baseline** | **already trimmed** | was one broad `session:any` cap per user; now `[]` — redundant with per-session membership grant. |
| **`:vm_internal`-trusted paths** | marker exists | `default_holds_cap?(:vm_internal, _) → true` (**33 `:vm_internal` uses**); any remaining explicit cap-check on a VM-internal-trusted path is covered by the #154 marker and trimmable. |
| **membership-gated where cap is redundant** | precedent exists | `SocialwarePublisherRead :snapshot/:history` are **cap-EXEMPT** — live membership is the sole authority. A precedent to extend where a held cap merely duplicates a membership check. |
| **system-principal Catalog** | in progress | 15 → genesis-only (`system_principal_elimination_test @remaining → []`); minters already 0. Each removal is re-attribution, not deletion. |
| **admin?/1 4-predicate union** | candidate | consolidate 4 scattered predicates for one coarse question into a single named role predicate. |

**Quantified conclusion:** the **essential** core is ~2.1 % (tight) / 7 % (full). The
**accidental** over-application is a **bounded, enumerable set** — most of it (#56,
default_caps) **already removed**, the rest (`:vm_internal` coverage, Catalog collapse) **in
active flight under the #154 program**. The over-complexity is *not* the model; it is a
shrinking tail of over-application the team is already cutting.

---

## RECOMMENDATION

**KEEP the capability core. FORMALIZE the coarse layer as explicit roles (HYBRID). CONTINUE
the #154 trim. Do NOT migrate to RBAC.**

Grounded in the numbers and the #154 rationale:

1. **The footprint doesn't justify a rewrite.** CapBAC is ~2.1 % tight / ~7 % full of a 128 K
   codebase, centralized at two CI-gated chokepoints. A model migration is a large, risky
   change to a small, contained, *well-fenced* surface.

2. **Today's bugs aren't cap-caused.** 5/8 are deploy/sync/read-model (c); 1 is #161 where
   CapBAC is the fix (b); only 2/8 are cap-ergonomics (a) — both bounded, both already being
   trimmed. Migrating away from CapBAC would fix ~0 of the operational bug stream.

3. **RBAC regresses on the exact things #154/#161 bought.** Per-instance scope → per-object
   ACLs (caps re-invented); delegation lineage → no analog; blanket admin role → the
   god-boolean #154 spent a whole program eliminating.

4. **The system is already ~85 % of the honest hybrid.** `default_caps → []`, per-session
   grant at join, `ActionSet.Manage` creator authority, a closing Catalog. The productive move
   is to make it **more** so: (i) retire the `admin?/1` 4-predicate union into a named admin
   **role** (captures RBAC's readability where authority is coarse); (ii) finish the
   Catalog → genesis collapse; (iii) audit the 33 `:vm_internal` sites so no trusted in-VM path
   carries a redundant cap-check. All three are cap-model *trims*, not a model change.

---

### Sources

- Skill ref `.claude/skills/ezagent-developer/references/capbac.md` (the end-to-end model)
- `docs/notes/2026-06-16-capbac-system-principal-audit.md` (Decision #154, 15-principal A/B audit)
- `docs/notes/2026-06-19-fanout-principal-elimination-design.md`
- `docs/notes/2026-06-20-bespoke-core-framework-roi-decision.md` (the ~7 % authz figure)
- `docs/superpowers/specs/2026-06-14-cap-in-process-op-design.md` (#56 decision B)
- `GLOSSARY.md` Decision #153/#154 · `apps/ezagent_core/test/invariants/{cap_check_only_at_chokepoint,grant_dispatch_chokepoint,no_unowned_system_principal_grant}_test.exs`
- MEMORY: `project_agent_credential_isolation_audit`, `project_afk_goal_eliminate_sysprincipals`, `project_golive_prod_magiclink`, `reference_cold_agent_ui_verify_flavor_ets`
