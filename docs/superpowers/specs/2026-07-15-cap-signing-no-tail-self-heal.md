# Cap-signing "no-tail" self-healing upgrade

**Status:** SPEC **v3** — lead-locked 2026-07-15 (the 10 decisions in §1 are fixed; do NOT re-litigate). Revised after a SECOND codex adversarial review (9 flaws fixed on top of v2): the **`signed_and_valid?/2` classifier** replacing `verify_for/2` everywhere (the load-bearing correctness fix — `verify_for/2` accepts unsigned caps under dual-read, a false-zero); the policy resolver returns a **tagged action** (`:reissue` / `:refresh_binding` / `:quarantine`) so recipe caps refresh their binding; the audit scans **four** durable sources incl. `recipe_cap_bindings`; an **ABA-safe byte-identical CAS** (identity_key excludes provenance); explicit **two-home partial-apply convergence**; a **tombstoning quarantine ledger** (OPEN-only `--strict`); a **REQUIRED durable sweeper** (resolves OQ-2); a **durable==live enforce-flip fence** (resolves OQ-3); and a **full-surface resolver-coverage gate** (adds responsibility + world-layout classes). v2's fixes retained (per-class registry, background-executed heal, seed-writer hole, distribution). Ready for lead verification → impl-plan → build.

> **v3 predicate note:** wherever earlier drafts said "signed" or "signed-ness-keyed," read **`signed_and_valid?/2`** (§4.0) — signature+key_id+grantee_uri present AND cryptographic `Signing.verify` passes for the receiver, independent of the `require_signature?` flag. `verify_for/2` is NEVER a signed-ness classifier here.
**Date:** 2026-07-15
**Owner branch (codex builds here):** `feat/cap-signing-notail-upgrade` (codex owns fully; self-drives ALL phases onto it continuously — no PR, no per-phase coordinator gate; returns the target-branch HEAD at the end; coordinator does acceptance + the single merge to `main`).
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

### 4.0 The one classifier: `signed_and_valid?/2` — NEVER `verify_for/2`
> **The load-bearing correctness fix (v3).** Under dual-read (`require_signature: false`), `Cap.verify/1` **accepts unsigned legacy caps** — the `%Capability{signature: nil, …, granted_by: %URI{scheme: "entity"}}` clause returns `true` while enforce is off (`cap.ex:51-63`), and `verify_for/2` builds on it (`cap.ex:93-100`). So `verify_for/2` answers "is this cap *acceptable right now*," **NOT** "is this cap *signed*." Using `verify_for/2` as the keep/audit classifier would make the planner **keep unsigned caps**, the CAS **accept** them, and the audit report **`unsigned-authorizer = 0` without healing anything** — a false zero that makes the entire no-tail work a no-op.

Define a dedicated predicate, distinct from the dual-read `verify/1` family, used by the planner (keep-vs-reissue), the CAS (§4.5), and the audit (§4.7) — **the only classifier for "is this cap already signed":**

```
signed_and_valid?(cap, receiver_uri) :=
  is_binary(cap.signature) and cap.signature != "" and
  is_binary(cap.key_id)    and cap.key_id    != "" and
  match?(%URI{}, cap.grantee_uri) and
  URI.stable_key(cap.grantee_uri) == URI.stable_key(receiver_uri) and
  crypto_ok?(cap)          # Cap.Signing.parse_key_id + derive_keypair + Signing.verify pass
```

`crypto_ok?` runs the **cryptographic** path (`Signing.verify/3`, `signing.ex:128-129`) — the same body `verify/1`'s *signed* clause runs (`cap.ex:65-82`), but **independent of the `require_signature?` flag**, so it returns the same answer in dual-read and enforce. `signed_and_valid?` is `false` for every unsigned legacy cap, a signed-looking-but-malformed cap, a wrong-receiver cap, or a bad signature. This is the single source of truth for "signed"; `verify_for/2` is only ever "acceptable at this moment" and is NOT used as a signed-ness classifier anywhere in this spec.

