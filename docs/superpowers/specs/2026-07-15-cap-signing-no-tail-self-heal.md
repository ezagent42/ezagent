# Cap-signing "no-tail" self-healing upgrade

**Status:** SPEC **v2** — lead-locked 2026-07-15 (the 10 decisions in §1 are fixed; do NOT re-litigate). Revised after codex adversarial review (7 architectural flaws fixed: per-class re-issue policy registry replacing granted_by-derivation; lifecycle-triggered/background-executed heal avoiding the `activate/2`↔`persist` deadlock; compare-and-set heal op replacing unsound `:absorb_cap` reuse; domain-owned resolvers; seed-writer hole; durable quarantine ledger + both-bucket audit; distribution assurance). Ready for re-review → impl-plan → build.
**Date:** 2026-07-15
**Owner branch (codex builds here):** `feat/cap-signing-notail-upgrade` (codex owns; lands sub-steps; coordinator reviews + merges to `main`).
**Depends on:** Phase-4 ed25519 signing on main, dual-read (`docs/superpowers/specs/2026-07-14-cbac-phase4-ed25519-signing.md`, merge `e9b99443e`); Phase-3 cap self-store (`Cap.issue` → STORE → VERIFY, capbac.md §4.5); #154 no-unowned-caps; the #1409 write-side arch gate (`apps/ezagent_core/test/invariants/entity_caps_access_gate_test.exs`).
**Grounded in (MUST READ before building):**
- `docs/notes/2026-07-14-cap-signing-investigation-findings.md` — codex's **empirical** per-class differential (which cap classes are born unsigned; the wildcard-`ArgumentError` root cause); the authoritative source for §7's table. *Provenance: authored by codex on `feat/cap-signing-notail-upgrade` (commit `c86069aa4`) and copied onto this spec branch so the grounding lands self-contained when the coordinator merges to `main`.*
- `docs/notes/2026-07-14-cap-signing-upgrade-real-data.md` — the "no big code fix; re-issue through `Cap.issue`" framing + the retired-EventLog-backfill finding.
- `docs/superpowers/handoffs/2026-07-14-cap-signing-notail-upgrade-codex-handoff.md`.
- **Existing codex artifacts to reuse (on `feat/cap-signing-notail-upgrade`, commit `c86069aa4` — the impl consumes these, they are not on `main`):** `apps/ezagent_core/test/support/caps_json_scanner.ex` (the durable-home scanner the audit reuses), `apps/ezagent_core/test/architecture/cap_signing_fail_loud_test.exs` (verify-never-rescues-to-false, complementary to §4.6b), and the investigation test `apps/ezagent_domain_identity/test/integration/cap_signing_notail_investigation_test.exs`.

---

## 1. Lead-locked decisions (encode these; do NOT re-open)

