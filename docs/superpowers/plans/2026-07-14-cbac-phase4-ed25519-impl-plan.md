# cbac Phase-4 ed25519 Signing — Implementation Plan

**Spec:** `docs/superpowers/specs/2026-07-14-cbac-phase4-ed25519-signing.md` (lead-locked 2026-07-14).
**Handoff:** `docs/superpowers/handoffs/2026-07-14-cbac-phase4-ed25519-codex-handoff.md`.
**Target branch:** `feat/cbac-phase4-ed25519` (codex owns; self-merges sub-steps onto this ONE branch continuously; coordinator validates the branch end-to-end then merges to `main`).
**Executor:** codex (bounded sub-steps, not whole-PR handoffs). **Coordinator:** Claude (validate + merge-to-main + report).

## Ground rules (from the spec + team memory)

- **No new dependency.** ed25519 + HKDF via OTP `:crypto` only.
- **Signing envelope = canonical-JSON via RFC 8785 JCS**, never `term_to_binary`, never `Jason.encode` output (§6). The `canon_*` value schema (§6.1) is normative and golden-vector-pinned; every field reduces to a string (only `v` is an int).
- **`trust_domain/1` is TOTAL and domain-separated** (§4): concrete → `"w:" <> Ezagent.URI.stable_key(ws)`; `:any` (incl genesis) → `"a:*"`; `nil`/other → **raise, don't sign**. The `"w:"`/`"a:"` prefixes make the ranges provably disjoint (no reliance on a constant being non-constructible). HKDF info is **length-prefixed**, not `|`-concatenated. The same `trust_domain` value feeds HKDF, `key_id`, and verify. One master seed in Phase-4.
- **`key_id` bounded grammar** `"v<digits>|b64url(trust_domain)"` (§6.2): anchored parse, ≤512, require decoded domain == `trust_domain(cap.workspace_uri)`; malformed/mismatch → deny (`false`), not raise.
- **Verify = boolean-or-raise** (§7): bad/absent sig or unknown/malformed `key_id` → `false` (deny); a *configured, trusted* `key_id` whose material is unavailable → **raise** (fail-loud-not-deny). Never rescue a crypto/seed error to `false`.
- **Fail-closed on missing seed at issue** (§4). No unsigned fallback.
- **Migration = dual-read → enforce**, backfill re-**authorize** from EventLog (not blind re-sign) (§10). The prod enforce-flip + live backfill are a **separate lead-owned ops task**, NOT in these PRs (OQ-6).
- Each sub-step: full static gate `mix ci.local` (NOT a subset) green + rebased on current `main` before self-merge to the target branch. Elixir files edited via editor, never `cat >>`.

## Phase breakdown (each = one codex sub-step / PR into the target branch)

### P1 — Struct + serialization fields (no behavior change)
- Add `signature: binary() | nil` and `key_id: String.t() | nil` to `%Ezagent.Capability{}` (capability.ex:36-46) + typespec.
- Extend `to_map/1` (capability.ex:436), `from_map/1` (capability.ex:450), and the `Jason.Encoder` impl (capability.ex:569-590) to round-trip both fields through `caps_json`.
- **Gate:** existing cap tests green; new golden **round-trip** vector (struct → map → JSON → struct is identity incl. the two new nil fields, and a populated-sig fixture). No signing logic yet.

### P2 — `Ezagent.Cap.Signing` module (crypto core, pure, unwired)
- New `apps/ezagent_core/lib/ezagent/cap/signing.ex`:
  - **Seed load:** versioned master seed from runtime config / secrets-home (`EZAGENT_SIGNING_SEED_V<N>`), fail-closed if the active version's seed is absent. Mirror `entity/token.ex` pepper-version discipline (token.ex:71-94).
  - **`trust_domain/1` — TOTAL, domain-separated (spec §4, codex-A):** concrete `%URI{}` → `"w:" <> Ezagent.URI.stable_key(ws)`; **every** `:any` (incl genesis) → `"a:*"`; `nil` / any other shape → **raise** (fail-closed, never sign under an undefined domain). The `"w:"`/`"a:"` prefixes guarantee the concrete and `:any` ranges are disjoint. This exact value feeds HKDF, `key_id`, and verify.
  - **Derivation:** `derive_keypair(entity_uri, trust_domain, version)` = HKDF-SHA256(ikm: seed_vN, info: **length-prefixed** `"ed25519\0" <> u32(size) <> td <> u32(size) <> entity_uri` — NOT raw `|` concat) → 32-byte seed → `:crypto.generate_key(:eddsa, :ed25519, seed)`.
  - **`canon_*` value schema (spec §6.1, normative):** the per-field table (atom/module→string, `:any`→`"any"`, `%URI{}`→`Ezagent.URI.stable_key/1` NOT raw `URI.to_string`, scope-tuple→ordered `[tag,val]` array, `granted_at`→UTC ms-truncated ISO8601, NFC on strings). Every **scalar leaf** reduces to a string; only `v` is an int and the `instance` scope array is the one structured value.
  - **`signing_payload/1`** → **RFC 8785 JCS** bytes over the §6 payload (sorted keys, no whitespace, UTF-8).
  - **`sign/2`**, **`verify/3`** via `:crypto.sign/verify(:eddsa, :none, msg, [key, :ed25519])`.
  - **`key_id` grammar (spec §6.2):** build `"v<version>|" <> b64url(trust_domain)`; parse anchored `^v(\d+)\|([A-Za-z0-9_-]+)$`, ≤512 len, decode domain, require `== trust_domain(cap.workspace_uri)` before key resolution; malformed/mismatch → `false` (deny), not raise.