### 4.1 The self-heal reconciler (pure planner + domain-owned re-issue policy)
Introduce a **cap self-heal reconciler** in `ezagent_domain_identity` with a **pure, domain-neutral planning core** and a thin invocation shell. The core owns *no* cross-domain re-issue recipes — it dispatches each unsigned cap to the **domain that owns that cap class** (§4.2), which keeps `ezagent_domain_identity` from hard-coding workspace/session authority rules (decision/fix #4).

**Pure core** — `plan(held_caps, receiver_uri, policy_registry) -> %{keep: [...], reissue: [...], quarantine: [...]}`:
- `keep` — caps for which **`signed_and_valid?(cap, receiver_uri)` is true** (§4.0). NOT `verify_for/2` — under dual-read that would keep unsigned caps and defeat the whole upgrade.
- `reissue` — non-`keep` caps for which the owning domain's resolver returns a `{:reissue, auth_tag}` or `{:refresh_binding, binding_ref}` action (§4.2).
- `quarantine` — non-`keep` caps with no owning resolver, or whose resolver returns `{:quarantine, reason}`/`{:error, _}`, or whose `Cap.issue`/binding-refresh later fails (§4.3).

**Reconcile the RAW merged set, BEFORE `verified_set/2` filters it.** `Behavior.Identity.activate/2` currently computes `merged = merge_caps_by_identity(...)` then `verified_caps = Cap.verified_set(merged, uri)` (`behavior/identity.ex:303-305`) — the `verified_set` step **drops** unsigned/invalid artifacts under dual-read. The reconciler MUST run on `merged` (the raw union of snapshot + caps_json + binding), because that is the only place the unsigned tail is still visible; running it after `verified_set` sees a set the tail has already been filtered out of.

The core is total, deterministic, and takes no DB/clock — it is unit-testable with in-memory cap lists + a stub registry (hermetic, decision #8).

### 4.2 The `CapReissuePolicy` registry (per-class, domain-owned)
> **Why the earlier "derive the tag from `granted_by`" design was wrong (fixed here).** `granted_by` does NOT determine the re-issue authorization. Concrete counter-examples, verified against code:
> - **creator `Manage`** records `granted_by: creator_uri`, but its real issue path is `{:genesis, creator_uri}` (`workspace.ex:870-874`), NOT `{:held_by, creator}`. `{:held_by, creator}` would be **denied**: `Manage :any` is a wildcard-action cap over a Behavior with no data-owner, so `authorize_action_axis` requires `admin_caps?(held)` and returns `{:error, :wildcard_action_grant_requires_admin_authority}` (`capability_registry.ex:396-402`). The creator does not hold admin, so a generic `granted_by → {:held_by}` derivation would **quarantine creator-Manage forever**.
> - **session participation** records `granted_by: <owner>`, but its issue path is `{:rule, :session_participation, granter}` (`membership.ex:1259-1267`), not `{:held_by}`.
>
> The authorization recipe is a property of the **cap class + its issue site**, not of `granted_by`. So the reconciler must ask the domain that owns the class.

Define a behaviour `CapReissuePolicy`. The resolver returns a **tagged re-issue ACTION**, not a bare authorization tag — because some classes (recipe caps) re-issue through a **binding refresh** (`RecipeCapBinding.issue_and_upsert/4`), which a plain `Cap.issue` authorization cannot express:

```
@callback classify(cap :: Capability.t()) :: {:ok, class :: atom()} | :not_mine
@callback reissue_action(cap :: Capability.t(), receiver_uri :: URI.t()) ::
            {:reissue, Cap.authorization()}          # generic: worker calls Cap.issue(tag, receiver, cap)
          | {:refresh_binding, binding_ref :: term()} # recipe: worker calls RecipeCapBinding.issue_and_upsert/4
          | {:quarantine, reason :: term()}
```

Each domain **registers a resolver for the cap classes IT owns**, via a registry the reconciler consults (compile-time list or an `Ezagent.CapReissuePolicy.Registry`, mirroring how Kinds/Behaviors self-register). Initial resolvers (verify each site before building):

| owning domain | cap class | resolver action | proof |
|---|---|---|---|
| `ezagent_domain_identity` | genesis admin wildcard (`any/any/any/any`) | `{:reissue, {:genesis, admin}}` | §7 row 1; sound (fix #6) |
| `ezagent_domain_identity` | structural self `Identity.list_caps` (user/agent/template) | `{:reissue, {:admin, admin}}` (admin holds genesis wildcard → `authorize_grant` passes) | `behavior/identity.ex:249-260`; recognizer `capability_registry.ex:476-484` |
| `ezagent_domain_identity` | agent self `Sandbox.update_config` / `ConfigEvolve.reconcile_cascade` | `{:reissue, {:admin, admin}}` | `behavior/identity.ex:208-246` |
| `ezagent_domain_workspace` | creator `Manage :any` | `{:reissue, {:genesis, creator_uri}}` (creator = `granted_by`; genesis satisfies the wildcard-action grant boundary) | `workspace.ex:849-874` |
| `ezagent_domain_workspace` | **responsibility bundle caps** (`{:genesis, caller}`-granted at assignment) | `{:reissue, {:genesis, granted_by}}` | `responsibility_assignments.ex:124-130` |
| `ezagent_plugin_world` | **world-layout manage cap** (`workspace / World.Behavior.Layout / :manage`, genesis-granted) | `{:reissue, {:genesis, granted_by}}` | `layout_bootstrap.ex:8-28` |
| `ezagent_domain_session` | session participation / chat (`Session.*`, `Publisher.SessionImpl.*`) | `{:reissue, {:rule, :session_participation, granter}}` (granter = the session owner on the cap) | `membership.ex:1240-1267` |
| `ezagent_domain_session` | owner `Sandbox.destroy` / `Terminable.terminate` (`spawned_by`) / `Template:any within_workspace` / orchestrator scoped | `{:reissue, <the tag its materializer uses>}` | `materializer.ex:245-303`; `session_template.ex:706-743`; `orchestrator/caps.ex:74-98` |
| `ezagent_domain_identity` | agent recipe cap (binding-derived) | usually `keep` (already `signed_and_valid?`); else `{:refresh_binding, binding_ref}` → `issue_and_upsert` | `recipe_cap_binding.ex:139-155` |

The pure core dispatches by `classify/1` (first domain that claims the cap wins), then calls that domain's `reissue_action/2`. **No resolver claims the cap → `{:quarantine, :no_resolver}`** (safe default — unknown classes quarantine, never blind-sign, and are flagged by the coverage test §9/§4.6c). The reconciler NEVER hard-codes a workspace/session recipe; it only routes. This is the fix for #1 (correct per-class recipe), #2 (binding action), #4 (domain boundary), and #9 (full surface).

**Forbidden:** filling `signature`/`key_id` directly on a raw cap to "make it look signed." That bypasses `authorize_grant` and is the anti-pattern the differential §"建议顺序 1" calls out. The only signing path is `Cap.issue`.

### 4.3 Quarantine rule + durable quarantine ledger (upholds #154; no false audit=0)
A non-`keep` cap is quarantined when: no domain resolver claims it; the resolver returns `:quarantine`/`{:error, _}`; the resolved issuer entity is not loadable; or `Cap.issue` under the chosen authorization returns `{:error, _}` (the issuer no longer holds the authority — `authorize_grant` denies).

**Quarantine is record-in-a-durable-ledger, NOT silent drop.** A `cap_quarantine` durable table records `{holder_uri, cap identity_key, granted_by, class, reason, status, first_seen, last_seen, closed_at}`. The heal step does not simply delete the unsigned cap from the durable home and move on — that would make the unresolved authorizer *invisible* to an audit that only scans caps_json + snapshots, letting the tail falsely reach 0. Instead:
- Under **dual-read**, the unsigned cap stays where it is (still legacy-accepted by `verify/1`) AND an OPEN quarantine-ledger row is written (idempotent upsert keyed by `{holder, identity_key}` — re-detecting the same cap updates `last_seen`, never duplicates), so the audit can count it.
- At **enforce**, `verify/1` returns false for it → denied + surfaced (no silent drop); the OPEN ledger row is the operator's worklist.

**The ledger tombstones on resolution — it is not write-only.** A row is **closed** (`status: :resolved`, `closed_at` set) when the cap it tracks is resolved: either it later becomes `signed_and_valid?` (the authority got fixed and a heal succeeded) or it is revoked. The heal worker and the revoke path both close the matching OPEN row. Without this, a once-quarantined-then-resolved cap would leave a permanent row that blocks `--strict` forever. The audit (§4.7) counts **only OPEN** rows; `--strict` fails while any OPEN row exists. A quarantined cap is **never blind-signed** (#154) — the operator resolves the authority (→ heal closes the row) or revokes it (→ revoke closes the row).

### 4.4 Where the self-heal runs — lifecycle-TRIGGERED, background-EXECUTED (reads stay pure)
> **Why healing cannot be executed synchronously inside `activate/2` (fixed here).** `Behavior.Identity.activate/2` runs **PRE-`:ready`** (`lifecycle.ex` — `activate` is the pre-ready hook; the `ReadyGate` flips only AFTER it returns). But `EntityCaps.persist/2` **awaits** the mutation target becoming ready (`ensure_mutation_target` → `ReadyGate.await`, `entity_caps.ex:74-80,157-165`). Calling `persist` from inside the entity's own `activate/2` therefore **deadlocks / times out** — the entity can't become ready until `activate` returns, and `activate` is blocked waiting for it to be ready. So the heal is **triggered by** the lifecycle but **executed by** a separate worker that runs AFTER the entity is ready.

The mechanism, in three parts:

1. **Detect + enqueue (on the write path, non-blocking).** On activation, run the reconciler's pure `plan/3` over the **raw merged set** (§4.1). If it yields any `reissue`/`quarantine`, enqueue a **durable heal request** keyed by holder — a cheap, non-waiting write (an insert into the heal/outbox table, or a `set_transient` + outbox row). `activate/2` returns normally; it does NOT itself re-issue or persist. Writing the ledger/heal-request row is a plain durable insert, not a facade `persist`, so it does not await readiness.
2. **Execute (background worker, post-ready).** A background heal worker (which CAN wait for readiness) drains heal requests. Per cap action: for `{:reissue, tag}` it calls `Cap.issue(tag, holder_uri, cap)`; for `{:refresh_binding, ref}` it calls `RecipeCapBinding.issue_and_upsert/4` (the binding replays signed artifacts into the holder's `create/1` self-store lane). It then durably stores each signed artifact via the **compare-and-set heal op** (§4.5) into BOTH homes as applicable (snapshot `:identity` slice via the facade, `caps_json` via `EntityCaps.persist`). For `{:quarantine, reason}` it upserts the OPEN ledger row (§4.3).
3. **Required durable sweeper (Phase 3 backstop — NOT optional).** A durable background **sweeper/enumerator** periodically scans the durable homes (§4.7's four sources) for caps that are not `signed_and_valid?` and re-enqueues heal requests for them. This is REQUIRED, not deferred (resolves OQ-2, decision A), because lifecycle-triggered heal alone cannot guarantee audit=0: (a) an entity that **never activates** during the drain is never triggered; (b) an initial durable-enqueue **failure** (e.g. `delivery_outbox.ex:300-308`) is not something the outbox can retry (nothing was enqueued); (c) a **partial two-home heal** (part 4 below) needs another pass. The sweeper is idempotent (§4.5 CAS makes re-runs safe) and is the mechanism that makes "automatic drain to 0" actually hold.

**Both durable homes, explicitly + convergent under partial apply.** For a User, caps live in `caps_json` (the durable *seed*, re-read into the slice on every activation — `behavior/identity.ex:296-317` unions `UserStore.load(uri)`) AND the snapshot `:identity` slice, which **commit separately** (`behavior/identity.ex:621-630`, `server.ex:603-630`). A crash between the two writes leaves one home signed and the other unsigned. The design does NOT rely on a cross-home transaction; instead the heal is **idempotent and convergent**: the audit (§4.7) counts a holder as `unsigned-authorizer > 0` if **EITHER** home has an unsigned authorizer cap, and the sweeper (part 3) re-heals it on the next pass. Ordering is deliberately `caps_json` first (the re-read seed — healing it stops the next activation re-introducing the unsigned cap), then the snapshot slice; but correctness rests on convergence, not ordering. Healing only the snapshot never "sticks" because the unsigned `caps_json` seed is re-merged on the next activation — the worker MUST rewrite both.

**Reads stay pure (decision #3):** `EntityCaps.load` / `load_persisted` are untouched — they filter via `verified_set` and never write. A read can only trigger the *next* activation's detect-and-enqueue (or be picked up by the sweeper); the actual write is always the background worker. Detection-enqueue is itself a write path (a durable insert), never invoked from `load`.

### 4.5 The heal store op — compare-and-set, both homes (not raw `:absorb_cap`)
> **Why raw `:absorb_cap` reuse is unsound (fixed here).** The absorb store handler `store_verified_cap` (`identity.ex:676-705`) **unconditionally** dedups-by-identity, inserts the artifact, and emits `:cap_granted` — with **no precondition** on the current durable state, and it touches only the `:identity` slice, **never `caps_json`.** A delayed background heal reusing it would: (a) **resurrect** a cap that was revoked between enqueue and execution (the revoke removed the identity_key; the heal re-inserts it); (b) **overwrite** a newer artifact re-issued in the meantime; and (c) leave `caps_json` unhealed.

Introduce a **dedicated heal store op** (a distinct `:heal_cap` handler + a distinct `Cap.DeliveryOutbox` op type — NOT the `:absorb_cap` envelope, whose semantics are wrong here) with an **ABA-safe compare-and-set precondition**:

- **The CAS token is the EXACT unsigned artifact captured at enqueue, compared byte-for-byte** (full struct incl. `granted_by`/`granted_at`) — **NOT** the logical `identity_key`. This matters because `identity_key` deliberately **excludes** provenance (`capability/match.ex:66`), so a revoke + same-shape regrant **from a different issuer / at a different time** shares the same `identity_key`. A logical-key CAS would then overwrite a legitimately different newer cap (ABA). The heal replaces the durable cap **only if the current durable cap is byte-identical to the exact artifact the heal captured** (i.e. still the same unsigned artifact, same provenance). Otherwise → **do nothing** (a revoke removed it, or a newer cap won) — it is not resurrected/clobbered; the sweeper (§4.4 part 3) re-detects on the next pass if the current state is still unsigned.
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
- **(c) Resolver-coverage gate — enumerate the ACTUAL issuance surface, not §7.** §7's table is a curated map, but the live issuance surface is larger (e.g. workspace **responsibility** caps `responsibility_assignments.ex:124-130`, **world-layout** caps `layout_bootstrap.ex:8-28` — both outside the original §7). A coverage test greps every cap-producing site (`Cap.issue`, `Identity.Grant.grant_cap*`, `RecipeCapBinding.issue_and_upsert`, and direct `%Capability{}` constructors) and asserts each resulting cap **class** has a registered `CapReissuePolicy` resolver OR is explicitly classified quarantine. An **unknown class defaults to quarantine (safe — never blind-signed)** and is **flagged** by this test so a new issuance site can't silently create an un-healable tail. This is what makes the registry complete instead of §7-limited.

### 4.7 The audit task (go/no-go + progress meter)
A `mix` task (distinct name — `mix ezagent.caps.audit` is the unrelated `data_owner/1` audit; use e.g. `mix ezagent.caps.signing_audit`) that:
- scans **all FOUR** durable sources: every `users.caps_json` row, every `kind_snapshots` latest identity slice (reusing codex's `test/support/caps_json_scanner.ex` shape where possible), **every `recipe_cap_bindings` row** (binding artifacts are fetched + merged into Identity state at create/activate — `behavior/identity.ex:153-186,321-334` — so binding-derived unsigned caps are otherwise invisible), **and the `cap_quarantine` ledger** (§4.3);
- classifies each cap with **`signed_and_valid?/2` (§4.0), NEVER `verify_for/2`** — under dual-read `verify_for/2` accepts unsigned caps, so an audit built on it would report a false `unsigned-authorizer = 0` while the tail is fully intact. Buckets: **signed** (`signed_and_valid?` true) / **unsigned-authorizer** / **quarantined (OPEN ledger rows only)** / **sentinel-excluded** (declared/needed markers, not authorizers);
- reports **unsigned-authorizer count by class** (§7 rows) + **OPEN-quarantine count by reason**;
- `--strict` **exits non-zero when `unsigned-authorizer > 0` OR `open-quarantined > 0`** — so `audit == 0` means **both buckets empty**: no unsigned tail across any of the four homes AND no unresolved-authority cap in an OPEN ledger row. A tail cannot be "cleared" by dropping an unresolvable cap into quarantine (the OPEN row still fails `--strict`), and a resolved cap's tombstoned row does not block it (§4.3).
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
| 2 | Automatic self-heal on write-path lifecycle | §4.1, §4.4 (triggered + required sweeper), §4.5 (executed) |
| 3 | No read-path mutation | §4.4 (background-executed, reads never write) |
| 4 | Quarantine, never blind-sign | §4.3 (durable + tombstoning ledger) |
| 5 | Genesis self-signs, no exemption | §4.2 registry row 1; §7 genesis row |
| 6 | Double gate | §4.6 (a static / a′ seed-writer / b runtime / c resolver-coverage) |
| 7 | Independent audit, not EventLog backfill | §4.7; §8 retires backfill |
| 8 | Hermetic tests | §4.9 |
| 9 | Manual flip, canary E2E first | §6 phase 4; §9 acceptance |
| 10 | Readers already receiver-aware | out of scope (§2) |

---

## 6. Phasing

Each phase is a commit on the target branch `feat/cap-signing-notail-upgrade`: full `mix ci.local` green + gates + rebased on latest `main` before landing — codex self-drives P0→P3 continuously (no per-phase coordinator gate, no PR); the coordinator reviews the target branch at the end + merges to `main` once. Elixir via editor; `MIX_TEST_PARTITION` for parallel tests.

**Phase 0 — fix future issue sites + close seed-writer hole, still dual-read.** (a) Route the born-unsigned **structural** classes (user/agent/template self `Identity.list_caps`; agent self `Sandbox.update_config` + `ConfigEvolve.reconcile_cascade`) through a provable-authority `Cap.issue` at construction, so *newly created* entities are born signed. (b) Close the caps_json seed-writer hole (§4.6 a′): make `Users.create`/`create_read_only` born-signed or validated so no allowlisted seam can grow a NEW unsigned tail. No enforce change. (Differential §"建议顺序 1".)

**Phase 1 — reconciler + `CapReissuePolicy` registry + background heal worker.** The `signed_and_valid?/2` classifier (§4.0). Pure `plan/3` core dispatching by cap class to domain-registered resolvers returning tagged actions (§4.2); each domain (identity/workspace/session/world) registers its classes' resolvers. Lifecycle **detect+enqueue** on `activate/2` over the raw merged set; a **background worker** (post-ready) that re-issues (via `Cap.issue` or `RecipeCapBinding.issue_and_upsert`) and stores via the **ABA-safe CAS heal op** into BOTH homes; the tombstoning `cap_quarantine` ledger. Reads stay pure. Retire the EventLog backfill + its mix task + handoff runbook step (§8).

**Phase 2 — the signing audit + both gates.** `mix ezagent.caps.signing_audit [--strict]` scanning caps_json + snapshots + the quarantine ledger; `--strict` fails on `unsigned-authorizer > 0` OR `quarantined > 0`. The enforce-mode fail-loud runtime invariant (incl. the seed-writer guard); extend/clean the #1409 allowlist. Hermetic tests throughout.

**Phase 3 — drain on canary + REQUIRED sweeper.** In the isolated canary-data env (throwaway PG, restored dump — NEVER live stacks): the write-path self-heal drains as entities activate, and the **required durable sweeper** (§4.4 part 3) enumerates the four durable sources and re-enqueues every not-`signed_and_valid?` cap — the backstop for never-activated entities, enqueue failures, and partial two-home heals. This is what makes the drain reach 0 automatically (not an optional accelerator). Re-run the audit; iterate until `--strict` = 0 on BOTH buckets across all four sources. OPEN-quarantined caps are investigated + reported to the lead, never force-signed; resolving one closes its ledger row.

**Phase 4 — manual enforce flip (NOT in this spec).** Lead decision, after audit=0 on real canary data + a real-canary-data E2E confirming `require_signature: true` denies nothing legitimate. **Durable==live fence (required before the flip):** the audit scans DURABLE homes, but authorization reads the **live** `:identity` slice, and reconciled state can be live-only if a post-init snapshot write failed (`server.ex:432-463`) while the live slice is used for authz without re-verifying (`kind.ex:268-299`). So a durable audit=0 does not by itself prove no live entity still authorizes on an unsigned cap. The flip procedure must therefore **quiesce/restart the target** (so every live slice is re-hydrated from the now-signed durable homes) **OR** run a live-slice audit/fence proving `durable == live` for every active entity, immediately before setting `require_signature: true`. This spec stops before the flip but pins the fence as an acceptance precondition (§9).

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
| **workspace responsibility bundle caps** | ✓ | ✗ (idempotent) | `responsibility_assignments.ex:124-130` → `Identity.Grant.grant_cap` `{:genesis, caller}` | reconciler re-issues under workspace resolver `{:genesis, granted_by}` |
| **world-layout manage cap** (`workspace / World.Behavior.Layout / :manage`) | ✓ | ✗ | `layout_bootstrap.ex:8-28` → `Identity.Grant.grant_cap` `{:genesis, admin}` | reconciler re-issues under world resolver `{:genesis, granted_by}` |

**Two structural takeaways the reconciler is designed around:**
1. **Boot/activate is not an upgrade operation by itself** — inventory is identical before/after a plain restart.
2. Every class either (a) is born unsigned via a direct-construct bypass → Phase-0 fix + reconciler re-issue, or (b) signs on *fresh* materialize but has a legacy unsigned equivalent that the idempotent-skip protects → the **`signed_and_valid?`-keyed** reconciler (§3.3/§4.0) is what forces those to re-issue.

*(This table is a curated map; §4.6c's coverage test enumerates the FULL issuance surface so a class outside this table cannot silently escape — unknown class → quarantine + flagged. All file:line anchors are impl-constraints for the builder to confirm, not the design — the code wins if they have drifted. Verify against `main` + the owner branch before citing.)*

---

## 8. Retiring the EventLog backfill (decision #7)

`Ezagent.Identity.CapSigningBackfill` and its test are deleted **together with the mix task that invokes it** — `mix ezagent.cap.backfill` (`apps/ezagent_domain_identity/lib/mix/tasks/ezagent.cap.backfill.ex:19-38` calls `CapSigningBackfill.dry_run/apply`), which would fail to compile once the module is gone. Delete or rewrite the task in the same PR. Its two residual entries in the #1409 gate allowlist (`cap_signing_backfill.ex` → `user_candidates/0` in `@raw_user_caps_allowlist`; `identity_caps/1` in `@snapshot_identity_caps_allowlist`, `entity_caps_access_gate_test.exs:21-22,38-39`) are removed in the same PR — leaving them makes the gate reference a deleted module and drift. Any doc/runbook referencing `dry_run/1` as the gate is updated to point at the new signing audit (§4.7) — including the **handoff's operator step** (`docs/superpowers/handoffs/2026-07-14-cap-signing-notail-upgrade-codex-handoff.md:53` still tells operators to run `Ezagent.Identity.CapSigningBackfill.dry_run()`), which must be repointed to `mix ezagent.caps.signing_audit`. **Enumerate every reference — `grep -rn CapSigningBackfill apps/ docs/` — before deletion so main stays green** (current refs: the module, its test, the `ezagent.cap.backfill` mix task, and the handoff runbook step).

---

## 9. Acceptance criteria

1. **Audit = 0 on real canary data — BOTH buckets, FOUR sources, signed classifier.** `mix ezagent.caps.signing_audit --strict` exits 0 against the restored canary dump after the drain (Phase 3): `unsigned-authorizer == 0` AND `open-quarantined == 0` across all four durable sources (caps_json, snapshots, `recipe_cap_bindings`, quarantine ledger), classified by `signed_and_valid?/2` (§4.0), never `verify_for/2`. A test proves the audit reports non-zero on a dual-read fixture that `verify_for/2` would call "verified," guarding against the false-zero.
2. **Automatic, lifecycle-triggered / background-executed / sweeper-backstopped.** A born-unsigned structural cap and a legacy unsigned `caps_json` cap become signed **without a manual per-cap script** — activation enqueues, the background worker re-issues + rewrites both homes, and the **required durable sweeper** (§4.4 part 3) reaches never-activated entities + enqueue-failures + partial heals. Proven by a hermetic test that starts from an unsigned fixture, runs the sweeper, drains the worker, and asserts signed-in-both-homes. No `persist` is called synchronously from `activate/2` (no deadlock).
3. **Per-class recipe is correct.** A test proves creator-`Manage` re-issues under `{:genesis, creator}` (a `{:held_by, creator}` recipe would be denied by `authorize_action_axis`) and participation under `{:rule, :session_participation, granter}` — i.e. the resolver registry, not `granted_by`, chooses the authorization.
4. **ABA-safe compare-and-set, no resurrection/clobber.** A test enqueues a heal, revokes the cap before the worker runs, drains the worker, asserts NOT resurrected; a second test regrants a same-`identity_key` cap from a DIFFERENT issuer before the worker runs and asserts the stale heal does NOT overwrite it (byte-identical CAS, §4.5).
5. **Reads don't write.** A test asserts `EntityCaps.load`/`load_persisted` over an unsigned-cap fixture leaves the durable store byte-unchanged.
6. **Quarantine upholds #154, durably, with tombstoning.** A cap with unresolvable/`non-entity` authority is written to an OPEN `cap_quarantine` row + counted by the audit, never signed and never silently dropped; a resolved (healed or revoked) cap's row is **closed**, so `--strict` (OPEN-only) is not blocked forever — asserted by tests for both the open and close transitions.
7. **Genesis signs with no exemption.** `Cap.issue({:genesis, admin}, admin, admin_genesis_cap())` produces a verifying signed artifact (`authorize_grant` recognizes the raw wildcard as admin authority — `capability_registry.ex:476-484` — no circularity); the healed genesis cap verifies.
8. **Double gate holds, seed-writer hole closed, resolver coverage complete.** (a) A fixture adding a direct caps_json/snapshot writer fails the extended #1409 gate; (a′) a fresh user cannot be minted with an unsigned authorizer cap at enforce (seed writers born-signed or guarded); (b) under `require_signature: true`, persisting or verifying an unsigned authorizer cap fails loud; (c) the resolver-coverage gate (§4.6c) enumerates every cap-producing site and asserts each class has a resolver or is quarantine-classified — a new issuance site with no resolver fails the gate.
9. **Node-portable (distribution).** A test signs a cap under one derived keypair and verifies it via key re-derivation from the same master seed (proving no node-pinned material); delivery rides the durable outbox, not node-local ETS (§4.8).
10. **Dual-read stays safe / enforce NOT flipped / flip fence pinned.** No code in this work sets `require_signature: true`; new grants still sign, legacy caps still authorize during the drain. The Phase-4 flip precondition (out of this spec's build) is recorded: audit=0 on durable homes PLUS a **durable==live fence** (quiesce/restart or live-slice audit — §6 Phase 4) so no live entity authorizes on an unsigned cap the durable audit couldn't see.
11. **Hermetic + parallel-safe.** All new tests pass under `mix ci.local` with `MIX_TEST_PARTITION`; no machine-coupled counts; re-clonable fixture.

---

## 10. Risks

- **R1 — the per-class table is code-grounded, empirically confirmed on a small clean dump, but the "196" scale is unreproducible (§3.5).** The audit (§4.7) is the reconciliation: it reports the *actual* per-class unsigned inventory on whatever real data it is pointed at. Treat §7 as the map, the audit as the territory. If the audit surfaces a class not in §7, that is a finding to fold back, not a spec failure.
- **R2 — idempotent-skip classes.** If the reconciler's key is implemented as "authority-equivalent already held" (the trap in §3.3), legacy unsigned caps will be silently skipped and the tail never reaches 0. Mitigation: the reconciler MUST key on **`signed_and_valid?/2`** (§4.0), not authority-equivalence and not dual-read `verify_for/2`; a test drives a legacy-unsigned-equivalent through activate + sweeper and asserts it is re-issued (fails if the skip fires).
- **R3 — re-issue authority no longer resolvable.** A legacy cap whose issuer entity was deleted, or whose issuer no longer holds the authority, cannot be re-issued. This is expected → quarantine (§4.3); at enforce it is denied. The audit counts it, so the tail cannot reach 0 while such caps exist — forcing an explicit lead decision on each (never a blind-sign).
- **R4 — activate-path cost / coupling.** The activation hook does only the cheap **detect+enqueue** (a no-op fast-path when all held caps already `signed_and_valid?`); the expensive re-issue + durable write is the background worker, decoupled from activation. A transient store failure retries via the durable outbox without failing activation, and never blocks the entity becoming ready (that was the deadlock — §4.4).
- **R5 — snapshot vs `caps_json` split writes.** A user has caps in both homes; a partial heal (slice signed but caps_json not) regresses on next reload because caps_json is the re-read seed. Mitigation: the heal op rewrites **both** homes through the facade; the audit scans both; a test covers a user with unsigned caps in both homes reaching all-signed and staying signed across a re-activation.
- **R6 — silent resurrection / overwrite by a stale heal.** A background heal that runs after a revoke/re-issue could resurrect or clobber. Mitigation: the compare-and-set heal op (§4.5) is a no-op unless the exact unsigned equivalent is still present.
- **R7 — the `CapReissuePolicy` registry is a new coordination surface.** A cap class with no registered resolver quarantines (safe, but could mask a missing resolver). Mitigation: the §4.6c coverage gate enumerates the FULL issuance surface (not just §7) and fails on any class lacking a resolver or explicit quarantine-classification; the audit's by-class breakdown surfaces an unexpectedly-large quarantine bucket.
- **R8 — deleting the backfill red-flags the gate / breaks compile.** Removing the module without removing its allowlist entries AND the `ezagent.cap.backfill` mix task (§8) leaves the #1409 gate referencing a deleted function → main red, or a compile error. Mitigation: single PR, grep-enumerated.

---

## 11. Open questions (genuinely unresolved — the §1 decisions are LOCKED, not listed here)

1. **Session/creator/template legacy caps: re-issue in place, or safe-replace?** The differential notes these can be "显式 re-issue 或先安全替换" (re-issue OR safely replace). **Re-issue preserves the `identity_key` + scope, but NOT `granted_at`** — `Cap.issue` → `prepare_provenance/3` overwrites `granted_by`, `granted_at` (fresh `DateTime.utc_now()`), and `grantee_uri` (`cap.ex:149-166`); only the identity axes (kind/behavior/action/instance/workspace) survive. So "re-issue is provenance-preserving" is inaccurate — it preserves *identity*, and re-stamps *provenance* with the same issuer + a new timestamp. Safe-replace (revoke + grant fresh) additionally emits revoke/grant events and briefly de-authorizes. **Recommendation:** re-issue in place (identity-preserving) for the drain; use safe-replace only where the original authority is unresolvable-but-re-derivable from live session/membership state. Needs a lead/codex call per class in the impl-plan.
**Resolved in v3 (were OQ-2 / OQ-3 — no longer open):**
- *Cold-entity reach* — **RESOLVED: the durable sweeper is REQUIRED, not optional** (§4.4 part 3, decision A). Lifecycle-triggered heal cannot guarantee audit=0 (never-activated entities, enqueue failures, partial two-home heals), so the sweeper is the mandatory backstop that makes the drain truly automatic.
- *Durable-vs-live audit at flip* — **RESOLVED: a durable==live fence is a Phase-4 flip precondition** (§6 Phase 4, §9 crit-10). A durable audit=0 does not prove no live slice authorizes on an unsigned cap (post-init snapshot failure can leave reconciled state live-only, `server.ex:432-463`; live-slice authz doesn't re-verify, `kind.ex:268-299`), so the flip requires a quiesce/restart or a live-slice fence.
