# CapBAC — capability authorization, end to end

The permission model is the single most pitfall-prone area of ezagent. This file is
the authoritative reference: read it **before** touching anything that grants, revokes,
checks, or declares a capability. Every claim here is grounded in the code on `main`;
verify against the cited modules before relying on a detail (the code wins).

> **The one-sentence model:** a dispatch is authorized by the **caps the dispatch ctx
> carries** (`ctx.caps`), a capability records **who is accountable for it**
> (`granted_by`, which MUST be a real entity — Decision #154), and these are produced at
> exactly one chokepoint (`Ezagent.Identity.Grant`). Confusing any two of these is how
> every bug in this area happens.

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
- `behavior` — the Behavior module (`Ezagent.Behavior.Session`, …) or `:any`
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
| `{:system, principal, entity}` | the Catalog `principal`'s caps | `entity` | **transitional**: preserves a system-principal authorizer while forcing an entity `granted_by`. Convert to one of the above and drop the principal. |

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
   and it's `behavior:any`/`action:any` so rule-ineligible? → `{:system, bootstrap, owner}`.
   `bootstrap` is the accepted genesis root (governed by `no_wildcard_system_principals_test`,
   NOT a Decision-#154 violation); `granted_by` = the owner entity.
4. None fit cleanly? **Do not invent a workaround** — surface it. A new system-principal
   authorizer is a Decision-#154 review surface.

---

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
**rule-INELIGIBLE** — it uses `{:system, bootstrap, owner}`, not `{:rule}`. Same for any
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

**Target model (the per-session refactor, in progress):** "a member not pulled into a
session should not have that session's permissions." The baseline is narrowed and
participation is granted **per-session at join, by the session owner** (reusing
`grant_first_join_owner_cap` in `membership.ex`; the anon `public_view` flow is the existing
template). When this lands, the `system://bootstrap`-granted baseline goes away and #154 is
fully realized down to the default grant. Until then, treat the broad `default_caps` as
known debt, not a pattern to copy.

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
   `rule_cap_bounded?` rejects it. Use `{:system, bootstrap, owner}` (genesis) instead.
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