1. **Goal:** every existing authorizer cap becomes signed (**0 unsigned tail**) so `require_signature: true` (enforce) can be flipped. The system is currently **dual-read** (`require_signature: false`).
2. **Automatic self-healing, not a manual ops pass:** unsigned caps are re-issued signed transparently on their **normal write-path lifecycle** — `EntityCaps.persist`, activation, materialization — anywhere a cap is written through the facade. An unsigned cap whose `granted_by`/authority is **resolvable** is re-issued through `Cap.issue` and its durable store (caps_json / snapshot identity slice) is rewritten with the signed artifact.
3. **No read-path mutation:** `EntityCaps.load` must NOT write as a side effect. If a load surfaces unsigned caps, the re-sign happens on a write path / async (the existing `Ezagent.Cap.DeliveryOutbox` durable outbox is the sanctioned async carrier). Invariant: **reads don't write.**
4. **Quarantine, never blind-sign:** a cap whose `granted_by`/authority cannot be resolved is quarantined + reported, NOT signed (upholds #154). At enforce these are denied and surface.
5. **Genesis/admin self-signs:** the admin all-wildcard genesis cap is re-issued via `Cap.issue({:genesis, admin}, admin, genesis)` — proven signable (§7), **no federation/wildcard exemption**. Covered by the self-heal path.
6. **Double gate against regression:** (a) the static write-side arch gate already landed in #1409 (forbids direct caps_json / snapshot-identity writes outside `EntityCaps` + a function allowlist) — reference + extend it; (b) a **NEW runtime invariant**: once enforce is on, persisting or verifying an unsigned authorizer cap **fails loud**.
7. **Independent audit (go/no-go):** a `mix` task scanning **both** durable homes (`users.caps_json` + `kind_snapshots` identity slice), counting unsigned authorizer caps **by class**. NOT the EventLog `CapSigningBackfill` (retired). Target = 0. Reusable as the acceptance gate + the progress meter as the tail drains.
8. **Hermetic tests:** the earlier B1 investigation test hard-coded fixture-snapshot counts (`scanned:15`, `before==after`) and mass-failed on raw re-run (unloaded sibling apps + SQL-Sandbox ownership). The audit + its tests MUST be hermetic/reproducible — re-clonable fixture, **no machine-coupled counts**, runnable under `mix ci.local` with `MIX_TEST_PARTITION`.
9. **Flip trigger stays manual:** audit=0 is the gate, but flipping `require_signature: true` is a **manual lead decision**, preceded by a real-canary-data E2E. **This spec does NOT flip enforce.**
10. **Readers already receiver-aware** (grantee-signing audit confirmed `live_auth`/`api_v1` route through `EntityCaps.load`) — NOT part of this spec.

---

## 2. Goal / Non-goals

### Goal
Drive the durable cap inventory to a state where **every authorizer cap is signed** (`signature + key_id + grantee_uri` present and verifiable), reached **automatically** as entities pass through their normal write-path lifecycle, so the lead can later flip `require_signature: true` with confidence backed by an independent audit reporting 0 unsigned authorizer caps on real canary data.

### Non-goals
- **Not** flipping enforce (decision #9). Dual-read stays on throughout this work.
- **Not** a manual per-holder ops-script backfill run (decision #2 — the self-heal is the mechanism; the audit + the re-materialize procedure are the operator's only manual levers).
- **Not** resurrecting the EventLog `CapSigningBackfill` — it is retired/deleted (decision #7).
- **Not** any crypto/signing-envelope change — Phase-4 signing is fixed; this spec only routes existing artifacts through the existing `Cap.issue`/`Signing.sign` seam.
- **Not** touching reader-side authz (decision #10).
- **Not** cross-node absorb transport — same-node/single-BEAM scope, as Phase-3/4 (capbac.md §4.5 "Accepted scope").

---

## 3. Background — why boot/activate does not self-heal today

### 3.1 The one seam that signs
`Cap.issue/3` (`apps/ezagent_core/lib/ezagent/cap.ex:33-40, 204-211`) is the **only** complete `authorize → stamp-provenance → key_id → sign` chokepoint. It: loads the issuer's held authority (`authorization_context/1`), runs `CapabilityRegistry.authorize_grant/3`, stamps `granted_by`/`granted_at`/`grantee_uri` (`prepare_provenance/3`), then `sign_artifact/1` sets `key_id` + `signature`. `Cap.verify/1` / `verified_set/2` are **dual-read filters only — they never re-sign**.

### 3.2 The write facade already rejects unsigned — so the tail lives upstream of it
Critical, review-load-bearing finding: `EntityCaps.persist/2` and `grant/2` already **reject** unsigned caps. `persist` calls `validate_issued_caps/2` → `issued_for?/2`, which requires a non-empty `signature` + non-empty `key_id` + a `grantee_uri` matching the receiver (`entity_caps.ex:74, 127-138, 232-240`). Therefore:

> **`EntityCaps.persist` cannot "re-issue" an unsigned cap — it refuses it.** The unsigned tail exists only in durable stores written by paths that **bypass the facade's issued-check**:
> - `users.caps_json` — written **directly** by `Users.do_create` / `create_read_only` (`users.ex:112-120, 167-184`) via `encode_caps/1`, never through `persist`.
> - `kind_snapshots` identity slice — structural caps constructed as **raw `%Capability{}`** (with `granted_by` set but no `signature`) in `Behavior.Identity` (`behavior/identity.ex:208-246` self Sandbox/ConfigEvolve; `:249-260` self `Identity.list_caps`), then snapshotted. `activate/2` (`:296-317`) only **merges + `verified_set`** — in dual-read the unsigned caps pass `verify` and stay, unsigned, forever.
> - the admin genesis wildcard — `initial_caps_for_spawn/1` injects the raw `Capability.admin_genesis_cap()` (`entity/user.ex:81-92`; raw shape `capability.ex:249-259`).

So decision #2's phrase "re-issued on persist" is precise only when read as: **the self-heal is a distinct re-issue step upstream of persist; persist is the fail-closed store/enforcement point** that accepts the result. The re-issue produces a signed artifact; persist (or the `:vm_internal absorb_cap` store lane) then durably writes it.

### 3.3 "New path signs" ≠ "old data self-heals" — the idempotent-skip trap
The empirical differential (§7) shows several classes DO sign on a *fresh* materialization (recipe binding, creator `Manage`, session participation, template owner, orchestrator scoped) — their grant path already runs `Cap.issue`. **But re-activating an existing entity does NOT re-sign them**, because the grant/materialize path first checks "is an equivalent authority already held?" (idempotent skip, e.g. creator `same_authority?` `workspace.ex:850-853`, membership `already_authorized?` `membership.ex:1258-1260`) — and a **legacy unsigned artifact satisfies that check under dual-read**, so the re-issue is skipped. Net: a plain restart is a no-op on the tail (the differential measured identical durable inventory before/after boot on the clean dump).

**Design consequence:** the self-heal cannot rely on re-materialization keying on *authority equivalence*. It must key on **signed-ness** ("this held cap lacks a valid signature") so it re-issues precisely the unsigned artifacts the idempotent-skip would otherwise leave behind.

### 3.4 The retired EventLog backfill
`Ezagent.Identity.CapSigningBackfill` (EventLog re-authorize) signed only 6/196 real caps (189 quarantined: malformed/missing grant events, unsupported structural shapes). It is **the wrong tool** and is retired here (decision #7 / §8). Its residual allowlist entries in the #1409 gate (`cap_signing_backfill.ex` `user_candidates/0`, `identity_caps/1`) and its test are deleted as part of this work, or the gate goes stale.

### 3.5 Counts are illustrative, never load-bearing
The older "196 caps" bucket is **not reproducible** from the specified clean dump: a fresh restore of `backups/canary/20260713T200002Z` yields **7 users / 50 kind_snapshots / 13 caps_json elements** (differential §"先纠正一个 grounding"). The 196/99 numbers depended on an already-mutated throwaway DB. **This spec and its tests therefore treat all counts as illustrative** and assert only structural properties (class → unsigned? → action) and the acceptance property (audit=0). This is the same discipline decision #8 mandates.

---

## 4. Design

### 4.1 The self-heal reconciler (pure planner + domain-owned re-issue policy)
Introduce a **cap self-heal reconciler** in `ezagent_domain_identity` with a **pure, domain-neutral planning core** and a thin invocation shell. The core owns *no* cross-domain re-issue recipes — it dispatches each unsigned cap to the **domain that owns that cap class** (§4.2), which keeps `ezagent_domain_identity` from hard-coding workspace/session authority rules (decision/fix #4).

**Pure core** — `plan(held_caps, receiver_uri, policy_registry) -> %{keep: [...], reissue: [...], quarantine: [...]}`:
- `keep` — caps that **successfully `Cap.verify_for/2`** against `receiver_uri`. The keep test is **successful verification, NOT signature-field presence**: a cap that merely *has* a `signature`/`key_id` but is malformed / untrusted-selector / wrong-receiver must NOT be kept — `verify_for/2` (`cap.ex:51-84,93-100`) is the one authority on "is this artifact good." A signed-looking-but-invalid artifact falls to `reissue`/`quarantine`, never `keep`.
- `reissue` — non-`keep` caps for which the owning domain's resolver returns `{:ok, authorization}` (§4.2). Each carries the `Cap.issue` authorization the resolver chose.
- `quarantine` — non-`keep` caps with no owning resolver, or whose resolver returns `:quarantine`/`{:error, _}`, or whose `Cap.issue` later fails (§4.3).

**Reconcile the RAW merged set, BEFORE `verified_set/2` filters it.** `Behavior.Identity.activate/2` currently computes `merged = merge_caps_by_identity(...)` then `verified_caps = Cap.verified_set(merged, uri)` (`behavior/identity.ex:303-305`) — the `verified_set` step **drops** unsigned/invalid artifacts under dual-read. The reconciler MUST run on `merged` (the raw union of snapshot + caps_json + binding), because that is the only place the unsigned tail is still visible; running it after `verified_set` sees a set the tail has already been filtered out of.

The core is total, deterministic, and takes no DB/clock — it is unit-testable with in-memory cap lists + a stub registry (hermetic, decision #8).

### 4.2 The `CapReissuePolicy` registry (per-class, domain-owned)
> **Why the earlier "derive the tag from `granted_by`" design was wrong (fixed here).** `granted_by` does NOT determine the re-issue authorization. Concrete counter-examples, verified against code:
> - **creator `Manage`** records `granted_by: creator_uri`, but its real issue path is `{:genesis, creator_uri}` (`workspace.ex:870-874`), NOT `{:held_by, creator}`. `{:held_by, creator}` would be **denied**: `Manage :any` is a wildcard-action cap over a Behavior with no data-owner, so `authorize_action_axis` requires `admin_caps?(held)` and returns `{:error, :wildcard_action_grant_requires_admin_authority}` (`capability_registry.ex:396-402`). The creator does not hold admin, so a generic `granted_by → {:held_by}` derivation would **quarantine creator-Manage forever**.
> - **session participation** records `granted_by: <owner>`, but its issue path is `{:rule, :session_participation, granter}` (`membership.ex:1259-1267`), not `{:held_by}`.
>
> The authorization recipe is a property of the **cap class + its issue site**, not of `granted_by`. So the reconciler must ask the domain that owns the class.

Define a behaviour `CapReissuePolicy` (in `ezagent_core` or a shared identity contract module):

```
@callback classify(cap :: Capability.t()) :: {:ok, class :: atom()} | :not_mine
@callback reissue_authorization(cap :: Capability.t(), receiver_uri :: URI.t()) ::
            {:ok, Cap.authorization()} | :quarantine | {:error, term()}
```

Each domain **registers a resolver for the cap classes IT owns**, via a registry the reconciler consults (compile-time list or an `Ezagent.CapReissuePolicy.Registry`, mirroring how Kinds/Behaviors self-register). Initial resolvers (verify each site before building):

| owning domain | cap class | resolver returns | proof |
|---|---|---|---|
| `ezagent_domain_identity` | genesis admin wildcard (`any/any/any/any`) | `{:genesis, admin}` | §7 row 1; sound (§4 fix #6) |
| `ezagent_domain_identity` | structural self `Identity.list_caps` (user/agent/template) | `{:admin, admin}` (admin holds genesis wildcard → `authorize_grant` passes) | `behavior/identity.ex:249-260`; `admin_caps?` recognizer `capability_registry.ex:476-484` |
| `ezagent_domain_identity` | agent self `Sandbox.update_config` / `ConfigEvolve.reconcile_cascade` | `{:admin, admin}` | `behavior/identity.ex:208-246` |
| `ezagent_domain_workspace` | creator `Manage :any` | `{:genesis, creator_uri}` (creator = `granted_by`, genesis satisfies the wildcard-action grant boundary) | `workspace.ex:849-874` |
| `ezagent_domain_session` | session participation / chat (`Session.*`, `Publisher.SessionImpl.*`) | `{:rule, :session_participation, granter}` (granter = the session owner recorded on the cap) | `membership.ex:1240-1267` |
| `ezagent_domain_session` | owner `Sandbox.destroy` / `Terminable.terminate` (`spawned_by`) / `Template:any within_workspace` / orchestrator scoped | the same tag its materializer uses | `materializer.ex:245-303`; `session_template.ex:706-743`; `orchestrator/caps.ex:74-98` |
| any | agent recipe cap (already `Cap.issue`-born) | usually `keep` (already signed); else refresh via `RecipeCapBinding.issue_and_upsert` | `recipe_cap_binding.ex:139-155` |

The pure core dispatches by `classify/1` (first domain that claims the cap wins), then calls that domain's `reissue_authorization/2`. **No resolver claims the cap → `quarantine`.** The reconciler NEVER hard-codes a workspace/session recipe; it only routes. This is the fix for both #1 (correct per-class recipe) and #4 (domain boundary).

**Forbidden:** filling `signature`/`key_id` directly on a raw cap to "make it look signed." That bypasses `authorize_grant` and is the anti-pattern the differential §"建议顺序 1" calls out. The only signing path is `Cap.issue`.

### 4.3 Quarantine rule + durable quarantine ledger (upholds #154; no false audit=0)
A non-`keep` cap is quarantined when: no domain resolver claims it; the resolver returns `:quarantine`/`{:error, _}`; the resolved issuer entity is not loadable; or `Cap.issue` under the chosen authorization returns `{:error, _}` (the issuer no longer holds the authority — `authorize_grant` denies).

**Quarantine is record-in-a-durable-ledger, NOT silent drop.** A `cap_quarantine` durable table records `{holder_uri, cap identity_key, granted_by, class, reason, first_seen, last_seen}`. The heal step does not simply delete the unsigned cap from the durable home and move on — that would make the unresolved authorizer *invisible* to an audit that only scans caps_json + snapshots, letting the tail falsely reach 0. Instead:
- Under **dual-read**, the unsigned cap stays where it is (still legacy-accepted by `verify/1`) AND a quarantine-ledger row is written, so the audit can count it.
- At **enforce**, `verify/1` returns false for it → denied + surfaced (no silent drop); the ledger row is the operator's worklist.

The audit (§4.7) counts ledger rows; `--strict` fails while any exist (§4.7). A quarantined cap is **never blind-signed** (#154) — clearing it is an explicit lead decision (resolve the authority, or revoke the cap).

### 4.4 Where the self-heal runs — lifecycle-TRIGGERED, background-EXECUTED (reads stay pure)
> **Why healing cannot be executed synchronously inside `activate/2` (fixed here).** `Behavior.Identity.activate/2` runs **PRE-`:ready`** (`lifecycle.ex` — `activate` is the pre-ready hook; the `ReadyGate` flips only AFTER it returns). But `EntityCaps.persist/2` **awaits** the mutation target becoming ready (`ensure_mutation_target` → `ReadyGate.await`, `entity_caps.ex:74-80,157-165`). Calling `persist` from inside the entity's own `activate/2` therefore **deadlocks / times out** — the entity can't become ready until `activate` returns, and `activate` is blocked waiting for it to be ready. So the heal is **triggered by** the lifecycle but **executed by** a separate worker that runs AFTER the entity is ready.

The mechanism, in two phases per entity:

1. **Detect + enqueue (on the write path, non-blocking).** On activation, run the reconciler's pure `plan/3` over the **raw merged set** (§4.1). If it yields any `reissue`/`quarantine`, enqueue a **durable heal request** keyed by holder — a cheap, non-waiting write (an insert into the heal/outbox table, or a `set_transient` + outbox row). `activate/2` returns normally; it does NOT itself re-issue or persist. Writing the ledger/heal-request row is a plain durable insert, not a facade `persist`, so it does not await readiness.
2. **Execute (background worker, post-ready).** A background heal worker (which CAN wait for readiness) drains heal requests: for each `reissue` it calls `Cap.issue(<resolver authorization>, holder_uri, cap)` and durably stores the signed artifact via the **compare-and-set heal op** (§4.5) into BOTH homes as applicable (snapshot `:identity` slice via the facade, and `caps_json` via `EntityCaps.persist`). For each `quarantine` it writes the ledger row.

**Both durable homes, explicitly.** For a User, caps live in `caps_json` (the durable *seed*, re-read into the slice on every activation — `behavior/identity.ex:296-317` unions `UserStore.load(uri)`) AND the snapshot `:identity` slice. Healing only the snapshot does **not** stick: the next activation re-merges the still-unsigned `caps_json` seed. The heal is complete only when `caps_json` **itself** is rewritten signed (through `EntityCaps.persist` → `UserStore.update_locked/2`). The background worker rewrites both; a builder must not read "heal on activate" as "snapshot rewrite is enough" for users.

**Reads stay pure (decision #3):** `EntityCaps.load` / `load_persisted` are untouched — they filter via `verified_set` and never write. The only thing a read can trigger is the *next* activation's detect-and-enqueue; the actual write is always the background worker. Detection-enqueue is itself a write path (a durable insert), never invoked from `load`.

### 4.5 The heal store op — compare-and-set, both homes (not raw `:absorb_cap`)
> **Why raw `:absorb_cap` reuse is unsound (fixed here).** The absorb store handler `store_verified_cap` (`identity.ex:676-705`) **unconditionally** dedups-by-identity, inserts the artifact, and emits `:cap_granted` — with **no precondition** on the current durable state, and it touches only the `:identity` slice, **never `caps_json`.** A delayed background heal reusing it would: (a) **resurrect** a cap that was revoked between enqueue and execution (the revoke removed the identity_key; the heal re-inserts it); (b) **overwrite** a newer artifact re-issued in the meantime; and (c) leave `caps_json` unhealed.

Introduce a **dedicated heal store op** (a distinct `:heal_cap` handler + a distinct `Cap.DeliveryOutbox` op type — NOT the `:absorb_cap` envelope, whose semantics are wrong here) with a **compare-and-set precondition**:

- **Replace only if the current durable cap IS still the unsigned equivalent** being healed — i.e. an artifact with the same `identity_key` is present AND it still fails `verify_for/2` (still the legacy unsigned cap, not a newer signed one). If the identity_key is now **absent** (revoked after enqueue) → **do nothing** (no resurrection). If a **signed** artifact with that identity_key is already present (someone re-issued it first) → **do nothing** (no overwrite of newer).
- **Covers BOTH durable homes:** the snapshot `:identity` slice AND `caps_json`. The op is expressed through the `EntityCaps` facade for both, so it stays inside the #1409 allowlist and never becomes a new direct writer.
- **Durable + distribution-safe carrier:** the op rides the existing `Cap.DeliveryOutbox` durable-retry boundary (§4.8), so a crash mid-drain retries; it is **not** node-local ETS-only.

This is the STORE lane for the background worker of §4.4. It emits a heal-specific event (not a plain `:cap_granted`, so a spurious "new capability granted to you" notice is not shown for an in-place re-sign).

### 4.6 Double gate against regression (decision #6) + closing the seed-writer hole
- **(a) Static write-side gate — extend #1409.** `entity_caps_access_gate_test.exs` already forbids any executable consumer reading/writing `users.caps_json` or reaching snapshot `:identity` caps outside the `EntityCaps` facade + a function allowlist. The self-heal's writes route through the facade (so they need **no** new allowlist entry); the retired backfill's entries are **removed** (§8).
- **(a′) Close the caps_json seed-writer hole.** `Users.do_create/4` and `create_read_only/2` write `caps_json` **directly** (`users.ex:112-120,167-184`) **without `validate_issued_caps`**, and are allowlisted by the #1409 gate (`entity_caps_access_gate_test.exs:12-20`). **Under enforce these seams can grow a NEW unsigned tail** — a fresh user could be minted with unsigned caps that authorize nothing at enforce (or, worse, silently persist). The design REQUIRES one of, chosen in Phase 0:
  - **Preferred:** route the seed writers so new writes are **born signed** — `create/create_read_only` issue their caller-supplied caps through `Cap.issue` (or `validate_issued_caps` before write), so `caps_json` is signed-by-construction. This makes the "supported authz entry" classes (§7) leave no new tail.
  - **Or (minimum):** an **enforce-time invariant** that fails loud if `caps_json` is written with any unsigned authorizer cap while `require_signature: true` — a runtime guard inside the seed writers, tested. The design must not leave enforce mode able to mint unsigned caps through an allowlisted seam.
- **(b) NEW runtime invariant — enforce-mode fail-loud.** When `require_signature: true`, an unsigned authorizer cap can neither be persisted nor pass verification silently:
  - `persist`/`grant` already fail closed via `validate_issued_caps` — pin with a test that persisting an unsigned authorizer cap returns `{:error, :invalid_cap_artifact}`.
  - `Cap.verify/1` under enforce returns `false` for the unsigned `granted_by: entity` clause (`cap.ex:51-63`) — pin that this denies, not legacy-accepts.
  - the (a′) seed-writer guard, above.
  - Complements codex's `cap_signing_fail_loud_test.exs` (verify callers never rescue an infra failure to a silent `false`). Together: unsigned → denied + surfaced; infra failure → raised, never masked.

### 4.7 The audit task (go/no-go + progress meter)
A `mix` task (distinct name — `mix ezagent.caps.audit` is the unrelated `data_owner/1` audit; use e.g. `mix ezagent.caps.signing_audit`) that:
- scans **all three** durable sources: every `users.caps_json` row, every `kind_snapshots` latest identity slice (reusing codex's `test/support/caps_json_scanner.ex` shape where possible), **and the `cap_quarantine` ledger** (§4.3);
- classifies each cap: **signed** (passes `verify_for/2`) / **unsigned-authorizer** / **quarantined** / **sentinel-excluded** (declared/needed markers, not authorizers);
- reports **unsigned-authorizer count by class** (§7 rows) + **quarantined count by reason**;
- `--strict` **exits non-zero when `unsigned-authorizer > 0` OR `quarantined > 0`** — so `audit == 0` means **both buckets empty**: no unsigned tail AND no unresolved-authority cap hiding in the ledger. A tail cannot be "cleared" by dropping an unresolvable cap into quarantine and calling it done.
- is **read-only** (never mutates), safe against any restored DB, and does not itself heal.

It shares no code with the retired EventLog backfill. Its by-class + by-reason breakdown is the drain progress meter.

### 4.8 Distribution assurance (mutually-trusting nodes; per lead)
Signed caps are **node-portable** in a mutually-trusting distributed deployment. `Cap.verify/1` re-derives the verifying key from the shared platform master seed — `Signing.derive_keypair(granted_by, trust_domain, version)` runs `HKDF(fetch_seed!(version), granted_by ‖ trust_domain)` (`signing.ex:88-95,155-160`) — so a cap **signed on any node verifies on any other node holding the same seed**; there is no node-pinned key material in the artifact. Cap **delivery** is likewise distribution-safe: the heal store op and grants ride the durable `Cap.DeliveryOutbox` (#1409), a DB-backed retry boundary, **not** node-local ETS, so a heal enqueued on one node survives failover and is applied durably. **Out of scope (deferred):** zero-trust per-node key isolation / entity-held private keys — this spec assumes the Phase-4 single-master-seed trust model (capbac.md §4.5 "Accepted scope"); it neither builds nor blocks that future work.

### 4.9 Hermetic testing (decision #8)
- The audit and reconciler tests run under `--no-start` with a test helper that starts **only** core (Repo/registry) and explicitly starts each downstream app + lifecycle path inside the same SQL-Sandbox transaction (the method the differential validated: `1 test, 0 failures` reproducibly).
- **No machine-coupled counts.** Tests assert structural properties: "a fresh raw structural cap is unsigned"; "after self-heal on the write path it is signed and verifies"; "an unresolvable-authority cap is quarantined, not signed"; "the audit reports 0 after a full drain of the fixture." Never `scanned == 15` / `before == after`.
- **Re-clonable fixture.** Where a real-data check is needed, clone a partition DB from a read-only restored source (`ezagent_raw…` → `ezagent_pg_compat_test<partition>`), migrated, per `MIX_TEST_PARTITION` — never mutate a shared default test DB.
- Runs green under `mix ci.local` with `MIX_TEST_PARTITION` (parallel-safe ecto).

---

## 5. The 10 decisions → where they live in the design

| # | Decision | Realized in |
|---|---|---|
| 1 | 0 unsigned tail → enforce-flippable | Goal §2; audit §4.7 gates it |
| 2 | Automatic self-heal on write-path lifecycle | §4.1, §4.4 (triggered), §4.5 (executed) |
| 3 | No read-path mutation | §4.4 (background-executed, reads never write) |
| 4 | Quarantine, never blind-sign | §4.3 (+ durable ledger) |
| 5 | Genesis self-signs, no exemption | §4.2 registry row 1; §7 genesis row |
| 6 | Double gate | §4.6 (a static / a′ seed-writer hole / b runtime) |
| 7 | Independent audit, not EventLog backfill | §4.7; §8 retires backfill |
| 8 | Hermetic tests | §4.9 |
| 9 | Manual flip, canary E2E first | §6 phase 4; §9 acceptance |
| 10 | Readers already receiver-aware | out of scope (§2) |

---

## 6. Phasing

Each phase is a codex sub-step: full `mix ci.local` green + rebased on main before self-merge; Elixir via editor; `MIX_TEST_PARTITION` for parallel tests.

**Phase 0 — fix future issue sites + close seed-writer hole, still dual-read.** (a) Route the born-unsigned **structural** classes (user/agent/template self `Identity.list_caps`; agent self `Sandbox.update_config` + `ConfigEvolve.reconcile_cascade`) through a provable-authority `Cap.issue` at construction, so *newly created* entities are born signed. (b) Close the caps_json seed-writer hole (§4.6 a′): make `Users.create`/`create_read_only` born-signed or validated so no allowlisted seam can grow a NEW unsigned tail. No enforce change. (Differential §"建议顺序 1".)

**Phase 1 — reconciler + `CapReissuePolicy` registry + background heal worker.** Pure `plan/3` core dispatching by cap class to domain-registered resolvers (§4.2); each domain (identity/workspace/session) registers its classes' resolvers. Lifecycle **detect+enqueue** on `activate/2` over the raw merged set; a **background worker** (post-ready) that re-issues via the resolver's authorization and stores via the **compare-and-set heal op** into BOTH homes (snapshot slice + `caps_json`); the durable `cap_quarantine` ledger. Reads stay pure. Retire the EventLog backfill + its mix task (§8).

**Phase 2 — the signing audit + both gates.** `mix ezagent.caps.signing_audit [--strict]` scanning caps_json + snapshots + the quarantine ledger; `--strict` fails on `unsigned-authorizer > 0` OR `quarantined > 0`. The enforce-mode fail-loud runtime invariant (incl. the seed-writer guard); extend/clean the #1409 allowlist. Hermetic tests throughout.

**Phase 3 — drain on canary.** In the isolated canary-data env (throwaway PG, restored dump — NEVER live stacks): the write-path self-heal drains `caps_json` + structural snapshots + idempotent-skip classes **automatically as entities activate** (decision #2). Re-activation is the trigger, not a manual per-cap script. Operator re-materialize is an **optional accelerator** for entities that do not naturally activate during the drain window. Re-run the audit; iterate until `--strict` = 0. Quarantined caps are investigated + reported to the lead, never force-signed.

**Phase 4 — manual enforce flip (NOT in this spec).** Lead decision, after audit=0 on real canary data + a real-canary-data E2E confirming `require_signature: true` denies nothing legitimate. This spec stops before the flip.

---

## 7. Per-class differential — how each class self-heals or quarantines

From the empirical differential (`docs/notes/2026-07-14-cap-signing-investigation-findings.md`, commit `c86069aa4`), verified against code. "Fresh signs?" = does a *fresh* materialization produce a signed artifact. "Old data self-heals on activate?" = does re-activating an existing entity re-sign a legacy unsigned equivalent (see §3.3 idempotent-skip).

| cap class | fresh signs? | old self-heals on plain activate? | bypass / issue site | self-heal action (this spec) |
|---|---|---|---|---|
| **admin genesis wildcard** (`any/any/any/any`) | n/a (injected raw) | ✗ | `initial_caps_for_spawn/1` injects raw genesis (`entity/user.ex:81-92`; shape `capability.ex:249-259`) | re-issue `Cap.issue({:genesis, admin}, admin, genesis)` + persist signed. **No exemption** (decision #5) |
| **user `caps_json` existing seed** | ✗ | ✗ | direct write `Users.do_create`/`create_read_only` (`users.ex:112-120,167-184`); activate only merge+verify (`behavior/identity.ex:296-317`) | re-issue each held authorizer cap + rewrite `caps_json` via `EntityCaps.persist` → reload snapshot (§4.4 path 2) |
| **user supported authz entry** (`Workspace.create_user caps:"*"`, `mix ezagent.user.create`) | ✓ | — | `workspace_user_admin.ex:221-245` + `mix .../user.create.ex:226-253` call `Cap.issue` | keep entry; audit/tighten any direct `Users.create` caller passing raw caps |
| **user/agent/template self `Identity.list_caps`** | ✗ | ✗ | direct `%Capability{}` `behavior/identity.ex:249-260`, then only `verified_set` | Phase 0: route construction through `Cap.issue`; Phase 1: re-issue existing snapshots |
| **agent self `Sandbox.update_config`** | ✗ | ✗ | direct `%Capability{}` `behavior/identity.ex:208-246` | same as above; plain reactivate does NOT self-heal |
| **agent self `ConfigEvolve.reconcile_cascade`** | ✗ | ✗ | direct `%Capability{}` `behavior/identity.ex:208-246` | same as above |
| **agent recipe cap** | ✓ | ✗ (same binding version) | `RecipeCapBinding.issue_and_upsert` → `Cap.issue` (`recipe_cap_binding.ex:58-67,139-155`) | operator refresh/upsert binding version re-issues; signed-ness-keyed reconciler also re-issues on activate |
| **agent creator `Manage`** | ✓ | ✗ (idempotent skip) | entry `workspace.ex:849-874` → `Ezagent.Identity.Grant` `{:genesis, creator}` → `Cap.issue` (NOT `{:held_by}` — wildcard-action needs admin/genesis authority) | fresh none; legacy unsigned triggers `same_authority?` skip (`workspace.ex:850-853`) → explicit re-issue via reconciler under the workspace resolver `{:genesis, creator}` |
| **owner `Sandbox.destroy` / `Terminable.terminate`** (`spawned_by`) | ✓ | ✗ (idempotent skip) | session materializer `.../materializer.ex:245-303` → Identity.Grant → `Cap.issue` | fresh none; legacy unsigned → explicit re-issue |
| **SessionTemplate owner `Template:any within_workspace`** | ✓ | ✗ | `session_template.ex:706-743` → grant → `Cap.issue` | fresh none; old owner cap explicit re-issue |
| **session participation / chat** (`receive`, `remove_participant`, `assign_role`) | ✓ | ✗ (cold rehydrate not an upgrade; `already_authorized?` skip) | `session/membership.ex:1240-1267` → Identity.Grant → `Cap.issue` | new materialize signs; legacy unsigned → explicit re-issue or safe replace |
| **orchestrator scoped / socialware recipe caps** | ✓ | ✗ (same version) | `.../orchestrator/caps.ex:74-98` → `Cap.issue`; `definition_agents.ex:303-317,667-674` bind-then-spawn | re-bind/materialize re-issues; reconciler re-issues on activate |

**Two structural takeaways the reconciler is designed around:**
1. **Boot/activate is not an upgrade operation by itself** — inventory is identical before/after a plain restart.
2. Every class either (a) is born unsigned via a direct-construct bypass → Phase-0 fix + reconciler re-issue, or (b) signs on *fresh* materialize but has a legacy unsigned equivalent that the idempotent-skip protects → the **signed-ness-keyed** reconciler (§3.3) is what forces those to re-issue.

*(All file:line anchors are impl-constraints for the builder to confirm, not the design — the code wins if they have drifted. Verify against `main` + the owner branch before citing.)*

---

## 8. Retiring the EventLog backfill (decision #7)

`Ezagent.Identity.CapSigningBackfill` and its test are deleted **together with the mix task that invokes it** — `mix ezagent.cap.backfill` (`apps/ezagent_domain_identity/lib/mix/tasks/ezagent.cap.backfill.ex:19-38` calls `CapSigningBackfill.dry_run/apply`), which would fail to compile once the module is gone. Delete or rewrite the task in the same PR. Its two residual entries in the #1409 gate allowlist (`cap_signing_backfill.ex` → `user_candidates/0` in `@raw_user_caps_allowlist`; `identity_caps/1` in `@snapshot_identity_caps_allowlist`, `entity_caps_access_gate_test.exs:21-22,38-39`) are removed in the same PR — leaving them makes the gate reference a deleted module and drift. Any doc/runbook referencing `dry_run/1` as the gate is updated to point at the new signing audit (§4.7). **Enumerate every reference — `grep -rn CapSigningBackfill apps/` — before deletion so main stays green** (current refs: the module, its test, and the `ezagent.cap.backfill` mix task).

---

## 9. Acceptance criteria

1. **Audit = 0 on real canary data — BOTH buckets.** `mix ezagent.caps.signing_audit --strict` exits 0 against the restored canary dump after the drain (Phase 3): `unsigned-authorizer == 0` AND `quarantined == 0` across caps_json + snapshots + the quarantine ledger. A tail cannot be "cleared" by dropping an unresolvable cap into quarantine.
2. **Automatic, lifecycle-triggered / background-executed.** A born-unsigned structural cap and a legacy unsigned `caps_json` cap become signed **without a manual per-cap script** — the entity's activation enqueues, the background worker re-issues + rewrites both homes. Proven by a hermetic test that starts from an unsigned fixture, drives activation, drains the worker, and asserts signed-in-both-homes. No `persist` is called synchronously from `activate/2` (no deadlock).
3. **Per-class recipe is correct.** A test proves creator-`Manage` re-issues under `{:genesis, creator}` (a `{:held_by, creator}` recipe would be denied by `authorize_action_axis`) and participation under `{:rule, :session_participation, granter}` — i.e. the resolver registry, not `granted_by`, chooses the authorization.
4. **Compare-and-set, no resurrection.** A test enqueues a heal, revokes the cap before the worker runs, drains the worker, and asserts the cap is NOT resurrected; a second test asserts a newer signed artifact is not overwritten by a stale heal.
5. **Reads don't write.** A test asserts `EntityCaps.load`/`load_persisted` over an unsigned-cap fixture leaves the durable store byte-unchanged.
6. **Quarantine upholds #154, durably.** A cap with unresolvable/`non-entity` authority is written to the `cap_quarantine` ledger + counted by the audit, never signed and never silently dropped — asserted by a test.
7. **Genesis signs with no exemption.** `Cap.issue({:genesis, admin}, admin, admin_genesis_cap())` produces a verifying signed artifact (`authorize_grant` recognizes the raw wildcard as admin authority — `capability_registry.ex:476-484` — no circularity); the healed genesis cap verifies.
8. **Double gate holds, seed-writer hole closed.** (a) A fixture adding a direct caps_json/snapshot writer fails the extended #1409 gate; (a′) a fresh user cannot be minted with an unsigned authorizer cap at enforce (seed writers born-signed or guarded); (b) under `require_signature: true`, persisting or verifying an unsigned authorizer cap fails loud, asserted by the new runtime invariant.
9. **Node-portable (distribution).** A test signs a cap under one derived keypair and verifies it via key re-derivation from the same master seed (proving no node-pinned material); delivery rides the durable outbox, not node-local ETS (§4.8).
10. **Dual-read stays safe / enforce NOT flipped.** No code in this work sets `require_signature: true`; new grants still sign, legacy caps still authorize during the drain.
11. **Hermetic + parallel-safe.** All new tests pass under `mix ci.local` with `MIX_TEST_PARTITION`; no machine-coupled counts; re-clonable fixture.

---

## 10. Risks

- **R1 — the per-class table is code-grounded, empirically confirmed on a small clean dump, but the "196" scale is unreproducible (§3.5).** The audit (§4.7) is the reconciliation: it reports the *actual* per-class unsigned inventory on whatever real data it is pointed at. Treat §7 as the map, the audit as the territory. If the audit surfaces a class not in §7, that is a finding to fold back, not a spec failure.
- **R2 — idempotent-skip classes.** If the reconciler's signed-ness key is implemented as "authority-equivalent already held" (the trap in §3.3), legacy unsigned caps will be silently skipped and the tail never reaches 0. Mitigation: the reconciler MUST key on signature presence/validity; a test drives a legacy-unsigned-equivalent through activate and asserts it is re-issued (fails if the skip fires).
- **R3 — re-issue authority no longer resolvable.** A legacy cap whose issuer entity was deleted, or whose issuer no longer holds the authority, cannot be re-issued. This is expected → quarantine (§4.3); at enforce it is denied. The audit counts it, so the tail cannot reach 0 while such caps exist — forcing an explicit lead decision on each (never a blind-sign).
- **R4 — activate-path cost / coupling.** The activation hook does only the cheap **detect+enqueue** (a no-op fast-path when all held caps already `verify_for/2`); the expensive re-issue + durable write is the background worker, decoupled from activation. A transient store failure retries via the durable outbox without failing activation, and never blocks the entity becoming ready (that was the deadlock — §4.4).
- **R5 — snapshot vs `caps_json` split writes.** A user has caps in both homes; a partial heal (slice signed but caps_json not) regresses on next reload because caps_json is the re-read seed. Mitigation: the heal op rewrites **both** homes through the facade; the audit scans both; a test covers a user with unsigned caps in both homes reaching all-signed and staying signed across a re-activation.
- **R6 — silent resurrection / overwrite by a stale heal.** A background heal that runs after a revoke/re-issue could resurrect or clobber. Mitigation: the compare-and-set heal op (§4.5) is a no-op unless the exact unsigned equivalent is still present.
- **R7 — the `CapReissuePolicy` registry is a new coordination surface.** A cap class with no registered resolver silently quarantines (correct, but could mask a missing resolver). Mitigation: the audit's by-class breakdown surfaces an unexpectedly-large quarantine bucket for a class; a registration-coverage test asserts every class in §7 has an owning resolver.
- **R8 — deleting the backfill red-flags the gate / breaks compile.** Removing the module without removing its allowlist entries AND the `ezagent.cap.backfill` mix task (§8) leaves the #1409 gate referencing a deleted function → main red, or a compile error. Mitigation: single PR, grep-enumerated.

---

## 11. Open questions (genuinely unresolved — the §1 decisions are LOCKED, not listed here)

1. **Session/creator/template legacy caps: re-issue in place, or safe-replace?** The differential notes these can be "显式 re-issue 或先安全替换" (re-issue OR safely replace). **Re-issue preserves the `identity_key` + scope, but NOT `granted_at`** — `Cap.issue` → `prepare_provenance/3` overwrites `granted_by`, `granted_at` (fresh `DateTime.utc_now()`), and `grantee_uri` (`cap.ex:149-166`); only the identity axes (kind/behavior/action/instance/workspace) survive. So "re-issue is provenance-preserving" is inaccurate — it preserves *identity*, and re-stamps *provenance* with the same issuer + a new timestamp. Safe-replace (revoke + grant fresh) additionally emits revoke/grant events and briefly de-authorizes. **Recommendation:** re-issue in place (identity-preserving) for the drain; use safe-replace only where the original authority is unresolvable-but-re-derivable from live session/membership state. Needs a lead/codex call per class in the impl-plan.
2. **Cold-entity reach: sweeper, or rely on natural activation?** The automatic write-path self-heal (§4.4) drives the tail to 0 as entities activate — no manual step. The only gap is an entity that never activates during the drain window. Options to close it: a background **sweeper** (drain-on-boot over pending-unsigned durable rows, fully automatic, more new surface), vs. the operator's optional re-materialize accelerator (less surface, one manual nudge). Recommendation: rely on natural activation for Phase 3; add a sweeper only if the audit plateaus above 0 on genuinely-cold entities. Either way the mechanism stays automatic (decision #2) — the re-materialize is an accelerator, never the required path.
3. **Audit source-of-truth for `kind_snapshots`.** The audit must read the *latest* snapshot per entity; confirm whether reading only `kind_snapshots` latest rows (vs also live slices) can miss a live-but-un-snapshotted unsigned cap. Recommendation: audit reads durable homes only (the enforce target is durable); a live-only unsigned cap is transient and heals on next snapshot — but confirm no class holds authorizer caps live-only across restarts.
