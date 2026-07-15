# Cap-signing "no-tail" self-healing upgrade

**Status:** SPEC — lead-locked 2026-07-15 (the 10 decisions in §1 are fixed; do NOT re-litigate). Ready for codex adversarial-review → impl-plan → build.
**Date:** 2026-07-15
**Owner branch (codex builds here):** `feat/cap-signing-notail-upgrade` (codex owns; lands sub-steps; coordinator reviews + merges to `main`).
**Depends on:** Phase-4 ed25519 signing on main, dual-read (`docs/superpowers/specs/2026-07-14-cbac-phase4-ed25519-signing.md`, merge `e9b99443e`); Phase-3 cap self-store (`Cap.issue` → STORE → VERIFY, capbac.md §4.5); #154 no-unowned-caps; the #1409 write-side arch gate (`apps/ezagent_core/test/invariants/entity_caps_access_gate_test.exs`).
**Grounded in (MUST READ before building):**
- `docs/notes/2026-07-14-cap-signing-investigation-findings.md` — codex's **empirical** per-class differential (which cap classes are born unsigned; the wildcard-`ArgumentError` root cause). *Note: this note currently lives on `feat/cap-signing-notail-upgrade`, commit `c86069aa4`; it is the authoritative source for §7's table.*
- `docs/notes/2026-07-14-cap-signing-upgrade-real-data.md` — the "no big code fix; re-issue through `Cap.issue`" framing + the retired-EventLog-backfill finding.
- `docs/superpowers/handoffs/2026-07-14-cap-signing-notail-upgrade-codex-handoff.md`.

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
The empirical differential (§7) shows several classes DO sign on a *fresh* materialization (recipe binding, creator `Manage`, session participation, template owner, orchestrator scoped) — their grant path already runs `Cap.issue`. **But re-activating an existing entity does NOT re-sign them**, because the grant/materialize path first checks "is an equivalent authority already held?" (`already_authorized?` / idempotent skip, e.g. `identity.ex:852-853`, membership `already_authorized?`) — and a **legacy unsigned artifact satisfies that check under dual-read**, so the re-issue is skipped. Net: a plain restart is a no-op on the tail (the differential measured identical durable inventory before/after boot on the clean dump).

**Design consequence:** the self-heal cannot rely on re-materialization keying on *authority equivalence*. It must key on **signed-ness** ("this held cap lacks a valid signature") so it re-issues precisely the unsigned artifacts the idempotent-skip would otherwise leave behind.

