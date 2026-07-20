# CapBAC — capability authorization, end to end

The permission model is the single most pitfall-prone area of ezagent. This file is
the authoritative reference: read it **before** touching anything that grants, revokes,
checks, or declares a capability. Every claim here is grounded in the code on `main`;
verify against the cited modules before relying on a detail (the code wins).

> **⚠ CAP-SIGNING STATUS (read first — do NOT re-hallucinate this).** Cap-signing
> **Path A is DONE and merged to main** (PR #1457, 2026-07-18). **Caps are
> born-signed and STRICTLY verified with per-Kind ed25519 keys.** Do NOT assume
> cap verification is permissive, that a `dual-read` / `require_signature:false` /
> "verify-fail soft" path still exists, or that "cap-signing strict is pending /
> crypto is Phase-4". None of that is true on main. `Ezagent.Cap.verify/1` (the old
> provenance-format stand-in) **is gone**. The current model — per-Kind signing
> authority, born-signed storage filter, strict crypto verify at dispatch, Path B
> (isolated external signer) deferred — is **§4.6 below**. The `§4.5` "Phase-3 /
> Phase-4 stand-in" framing is HISTORY (ISSUE→STORE flow still holds; its VERIFY
> mechanism was replaced by real crypto).

> **The one-sentence model:** a dispatch is authorized by a matching cap from EITHER the **caps the
> dispatch ctx carries** (`ctx.caps`) OR the **caller's held caps** (`holds_cap(ctx.caller)`, §3), a capability records **who is accountable for it**
> (`granted_by`, which MUST be a real entity — Decision #154), and these are produced at
> exactly one chokepoint (`Ezagent.Identity.Grant`). Confusing any two of these is how
> every bug in this area happens.

> **Phase-3 update (cbac-done-right, landed on main 2026-07-12, merge `fa72d36ba`):** a grant
> is no longer a single issuer→grantee dispatch that writes the grantee's slice. It is now
> **ISSUE → STORE → VERIFY**: the grantor ISSUEs a provenance-stamped *artifact* at
> `Ezagent.Cap.issue/3` (transferring NO authority), the grantee STOREs it itself (via its own
> `create/1` self-store or the `:vm_internal` `absorb_cap` cast), and every load/store boundary
> VERIFIEs provenance via `Ezagent.Cap.verify/1`. `granted_by` = the issuer. The **I12
> paradigm-lock** forbids issuer→grantee dispatch. See **§4.5** for the full model; the
> ISSUE-chokepoint is `Ezagent.Cap.issue/3`, wrapped by the same `Ezagent.Identity.Grant`.
> **This file is the current source of truth for the Phase-3 model** — the design spec/plan
> were not merged; the invariant gates (§8) and `docs/e2e/2026-07-11/phase3-cbac-done-right/`
> are the other authoritative references.

---

## 1. The three roles you must keep separate

A capability grant involves **three distinct actors**. The classic bug is collapsing them
into one value (usually `ctx.caller`).

| role | "who/what is this" | where it lives |
|------|--------------------|----------------|
| **caller** | the code path that mechanically invokes the dispatch — often an HTTP handler, a reconciler, an assembly effect; frequently NOT a person | `ctx.caller` |
| **authorizer** | *what makes the action permitted* | a matching cap from **`ctx.caps` OR `holds_cap(ctx.caller)`** — step-5.5 checks the carried `ctx.caps` first, then falls back to the caller's `:caps` slice (`runtime.ex:405`, see §3). `ctx.caller`'s *identity* is also consulted only for the `caller == data_owner` self-check, but its *held caps* ARE an authorizer source. (Earlier this row said "reads ctx.caps NOT caller" — that's the GRANT-chokepoint case where the caller is machinery without the cap; corrected 2026-06-22.) |
| **granter** | the real, accountable **entity** recorded on the minted cap | `Capability.granted_by` |

In the simple case (an admin grants a user a cap) all three coincide, so the distinction is
invisible — and that is exactly the trap. The moment a grant is **rule-driven** (an
automated path mints a cap because a flag/policy says so), the caller is machinery, the
authorizer is the rule, and the granter is whoever *configured* the rule. See
`GLOSSARY.md` Decision #154 ("no unowned permissions") and #153 (manager-delegation).

**Decision #154 (the principle):** every `Capability.granted_by` MUST be a real
accountable entity (`%URI{scheme: "entity"}`). Auto-grants are driven by a RULE; whoever
configured the rule is the granter. In the extreme case the granter is
`entity://system/user/admin`. Abstract `system://…` principals that are not real
accountable entities **must not be the granter**.

---

## 2. The `%Ezagent.Capability{}` struct

`apps/ezagent_core/lib/ezagent/capability.ex`. Five **identity axes** + two **provenance**
fields:

- `kind` — the Kind axis (`:session`, `:user`, `:agent`, `:workspace`, `:session_template`, …) or `:any`
- `behavior` — the Behavior module (`Ezagent.ActionSet.Session`, …) or `:any`
- `action` — IS a struct field (`defstruct` default `:any`), but it is **not in `@enforce_keys`**, so a cap built without it defaults to `action: :any` (wildcard). It is matched as a real axis: a held cap authorizes the dispatched action when `action_of(held) == needed_action` or `held` is `:any` (`capability/match.ex`). The **needed** action is the concrete dispatched action, substituted at dispatch time (`runtime.ex` `resolve_required_cap`); a *required* action is declared as the map key in a Behavior's `required_caps/0` — that's how you DECLARE a needed action, not how the held cap stores it. (History note: putting action in the struct/identity-tuple is the NEWER change — SPEC 2026-05-27 capability-action-axis — not the historical state. Some moduledocs still say "no action field"; they're stale.)
- `instance` — a concrete `%URI{}`, `:any`, or a **scope tuple** `{:within_session, %URI{}}` / `{:within_workspace, %URI{}}` / `{:spawned_by, %URI{}}`
- `workspace_uri` — a concrete `%URI{}` or `:any`
- `granted_by` (provenance) + `granted_at`

**Matching is asymmetric** (`Capability.matches?/2`, `Capability.Match`): a HELD cap with
`:any`/scope-tuple axes matches a NEEDED concrete cap, never the reverse. `granted_by` /
`granted_at` are provenance only — `identity_key/1` excludes them (so a revoke matches by
identity regardless of who granted it).

**`Capability.normalize!/2` does NOT re-stamp `granted_by` on a `%Capability{}` struct** —
for an already-struct cap it returns it unchanged, ignoring the granter argument
(`capability/normalize.ex`). This is a sharp edge: code that "passes the granter to
normalize!" silently keeps the cap's pre-existing `granted_by`. The chokepoint overwrites
`granted_by` with an explicit struct update, not via `normalize!` (§4).

---

## 3. How a dispatch is authorized (step 5.5)

`apps/ezagent_core/lib/ezagent/kind/runtime.ex` — `handle_dispatch` step 5.5. For an action
with a `required_caps/0` entry, the runtime derives the **needed** cap (`resolve_required_cap/4`:
the declared shape with concrete instance + workspace substituted) and authorizes via, in order:

1. `granted_via_ctx_caps?(ctx, needed)` — does any cap in **`ctx.caps`** match `needed`? (the cheap, deadlock-free path; checked first since 2026-05-26)
2. `granted_via_holds_cap?(ctx, needed)` — read the caller's `:identity`/`:caps` slice and match

…plus `check_action_wildcard_grant_authorized/2` on the **grant** path (a wildcard-action
grant needs admin authority or a scope-bounded instance).

**The authorizer is `ctx.caps` OR the caller's held caps** — a dispatch is authorized when
EITHER `ctx.caps` contains a matching cap (path 1) OR the caller holds one in its `:caps`
slice (path 2). `ctx.caller`'s `granted_by` is never an authorizer. **Do NOT read this as
"empty `ctx.caps` ⇒ denied":** an empty `ctx.caps` still authorizes if `holds_cap(caller)`
matches (e.g. a world action that threads `caps: MapSet.new()` but whose caller-entity holds
the cap in its slice — contract drift, not a live bypass).

The "empty `ctx.caps` fails closed" claim is **specific to the grant chokepoint** (BLOCKER-1):
there the caller is grant *machinery* that does NOT hold the granted cap in its own slice, so
path 2 cannot save it — a grant tag that sets `caller`/`granted_by` but leaves `ctx.caps`
empty fails closed on every admin/manager grant. That is a property of the chokepoint, not of
the general dispatch path. (If a design needs a HARD fail-closed on a normal dispatch — e.g.
the Agent Console Manage-gate — enforce it at an explicit gate; do NOT assume empty caps denies.)

Two authorization styles coexist; know which gates a given action:

- **cap-gated** — step 5.5 checks `ctx.caps`. (e.g. `Session :join/:send`.)
- **membership-gated, cap-exempt** — a live `ChatMembership` owner/member check is the SOLE
  authority, no held cap consulted. (e.g. `Behavior.SocialwarePublisherRead`
  `:snapshot`/`:history`.)
- **view-cap-gated** (T2 app-package, 2026-07-02) — a socialware VIEW's visibility is a
  read cap on a view ActionSet's `<sw>_render` action (e.g. `{session, HelloRender,
  :hello_render, <session>}`). The cap check is NOT step 5.5 (a view read is a projection
  bypass, not a dispatch) but the unified `Ezagent.UI.SessionView.authorize_view/3` gate,
  which every render entry routes through (`SessionViewRegistry.applicable_views/2` /
  `external_renderers/2`). This EXTENDS cap-gating from write actions to view READS: the
  old membership-only "whole session visible/invisible" model is retired in favor of
  per-view caps. An anon is minted the `<sw>_render` caps of PUBLIC installed definitions'
  views only (`Installation.anon_view_caps/1`). See architecture-invariants.md §23.
- A handler may ALSO impose a precondition that is not authorization — e.g. `Session.handle_join`
  returns `{:error, {:member_not_registered, _}}` if the member Kind isn't live. That is a
  liveness gate, distinct from the cap check.

---

## 4. The grant chokepoint — `Ezagent.Identity.Grant`

`apps/ezagent_domain_identity/lib/ezagent/identity/grant.ex` (introduced PR #814). **Every**
grant/revoke dispatch is constructed here and nowhere else — a grep invariant gate
(`grant_dispatch_chokepoint_test.exs`) fails CI if any non-test file builds an
`action: :grant_cap`/`:revoke_cap` dispatch (literal OR variable-action) outside this module.

`prepare/4` is the single source of truth. From a **tagged authorization basis** it derives
`ctx.caps` (the authorizer), `ctx.caller`, the cap's `granted_by` (struct-overwrite, then
**validate `%URI{scheme: "entity"}`** else `{:error, {:granter_not_entity, _}}`), and the
rule flag. The closed tag set:

| tag | `ctx.caps` (authorizer) | derived `granted_by` | when to use |
|-----|-------------------------|----------------------|-------------|
| `{:held_by, actor}` | `actor`'s real caps (`read_held_caps`) | `actor` | the actor genuinely HOLDS the authority: self-grant, admin grant, or #811 manager-delegation (actor holds a Manage cap over the target) |
| `{:admin, admin}` | `admin`'s caps | `admin` | convenience alias when the actor is a known admin |
| `{:rule, name, configurer}` | `[]` + `ctx.authorization_rule = name` | `configurer` | a rule authorizes the grant (e.g. `public_view == true`); `granted_by` = whoever configured the rule. Cap MUST be concrete-scoped (§5). |
| `{:genesis, granted_by}` | `[admin_genesis_cap()]` (the admin-granted genesis wildcard) | `granted_by` (MUST be entity) | **extreme-fallback** genesis grant (#154): minting the first authority over a brand-new entity where neither `{:held_by}` nor `{:rule}` can authorize (e.g. the creator's `Manage :any` over what they just created). (The old `{:system, principal, entity}` tag is **deleted** — `grant.ex:56`; this is its replacement.) |

Wrappers (all delegate to `prepare/4`): imperative `grant_cap/3` (Invocation),
`grant_cap_via_router/4` (Cmd; `:sync`→`:call` propagates errors, `:async`→`:cast`
**swallows** them — pass `:sync` when a caller gates on the grant result), `revoke_cap/3`;
effect constructors `grant_cap_effect/3`, `grant_cap_returning_effect/4`,
`revoke_cap_returning_effect/4` (these **raise** on a `prepare` error — an effect site can't
return `{:error}` as an effect). `Ezagent.Identity.grant_cap/3` is a back-compat shim →
`{:held_by, granter_uri}`.

### Choosing a tag for a NEW grant site (decision tree)

1. Does the **actor genuinely hold** the authority being granted (or hold a Manage cap over
   the target, #811)? → `{:held_by, actor}`. `granted_by` = actor.
2. Is it a **rule-driven** auto-grant AND the cap is concrete-scoped (kind≠`:any`,
   behavior≠`:any`, instance is concrete `%URI{}` with a concrete action, OR a scope tuple)?
   → `{:rule, rule_name, configurer}`. `granted_by` = configurer.
3. Is it a **creation/genesis** grant — minting the first authority over a brand-new entity
   (e.g. the creator's `Manage :any` over what they just created), where nobody pre-holds it
   and it's `behavior:any`/`action:any` so rule-ineligible? → `{:genesis, owner}`
   (`grant.ex:38,84`). `granted_by` = the owner entity (MUST be `%URI{scheme: "entity"}`).
   (The old `{:genesis, owner}` form is **deleted** — there is no longer a `{:system, …}` tag.)
4. None fit cleanly? **Do not invent a workaround** — surface it. A new system-principal
   authorizer is a Decision-#154 review surface.

---

## 4.5 Phase-3 (cbac-done-right): grant = ISSUE → STORE → VERIFY, with I12 paradigm-lock

> **Before you write ANY cap-granting code, read [`cbac-grant-prompt.md`](cbac-grant-prompt.md)** —
> a paste-before-you-code checklist (decision tree + the shapes that fail the I12/I7 gates). This
> section is the full model; that file is the fast path.

Landed on main 2026-07-12 (merge `fa72d36ba`). The chokepoint is unchanged in *location*
(`Ezagent.Identity.Grant` is still the sole grant/revoke constructor, §4); the *paradigm*
changed. A grant used to be one issuer→grantee dispatch that mutated the grantee's `:caps`
slice. It is now three separable steps — and the **I12 paradigm-lock** forbids the old
issuer-drives-grantee shape.

### ISSUE — `Ezagent.Cap.issue/3`
`apps/ezagent_core/lib/ezagent/cap.ex`. The grantor's step. `issue(authorization, target, cap)`
loads the **issuer's** held authority through the dependency-inverted `:authority_loader`
(config `:ezagent_core, Ezagent.Cap`), runs the full grant-authorization algorithm
(`CapabilityRegistry.authorize_grant/3` — the same action-axis + shape + delegation checks as
§3/§5), and on success stamps issuer provenance: `%{cap | granted_by: <issuer>, granted_at:
now}`, validating `granted_by` is `%URI{scheme: "entity"}` (else `{:error,
{:granter_not_entity, _}}`). **ISSUE transfers NO authority to the grantee** — it produces only
a provenance-stamped *artifact*. The four authorization tags
(`{:held_by}`/`{:admin}`/`{:rule}`/`{:genesis}`, §4) are unchanged and each maps 1:1 to the
issuer that `granted_by` records. `Ezagent.Identity.Grant.prepare/4` calls `Cap.issue` for
grant and `Cap.prepare_provenance` for revoke (both share the one provenance primitive —
`cap_provenance_chokepoint` gate).

### STORE — the grantee absorbs the artifact into its own `:caps` slice
Two lanes, both **grantee-driven**, never issuer-driven:
- **`create/1` self-store** — a keyed entity at Identity `create/1`/`activate/2` reads its OWN
  pre-issued artifacts (from `RecipeCapBinding`, below) and folds them in via
  `Ezagent.Cap.verified_set/1` (`behavior/identity.ex`).
- **`:vm_internal` absorb** — for a live grantee, `Ezagent.Identity.absorb_cap/2`
  (`identity.ex`) dispatches ONE `:absorb_cap` `%Cmd{}` with `caller: :vm_internal, caps:
  MapSet.new(), mode: :cast, reply: :ignore`. `handle_absorb_cap/2` accepts ONLY a
  `:vm_internal` caller (any other caller → `{:error, :unauthorized}`), verifies the artifact,
  and writes the slice via `store_verified_cap`. `absorb_cap` is a same-BEAM, same-node store
  that never issues authority; there is no cross-node absorb transport (`cap_absorb_reachability`
  gate — that requires Phase-4 crypto first). The absorb `%Cmd{}` is constructed in exactly one
  place (the `Ezagent.Identity` facade).

### VERIFY — `Ezagent.Cap.verify/1` at load/store boundaries
`verify/1` is total and fail-closed: true only for `%Capability{granted_by: %URI{scheme:
"entity"}}`. It runs at the reviewed boundaries only (`cap_verify_load_boundaries` gate, ≤5
homes): the grantee's `create/1`/`activate/2` slice load, the identity
`read_held_caps`/`list_caps_for` loader that feeds dispatch ctx, the snapshot load fallback,
and `store_verified_cap` on both the grant and absorb write paths. In Phase-3, `verify/1` is a
**provenance-format** check (entity-scheme `granted_by`) standing in for Phase-4 signature
verification — the seam is designed so Phase-4 swaps the one `verify/1` body without touching
callers.

> **⚠ SUPERSEDED by Path A (2026-07-18, PR #1457) — this paragraph is history.**
> `Ezagent.Cap.verify/1` **no longer exists on main**. The stand-in did NOT get its
> body swapped in place; the VERIFY responsibility was split into two real-crypto
> homes: a **born-signed storage filter** (`Cap.storable_for?`/`verified_set`) and a
> **strict crypto verifier at dispatch** (`Ezagent.Cap.Verifier` via
> `Authority.verify_current`). See **§4.6**. Do not describe verify as a
> "provenance-format / Phase-4-pending stand-in".

### How a stored grant is authorized at dispatch — the `cap_issued` runtime bypass
Because the grant *dispatch* itself is machinery (the grantee holds nothing yet),
`Kind.Runtime` step-5.5's first `cond` arm authorizes an `IdentityAdmin` `:grant_cap` dispatch
when `ctx.cap_issued == true` — with no separate matching cap. The token is safe because it is
stamped ONLY by the chokepoint, and ONLY on the `Cap.issue/3` success branch
(`grant.ex` `maybe_mark_issued(ctx, :grant_cap)`; revoke never stamps it). So an unauthorized
grantor ⇒ `Cap.issue` returns `{:error, _}` ⇒ no `cap_issued`, no dispatch; and an
externally-built ctx (web/CLI/MCP/workspace) can never carry `cap_issued` (nor forge the
`:vm_internal` absorb caller). These two trust-key properties are pinned by
`cap_issued_bypass_trust_keys_test.exs` (the N1 regression, §8).

### `RecipeCapBinding` — durable home for pre-issued recipe caps
`Ezagent.Identity.RecipeCapBinding` (`recipe_cap_binding.ex`). When a recipe is materialized
*before* its agent exists, the materializer calls `issue_and_upsert/4`: it ISSUEs every
proposed cap under the recorded issuer (`Cap.issue({:admin, issuer}, agent_uri, proposal)`),
validates the issued set (issuer/kind/target/workspace match), and only then commits the whole
set to a durable, version-and-tombstone-tracked binding keyed by agent instance. **Persistence
never dispatches a cap write to the grantee** — the keyed agent later reads the artifacts from
its own lifecycle hooks (the `create/1` self-store lane). Repeating a recipe is idempotent
(content-hash); changed content advances a monotone version.

### I12 — the paradigm lock (what's pinned)
`cap_self_store_paradigm_lock` invariant. The structural rule: **authority moves issuer →
artifact; storage moves only through the grantee's own lifecycle (`create/1`) or the
`:vm_internal` `absorb_cap` cast — never an issuer→grantee grant dispatch that drives the
grantee.** The gate:
- **forbids new issuer-driven grant sites.** The ~16 legacy
  `grant_cap`/`grant_cap_via_router` sites (12 files) are pinned as **shrink-only** migration
  debt (the exact `@legacy_grant_drivers` ledger — the count can only go DOWN, never up).
- the three Phase-3 cold-agent cutovers (recipe / orchestrator / workspace) are
  **zero-tolerance**: each must `issue_*` then `absorb_*`, with no `Identity.Grant`, no
  `mode: :call`, no `await_ready`.
- the companion `cap_issue_chokepoint` gate ratchets every provenance-bearing
  `%Capability{granted_by: …}` constructor and every explicit `{:set, :caps, …}` slice writer
  DOWN toward `Cap.issue`/`store_verified_cap`.

Adding a new grant driver, a new caps-slice writer, or a second `cap_issued`/absorb producer
fails CI.

### Accepted scope (Phase-3 — historical framing; see §4.6 for what actually landed)
Single-BEAM / trusted-node: the whole issue→store path (including `absorb_cap`) is same-node;
there is no cross-node transport. Crypto is **Phase-4**: `verify/1` checks provenance *format*
(entity-scheme `granted_by`), not a signature; a malicious in-VM actor is out of scope (the
`:vm_internal` trust model already trusts all in-VM code). Phase-4 replaces the `issue/3` and
`verify/1` bodies with signing + signature verification behind the same seam, and only then is
cross-node absorb transport unlocked.

> **⚠ CORRECTED 2026-07-18 (PR #1457).** "Crypto is Phase-4 (pending)" is stale.
> Per-Kind ed25519 signing + strict verification **landed as Path A** — caps are
> born-signed and strictly verified today. The in-VM-malicious-actor and cross-node
> concerns remain out of scope, but they are covered by the **deferred Path B**
> (isolated external signer), NOT by an unshipped Phase-4. See §4.6.

---

## 4.6 Cap authority & signing — Path A born-signed strict-verify (LANDED, PR #1457, 2026-07-18)

**This is the current cap-signing truth. It supersedes §4.5's "Phase-3 / Phase-4 stand-in"
VERIFY mechanism.** The ISSUE→STORE→VERIFY *flow* still holds; what changed is that VERIFY is
now real cryptography and `Ezagent.Cap.verify/1` is retired.

**Every target Kind is its own signing + verifying authority, using its OWN per-Kind ed25519
key.** Key material lives in a framework-owned compartment and never enters a Behavior slice,
snapshot, handler ctx, event, log, or generic admin listing; callers outside the framework
receive capability artifacts, never key material.

- **Authority compartment — `Ezagent.Cap.Authority`** (`apps/ezagent_core/lib/ezagent/cap/authority.ex`).
  The live authority struct is `Kind.Server` private top-level state (`@opaque`, `private_key`
  excluded from `Inspect`). Durable custody is a **dedicated top-level table**
  `kind_cap_authorities` (`Ezagent.Ecto.KindCapAuthority`,
  `apps/ezagent_core/lib/ezagent/ecto/kind_cap_authority.ex`) — append-only, `generation`-tracked,
  one-active-per-URI, `private_key` `redact: true`, no delete API. **Keys are NOT in env vars**
  (the old `EZAGENT_SIGNING_SEED_V1` master-seed approach was retired with #1457 — zero refs in
  `apps/` prod code or `config/`) and **NOT in `kind_snapshots`**. **Genesis is a single
  admin-pinned root**: `genesis/2` seeds `entity://user/system/admin`'s authority first;
  `regenesis/3` requires `presenter == admin_uri()` else `:admin_required`.
- **Born-signed at issue** — `Ezagent.Cap.issue/3` (`cap.ex`) authorizes the issuer, then asks
  the **concrete target Kind's authority** `Authority.sign/2` to ed25519-sign the immutable grant
  intent (`key_id` = the per-Kind public key's fingerprint). Caps are signed from birth.
  `granted_by` is still the real-entity issuer (§4 provenance unchanged).
- **Storage filter (structural, not an authz decision)** — `Cap.storable_for?/2` +
  `verified_set/2` (`cap.ex`) admit only born-signed (non-empty `signature` + `key_id`) and
  receiver-bound (`grantee_uri == receiver`) artifacts into a cap store; **unsigned / legacy
  artifacts are discarded at storage**. The legacy-unsigned fallback was **removed**
  (`capability.ex:282`, codex r4 SPEC option-B).
- **Strict crypto verify at dispatch** — `Ezagent.Cap.Verifier`
  (`apps/ezagent_core/lib/ezagent/cap/verifier.ex`) is the **single** framework verifier that
  dominates every Kind handler invocation. For a **cap-gated** action, `verify_cap` accepts a cap
  **only if** (a) `Authority.verify_current(cap, presenter)` cryptographically verifies (signature
  valid under the current per-Kind authority + `key_id` match + bound to the authenticated
  presenter) **and** (b) it matches the required shape; unsigned / malformed / tampered /
  retargeted / wrong-key artifacts **fail loud** (`:invalid_cap_signature` / `:missing_cap` /
  `:presenter_required`). **There is NO soft / permissive branch.**
  - Alongside cap-gated dispatch there is a fixed **`@non_cap_actions` allowlist**
    (`Agent`/`User.Receive` `:receive`; `IdentityAdmin` store ops `absorb_cap`/`persist_caps`/
    `store_cap`/…; socialware `:snapshot`/`:history`; session admission actions) — each with its
    own in-handler predicate. This is an **interim structural split, not a soft fallback**. So the
    model is "**cap-gated actions get strict crypto verification + an explicit non-cap
    allowlist**", NOT "every action needs a signed cap".

**Threat model = Path A (reviewed-code).** Code already executing maliciously inside the BEAM is
**explicitly out of scope** — all loaded code (including community plugins) is reviewed before
load (see the `Cap.Verifier` / `Cap.Authority` moduledocs). Path A defends: accidental forgery,
review-missed architecture violations, external-ingress caller-spoofing. **Signing ≠
revocation** — cap-signing defends forgery / tamper / retarget / issuer-spoof; revocation is a
separate line (epoch target-generation + `delete_user` cascade).

**Path B — the isolated signer domain (external signer / sidecar / HSM) + `Cap.issue`
issuer-URL authentication — is DEFERRED / roadmapped**, not pending-now/required-now. It defends
against **in-VM malicious code** (extracting the seed / impersonating an issuer), for when
unreviewed 3rd-party plugins run in-BEAM. The old v11 "isolated central signer / single CapStore
/ one-shot re-sign" spec (2026-07-15) **IS Path B**, superseded by Path A for current needs. **Do
not describe Path B as pending or required now.**

Refs: `Ezagent.Cap.Authority` + `Ezagent.Cap.Verifier` moduledocs; ARCHITECTURE.md §7.8;
GLOSSARY Decision #164 + §2 "Cap authority & signing (Path A)"; PR #1457 (commit `596bd3a1d`).

## 5. `rule_cap_bounded?` and the rule branch

`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex`. A `{:rule, …}` grant carries
`ctx.caps = []`, so the normal cap check would deny it. `Kind.Runtime` step-5.5 has a
narrowly-fenced branch: when `ctx[:authorization_rule]` is set AND the dispatch is
`IdentityAdmin` `grant_cap`/`revoke_cap`, it defers authorization to the handler's
`check_grant_authorized` rule branch, which enforces:

```
rule_cap_bounded?(cap) :=
  cap.kind != :any and cap.behavior != :any and
  (scope_bounded_instance?(cap.instance) or
   (match?(%URI{}, cap.instance) and Capability.action_of(cap) != :any))
```

i.e. a rule may NOT mint a `kind:any` / `behavior:any` cap, and an `action:any` cap is
allowed only with a scope-bounded instance. This is **written to match
`check_action_wildcard_grant_authorized` exactly** (which runs first) so the rule branch is
actually reachable — an `action:any` + concrete-`%URI{}` cap would be rejected by the
wildcard gate before the rule branch is seen, so `rule_cap_bounded?` doesn't advertise it.

The bypass is **safe from injection**: `:authorization_rule` enters `ctx` ONLY via the
chokepoint's `{:rule, …}` tag, and grant/revoke dispatch construction is grep-gated to the
chokepoint. External entry points (web/CLI/MCP/workspace) build `ctx` from a fixed key set
with no payload→ctx splat; no deserialization rehydrates a dispatch ctx; no untrusted node
delivers one (verified, PR #815 security review). **Revoke under a rule tag is authorized
SOLELY by the step-5.5 bypass** (`rule_cap_bounded?` is grant-only) — acceptable because
revoke only de-escalates.

`cap#2` (the orchestrator worker-spawn `agent/_/{:spawned_by}`) is `behavior: :any`, so it is
**rule-INELIGIBLE** — it uses `{:genesis, owner}`, not `{:rule}`. Same for any
Manage-shaped (`behavior: Manage, action: :any, concrete instance`) cap.

---

## 6. `User.default_caps` — the universal baseline (and the per-session target)

`apps/ezagent_domain_identity/lib/ezagent/entity/user.ex` — **as of the per-session refactor,
`default_caps(workspace_uri)` now returns `[]`** (verify: `user.ex:175`). The per-session
narrowing landed: a fresh user holds NO standing caps; session participation (`:send`/`:join`)
is granted **per-session at join, by the session owner**.

> **Historical (pre-refactor, for context):** `default_caps/1` used to return one broad cap
> `%Capability{kind: :session, behavior: :any, action: :any, instance: :any, workspace_uri: <ws>,
> granted_by: system://bootstrap}` — so any user could participate in any session in their
> workspace, and `Session.handle_join` granted no per-session caps. That broad baseline is gone
> (corrected here 2026-06-22); do not assume a user has session caps by default.

**The per-session model (LANDED — `default_caps` now `[]`):** "a member not pulled into a
session should not have that session's permissions." The broad baseline is **gone**;
participation is granted **per-session at join, by the session owner** (`grant_first_join_owner_cap`
in `membership.ex`; the anon `public_view` flow is the same template). The `system://bootstrap`-granted
broad baseline is removed and #154 is realized down to the default grant. **Do not assume a user
has session caps by default** — they have `[]` until granted at join.

---

## 7. System principals (`SystemPrincipal.Catalog`)

`apps/ezagent_core/lib/ezagent/system_principal/catalog.ex` — the **closed** allowlist of
`system://` principals and their caps. Adding one is a review surface ("are we adding ambient
authority?"). Four shapes:

- **genesis full-wildcard** (`bootstrap`, and `chat-router`/`chat-reply`/`mix-task` which hold
  `bootstrap_wildcard`): all-5-axes `:any`. Governed by `no_wildcard_system_principals_test`,
  EXCLUDED from the no_unowned minter check. `bootstrap` is the accepted genesis root.
- **narrow** (workspace-loader, orchestrator-tools, session-internal, template-materialize
  [non-minter after PR #815], socialware-gc): a precise `Capability.cap/N` per the Behavior's
  real `required_caps`. (`agent-internal` was eliminated 2026-06-19 — its sole
  `cap(:agent, Sandbox, :write_path)` was the agent writing its OWN sandbox → re-attributed
  to agent self-authority carried inline at the `Agent.TemplateSpawn` dispatch; same play as
  the already-eliminated `worker-publish`.)
- **empty / audit-only** (lv-anon-mount, credential-materializer): hold NO standing caps;
  least-privilege authority is minted per-use (e.g. credential `GrantCap`).
- **minter** (holds `IdentityAdmin :grant_cap`/`:revoke_cap`): the `no_unowned` program is
  eliminating these. As of the #154 program only `feishu-binding-policy` remains, pending the
  per-session refactor.

A principal's caps are its `ctx.caps` when a dispatch runs "under" it — i.e. a principal is
an **authorizer**, never a `granted_by`.

---

## 8. The gates (what CI enforces)

| gate (test/task) | enforces |
|------------------|----------|
| `no_unowned_system_principal_grant_test.exs` | every `system://` principal that MINTS (holds grant/revoke cap) is explicitly classified; the allowlist only shrinks. The Decision-#154 ratchet (target: 0). |
| `no_wildcard_system_principals_test.exs` | only the sanctioned genesis principals hold the full 5-axis wildcard. |
| `grant_dispatch_chokepoint_test.exs` | no grant/revoke dispatch is constructed outside `Ezagent.Identity.Grant` (literal + variable-action). |
| `check_action_wildcard_grant_authorized/2` (runtime) | a wildcard-action grant needs admin authority or a scope-bounded instance. |
| `no_admin_caps_fallback_test.exs` | no ad-hoc principal mint; the Catalog is closed. |
| `mix ezagent.check_invariants` (#1 cap-check-only-at-chokepoint, …) | cap checks live at the dispatch chokepoint, not scattered. |
| **Phase-3 (cbac-done-right):** | |
| `cap_self_store_paradigm_lock_test.exs` (I12) | authority moves issuer→artifact; storage only via grantee `create/1` self-store or `:vm_internal` absorb; ~16 legacy grant drivers are shrink-only; the 3 cold-agent cutovers are zero-tolerance. |
| `cap_issue_chokepoint_test.exs` (I7) | every provenance-bearing `%Capability{granted_by:}` constructor + every `{:set, :caps, …}` writer is ratcheted (shrink-only) toward `Cap.issue` / `store_verified_cap`. |
| `cap_absorb_reachability_test.exs` (I2/I8) | `absorb_cap` is VM-internal, same-node, verifies, never self-issues; no cross-node absorb transport. |
| `cap_provenance_chokepoint_test.exs` (I11) | `Ezagent.Cap` is the sole home that stamps `granted_by`; grant issues, revoke shares the provenance primitive. |
| `cap_verify_load_boundaries_test.exs` (I5) | `Cap.verify`/`verified_set` live only at ≤5 reviewed load/store homes, never beside a `matches?/2` check. |
| `cap_issued_bypass_trust_keys_test.exs` (N1) | the `cap_issued` runtime bypass: unauthorized grantor ⇒ `Cap.issue` error ⇒ no token / no dispatch; `cap_issued` is written only at the grant chokepoint. |

**Run the FULL suite before any admin-merge** — a green security subset is not a green PR
(see `feedback_run_check_invariants_gate`).

---

## 9. Pitfalls (every one of these has bitten someone)

1. **`granted_by = caller`.** The authorizer (`ctx.caps`) and the granter (`granted_by`) are
   different. Never default `granted_by` to whoever happened to call. Use a `Grant` tag.
2. **Setting `caller`/`granted_by` but not `ctx.caps`.** Authorization reads `ctx.caps`;
   an empty-caps grant fails closed on every non-self path. The tag populates `ctx.caps`.
3. **Relying on `normalize!/2` to stamp `granted_by`.** It ignores the granter for an
   already-built struct. The chokepoint does an explicit struct update + entity validation.
4. **Forcing a `behavior:any`/`action:any`+concrete-instance cap through `{:rule}`.**
   `rule_cap_bounded?` rejects it. Use `{:genesis, owner}` (genesis) instead.
5. **`grant_cap_via_router` defaulting to `:async`/`:cast` when the caller gates on the
   result.** `:cast` returns `:ok` immediately and swallows the grant failure. Pass `:sync`.
6. **Treating `template-materialize`/`feishu-binding-policy` as a `granted_by`.** A system
   principal is an authorizer; the `granted_by` must be the real configurer/owner entity.
7. **Storing a URI under a map key with inline `URI.to_string` on the same line.** Trips
   `uri_query.scan`'s `:uri_string_key` heuristic — extract a `uri_to_string/1` helper
   (see `CustomerController` / `anon_cookie.ex`).
8. **Admin-merging on a security-test subset.** #808 left main red on `uri_query.scan` this
   way. Run arch.scan + check_invariants + doc.scan + uri_query.scan + touched-app tests.

---

## 10. "I need to grant a capability" — quick checklist

1. Build the cap (5 axes; least-privilege — concrete instance + workspace, specific action).
2. Pick the tag (§4 decision tree). The `granted_by` it derives must be a real entity.
3. Call the right `Ezagent.Identity.Grant` wrapper (imperative vs effect; `:sync` if the
   caller gates on the result).
4. Never hand-roll the dispatch — the grep gate will fail you, and rightly.
5. If you reach for a new `system://` principal, stop: that's a Decision-#154 review surface.

See also: `references/architecture-invariants.md` (the CI-gate detail),
`references/design-principles.md` (P-series), `GLOSSARY.md` Decision #153/#154,
`docs/notes/2026-06-16-capbac-system-principal-audit.md` (per-principal classification),
`docs/superpowers/specs/2026-06-17-unified-grant-chokepoint.md` (the chokepoint design).