- Config beside `authority_loader` (config/config.exs:148): `signing: [seed_provider: …, active_key_version: 1, require_signature: false]` — integer version; each cap's composite `key_id` is *built* from it + `trust_domain(cap.workspace_uri)`.
- **Gate:** unit tests for derive-determinism, sign/verify round-trip, `canon_*` per-type; **`trust_domain/1` totality + disjointness** (concrete→`"w:"<>stable_key`, `:any` incl genesis→`"a:*"`, `nil`→raise; assert no concrete domain equals `"a:*"`); **`key_id` grammar** (valid parse, `|`-in-domain safe via b64url, malformed→false, domain-mismatch→false); **golden signing vectors** (fixed cap → fixed JCS bytes → fixed hex signature); **INV-SIGN-2** raise on missing-seed / broken-crypto (injected).

### P3 — Wire signing into `issue/3` (sign-on-issue)
- `cap.ex:30-36`/`prepare_provenance/2` (cap.ex:67-76): as the **last** step after `granted_by`/`granted_at` are stamped, compute `signing_payload`, sign with the granter's derived private key, set `signature` + `key_id`. **Raise (fail-closed) if seed missing.**
- Cover all `granted_by` signer cases (§3): `:held_by`/`:admin`/`:rule` entities, and the genesis/admin self-granted cap → system entity's derived key. Declared/needed sentinels (`:plugin_declared`) are **not** signed (§3).
- **Gate:** every issued authorizer cap carries a valid sig verifiable by P2; genesis cap signs+verifies; sentinels untouched; e2e grant path (identity/grant.ex:232) green.

### P4 — Wire verify at the gate + caller audit (dual-read)
- Fill `verify/1` (cap.ex:43-45): resolve granter pubkey by **direct derivation** from `granted_by` + `key_id` (workspace-scoped), `:crypto.verify` over `signing_payload`. Boolean-or-raise per §7 with the attacker-controlled-`key_id` split (unknown/malformed → false; trusted-but-unavailable → raise).
- **Dual-read (stage 1):** `signature: nil` cap falls back to the legacy #154 predicate (`granted_by = entity://`); instrument a **telemetry counter** on the legacy-fallback branch.
- **Caller audit — the raise must propagate, never be rescued to `false`:** `verified_set/1` (cap.ex:56-62), `identity.ex:411`, `behavior/identity.ex:167,303,614` (`store_verified_cap/2`), `recipe_cap_binding.ex:75`.
- **Gate:** INV-SIGN-2 (verify + verified_set raise on infra failure, not filter-out); caller-raise-propagation tests; dual-read accepts legacy + signed.

### P5 — Migration scaffolding + enforce flag (mechanism only; prod flip deferred)
- `require_signature` flag (default `false` = dual-read). When `true`: unsigned cap → genuine deny (`false`), not raise.
- **Re-authorize backfill task** (mix task / ops fn, NOT auto-run): replay each cap's originating `:cap_granted` EventLog event (capability.ex:561-568) through `Cap.issue/3` (re-runs `authorize_grant`) then signs; a slice cap with **no** authoritative grant event is **quarantined/reported, not blessed**. Idempotent by identity-tuple.
- **INV-SIGN-1** (test-config `require_signature: true`): every authorizer cap in any slice verifies; sentinels exempt.
- **Gate:** INV-SIGN-1 green under enforce test-config; dual-read remains prod default; backfill task dry-run reports quarantine set. **Prod enforce-flip + live backfill are OUT of scope (lead-owned ops, OQ-6).**

### P6 — Arch-gate + invariant finalize
- `ezagent.arch.scan` anchor: no path in `verify/1` or its enumerated callers rescues a crypto/seed error to `false` (grep-anchored).
- Land INV-SIGN-1 / INV-SIGN-2 under `apps/ezagent_core/test/invariants/`.
- **Gate:** full `mix ci.local` green on the target branch; arch anchor active.

## Federation seams (verify these are present, do NOT build the endpoints)
- ✅ canonical-JSON envelope (P2) — a non-BEAM verifier can re-check.
- ✅ `workspace_uri` in derivation (P2) — per-org seed later = config swap.
- ✅ `key_id = {version, trust-domain}` (P2) — directory-lookup-able.
- ⛔ external pubkey-directory endpoint / trust-anchor, per-org independent seeds, entity-held keys → **Phase-5/federation, not this plan.**

## Sequencing / merge model
P1→P2→P3→P4→P5→P6 are dependency-ordered but land **continuously** onto `feat/cbac-phase4-ed25519` (no inter-phase wait; coordinator does not gate each phase on review — validates the target branch at the end, rebases + fixes, merges to `main`). P1+P2 are safe to land early (no behavior change / unwired). Behavior only changes at P3 (sign) and P4 (verify), both under `require_signature: false` dual-read so main stays green.

## Definition of Done (closed set)
1. `%Capability{}` carries `signature`/`key_id`, round-trips through `caps_json` (golden vector). 
2. `Ezagent.Cap.Signing` derives per-(entity,workspace,version) ed25519 keys, signs/verifies canonical-JSON, golden-vector-pinned.
3. `issue/3` signs every authorizer cap (incl. genesis via system key); sentinels unsigned; fail-closed on missing seed.
4. `verify/1` is boolean-or-raise per §7; every enumerated caller propagates the raise; dual-read fallback + telemetry counter present.
5. `require_signature` flag + re-authorize-from-EventLog backfill task (quarantines unauthorized) exist; prod flip deferred to lead ops.
6. INV-SIGN-1 (enforce test-config) + INV-SIGN-2 green; arch anchor active; full `mix ci.local` green on the target branch.
7. Three federation seams present; no federation endpoint built.