### 3.4 The retired EventLog backfill
`Ezagent.Identity.CapSigningBackfill` (EventLog re-authorize) signed only 6/196 real caps (189 quarantined: malformed/missing grant events, unsupported structural shapes). It is **the wrong tool** and is retired here (decision #7 / §8). Its residual allowlist entries in the #1409 gate (`cap_signing_backfill.ex` `user_candidates/0`, `identity_caps/1`) and its test are deleted as part of this work, or the gate goes stale.

### 3.5 Counts are illustrative, never load-bearing
The older "196 caps" bucket is **not reproducible** from the specified clean dump: a fresh restore of `backups/canary/20260713T200002Z` yields **7 users / 50 kind_snapshots / 13 caps_json elements** (differential §"先纠正一个 grounding"). The 196/99 numbers depended on an already-mutated throwaway DB. **This spec and its tests therefore treat all counts as illustrative** and assert only structural properties (class → unsigned? → action) and the acceptance property (audit=0). This is the same discipline decision #8 mandates.

---

## 4. Design

### 4.1 The self-heal reconciler (write-path, signed-ness-keyed)
Introduce a **cap self-heal reconciler** in `ezagent_domain_identity` with a **pure planning core** and a thin write-path invocation shell.

**Pure core** — `plan(held_caps, receiver_uri) -> %{keep_signed: [...], reissue: [...], quarantine: [...]}`:
- `keep_signed` — caps already carrying a valid `signature`/`key_id`/`grantee_uri` for `receiver_uri`.
- `reissue` — unsigned authorizer caps whose `granted_by`/authority **resolves** (§4.2). Each is tagged with the `Cap.issue` authorization to use.
- `quarantine` — unsigned caps whose authority does NOT resolve (§4.3), plus any declared sentinel/needed markers that are excluded from the authorizer count.

The core is total, deterministic, and takes no DB/clock — it is unit-testable with in-memory cap lists (hermetic, decision #8).

**Write-path shell** — invoked at the enumerated write points below. For each `reissue` entry it calls `Cap.issue(<derived tag>, receiver_uri, cap)` (in-BEAM ed25519, cheap), then **stores the signed artifact through the existing durable write lane** (never a new direct writer — decision #6a). It never runs on a read path.

### 4.2 Resolve-authority → re-issue tag derivation
For an unsigned held cap, derive the `Cap.issue` authorization from its existing `granted_by` (which #154 already guarantees is `%URI{scheme: "entity"}` for the born-unsigned structural/genesis classes):

| held `granted_by` resolves to… | tag | rationale |
|---|---|---|
| the canonical admin/genesis root (`Entity.User.admin_uri/0`) AND the cap is the all-wildcard genesis | `{:genesis, admin}` | decision #5; proven signable (§7). |
| the admin/genesis root, non-wildcard structural self-cap | `{:admin, admin}` | admin holds the genesis wildcard → `authorize_grant` passes → signs. |
| an entity that **holds** the authority being granted (self-grant / manager-delegation / session-owner grant) | `{:held_by, granted_by}` | the issuer genuinely holds it (capbac.md §4 decision tree). |
| a rule-configured concrete-scoped grant | `{:rule, name, configurer}` | only if the class is rule-eligible (`rule_cap_bounded?`, capbac.md §5). |

The tag choice is **the same decision tree the grant chokepoint already uses** (capbac.md §4) — the self-heal reuses `Ezagent.Identity.Grant`/`Cap.issue`, never a private signing shortcut. **Filling `signature`/`key_id` directly on a raw cap to "make it look signed" is forbidden** — it would bypass `authorize_grant` and is exactly the anti-pattern the differential §"建议顺序 1" calls out.

### 4.3 Quarantine rule (upholds #154)
A held unsigned cap is quarantined (dropped from the durable set on the write path + reported) when **any** of:
- `granted_by` is not `%URI{scheme: "entity"}` (an unowned/`system://`-granted legacy cap);
- the resolved issuer entity does not exist / is not loadable;
- `Cap.issue` under the derived tag returns `{:error, _}` (the issuer no longer holds the authority — `authorize_grant` denies).

Quarantine is **report-and-hold**, never blind-sign. Under dual-read a quarantined cap continues to be accepted as legacy by `verify/1` (no behaviour change tonight); the audit (§4.6) counts it as an unsigned-authorizer blocker so the tail cannot silently reach 0 by hiding un-resolvable caps. At enforce, `verify/1` returns false for it → it is denied and surfaces (no silent drop — §4.5).

### 4.4 Where the self-heal runs (write-path lifecycle points; reads stay pure)
1. **Entity activation** (`Behavior.Identity.activate/2`): after the existing merge, run the reconciler over the merged held set. Fold `reissue` results into the persistent `state.caps`; the existing `{:ok, %{}, reconciled}` return already triggers a **snapshot rewrite** (a write path) so signed structural/genesis caps become durable. Same-version idempotency (recipe binding) is bypassed because the reconciler keys on signed-ness, not binding version.
2. **User `caps_json` rewrite**: when a user Kind activates (or on any facade write), if `caps_json` holds unsigned authorizer caps that resolve, re-issue them and rewrite `caps_json` **through `EntityCaps.persist`** (now accepted — they are signed) → the `UserStore.update_locked/2` transactional write. This is a write path and stays inside the #1409 allowlist.
3. **Materialization** (session/creator/template/orchestrator): these already `Cap.issue` on *fresh* materialize (§7). The self-heal adds nothing new to the fresh path; existing unsigned equivalents are healed via path (1)/(2) when the holding entity next activates, OR via the operator's re-materialize step (§6 phasing) which refreshes the binding version and forces re-issue.

**Reads stay pure (decision #3):** `EntityCaps.load` / `load_persisted` are untouched — they filter via `verified_set` and never write. If a read is the first thing to observe an unsigned cap, the correction is deferred to the next write-path activation, or enqueued async (§4.7).

### 4.7 Async carrier — deliberate sync-vs-async choice
The re-issue itself (ed25519 sign) is cheap and can run inline on the write path. The concern is the **durable rewrite** surviving a crash mid-drain, and not coupling drain latency to every cold-start activate.

- **Recommended:** re-issue **inline** in the write-path reconciler (cheap, deterministic), and STORE the signed artifact through the **existing durable write lane** — `EntityCaps.persist` for `caps_json`, and the already-durable `:vm_internal absorb_cap` → `Cap.DeliveryOutbox` retry lane for the live `:identity` slice. The outbox **already supports `:absorb_cap`** envelopes (`delivery_outbox.ex` moduledoc; `Envelope.eligible?`), so a healed artifact rides the existing absorb path with **no new envelope type**. This is the least-new-surface option and reuses a proven durable-retry boundary.
- **Rejected:** a bespoke "re-sign" outbox envelope type. `DeliveryOutbox.Envelope.eligible?` is scoped to `:absorb_cap`/`:revoke_cap`; a new type is new surface for no gain over routing the healed artifact as an `:absorb_cap` store.
- **Constraint (hard):** whichever lane, it is invoked from a **write path or a background sweeper**, never from `load`. The impl-plan picks inline-vs-sweeper per class; the invariant is reads-don't-write.

### 4.5 Double gate against regression (decision #6)
- **(a) Static write-side gate — extend #1409.** `entity_caps_access_gate_test.exs` already forbids any executable consumer reading/writing `users.caps_json` or reaching into snapshot `:identity` caps outside the `EntityCaps` facade + a function-level allowlist. The self-heal's durable writes MUST route through the facade (so they need **no** new allowlist entry); the retired backfill's entries are **removed** from the allowlist (§8). Adding a new direct caps_json/snapshot writer trips this gate — that is the intended guard.
- **(b) NEW runtime invariant — enforce-mode fail-loud.** Add an invariant/architecture test asserting that, **when `require_signature: true`**, an unsigned authorizer cap can neither be persisted nor pass verification silently:
  - `persist`/`grant` already fail closed via `validate_issued_caps` (any env) — pin this with a test that persisting an unsigned authorizer cap returns `{:error, :invalid_cap_artifact}`.
  - `Cap.verify/1` under enforce returns `false` for the unsigned `granted_by: entity` clause (`cap.ex:51-63`) — pin that this denies rather than legacy-accepts.
  - Complements codex's existing `cap_signing_fail_loud_test.exs` (verify callers never rescue an infra failure to a silent `false`). Together: unsigned → denied + surfaced; infra failure → raised, never masked.

### 4.6 The audit task (go/no-go + progress meter)
A `mix` task (distinct name — the existing `mix ezagent.caps.audit` is the unrelated `data_owner/1` audit; use e.g. `mix ezagent.caps.signing_audit`) that:
- scans **both** durable homes directly: every `users.caps_json` row and every `kind_snapshots` latest identity slice (reusing codex's `test/support/caps_json_scanner.ex` shape where possible);
- classifies each cap: **signed** / **unsigned-authorizer** / **quarantined (unresolvable)** / **sentinel-excluded** (declared/needed markers that are not authorizers);
- reports **unsigned authorizer count by class** (§7 rows) + quarantine reasons;
- `--strict` exits non-zero when unsigned-authorizer > 0 (the acceptance gate);
- is **read-only** (never mutates), so it is safe against any restored DB and does not itself heal.

It is **not** the EventLog backfill and shares no code with it. Its "by class" breakdown doubles as the drain progress meter.

### 4.8 Hermetic testing (decision #8)
- The audit and reconciler tests run under `--no-start` with a test helper that starts **only** core (Repo/registry) and explicitly starts each downstream app + lifecycle path inside the same SQL-Sandbox transaction (the method the differential validated: `1 test, 0 failures` reproducibly).
- **No machine-coupled counts.** Tests assert structural properties: "a fresh raw structural cap is unsigned"; "after self-heal on the write path it is signed and verifies"; "an unresolvable-authority cap is quarantined, not signed"; "the audit reports 0 after a full drain of the fixture." Never `scanned == 15` / `before == after`.
- **Re-clonable fixture.** Where a real-data check is needed, clone a partition DB from a read-only restored source (`ezagent_raw…` → `ezagent_pg_compat_test<partition>`), migrated, per `MIX_TEST_PARTITION` — never mutate a shared default test DB.
- Runs green under `mix ci.local` with `MIX_TEST_PARTITION` (parallel-safe ecto).

---

## 5. The 10 decisions → where they live in the design

| # | Decision | Realized in |
|---|---|---|
| 1 | 0 unsigned tail → enforce-flippable | Goal §2; audit §4.6 gates it |
| 2 | Automatic self-heal on write-path lifecycle | §4.1, §4.4 |
| 3 | No read-path mutation | §4.4, §4.7 (constraint) |
| 4 | Quarantine, never blind-sign | §4.3 |
| 5 | Genesis self-signs, no exemption | §4.2 row 1; §7 genesis row |
| 6 | Double gate | §4.5 (a static / b runtime) |
| 7 | Independent audit, not EventLog backfill | §4.6; §8 retires backfill |
| 8 | Hermetic tests | §4.8 |
| 9 | Manual flip, canary E2E first | §6 phase 4; §9 acceptance |
| 10 | Readers already receiver-aware | out of scope (§2) |

---

## 6. Phasing

Each phase is a codex sub-step: full `mix ci.local` green + rebased on main before self-merge; Elixir via editor; `MIX_TEST_PARTITION` for parallel tests.

**Phase 0 — fix future issue sites, still dual-read.** Route the born-unsigned **structural** classes (user/agent/template self `Identity.list_caps`; agent self `Sandbox.update_config` + `ConfigEvolve.reconcile_cascade`) through a provable-authority `Cap.issue` at construction, so *newly created* entities are born signed. No enforce change. (Differential §"建议顺序 1".)

**Phase 1 — the self-heal reconciler + write-path wiring.** Pure `plan/2` core; wire into `Behavior.Identity.activate/2` (snapshot rewrite) and the user `caps_json` write (via `EntityCaps.persist`); genesis re-issue via `{:genesis, admin}`. Reads stay pure; async store via existing `absorb_cap`/outbox lane. Retire the EventLog backfill (§8).

**Phase 2 — the signing audit task + both gates.** `mix ezagent.caps.signing_audit [--strict]`; the new enforce-mode fail-loud runtime invariant; extend/clean the #1409 allowlist. Hermetic tests throughout.

**Phase 3 — drain on canary.** In the isolated canary-data env (throwaway PG, restored dump — NEVER live stacks): re-activate/re-materialize entities (self-healing classes re-sign), run the operator re-materialize for classes needing a binding-version refresh, and let the write-path self-heal drain `caps_json` + structural snapshots. Re-run the audit; iterate until `--strict` = 0. Quarantined caps are investigated + reported to the lead, never force-signed.

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
| **agent creator `Manage`** | ✓ | ✗ (idempotent skip) | grant adapter `grant.ex:218-233` → `Cap.issue`; entry `workspace.ex:841-878` | fresh none; legacy unsigned triggers `already_authorized?` skip (`identity.ex:852-853`) → explicit re-issue via reconciler |
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

`Ezagent.Identity.CapSigningBackfill` and its test are deleted. Its two residual entries in the #1409 gate allowlist (`cap_signing_backfill.ex` → `user_candidates/0` in `@raw_user_caps_allowlist`; `identity_caps/1` in `@snapshot_identity_caps_allowlist`, `entity_caps_access_gate_test.exs:21-22,38-39`) are removed in the same PR — leaving them makes the gate reference a deleted module and drift. Any doc/runbook referencing `dry_run/1` as the gate is updated to point at the new signing audit (§4.6). Enumerate every reference (grep `CapSigningBackfill`) before deletion so main stays green.

---

## 9. Acceptance criteria

1. **Audit = 0 on real canary data.** `mix ezagent.caps.signing_audit --strict` exits 0 against the restored canary dump after the drain (Phase 3): zero unsigned authorizer caps across both durable homes; any quarantined caps are enumerated + reported, not hidden.
2. **Automatic, write-path.** A born-unsigned structural cap and a legacy unsigned `caps_json` cap become signed **without a manual per-cap script** — solely by the entity passing through its write-path lifecycle (activation / facade write / re-materialize). Proven by a hermetic test that starts from an unsigned fixture and asserts signed-after-write-path.
3. **Reads don't write.** A test asserts `EntityCaps.load`/`load_persisted` over an unsigned-cap fixture leaves the durable store byte-unchanged.
4. **Quarantine upholds #154.** A cap with unresolvable/`non-entity` authority is quarantined + reported, never signed — asserted by a test.
5. **Genesis signs with no exemption.** `Cap.issue({:genesis, admin}, admin, admin_genesis_cap())` produces a verifying signed artifact; the healed genesis cap verifies (§7 row 1).
6. **Double gate holds.** (a) A fixture adding a direct caps_json/snapshot writer fails the extended #1409 gate; (b) under `require_signature: true`, persisting or verifying an unsigned authorizer cap fails loud (returns error / denies), asserted by the new runtime invariant.
7. **Dual-read stays safe / enforce NOT flipped.** No code in this work sets `require_signature: true`; new grants still sign, legacy caps still authorize during the drain.
8. **Hermetic + parallel-safe.** All new tests pass under `mix ci.local` with `MIX_TEST_PARTITION`; no machine-coupled counts; re-clonable fixture.

---

## 10. Risks

- **R1 — the per-class table is code-grounded, empirically confirmed on a small clean dump, but the "196" scale is unreproducible (§3.5).** The audit (§4.6) is the reconciliation: it reports the *actual* per-class unsigned inventory on whatever real data it is pointed at. Treat §7 as the map, the audit as the territory. If the audit surfaces a class not in §7, that is a finding to fold back, not a spec failure.
- **R2 — idempotent-skip classes.** If the reconciler's signed-ness key is implemented as "authority-equivalent already held" (the trap in §3.3), legacy unsigned caps will be silently skipped and the tail never reaches 0. Mitigation: the reconciler MUST key on signature presence/validity; a test drives a legacy-unsigned-equivalent through activate and asserts it is re-issued (fails if the skip fires).
- **R3 — re-issue authority no longer resolvable.** A legacy cap whose issuer entity was deleted, or whose issuer no longer holds the authority, cannot be re-issued. This is expected → quarantine (§4.3); at enforce it is denied. The audit counts it, so the tail cannot reach 0 while such caps exist — forcing an explicit lead decision on each (never a blind-sign).
- **R4 — activate-path cost / coupling.** Running the reconciler on every cold-start activate adds work and couples re-sign failure to activation. Mitigation: the reconciler is a no-op fast-path when all held caps are already signed (the steady state); the durable store lane is the existing durable-retry outbox, so a transient store failure retries without failing activation.
- **R5 — snapshot vs `caps_json` split writes.** A user has caps in both homes; a partial heal (slice signed but caps_json not, or vice versa) could regress on next reload. Mitigation: the reconciler heals through the facade which owns both homes; the audit scans both; a test covers a user with unsigned caps in both homes reaching all-signed.
- **R6 — deleting the backfill red-flags the gate.** Removing the module without removing its allowlist entries (§8) leaves the #1409 gate referencing a deleted function → main red. Mitigation: single PR, grep-enumerated.

---

## 11. Open questions (genuinely unresolved — the §1 decisions are LOCKED, not listed here)

1. **Session/creator/template legacy caps: re-issue in place, or safe-replace?** The differential notes these can be "显式 re-issue 或先安全替换" (re-issue OR safely replace). Re-issue preserves the exact identity_key + provenance; safe-replace (revoke legacy + grant fresh) is simpler but changes `granted_at` and briefly de-authorizes. **Recommendation:** re-issue in place (identity-preserving) for the drain; use safe-replace only where the original authority is unresolvable-but-re-derivable from live session/membership state. Needs a lead/codex call per class in the impl-plan.
2. **Async carrier scope.** §4.7 recommends reusing the `:absorb_cap` outbox lane for the live-slice store and `EntityCaps.persist` for `caps_json`. Is a background **sweeper** (drain-on-boot over pending-unsigned) also wanted for entities that rarely activate, or is "heal on next natural activation + the operator re-materialize step" sufficient for the canary drain? The former reaches 0 faster with no manual step; the latter is less new surface. Recommendation: rely on natural activation + operator re-materialize for Phase 3; add a sweeper only if the audit plateaus above 0 on cold entities.
3. **Audit source-of-truth for `kind_snapshots`.** The audit must read the *latest* snapshot per entity; confirm whether reading only `kind_snapshots` latest rows (vs also live slices) can miss a live-but-un-snapshotted unsigned cap. Recommendation: audit reads durable homes only (the enforce target is durable); a live-only unsigned cap is transient and heals on next snapshot — but confirm no class holds authorizer caps live-only across restarts.
