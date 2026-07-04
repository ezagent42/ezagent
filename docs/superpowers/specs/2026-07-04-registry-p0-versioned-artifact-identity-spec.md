# P0 Spec — Versioned, Promotable Artifact Identity for Socialware Definitions

**Type:** Implementation spec (P0 of the Socialware Registry & Distribution Plan)
**Date:** 2026-07-04
**Author:** Claude Opus 4.8 (1M context), for Allen
**Status:** Draft for lead review → writing-plans
**Parent plan:** `docs/superpowers/specs/2026-07-04-socialware-registry-and-distribution-plan.md`
(landed as PR #1169) — P0 line §6, "biggest missing piece" §1.4, R-2 §3/§7, O-1 §4.4/§7.

> This spec turns prod's per-node config table into a **registry** by giving a published
> socialware `Definition` a **stable, environment-independent, promotable artifact identity** plus a
> **version**, makes installs **pin** to a specific revision, adds **def-level retract**, unifies the
> two divergent in-code seeds onto **one content-hash idempotency primitive** (killing R-2), and
> lands the **`owner_policy`** field the anon public homesite needs (O-1, DECIDED yes by lead).

Every design claim below is grounded in code with `file:line`. The appendix separates
**CONFIRMED-in-code** from **PROPOSED**.

---

## 1. Goal

A socialware `Definition` today is a config manifest with no machine identity beyond its `name`, a
free-form `version` string that is never enforced, and an install path that resolves defs **by name
to whatever the current pointer is**. That is a runtime config table, not a registry.

P0 delivers the one property that distinguishes a registry (npm/docker) from a config table:

> **A named, versioned, environment-independent artifact that can be pinned on install, promoted
> between environments, and retracted from the catalog — without an install silently mutating
> underneath a running session.**

**In scope (P0):**
1. Versioned artifact identity — a first-class, stored **content-hash** + the existing per-env
   **revision id**, plus keeping `version` as an advisory tag.
2. Pin-to-version on install — installs resolve a **pinned revision**, not the live pointer.
3. Def-level unpublish / retract — withdraw a published def from discovery; grandfather pinned
   installs.
4. Unified idempotency primitive — one **content-hash** publish/upgrade both seeds call (fixes R-2).
5. The `owner_policy` field on `Definition` (O-1, DECIDED) that lets install reproduce owner +
   orchestrator-auto-join for an anon public homesite.

**Out of scope (deferred to later phases, per the parent plan):**
- Catalog browse/search/detail UI (P1).
- Retiring the bespoke `:hello` URI-type creation path + `PageView` `OR` (P2 — this spec's
  `owner_policy` is its *enabler*, not its execution).
- External config source-of-truth repo + `mix ezagent.socialware.publish --from <dir>` deploy-seed
  pipeline (P3 — this spec's unified primitive is the *primitive* it will call, not the pipeline).
- Enforced semver / monotonic version bump on publish (Open Decision D-1).

---

## 2. Current state (CONFIRMED-in-code)

### 2.1 Three identity primitives already exist — none is first-class

| Primitive | What it is | Env scope | Today's role | Citation |
|---|---|---|---|---|
| **Content-hash** — `sha256(json_normalize(Definition.body))` | Deterministic over the manifest bytes | **Environment-INDEPENDENT** (same bytes → same hash anywhere) | Only computed transiently inside a `source_turn_id` for seed idempotency; **not stored, not queryable** | `definition_registry.ex:328-337` (`builtin_upgrade_source_turn_id`) |
| **`ConfigObject.id`** — an `Ecto.UUID` minted per write | Immutable append-only revision row | **Environment-LOCAL** (random UUID; dev's id ≠ prod's id for the same bytes) | The immutable revision a write produces; already stored in the per-session install record | `config_object.ex:12` (`@primary_key {:id, :string, autogenerate: false}`, append-only moduledoc), `config_store.ex:609` (`id: Map.get(attrs, :id) || Ecto.UUID.generate()`), `installation.ex:308-312` (`definition_config_id: object.id`) |
| **`Definition.version`** — a free-form string, default `"0.1.0"` | Human tag | n/a | Displayed in `list/1`; **never enforced, never bumped** | `definition.ex:13` (`version: "0.1.0"`), `definition.ex:61` (`optional_string(attrs, :version, "0.1.0")`), `definition_registry.ex:211` (surfaced in `list_entry_for`) |

**Consequence:** the *content-hash* is the one primitive that answers "this def in prod is the SAME
artifact authored in dev", but it is thrown away after computing a `source_turn_id`. The
*revision id* is a perfect within-env pin, but it is inconsistently honored (§2.3). The *version
string* is decorative.

### 2.2 Publish → store → discover → install (CONFIRMED)

- **Publish** — `Ezagent.Socialware.ConfigGovernance.Socialware` is a CR lifecycle
  (`open_cr → stage_definition → publish_cr`, `socialware.ex:41/60/81`). Public scope is admin-gated:
  `publish_cr → authorize_public_scope → authorize_admin` requires
  `Ezagent.Identity.AdminAuthority.admin?/2` (`socialware.ex:86,113-121,144-151`).
- **Store** — each `publish_cr` writes a **new immutable `ConfigObject`** and repoints the current
  pointer (`ConfigStore.write_and_point`, `config_store.ex:56-72`; append-only rollback-by-repoint,
  `config_object.ex:1-8`). **So each publish = a new revision id.** Subject is the non-URI
  `socialware:<name>`, layer `"workspace"`, key `"socialware"`
  (`definition_registry.ex:14,27-31`).
- **Discover** — `DefinitionRegistry.list/1` returns defs visible to a caller workspace (own +
  system + any `scope: :public`), keyed by name, deduped, sorted by visibility rank
  (`definition_registry.ex:107-120,204-231`). `lookup/2` resolves caller → system → public fallback
  (`definition_registry.ex:36-45,153-199`).
- **Install** — `/sessions` create → `SocialwareInstall.prepare_create_template/4` validates the ref
  is visible, writes a local install template `%{installs: [ref]}`, tags it `current`, hands it to
  `session.create` (`socialware_install.ex:20-43,55-70`). Materialization of the def's behaviors +
  agents/members happens on the create path (§2.3, §2.6).

### 2.3 The pin split — the spine of the pin section (CONFIRMED)

The per-session **install record already pins a specific revision**, but the **behavior set the
session actually runs with re-resolves the current pointer**. Two paths, two answers:

- **Install record — PINNED.** `seed_install` stores
  `install_body = %{ref:, seed_config:, definition_subject_uri: object.subject_uri,
  definition_config_id: object.id}` (`installation.ex:288-312`). `installed_definitions/1` reads it
  back via `ConfigStore.fetch_object(config_id)` — the **exact immutable revision**, not the current
  pointer (`installation.ex:274-283`).
- **Behavior set — LIVE-RESOLVED.** `behavior_set_for_template/2` (called on session spawn to build
  the Session host's behavior list) resolves via `resolve_definitions → DefinitionRegistry.lookup`
  (`installation.ex:53-56,313-322`), which returns **whatever the current pointer is**
  (`definition_registry.ex:36-45`). The `install_spec` type carries **no version**:
  `%{ref: String.t(), config: map()}` (`installation.ex:16`), and `parse_install` produces only
  `%{ref:, config:}` (`installation.ex:339-366`).

**So today:** publish a new revision of a def, and every already-running install of it silently
picks up the new *behaviors* on next spawn/rehydrate, while its install *record* still points at the
old revision. The registry already has the pin primitive (`definition_config_id`); it just isn't the
thing that decides what the session runs. There is also an explicit re-point primitive,
`repoint_template_installs/4` (`installation.ex:88-113`), that is meant to be the *only* way a
binding moves — the name-lookup in `behavior_set_for_template` bypasses it.

### 2.4 The divergent-idempotency trap — R-2 (CONFIRMED)

Two in-code seeds, two different idempotency rules:

1. **`DefinitionRegistry.seed_builtin_definitions/0`** (built-in `chat` + `socialware`, seeded at
   boot) → `seed_builtin_definition/2` is **idempotent-on-CONTENT**: unchanged body →
   `{:ok, :exists}`; changed body of a **seed-owned** object → re-writes with a content-hash
   `source_turn_id` (`definition_registry.ex:275-337`). An edited manifest **re-promotes**.
2. **`Demo.Hello.publish/0`** (the hello demo, published at plugin boot via governance) is
   **idempotent-on-EXISTENCE**: `if already_public?(ws) do {:ok, :exists} else do_publish(ws)`
   (`demo/hello.ex:128-136`), where `already_public?` only checks *presence of a public def by name*
   (`demo/hello.ex:169-174`). **An edited hello manifest is NOT re-applied on redeploy.**

This is R-2: any future deploy-seed that inherits path 2's semantics will silently fail to promote
first-party manifest edits. §5 unifies both onto content-hash.

### 2.5 No def-level retract (CONFIRMED)

Only CR-level `reject_cr` (`socialware.ex:103-111`) and `ConfigChangeStore.mark_rolled_back`
(`config_change_store.ex:353-354`) exist. There is no way to withdraw an already-published def from
`list/1` discovery or the `lookup/2` public fallback.

### 2.6 No owner field; owner is hard-coded on the bespoke path (CONFIRMED — O-1)

`Definition` carries `agents`, `members`, `orchestrator_template_uri`, `routing_rules`, and
`visibility_policy` (`definition.ex:12-28`) but **no `owner`**. The bespoke hello path hard-codes it:
`spawn_kind(Session, %{... owner_uri: User.admin_uri() ...})` (`app.ex:50-57`), with the comment
"Without this the session is ownerless and every message falls to the concierge" (`app.ex:52-54`).
An anon public homesite has **no logged-in installer** to inherit ownership from, so the owner must
come from the Definition.

**Orchestrator-auto-join is already expressible.** `DefinitionAgents.materialize_definition_agents/4`
turns a Definition's `agents` (`%{recipe, role_name, flavor}`) into **live session members that join
carrying their `role_name` facet** — CONFIRMED by `definition_agents_materialize_test.exs:8-13`
("the agent joins as a member carrying its `role_name` facet"). So the orchestrator that
`App.ensure_app` creates imperatively (`ensure_orchestrator → create_role_agent + join_as
"orchestrator"`, `app.ex:87-108`) is reproducible by **declaring it as an `agents` entry**
(role_name `"orchestrator"`, flavor `"hello"`). The **only** schema gap the install path cannot
express today is **owner** — which P0 closes.

### 2.7 Validation is code-presence-gated (CONFIRMED — bounds env-independence)

`Definition.new/1` validates `bases`/`shape`/`views` through `behavior_module/1`, which requires
`Code.ensure_loaded?(mod) and Ezagent.ActionSet.new_style?(mod)` (`definition.ex:194-200`, views via
`definition.ex:67`). A def only *resolves* where its referenced code is loaded — the parent plan's
§1.3 invariant. This bounds "environment-independent": the **content-hash is portable**, but a
manifest still only rehydrates where its `uses`/`views` code is deployed. P0's identity does not
change that; it makes the identity checkable, ordering stays P3's concern.

---

## 3. Versioned artifact identity design

### 3.1 Decision — a three-layer model, content-hash is canonical

| Layer | Field | Answers | Model chosen | Why (vs alternatives) |
|---|---|---|---|---|
| **Artifact identity** | `content_hash` (stored, queryable) = `sha256(json_normalize(body))` | "Is prod's def the SAME artifact authored in dev?" | **Content-hash** | Env-independent by construction; the primitive already exists (`definition_registry.ex:328-337`) and already backs seed idempotency. Semver can't answer cross-env sameness (two envs can carry `0.1.0` with different bytes); a per-env revision UUID is env-local. |
| **Revision** | `ConfigObject.id` (exists) | "Which exact published revision is this?" / "what does an install pin?" | **Published-revision-id** | Immutable append-only row per `publish_cr` (`config_store.ex:56-72`); already stored in install records (`installation.ex:311`). Each `publish_cr` = a new revision — no new machinery. |
| **Advisory tag** | `Definition.version` (exists) | Human "which release" | **Opaque string, NOT enforced in P0** | Machine identity is the hash; forcing monotonic semver adds authoring friction with zero P0 payoff. Enforcement is Open Decision **D-1**. |

**Rationale for content-hash as canonical (the task's core fork):** the task asks whether identity
is content-hash vs monotonic/semver vs published-revision-id. The answer is **content-hash for
cross-env identity, published-revision-id for within-env pinning** — they are complementary, not
competing, and *both already exist in the codebase*. The registry's missing piece is not a new
scheme; it is **promoting the content-hash to a first-class stored field** and **making the revision
id the thing installs bind to** (§4). Semver is rejected as the identity because it cannot detect
drift (same tag, different bytes) — exactly the "same artifact across envs" property the registry
needs; it stays available as an advisory display tag.

### 3.2 What P0 adds

- **`content_hash` becomes a first-class stored + queryable field** on the published object.
  - **Storage (PROPOSED):** compute `content_hash` from `Definition.body` and record it on write.
    Preferred: a dedicated `content_hash` column on `socialware_config_objects`, populated in
    `object_attrs/1` (`config_store.ex:607`) from `body`. (Alternative, no-migration: fold it into
    the `source_turn_id` grammar as today — rejected: not queryable, overloads the turn-id.)
  - The hash is computed with the **same normalization already used**:
    `body |> json_normalize() |> Jason.encode!() |> :crypto.hash(:sha256, …) |> Base.encode16`
    (`definition_registry.ex:322-337`). One helper, `Definition.content_hash/1`, becomes the single
    source of that computation, called by both the store and the idempotency primitive (§5).
- **`Definition.version` stays** as-is (advisory), surfaced in `list/1` alongside a short
  `content_hash` prefix so the catalog (P1) and operators can see drift.
- **Each `publish_cr` = one revision** (already true, `config_store.ex:56-72`); P0 makes that
  revision's `content_hash` recorded and its id the install target.

### 3.3 CR-publish-lifecycle interaction

No change to the CR lifecycle shape. `publish_cr` continues to produce a new immutable revision; P0
adds only that the revision carries its `content_hash`, and that a publish whose body hash equals the
current published body's hash **short-circuits to `:exists`** (§5) so a no-op redeploy does not open
a CR or mint a revision. Env promotion (P3) = publish the *same bytes* to the target env's registry;
identity of the promoted artifact is verified by equal `content_hash` (env-independent), not by the
revision id (env-local).

---

## 4. Pin-to-version on install

### 4.1 Principle

An install binds to a **specific revision** (`ConfigObject.id`), recorded with the env-independent
**`content_hash`** for audit/promotion. A later registry publish creates a *new* revision and does
**not** move a running install; a binding moves **only** via the explicit `repoint_template_installs`
primitive (`installation.ex:88-113`). This closes the §2.3 split.

### 4.2 Changes (PROPOSED)

1. **`install_spec` carries an optional pinned revision + hash.**
   `%{ref: String.t(), config: map(), config_id: String.t() | nil, content_hash: String.t() | nil}`
   (extends `installation.ex:16`). `parse_install` defaults both to `nil` (= "pin whatever is current
   at install time"), so existing `installs: [ref]` templates keep working
   (`installation.ex:339-366`).
2. **Resolution honors the pin.** `resolve_definitions/2` (`installation.ex:313-322`) resolves a
   pinned `config_id` via `ConfigStore.fetch_object/1` (the exact revision) and falls back to
   `DefinitionRegistry.lookup` **only when `config_id` is `nil`** (fresh install → resolve current,
   then record the resolved `object.id` + `content_hash` into the install spec, exactly as
   `seed_install` already records `definition_config_id`, `installation.ex:308-312`).
3. **Behavior-set resolution routes through the pin.** `behavior_set_for_template/2`
   (`installation.ex:53-66`) — the path that today live-resolves the current pointer — resolves the
   **pinned** revision for an already-installed session, so the behaviors the Session host rehydrates
   with match the pinned install record. This is the concrete fix for §2.3.
4. **Upgrade is explicit.** `repoint_template_installs/4` (`installation.ex:88-113`) becomes the sole
   way an install advances to a newer revision: it re-resolves the def (optionally to a chosen
   revision), re-points the install record's `config_id`/`content_hash`, and the next spawn rebuilds
   behaviors from the new pin. Re-install of the same ref is idempotent
   (`seed_object_if_no_pointer`, `installation.ex:288-303`).

### 4.3 Where the pin lives

The pin lives **in the per-session install record** (`socialware_config_objects` under the session
subject, install layer — `installation.ex:288-312`), which already stores `definition_config_id`.
P0 adds `content_hash` to that same body and makes it the resolution key. No new store; the pin is
already persisted — P0 makes it *authoritative*.

---

## 5. Unified idempotency primitive — the R-2 fix

### 5.1 One primitive, content-hash only

Both seeds (and the future P3 deploy-seed) call **one** primitive:

```
ConfigGovernance.Socialware.publish_or_upgrade(definition, ctx) ::
  {:ok, :published | :upgraded | :exists} | {:error, term()}
```

Semantics (**hash-comparison only — NO provenance guard**):

1. Resolve the current published object for `(name, workspace)` (`DefinitionRegistry.lookup/2`).
2. **None** → `open_cr → stage_definition → publish_cr` → `{:ok, :published}`.
3. **Present, `content_hash(current.body) == content_hash(new.body)`** → `{:ok, :exists}`, **no CR
   opened, no revision minted**.
4. **Present, hashes differ** → `open_cr → stage_definition → publish_cr` → `{:ok, :upgraded}`.

Steps 2 and 4 go through the **full governance flow**, so the public-scope admin gate
(`authorize_public_scope → authorize_admin`, `socialware.ex:113-151`) and R-5's genuine-admin
authority are preserved — the primitive never does a direct ConfigStore write to bypass moderation.

### 5.2 Why the provenance guard is DROPPED (critical — do not re-add)

Today's `seed_builtin_definition/2` only upgrades an object whose `source_turn_id` starts with
`socialware-definition-seed*` (`builtin_seed_object?/1`, `definition_registry.ex:307-315`). **Hello's
object is written by governance** (`open_cr → stage → publish_cr`, `demo/hello.ex:145-155`), so it
carries a **CR-owned `cr-stage:`/publish turn-id, not the seed prefix**. A unified primitive that
kept the provenance guard would classify Hello's object as a foreign override → `:exists` → **never
re-promote** — re-introducing R-2 for the exact path it targets. Therefore idempotency is **hash
comparison only**. The "deploy re-seed overwrites hand-edits in this workspace" behavior becomes an
**explicit stated policy** — the config repo / deploy-seed is the source of truth for first-party
public defs (parent plan §5.2) — not an implicit `source_turn_id` check.

### 5.3 Both seeds converge

- **`Demo.Hello.publish/0`** (`demo/hello.ex:128-136`): drop `already_public?` existence-check; call
  `publish_or_upgrade(definition, admin_ctx)`. An edited hello manifest now re-promotes.
- **`DefinitionRegistry.seed_builtin_definitions/0`** (`definition_registry.ex:49-56,275-305`):
  built-ins route through the same primitive (governance-published rather than the direct
  `write_definition` + `authority: :system_seed` path). Content-hash idempotency is preserved; the
  bespoke `builtin_upgrade_source_turn_id` / `builtin_seed_object?` machinery
  (`definition_registry.ex:307-337`) is replaced by `Definition.content_hash/1` + `publish_or_upgrade`.
- **Future P3 deploy-seed** (`mix ezagent.socialware.publish --from <dir>`) calls the **same**
  `publish_or_upgrade` — one idempotency rule across all first-party publishing.

> **Note (governance vs direct-write consolidation):** moving built-ins onto governance is a real
> behavior change (built-ins gain a CR trail; the direct `write_definition` seed path retires). It is
> the correct convergence — one publish primitive — but the lead should confirm the built-in seed is
> allowed to open CRs at boot. See Open Decision **D-2**.

---

## 6. Def-level unpublish / retract

### 6.1 Principle

Today the registry has **no way to withdraw an already-published def** — only CR-level
`reject_cr`/`mark_rolled_back` (§2.5). P0 adds **def-level retract**: a published def is removed from
the **catalog** (discovery + new-install lookup) while **existing pinned installs are grandfathered**
(they keep resolving the exact revision they pinned). Retract is a **catalog-state change, not a new
artifact** — so it does not mint a new revision or change the artifact's `content_hash` (Open
Decision **D-4**).

### 6.2 What retract does (PROPOSED)

Add `ConfigGovernance.Socialware.retract/2` (def-level, admin-gated exactly like public publish —
`authorize_admin`, `socialware.ex:144-151`). It records a **retract marker** for `(name, workspace)`
— **separate from the def `body`** so the artifact identity is preserved (D-4) — that:

1. **Excludes the def from discovery.** `DefinitionRegistry.list/1` filters retracted entries
   (`list_entry_for/3`, `definition_registry.ex:204-220`).
2. **Blocks new installs.** The `lookup/2` public fallback (`public_object/1`,
   `definition_registry.ex:182-199`) skips a retracted def, so a fresh
   `SocialwareInstall.prepare_create_template/4` (`socialware_install.ex:48-53`) fails with the
   existing `{:error, {:unknown_socialware_install, ref}}`.
3. **Leaves the immutable revisions intact.** The append-only `ConfigObject` rows
   (`config_object.ex:1-8`) are never deleted.

### 6.3 Grandfathering (PROPOSED — coupled to §4)

An existing install pins a specific `config_id` (§2.3). Its `installed_definitions/1` resolution goes
through `ConfigStore.fetch_object(config_id)` (`installation.ex:274-283`), which is **unaffected by
retract** — the immutable revision still exists. So a running install of a retracted def keeps
working. **This only holds because P0 also routes behavior-set resolution through the pinned
`config_id`** (§4.2 item 3): if `behavior_set_for_template` still name-resolved the current pointer,
retract-then-`lookup` would fail and a grandfathered session's behavior-set rebuild would break. §4
and §6 are therefore one atomic P0 (§9).

### 6.4 Un-retract

Retract is reversible: clearing the marker re-lists the def. No revisions were lost, so restore is a
marker delete — the def resumes at its last-published revision with its original `content_hash`
(the D-4 payoff: identity survives a retract/restore cycle).

---

## 7. O-1 — the `owner_policy` field (DECIDED: yes, P0)

Lead decision (2026-07-04): **P0 adds an `owner`/`owner_policy` field to `Definition`.** Specified as
accepted design (no longer an open decision).

### 7.1 Field shape (PROPOSED)

Add `owner_policy` to the `Definition` struct (`definition.ex:12-28`), validated in `new/1` and
serialized in `body/1`:

```elixir
owner_policy: %{type: :installer}          # default
# | %{type: :fixed, uri: "user://system/admin"}
# | %{type: :none}
```

- `:installer` (**default**) — owner = the caller performing the install (today's `/sessions`
  behavior). Backfills every existing owner-less def (§7.4).
- `:fixed` — owner = the declared `uri`. Reproduces `App.ensure_app`'s hard-coded
  `owner_uri: User.admin_uri()` (`app.ex:50-56`) as **data**.
- `:none` — explicitly ownerless (chat/generic defs that don't route to an owner).

Serialization mirrors `visibility_policy` (`definition.ex:257-297`): atom/string-key tolerant on
read, stringified on `body/1`. **Because `owner_policy` enters `body`, it enters the content-hash**
(§3) — expected one-time re-promotion of all first-party defs on the deploy that ships this field
(§7.5).

### 7.2 How install consumes it (PROPOSED)

The install → `session.create` path threads the resolved Definition's `owner_policy` into the
Session spawn's `owner_uri`, replacing the hard-coded value:

- `:fixed` → `owner_uri = policy.uri`.
- `:installer` → `owner_uri = caller` (the current normal-path behavior).
- `:none` → no owner (ownerless session; messages fall to concierge — the intended chat-flavor
  behavior).

This is the field that lets `SocialwareInstall`/`Installation` reproduce what `App.ensure_app` does
imperatively (`app.ex:46-77`), so P2 can retire the bespoke `:hello` path. **Orchestrator-auto-join
needs no new schema** — it is the Definition's `agents` list, materialized-and-joined-with-role by
`materialize_definition_agents/4` (§2.6, `definition_agents_materialize_test.exs:8-13`). Owner was
the last missing piece.

### 7.3 Anon public homesite — the load-bearing invariant (PROPOSED)

A headless/deploy-installed public homesite has **no logged-in installer**, so `:installer` cannot
derive an owner. Make it a **validation invariant** in `Definition.new/1`:

> **`visibility_policy.web_anon_access == true` AND `owner_policy.type == :installer` → invalid.**
> An anon-accessible def MUST declare `owner_policy: %{type: :fixed, uri: …}` (or `:none`).

*Why:* the owner is what routing sends the builder's work to; an anon visitor routes to the concierge
(`app.ex:52-54`). Without a fixed owner an anon homesite is ownerless and every visitor message —
including the operator's own build requests — falls to the concierge. This invariant is exactly what
cleanly replaces the hard-coded `User.admin_uri()`: the hello demo manifest (`web_anon_access: true`,
`demo/hello.ex:114-118`) gains `owner_policy: %{type: :fixed, uri: "user://system/admin"}`.

### 7.4 Migration for owner-less Definitions (PROPOSED)

Definitions are JSON `ConfigObject` bodies, not a rigid schema — **no DB migration**. `owner_policy`
is absent on every existing def (chat, socialware, hello, third-party). Handling:

- **Struct + `new/1` default** = `%{type: :installer}` — absent → `:installer`, preserving today's
  owner-is-caller behavior for all existing defs. This is a genuine default, not a back-compat shim
  (skill: no back-compat shims), because `:installer` **is** the current semantics.
- The hello demo manifest is edited to declare `:fixed` (it is `web_anon_access: true`, so §6.3's
  invariant now requires it). On next deploy it re-promotes via §5's content-hash upgrade.
- Third-party defs default to `:installer` (correct — a user's install owns to that user).

### 7.5 Hash-churn note

Adding `owner_policy` to `body` changes every existing def's content-hash → a **one-time
re-promotion of all first-party defs** on the deploy that ships the field, via §5's `publish_or_upgrade`
(hash differs → `:upgraded`). Expected and benign; called out so it is not mistaken for drift.

---

## 8. Testing

TDD (skill: test-driven-development). Each numbered item is a failing-first test tied to an
invariant. **★** marks the invariant tests that directly kill R-2 and the pin split.

### 8.1 R-2 — edited manifest re-promotes ★ (the trap-killer)

- **T-R2-a (governance path — the one R-2 lives on):** publish a def via governance; edit its
  manifest body; call `publish_or_upgrade` again. **Assert** the current published revision's
  `content_hash` == the edited body's hash and a **new revision** was minted (`:upgraded`). This must
  exercise the **Hello/governance-written path**, not only the direct-write builtin — otherwise it
  won't catch the §5.2 provenance-guard trap. *(Directly refutes `demo/hello.ex:128-136`'s
  existence-check.)*
- **T-R2-b (no-op stability):** call `publish_or_upgrade` twice with identical bytes → second call is
  `{:ok, :exists}`, **no new revision, no CR opened**.
- **T-R2-c (unify):** both `Demo.Hello.publish/0` and `seed_builtin_definitions/0` re-promote an
  edited manifest (same primitive, same result).

### 8.2 Pin-on-install ★

- **T-Pin-a (running install is stable):** install a def (records revision R1); `publish_or_upgrade`
  a new revision R2; **assert** the running install still resolves R1 AND its
  `behavior_set_for_template` builds from R1 (not R2). *(Directly refutes the §2.3 split — fails
  today because `behavior_set_for_template` name-resolves current.)*
- **T-Pin-b (explicit upgrade):** `repoint_template_installs` advances the install to R2; next spawn
  builds from R2.
- **T-Pin-c (fresh-install records the pin):** a fresh `installs: [ref]` (no `config_id`) records the
  resolved `object.id` + `content_hash` into the install spec.

### 8.3 Retract

- **T-Ret-a (discovery):** retract a def → gone from `DefinitionRegistry.list/1`
  (`definition_registry.ex:204-220`) and the `lookup/2` public fallback
  (`definition_registry.ex:182-199`).
- **T-Ret-b (grandfather):** a session with a **pinned** install of the retracted revision still
  resolves it (via `fetch_object(config_id)`) AND rebuilds its behavior set — **contingent on the
  §4 pin fix** (§9, coupling).
- **T-Ret-c (new install blocked):** a fresh install of a retracted ref fails
  (`{:error, {:unknown_socialware_install, ref}}`).

### 8.4 O-1 owner_policy

- **T-Own-a (fixed):** install a def with `owner_policy: :fixed` → session `owner_uri` == declared
  uri (reproduces `app.ex:50-56` as data).
- **T-Own-b (installer default):** owner-less def → owner == caller.
- **T-Own-c (anon invariant):** `Definition.new/1` REJECTS `web_anon_access: true` +
  `owner_policy: :installer` (§7.3).
- **T-Own-d (migration default):** an existing owner-less body rehydrates with
  `owner_policy == %{type: :installer}`.

### 8.5 Identity

- **T-Id-a (env-independence):** `content_hash` of identical bytes is equal across two workspaces
  (proxy for two envs), and differs when any body field changes.
- **T-Id-b (revision-per-publish):** two `publish_or_upgrade` of differing bytes → two distinct
  `ConfigObject.id`s, both queryable by `content_hash`.

---

## 9. Cross-item coupling (must land together)

**Retract grandfathering depends on the pin fix.** `installed_definitions` resolves via the pinned
`config_id` (unaffected by retract), but `behavior_set_for_template` today name-resolves the current
pointer — so if retract makes a name-lookup fail, a grandfathered session's **behavior-set rebuild
breaks** even though its install record is intact. Therefore §4 (pin) and §6 (retract)
are **one atomic P0**: retract removes a def from discovery + new-install lookup, and pinned installs
survive **only because** P0 also routes behavior-set resolution through the pinned `config_id`. The
writing-plan must not split these into independently-shippable steps.

---

## 10. Open decisions for the lead (resolve before writing-plans)

- **D-1 (version semantics):** Is `Definition.version` enforced (monotonic/semver bump required on
  each `publish_or_upgrade` that changes bytes), or does it stay an opaque advisory tag alongside the
  canonical `content_hash`? *This spec assumes **opaque tag** (content-hash is the machine identity).*
  Enforcement would add a bump-check to `publish_cr`. **Recommendation: opaque tag for P0**; revisit
  when the catalog (P1) needs human version history. *(Parent plan O-4.)*
- **D-2 (built-ins via governance):** §5.3 moves the built-in `chat`/`socialware` seed off the direct
  `write_definition` (`authority: :system_seed`) path onto the governance `publish_or_upgrade`, so a
  built-in re-promotion opens a CR at boot. Acceptable, or should built-ins keep a direct-write fast
  path that still uses `Definition.content_hash/1` idempotency (one hash rule, two write paths)?
  **Recommendation: one path (governance)** for a single audited primitive; flag the boot-CR cost.
- **D-3 (content_hash storage):** dedicated `content_hash` column on `socialware_config_objects`
  (queryable, needs a migration — §3.2) vs deriving it on read from `body`. **Recommendation: stored
  column** — the catalog (P1) and promotion checks (P3) both need to query by hash; deriving on read
  is O(n) over every list.
- **D-4 (retract representation):** a `retracted_at` marker inside the def `body` (enters the
  content-hash → retract mints a revision) vs a **separate retract pointer/marker object** (retract
  does not change the artifact's identity). **Recommendation: separate marker** — retract is a
  catalog-state change, not a new artifact; keeping it out of `body` means a retracted-then-restored
  def keeps its identity. Confirm before writing-plans.
- **D-5 (owner_policy `:none` reachability):** should `:none` be author-selectable, or only
  `:installer`/`:fixed` (with chat/generic defaults handled by `:installer`)? **Recommendation:
  keep `:none`** for explicit ownerless chat sessions, but gate it behind the same anon invariant
  (an anon def may not be `:none` either, unless the lead wants concierge-only homesites).

*(Parent-plan open questions O-2 [plugin-repo extraction], O-3 [promotion mechanism], O-5
[third-party trust] are P3/P4 concerns, out of P0 scope.)*

---

## Appendix — CONFIRMED-in-code vs PROPOSED

**CONFIRMED in code (with citations above):**
- Three identity primitives exist; content-hash is computed but discarded into a `source_turn_id`
  (`definition_registry.ex:328-337`); revision id is `Ecto.UUID` per write (`config_store.ex:609`,
  append-only `config_object.ex:1-8`); `version` is free-form/unenforced (`definition.ex:13,61`).
- The pin split: install record pins `definition_config_id` (`installation.ex:308-312`) but
  `behavior_set_for_template` name-resolves current (`installation.ex:53-56,313-322`); `install_spec`
  has no version (`installation.ex:16`).
- R-2 divergence: content-hash upgrade (`definition_registry.ex:275-337`) vs existence-check
  (`demo/hello.ex:128-136,169-174`); Hello publishes via governance (`demo/hello.ex:145-155`) so it
  carries a CR turn-id, not the seed prefix (→ §5.2 guard trap).
- No def-level retract (only `reject_cr`/`mark_rolled_back`, `socialware.ex:103-111`,
  `config_change_store.ex:353`).
- No `owner` field; owner hard-coded on the bespoke path (`app.ex:50-56`); orchestrator-auto-join is
  imperative (`app.ex:87-108`) but `agents` materialize-and-join-with-role is CONFIRMED
  (`definition_agents_materialize_test.exs:8-13`) → owner is the sole schema gap.
- Code-presence-gated validation bounds env-independence (`definition.ex:194-200`).

**PROPOSED (design, not yet built):**
- First-class stored + queryable `content_hash` (§3.2); `Definition.content_hash/1` single-source
  helper.
- Pinned `install_spec` (`config_id` + `content_hash`) and pin-honoring resolution across both
  `resolve_definitions` and `behavior_set_for_template` (§4).
- Def-level retract filtered in `list/1` + `lookup/2` public fallback, grandfathering pinned installs
  (§6/§8.3/§9).
- `ConfigGovernance.Socialware.publish_or_upgrade/2` — one content-hash-only idempotency primitive
  both seeds call (§5).
- `owner_policy` field + install owner-derivation + anon invariant + `:installer` migration default
  (§6).
- All of §10's open decisions.
