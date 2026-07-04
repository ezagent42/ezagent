# P0 Spec — Versioned, Promotable Artifact Identity for Socialware Definitions

**Type:** Implementation spec (P0 of the Socialware Registry & Distribution Plan)
**Date:** 2026-07-04
**Author:** Claude Opus 4.8 (1M context), for Allen
**Status:** Lead-approved (all decisions confirmed 2026-07-04, "全按推荐") — plan-ready, → writing-plans
**Parent plan:** `docs/superpowers/specs/2026-07-04-socialware-registry-and-distribution-plan.md`
(landed as PR #1169) — P0 line §6, "biggest missing piece" §1.4, R-2 §3/§7, O-1 §4.4/§7.

> This spec turns prod's per-node config table into a **registry** by giving a published
> socialware `Definition` a **stable, environment-independent, promotable artifact identity** plus a
> **version**, makes installs **pin** to a specific revision (frozen into the session's local
> template content at create time), adds **def-level retract**, unifies the two divergent in-code
> seeds onto **one shared content-hash idempotency rule** — two write paths (killing R-2), and
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
2. Pin-to-version on install — installs bind a **pinned revision** frozen into the session's local
   template content at create time (Decision A), not the live pointer.
3. Def-level unpublish / retract — withdraw a published def from discovery; grandfather pinned
   installs.
4. Unified idempotency rule — one shared **content-hash** compare across both write paths (governance
   + built-in direct-write, D-2); fixes R-2.
5. The `owner_policy` field on `Definition` (O-1, DECIDED) that lets install reproduce owner +
   orchestrator-auto-join for an anon public homesite.

**Out of scope (deferred to later phases, per the parent plan):**
- Catalog browse/search/detail UI (P1).
- Retiring the bespoke `:hello` URI-type creation path + `PageView` `OR` (P2 — this spec's
  `owner_policy` is its *enabler*, not its execution).
- External config source-of-truth repo + `mix ezagent.socialware.publish --from <dir>` deploy-seed
  pipeline (P3 — this spec's unified primitive is the *primitive* it will call, not the pipeline).
- Enforced semver / monotonic version bump on publish (resolved D-1: `version` stays an opaque
  advisory tag, never enforced — §3.1).

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
- **Store** — the CR governance path is a **stage-then-publish** two-step, not a single write:
  `stage_definition` creates the **new immutable staged `ConfigObject`**
  (`ConfigStore.write_object_staged`, `config_change_store.ex:120-128`), and `publish_cr` **flips the
  current pointer** to that already-created object (`flip_item → ConfigStore.put_pointer`,
  `config_change_store.ex:301-314`) — it does not itself write a new object. (The direct-write
  built-in seed path uses the atomic `ConfigStore.write_and_point`, `config_store.ex:56-72`, which
  writes the immutable object AND advances the pointer in one transaction.) Both paths are
  append-only rollback-by-repoint (`config_object.ex:1-8`). **So each stage+publish CR cycle = a new
  immutable revision that becomes current on publish.** Subject is the non-URI `socialware:<name>`,
  layer `"workspace"`, key `"socialware"` (`definition_registry.ex:14,27-31`).
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

**Why the pin cannot be resolved from the install record (the constraint that shapes §4).**
`behavior_set_for_template/2` only receives `(content, workspace_uri)`
(`installation.ex:50-64`), and session-create resolves the behavior set from that signature at
`session_creator.ex:331-332` — **BEFORE** the per-session install records exist, which are written
later inside `finalize_fresh_session` at `session_creator.ex:548-553`
(`Installation.install_template_installs`). So there is no install record to read a pin from at the
moment behaviors are resolved. The fix (§4) is therefore to **freeze the pin into the template
content** the session is created from, so `behavior_set_for_template` reads the frozen revision from
the content it already gets — no signature change.

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
| **Artifact identity** | `content_hash` (stored, queryable) = `sha256(canonical(body))` — canonical form with deterministic recursive key sorting (§3.2) | "Is prod's def the SAME artifact authored in dev?" | **Content-hash** | Env-independent by construction; the primitive already exists in idea (`definition_registry.ex:328-337`) and backs seed idempotency, though today's `json_normalize/1` does not sort keys and must be replaced (§3.2). Semver can't answer cross-env sameness (two envs can carry `0.1.0` with different bytes); a per-env revision UUID is env-local. |
| **Revision** | `ConfigObject.id` (exists) | "Which exact published revision is this?" / "what does an install pin?" | **Published-revision-id** | Immutable append-only row per `publish_cr` (`config_store.ex:56-72`); already stored in install records (`installation.ex:311`). Each `publish_cr` = a new revision — no new machinery. |
| **Advisory tag** | `Definition.version` (exists) | Human "which release" | **Opaque advisory string, NOT enforced (accepted — D-1)** | Machine identity is the hash; forcing monotonic semver adds authoring friction with zero P0 payoff. **Lead decision D-1 (2026-07-04): `version` is display-only, never enforced** — no monotonic/semver bump check on publish. |

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
  - **Storage (accepted — D-3):** a **dedicated `content_hash` column** on
    `socialware_config_objects` (needs a migration — see §11), populated in `object_attrs/1`
    (`config_store.ex:607`) from `body`. Deriving-on-read from `body` is rejected: the catalog (P1)
    and promotion checks (P3) both query by hash, and deriving on read is O(n) over every `list/1`.
  - **Canonicalization is an implementation constraint (requirement, not a prescribed function body).**
    The **requirement**: `content_hash` is computed over a **canonical form of `body` with
    deterministic recursive key sorting**, so the same manifest hashes identically regardless of key
    insertion order. The current `json_normalize/1` is only `body |> Jason.encode!() |>
    Jason.decode!()` (`definition_registry.ex:322-326`) — it round-trips JSON but imposes **no
    deterministic key ordering**, so it does **not** satisfy the requirement and must be replaced with
    a canonical sorter. Follow the sorted-keys determinism pattern already used for byte-identical
    projection at `config_projection.ex:213-227` (`Enum.sort_by(fn {k, _v} -> to_string(k) end)`),
    extended to recurse into nested maps. The invariant test (§8.5 T-Id-a) is: **the same body in any
    key order → the same hash.** Do not prescribe the exact function body — only the canonical-form +
    determinism requirement.
  - One helper, `Definition.content_hash/1`, is the **single source** of that computation, called by
    both the store (to populate the column) and the shared idempotency rule (§5).
- **`Definition.version` stays** as-is (advisory), surfaced in `list/1` alongside a short
  `content_hash` prefix so the catalog (P1) and operators can see drift.
- **Each `publish_cr` = one revision** (already true, `config_store.ex:56-72`); P0 makes that
  revision's `content_hash` recorded and its id the install target.

### 3.3 CR-publish-lifecycle interaction

No change to the CR lifecycle shape. The stage+publish CR cycle continues to produce a new immutable
revision (`stage_definition` creates the object, `publish_cr` flips the pointer to it — §2.2); P0
adds only that the revision carries its `content_hash`, and that a publish whose body hash equals the
current published body's hash **short-circuits to `:exists`** (§5) so a no-op redeploy does not open
a CR or mint a revision. Env promotion (P3) = publish the *same bytes* to the target env's registry;
identity of the promoted artifact is verified by equal `content_hash` (env-independent), not by the
revision id (env-local).

---

## 4. Pin-to-version on install

### 4.1 Principle — freeze the revision into the session's local template content at create time (accepted — Decision A)

An install binds to a **specific revision** (`ConfigObject.id`), recorded with the env-independent
**`content_hash`** for audit/promotion. A later registry publish creates a *new* revision and does
**not** move a running install; a binding moves **only** via the explicit `repoint_template_installs`
primitive (`installation.ex:88-113`). This closes the §2.3 split.

**The mechanism (Decision A, lead-accepted 2026-07-04):** the pin is **frozen into the session's
LOCAL template content at create time**, NOT resolved from the per-session install record at
behavior-resolution time. The originally-proposed "route behavior-set resolution through the pin
stored on the install record" **cannot work as-was**: `behavior_set_for_template/2` receives only
`(content, workspace_uri)` (`installation.ex:50-64`) and session-create resolves the behavior set
from that at `session_creator.ex:331-332` — **BEFORE** the per-session install records are written
(inside `finalize_fresh_session`, `session_creator.ex:548-553`). There is no install record to read
a pin from at the moment behaviors are resolved.

**Requirement:** at session create, resolve each declared Definition to its **CURRENT** published
revision-id and **BAKE that pinned revision-id (+ `content_hash`) into the `installs` entries of the
local template content** the session is created from. Because `behavior_set_for_template` reads its
`installs` from that content, it then resolves the **frozen** revision with **no signature change** —
the pin travels with the content. **Invariant:** *a later `publish_or_upgrade` of a def does NOT
change the behaviors of an already-running session installed from it* — the session keeps running the
revision frozen at its create time until an explicit re-point.

The exact wiring (where in `SocialwareInstall.prepare_create_template/4` /
`Installation.install_template_installs` the current-revision resolution is performed and written
into the content's `installs`) is left to the implementer — the requirement above and the invariant
are the contract. (Retract-grandfathering, §6.3, couples to this freeze and lands atomically — §9.)

### 4.2 Changes (PROPOSED)

1. **`install_spec` carries an optional pinned revision + hash.**
   `%{ref: String.t(), config: map(), config_id: String.t() | nil, content_hash: String.t() | nil}`
   (extends `installation.ex:16`). `parse_install` defaults both to `nil` (= "pin whatever is current
   at install time"), so existing `installs: [ref]` templates keep working
   (`installation.ex:339-366`). This is the shape the frozen pin travels in inside the baked template
   content.
2. **Resolution honors the pin.** `resolve_definitions/2` (`installation.ex:313-322`) resolves a
   pinned `config_id` via `ConfigStore.fetch_object/1` (the exact revision) and falls back to
   `DefinitionRegistry.lookup` **only when `config_id` is `nil`**. On the create path, the fresh
   (unpinned) resolution to the current revision is what produces the `object.id` + `content_hash`
   that get frozen into the content's `installs` (§4.1), exactly as `seed_install` already records
   `definition_config_id` (`installation.ex:308-312`).
3. **Behavior-set resolution reads the frozen pin.** `behavior_set_for_template/2`
   (`installation.ex:50-64`) — the path that today live-resolves the current pointer — now sees the
   **frozen** `config_id` in the content's `installs` and resolves the **pinned** revision via item 2,
   so the behaviors the Session host builds/rehydrates with match the revision frozen at create time.
   This is the concrete fix for §2.3 — achieved by the content already carrying the pin, **not** by a
   new signature or a read from the install record.
4. **Upgrade is explicit.** `repoint_template_installs/4` (`installation.ex:88-113`) becomes the sole
   way an install advances to a newer revision: it re-resolves the def (optionally to a chosen
   revision), re-points the install record's `config_id`/`content_hash` **and** re-freezes the new pin
   into the session's local template content, and the next spawn rebuilds behaviors from the new pin.
   Re-install of the same ref is idempotent (`seed_object_if_no_pointer`, `installation.ex:288-303`).

### 4.3 Where the pin lives

Two coordinated homes, both authoritative:
- **The session's local template content `installs` entries** — the frozen `config_id` + `content_hash`
  baked in at create time (§4.1). This is the copy `behavior_set_for_template` reads, so it is what
  decides which revision's behaviors the running session executes.
- **The per-session install record** (`socialware_config_objects` under the session subject, install
  layer — `installation.ex:288-312`), which already stores `definition_config_id` and gains
  `content_hash`. This is the durable audit/grandfathering copy `installed_definitions/1` reads
  (`installation.ex:274-283`).

No new store; the pin is already persisted in the install record — P0 makes it *authoritative* and,
per Decision A, also **freezes a copy into the local template content** so behavior resolution (which
runs before the install record exists) reads the pinned revision.

### 4.4 The freeze MUST cover EVERY production create path (codex round-2 BLOCKER)

The freeze invariant only holds if **every** production path that calls
`behavior_set_for_template/2` receives content whose `installs` are already pinned. The freeze
(resolve-current-revision → bake `config_id` + `content_hash` into the content's `installs`) is
therefore specified as a **single shared freeze step** (one helper) that MUST be applied at **every**
such call site — not just `SessionCreator`. **Requirement:** any code path that builds session
content from an unpinned `installs: [ref]` and then calls `behavior_set_for_template/2` must run the
freeze step **first**; a call site that does not is a bug the acceptance test (T-Pin-a) must catch.

Known production call sites at spec time (CONFIRMED — the implementer must re-grep for any others and
apply the same helper):

1. **`SessionCreator`** — resolves behaviors at `session_creator.ex:331-332`, before per-session
   install records at `:548-553`. The primary path §4.1 was written against.
2. **`EzagentPluginHello.App.ensure_app/3`** — the bespoke anon-homesite path, which builds
   `content = %{..., installs: [socialware_name]}` and calls
   `Installation.behavior_set_for_template(content, workspace)` **before** writing install records
   (`app.ex:44,48,60`). This path is **NOT retired in P0** (its retirement is P2), so P0 MUST apply
   the same freeze here — otherwise an unpinned hello install falls through to live
   `DefinitionRegistry.lookup/2` (`installation.ex:313`) and a later publish silently changes the
   running flagship, defeating the pin invariant on the exact surface it matters most for. (When P2
   folds this path onto `SocialwareInstall`, the freeze travels with it.)

The unpinned fallback in `resolve_definitions/2` (§4.2 item 2, `config_id == nil` → live lookup) is
retained *only* for genuinely legacy/unpinned templates; it must never be reached from a production
create path once the freeze helper is in place.

---

## 5. Unified idempotency RULE — the R-2 fix

### 5.1 One shared rule, two write paths (accepted — D-2)

The unified thing is the **idempotency RULE**, not a single write path. **Lead decision D-2
(2026-07-04): built-ins KEEP a direct-write fast path** (they do **not** open a CR at boot), but the
built-in path and the governance path apply the **same** hash-comparison upgrade rule. There is one
rule, two write paths:

**The shared RULE (hash-comparison only — NO provenance guard):**

1. Resolve the current published object for `(name, workspace)` (`DefinitionRegistry.lookup/2`).
2. **None** → publish a first revision → `{:ok, :published}`.
3. **Present, `Definition.content_hash(current.body) == Definition.content_hash(new.body)`** →
   `{:ok, :exists}`, **no revision minted** (and, on the governance path, **no CR opened**).
4. **Present, hashes differ** → publish a new revision → `{:ok, :upgraded}`.

**Path 1 — governance (public defs: Hello + the P3 deploy-seed).** Exposed as:

```
ConfigGovernance.Socialware.publish_or_upgrade(definition, ctx) ::
  {:ok, :published | :upgraded | :exists} | {:error, term()}
```

Steps 2 and 4 go through the **full governance flow** (`open_cr → stage_definition → publish_cr`), so
the public-scope admin gate (`authorize_public_scope → authorize_admin`, `socialware.ex:113-151`) and
R-5's genuine-admin authority are preserved — the primitive never does a direct ConfigStore write to
bypass moderation.

**Path 2 — direct-write fast path (built-in `chat`/`socialware` seeds at boot).** Built-ins continue
to use the atomic direct write (`ConfigStore.write_and_point`, `config_store.ex:56-72`, as
`seed_builtin_definitions/0` does today at `definition_registry.ex:94`) — **no CR opened at boot**.
The change is that they apply the **same** rule above: the bespoke `builtin_upgrade_source_turn_id` /
`builtin_seed_object?` **provenance** machinery (`definition_registry.ex:307-337`) is deleted and
replaced with the plain `Definition.content_hash/1` compare (steps 2–4). Built-ins never needed the
admin gate — they are the system seed authority — so keeping their fast path is safe; only the
idempotency *rule* is unified.

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

### 5.3 Both seeds converge on the rule (not on one path)

- **`Demo.Hello.publish/0`** (`demo/hello.ex:128-136`) — **governance path**: drop `already_public?`
  existence-check; call `publish_or_upgrade(definition, admin_ctx)`. An edited hello manifest now
  re-promotes (`:upgraded`).
- **`DefinitionRegistry.seed_builtin_definitions/0`** (`definition_registry.ex:49-56,275-305`) —
  **direct-write fast path, kept** (D-2): built-ins still write via `ConfigStore.write_and_point`
  (`definition_registry.ex:94`) with **no CR at boot**, but the provenance-guard machinery
  (`builtin_upgrade_source_turn_id` / `builtin_seed_object?`, `definition_registry.ex:307-337`) is
  replaced by the shared `Definition.content_hash/1` compare (§5.1 steps 2–4). Same idempotency rule,
  same re-promote-on-edit result — different write mechanism.
- **Future P3 deploy-seed** (`mix ezagent.socialware.publish --from <dir>`) calls the **governance**
  `publish_or_upgrade` — the same rule as Hello.

> **Note (one rule, two paths — D-2 accepted):** built-ins deliberately keep their direct-write fast
> path and do **not** open a CR at boot; the governance path (Hello + P3 deploy-seed) opens CRs for
> its audit/moderation trail. What is unified is the **hash-comparison idempotency rule** (no
> provenance guard), applied identically on both. The single source of the hash is
> `Definition.content_hash/1` (§3.2).

---

## 6. Def-level unpublish / retract

### 6.1 Principle

Today the registry has **no way to withdraw an already-published def** — only CR-level
`reject_cr`/`mark_rolled_back` (§2.5). P0 adds **def-level retract**: a published def is removed from
the **catalog** (discovery + new-install lookup) while **existing pinned installs are grandfathered**
(they keep resolving the exact revision they pinned). Retract is a **catalog-state change, not a new
artifact** — so it does not mint a new revision or change the artifact's `content_hash`. **Lead
decision D-4 (2026-07-04, accepted): retract is a SEPARATE marker, NOT a `retracted_at` field in the
def `body`** — keeping it out of `body` preserves the artifact's identity across a retract/restore
cycle (§6.4).

### 6.2 What retract does (PROPOSED)

Add `ConfigGovernance.Socialware.retract/2` (def-level, admin-gated exactly like public publish —
`authorize_admin`, `socialware.ex:144-151`). It records a **separate retract marker** for
`(name, workspace)` — **separate from the def `body`** so the artifact identity is preserved (D-4;
storage per §11) — that:

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
working. **This only holds because P0 also freezes the pinned `config_id` into the session's local
template content** (§4.1, Decision A): behavior-set resolution reads the frozen revision from the
content, so it never re-runs the name-`lookup` that retract would make fail. If
`behavior_set_for_template` still name-resolved the current pointer, retract-then-`lookup` would fail
and a grandfathered session's behavior-set rebuild would break. §4 (freeze-pin) and §6 (retract) are
therefore one atomic P0 (§9).

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
# | %{type: :fixed, uri: "entity://system/user/admin"}   # == User.admin_uri()
# | %{type: :none}
```

- `:installer` (**default**) — owner = the caller performing the install (today's `/sessions`
  behavior). Backfills every existing owner-less def (§7.4).
- `:fixed` — owner = the declared `uri`. Reproduces `App.ensure_app`'s hard-coded
  `owner_uri: User.admin_uri()` (`app.ex:50-56`) as **data**. The admin URI is
  `entity://system/user/admin`, built by `Ezagent.URI.user(:system, :admin)` (`uri.ex:435-437`) and
  exposed as `Ezagent.Entity.User.admin_uri/0` (`user.ex:30-32`) — first-party manifests should
  reference `User.admin_uri()` rather than hardcode the string. (Note: `user://…` is a **deleted
  scheme** — merged into `entity://` in PR #141, `uri.ex:106-109`; do not use it.)
- `:none` — explicitly ownerless (chat/generic defs that don't route to an owner). **Forbidden for
  anon-accessible defs (D-5, §7.3).**

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
derive an owner. **Lead decision D-5 (2026-07-04, accepted): an anon-public homesite
(`web_anon_access: true`) MUST be `owner_policy.type == :fixed`.** Both `:installer` AND `:none` are
**FORBIDDEN** for an anon def — `:none` re-introduces the exact ownerless condition this feature
eliminates. This is a **hard validation invariant** in `Definition.new/1`:

> **`visibility_policy.web_anon_access == true` AND `owner_policy.type != :fixed` → invalid.**
> An anon-accessible def MUST declare `owner_policy: %{type: :fixed, uri: …}`. Neither `:installer`
> (no logged-in installer to derive an owner from) nor `:none` (ownerless — the condition the feature
> eliminates) is permitted.

*Why:* the owner is what routing sends the builder's work to; an anon visitor routes to the concierge
(`app.ex:52-54`). Without a **fixed** owner an anon homesite is ownerless and every visitor message —
including the operator's own build requests — falls to the concierge. This invariant is exactly what
cleanly replaces the hard-coded `User.admin_uri()`: the hello demo manifest (`web_anon_access: true`,
`demo/hello.ex:114-118`) gains `owner_policy: %{type: :fixed, uri: User.admin_uri()}` (=
`entity://system/user/admin`).

### 7.4 Migration for owner-less Definitions (PROPOSED)

Definitions are JSON `ConfigObject` bodies, not a rigid schema — **no DB migration**. `owner_policy`
is absent on every existing def (chat, socialware, hello, third-party). Handling:

- **Struct + `new/1` default** = `%{type: :installer}` — absent → `:installer`, preserving today's
  owner-is-caller behavior for all existing defs. This is a genuine default, not a back-compat shim
  (skill: no back-compat shims), because `:installer` **is** the current semantics.
- The hello demo manifest is edited to declare `:fixed` (it is `web_anon_access: true`, so §7.3's
  anon invariant now requires it). On next deploy it re-promotes via §5's content-hash upgrade.
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
- **T-R2-c (one rule, two paths):** both `Demo.Hello.publish/0` (governance path) and
  `seed_builtin_definitions/0` (direct-write fast path, D-2) re-promote an edited manifest — **same
  hash-comparison rule, same `:upgraded` result** — even though only the governance path opens a CR.

### 8.2 Pin-on-install ★

- **T-Pin-a (running install is stable — the freeze invariant, Decision A):** install a def (freezes
  revision R1 into the session's local template content); `publish_or_upgrade` a new revision R2;
  **assert** the running install still resolves R1 AND its `behavior_set_for_template` builds from R1
  (not R2) — i.e. a later publish does NOT change a running session's behaviors. *(Directly refutes
  the §2.3 split — fails today because `behavior_set_for_template` name-resolves current.)*
- **T-Pin-a2 (the freeze covers the hello anon path — §4.4, codex round-2 BLOCKER):** create a
  homesite session via `EzagentPluginHello.App.ensure_app/3` (the bespoke path NOT retired in P0);
  `publish_or_upgrade` a new hello revision; **assert** the running homesite still resolves the
  create-time revision — i.e. the freeze helper is applied at this call site too, not only in
  `SessionCreator`. *(Guards the exact flagship surface the pin matters most for.)*
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
- **T-Own-c (anon invariant, D-5):** `Definition.new/1` REJECTS `web_anon_access: true` with any
  `owner_policy.type != :fixed` — assert **both** `:installer` AND `:none` are rejected, and `:fixed`
  is accepted (§7.3).
- **T-Own-d (migration default):** an existing owner-less body rehydrates with
  `owner_policy == %{type: :installer}`.

### 8.5 Identity

- **T-Id-a (env-independence + key-order determinism):** `content_hash` of identical bytes is equal
  across two workspaces (proxy for two envs), differs when any body field changes, **and — the codex
  canonicalization test — is equal for the same body supplied with keys in any order** (asserts the
  deterministic recursive key sorting of §3.2; fails against the current unsorted `json_normalize/1`,
  `definition_registry.ex:322-326`).
- **T-Id-b (revision-per-publish):** two `publish_or_upgrade` of differing bytes → two distinct
  `ConfigObject.id`s, both queryable by `content_hash`.

---

## 9. Cross-item coupling (must land together)

**Retract grandfathering depends on the freeze-pin fix (Decision A).** `installed_definitions`
resolves via the pinned `config_id` (unaffected by retract), but `behavior_set_for_template` today
name-resolves the current pointer — so if retract makes a name-lookup fail, a grandfathered session's
**behavior-set rebuild breaks** even though its install record is intact. Therefore §4 (freeze-pin)
and §6 (retract) are **one atomic P0**: retract removes a def from discovery + new-install lookup, and
pinned installs survive **only because** P0 also **freezes the pinned revision into the session's
local template content** (§4.1) so behavior-set resolution reads the frozen revision and never re-runs
the name-`lookup` retract would break. The writing-plan must not split these into
independently-shippable steps.

---

## 10. Resolved decisions (lead-confirmed 2026-07-04 — "全按推荐", all approved)

**No open decisions remain. This spec is plan-ready.** All of D-1..D-5 and the codex pin-data-flow
BLOCKER (Decision A) are resolved and folded into the accepted design above:

| # | Decision | Where specced |
|---|---|---|
| **A** (codex BLOCKER — pin data-flow) | **Freeze the resolved current revision-id into the session's LOCAL template content at create time**, so behavior-set resolution reads the frozen revision (no signature change; the originally-proposed "resolve pin from the install record" cannot work — behaviors resolve at `session_creator.ex:331` BEFORE install records exist at `:548`). Requirement + invariant ("a later publish does NOT change a running session's behaviors") stated; exact wiring left to the implementer. Couples atomically with retract-grandfathering. | §4.1, §4.2, §4.3, §6.3, §9 |
| **D-1** | `version` is an **opaque advisory tag** (display-only, never enforced — identity is the content-hash). | §3.1 |
| **D-2** | Built-ins **keep a direct-write fast path** (no CR at boot) but apply the **same hash-comparison rule** as the governance path. One shared idempotency RULE (hash compare, no provenance guard), two write paths. | §5.1, §5.3 |
| **D-3** | Store `content_hash` as a **dedicated queryable column** (migration — §11). | §3.2, §11 |
| **D-4** | Retract = a **separate marker** (preserves artifact identity across retract/restore), NOT a `retracted_at` in `body`. | §6.1, §6.2, §11 |
| **D-5** | An anon-public homesite (`web_anon_access: true`) **MUST be `:fixed`**; `:none` is **FORBIDDEN** for anon (it re-introduces the ownerless condition). Hard validation invariant. | §7.1, §7.3, §8.4 |

*(Parent-plan open questions O-2 [plugin-repo extraction], O-3 [promotion mechanism], O-5
[third-party trust] are P3/P4 concerns, out of P0 scope — not open items for this spec.)*

---

## 11. Migrations & storage changes

Definitions themselves are JSON `ConfigObject` bodies (no rigid schema), so the `owner_policy` field
(§7.4) needs **no** migration. Two storage changes are required:

### 11.1 D-3 — `content_hash` column on `socialware_config_objects`

- **Add a `content_hash` string column** to the `socialware_config_objects` table (schema
  `config_object.ex:16-25`, created by `20260618000500_add_socialware_config_store.exs`). Add the
  field to the Ecto schema + `changeset/1` cast list (`config_object.ex:29-41`) and populate it in
  `object_attrs/1` (`config_store.ex:607`) from `body` via `Definition.content_hash/1` (§3.2).
- **Both repos.** This project keeps parallel migration trees — SQLite under
  `apps/ezagent_core/priv/repo/migrations/` and Postgres under
  `apps/ezagent_core/priv/repo_pg/migrations/`. The column migration must be added to **both**.
- **Add an index** on `content_hash` (registry hash-lookup for catalog P1 + promotion P3).
- **Backfill:** existing rows have no hash. Either backfill in the migration (compute from `body`) or
  make the column nullable and lazily populate — implementer's choice; the spec requires only that
  new writes populate it and the column is queryable. (Aligns with skill: no back-compat shims —
  backfill is a one-time data step, not a runtime fallback.)

### 11.2 D-4 — the retract marker (requirement-level, storage left to implementer)

Retract is a **separate marker** for `(name, workspace)`, **NOT** a field in the def `body` (so it
never enters the content-hash — D-4, §6.1). The marker must be durable, admin-gated to set/clear
(§6.2), and independent of the immutable `ConfigObject` revisions (which are never deleted, §6.2
item 3). **Storage is the implementer's choice** between:
- riding the **existing `ConfigStore`** append-only object + pointer machinery under a distinct
  marker key/layer for the `socialware:<name>` subject (no new table, no migration — reuses
  `config_store.ex` writes + `config_change_store.ex` pointer flips), or
- a small **dedicated retract table** (its own migration in **both** `repo/` and `repo_pg/`).

The spec does not pick; it requires only that the marker is separate from `body`, reversible (§6.4),
and consulted by `list/1` (`definition_registry.ex:204-220`) + the `lookup/2` public fallback
(`definition_registry.ex:182-199`).

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
- First-class stored + queryable `content_hash` **column** (§3.2, §11.1, D-3); `Definition.content_hash/1`
  single-source helper computing over a canonical form with **deterministic recursive key sorting**
  (§3.2) — replacing the unsorted `json_normalize/1` (`definition_registry.ex:322-326`).
- Pinned `install_spec` (`config_id` + `content_hash`) **frozen into the session's local template
  content at create time** (Decision A, §4.1) so `behavior_set_for_template` reads the frozen revision
  with no signature change; explicit re-point re-freezes (§4.2).
- Def-level retract via a **separate marker** (D-4) filtered in `list/1` + `lookup/2` public fallback,
  grandfathering pinned installs (§6/§8.3/§9/§11.2).
- `ConfigGovernance.Socialware.publish_or_upgrade/2` (governance path) — the shared
  **hash-comparison idempotency rule** (no provenance guard); built-ins keep their **direct-write fast
  path** applying the same rule (D-2, §5).
- `owner_policy` field + install owner-derivation + anon `:fixed`-only invariant (D-5) + `:installer`
  migration default (§7).
- `content_hash` column migration in **both** `repo/` (SQLite) and `repo_pg/` (Postgres) (§11.1).

**All lead decisions (A, D-1..D-5) are resolved and folded into the accepted design above (§10) — no
open decisions remain; the spec is plan-ready.**
