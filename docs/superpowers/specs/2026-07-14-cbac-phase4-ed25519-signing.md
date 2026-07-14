# cbac Phase-4: ed25519 Cryptographic Signing of Capabilities

**Status:** SPEC — lead-locked 2026-07-14 (OQs resolved, §14). Ready for impl-plan + codex handoff.
**Date:** 2026-07-14
**Depends on:** Phase-3 cap self-store (`docs/plans/2026-07-11-phase3-cap-self-store-impl-plan.md`), #154 genesis collapse, #1361 HMAC-PAT key-management precedent.
**Decision fixed by lead (do NOT re-litigate):** use **ed25519 (asymmetric)** via OTP `:crypto`, chosen for cross-org / third-party verifiability. No new crypto library.

## Lead decisions — locked 2026-07-14 (do NOT re-litigate)

Guiding principle (lead, verbatim): *"目前仅添加基本的机制，不做复杂的安全措施是可以的。
但在成本可控的情况下，应该考虑未来改造（主要是 ezagent 联邦化改造）的便利性。"*
→ **Ship the basic mechanism now; bake in only the low-cost choices that keep future
ezagent federation (联邦化) cheap. Defer everything expensive to Phase-5/federation.**

**Ship now (basic mechanism):** ed25519, signer = granter, single platform master
seed (HKDF-derived keys), BEAM-internal verify, issuer-accountability guarantee,
dual-read → enforce migration. Platform-custody accepted.

**3 cheap federation bake-ins (low cost now, avoid a later migration):**

1. **Sign over canonical-JSON, NOT `term_to_binary`** (§6). `term_to_binary` is
   BEAM-only; canonical-JSON is language-agnostic → a future federated/non-BEAM
   verifier can verify **without a signing-format migration**. Cost ≈ codex HIGH-7's
   already-required `canon/1` + golden vectors. **This is the signing envelope, full
   stop** — no dual encoding path.
2. **`workspace_uri` in the HKDF derivation context** (§4):
   `HKDF(master_seed_vN, workspace_uri ‖ entity_uri)`. Cost ≈ one extra HKDF input.
   The key derivation then already carries the **trust-domain dimension**, so
   federating = give each org/workspace its **own independent seed** by swapping the
   master per trust-domain — no re-key, no derivation-structure change. The natural
   federation unit is "one seed per trust-domain," and this makes it a config swap.
3. **`key_id` is directory-lookup-able** (§5): encode `{version, trust-domain}` so a
   future authenticated public-key directory resolves an entry **without changing the
   cap wire format**.

**Deferred to Phase-5 / federation (NOT now):** the external public-key directory
endpoint + trust-anchor, per-org **independent** seeds (this phase keeps one master,
derivation-labelled by workspace), entity-held private keys (non-repudiation against
the platform). The data model is *shaped for* all three; none is built now.

**OQ resolutions:** OQ-1 → BEAM-internal verify now **+ canonical-JSON envelope**
(the cheap federation seam); external endpoint deferred. OQ-2 → platform-can-forge
**accepted**. OQ-5 → one-seed-forges-all **accepted now** + `workspace_uri` in HKDF
context as the cheap segmentation seam. OQ-7 → **issuer-accountability sufficient**;
signed delegation chain deferred. OQ-3/4/6 resolved in §14.

---

## 1. Problem

Today a capability's only provenance proof is a *structural* one: `Ezagent.Cap.verify/1`
(`apps/ezagent_core/lib/ezagent/cap.ex:43-45`) returns `true` iff
`granted_by` is a `%URI{scheme: "entity"}`. That is a #154 predicate — "was this
authorized by a real entity, not a `system://` principal" — but it proves nothing
cryptographically. Anyone who can construct a `%Capability{}` with an
`entity://` `granted_by` passes `verify/1`. Provenance is *asserted*, not *proven*.

The Phase-4 goal is to make the authorization-bearing fields of a capability
**cryptographically signed by the granter**, so that:

- a holder cannot forge or tamper an authorizer cap in its own slice;
- a **non-issuer** (potentially in another org) can *verify* the grant with the
  granter's **public** key — the property HMAC/symmetric secrets cannot give
  (a symmetric verifier can also forge).

The seam is already carved. `cap.ex:5-9` moduledoc: *"Phase 4 can replace these
bodies with signing and signature verification without changing callers."*
`issue/3` (cap.ex:30-36) is the single sign site; `verify/1` (cap.ex:43-45) is
the single verify site; `verified_set/1` (cap.ex:56-62) is the collection
adapter. This spec fills exactly those three bodies plus a key-management layer.

**In scope:** signing on issue, verifying at the gate, key management, migration.
**Out of scope (explicit):** reputation **scoring** on signed receipts — see §12.

---

## 2. Decided approach (summary)

| Axis | Decision |
|---|---|
| Algorithm | ed25519 via `:crypto.sign(:eddsa, :none, msg, [priv, :ed25519])` / `:crypto.verify(:eddsa, :none, msg, sig, [pub, :ed25519])`. No new dep. |
| Signer | The **granter** (= the target's `data_owner`, #154). The signature IS the proof "this data_owner authorized this cap." |
| Key custody (Phase-4) | **Platform-custody, derived keys**: one versioned master seed in secrets-home; each entity's ed25519 keypair is HKDF-derived from `(master_seed_vN, workspace_uri, entity_uri)` — the `workspace_uri` carries the **trust-domain dimension** (federation bake-in #2). Fail-closed on missing seed. Future external verification via an **authenticated public-key directory** (publishing a *public* key exposes no secret) — seam only, deferred. |
| What's signed | **Canonical-JSON** over the authorization-bearing fields + `key_id` + `granted_at` (bake-in #1 — language-agnostic, federation-verifiable). NOT `Jason.encode` output; NOT `term_to_binary`. |
| Verify contract | `verify/1` returns `false` for a genuine bad/absent signature (a real **deny**); **raises** on an infra failure (missing seed, crypto error, pubkey-resolution failure) — **fail-loud-not-deny**. |
| Rotation | `key_id = "v<N>|b64url(trust_domain)"` (§6.2) carried on the cap; verifier selects the master version `N`; dual-version window on rotate. |
| Revocation | Lean on existing slice-based cap-lifecycle revoke (`Capability.revoke/2`, capability.ex:216). Signatures don't expire; a signed cap is only *in force* while present in the authenticated holder's slice. |
| Migration | Dual-read (accept signed OR legacy #154-provenance) → backfill re-sign → flip `require_signature: true`. Mirrors #1361 token migration. |
| Scoring | **Separate follow-on.** Not in this spec. |

---

## 3. Axis 1 — Who is the signer?  → the granter (data_owner)

**Recommendation: signer = the granter** — the entity resolved as the **issuer**
(`issuer/1`, cap.ex:78-81) and stamped as `granted_by` in `prepare_provenance/2`
(cap.ex:67-76). The signature is the cryptographic upgrade of that same claim:
*"the entity named in `granted_by` authorized this exact cap."*

**Precise semantics (codex HIGH — do not overstate as "data_owner consent"):**
`granted_by` is the **issuer that the authorization policy admitted**, which is the
target's `data_owner` **only in the `:held_by` self-grant case**. For `:admin` and
`:rule` issuance the issuer is a *delegated authority*, not the target's owner —
the live #154 predicate only rejects `system://` provenance (capability.ex:319),
it does not prove issuer == owner. So what the signature proves is: *"the named
issuer signed this cap after `authorize_grant` admitted it"* — **issuer
accountability**, not necessarily *personal owner consent*. If a phase needs
provable **owner consent** on admin/rule-issued caps, that requires an owner
signature or a **signed delegation chain** (owner → admin → cap) — flagged as
OQ-7 (§14), out of scope for Phase-4's issuer-accountability guarantee.

**Alternatives considered:**

- *Single workspace/org key* — one keypair per workspace signs all grants in it.
  Rejected: loses per-granter accountability (can't tell *which* member granted),
  and #154 consent is per-`data_owner`, not per-workspace. A workspace key can't
  express "alice, the data_owner of this target, consented."
- *Single platform key* — platform signs everything. Rejected for the *meaning*:
  a cross-org verifier would be trusting "the platform says so," not "the
  data_owner authorized." It collapses the ed25519 win (per-granter public
  verifiability) back to a single trust root.

**Signer resolution must cover the non-entity `granted_by` cases** (this is a real
gap the spec closes, not an afterthought):

- `{:held_by | :admin | :rule | :genesis}` authorizations resolve `granted_by` via
  `issuer/1` (cap.ex:78-81). For `:held_by`/`:admin` the granter is a real
  `entity://` URI → **sign with that entity's derived key.**
- The **genesis/admin** self-granted cap (`admin_genesis_cap/0`, capability.ex:244)
  has `granted_by = entity://user/system/admin` — a real entity → signs with the
  **system entity's derived key** (the trust root; its public key is the platform's
  published anchor).
- `{:rule, name, configurer}` — the configurer is an entity → sign with its key.
- **Non-authorizer caps are NOT signed and MUST NOT be required to be:**
  `required_caps/0` declarations carry `granted_by: :plugin_declared` /
  `granted_at: :compile_time` (capability.ex:66-67, 132-134); `matches?/2` never
  reads a *needed* cap's `granted_by` (capability.ex:302-304 note). These are the
  `needed` shape at the gate, never an *authorizer* in a slice. The signing rule
  applies to caps that live in an entity's `:caps` slice as authorizers, not to
  declared/needed sentinels.

---

## 4. Axis 2 — Key storage + provenance (mirrors #1361, asymmetric)

The key-management **pattern** we mirror (per the lead, #1361 HMAC-PAT direction):
**one versioned secret, sourced from runtime config / secrets-home, fail-closed on
absence.** Precedent verified on main: `entity/token.ex` IS a versioned-pepper
HMAC store — `token_digest = HMAC-SHA256(pepper_vN, raw)`, `pepper(version)` read
from runtime config, **fail-closed on missing pepper, no bcrypt fallback**
(token.ex:3,14,24,77; `digest_version` column + migration `20260712010000`). So
"mirror #1361" is a **direct, literal precedent** for the versioned-secret +
dual-version-selector + fail-closed discipline. This spec **extends it to
asymmetric**: the versioned *pepper* becomes a versioned *master seed*, and the
symmetric HMAC becomes HKDF-derived ed25519 keypairs (§4 below). *(An earlier
draft mis-stated token.ex as bcrypt+random; corrected here and in §16.)*

**Recommendation: derived keys from one versioned master seed.**

```
master_seed_vN         # 32+ bytes, from EZAGENT_SIGNING_SEED_V<N> (secrets-home / runtime.exs)
# federation bake-in #2: the TRUST-DOMAIN (from workspace_uri) is IN the derivation context.
# HKDF info is LENGTH-PREFIXED, not raw-delimiter concatenated (codex D — no "|" ambiguity):
td      = trust_domain(cap.workspace_uri)                 # total function, defined below
info    = "ed25519\0" <> u32(byte_size(td)) <> td
                     <> u32(byte_size(entity_uri)) <> entity_uri
priv(entity, td, vN) = HKDF-SHA256(ikm: master_seed_vN, info: info)  → 32-byte ed25519 seed
pub(entity, td, vN)  = ed25519 public key from that seed
```

**`trust_domain/1` is TOTAL (codex A — the derivation input must never be undefined).**
`workspace_uri: :any` is a *legitimate* authorizer shape, not a sentinel — the genesis
cap carries it (capability.ex:244-253) and ordinary grants may request cross-workspace
`:any` (identity.ex:240-246); `nil` is also constructible because struct inputs bypass
normalization (normalize.ex:68-70) and some authorization paths don't validate the
workspace before `:ok` (capability_registry.ex:417-444). So:

```
# DOMAIN-SEPARATED by a leading discriminator so the concrete and :any ranges are
# PROVABLY DISJOINT — no reliance on "platform-root" being non-constructible (codex A-b):
trust_domain(%URI{} = ws)  = "w:" <> Ezagent.URI.stable_key(ws)  # concrete workspace domain (always starts "w:")
trust_domain(:any)         = "a:*"                               # the ONE any/platform-root domain (genesis + cross-workspace)
trust_domain(nil)          -> RAISE (fail-closed, do not sign)    # never derive under an undefined domain
trust_domain(_other)       -> RAISE
```

The `"w:"` / `"a:"` prefixes make the two ranges **disjoint by construction**: a concrete
domain is always `"w:" <> …`, so it can never equal the any-domain `"a:*"` — regardless of
what `Ezagent.URI.stable_key/1` returns for any (even maliciously hand-built, normalization-
bypassing) `%URI{}`. This is the load-bearing guarantee, and it holds structurally, not by
assuming `"platform-root"` is an unconstructable workspace name (it is *not* — `workspace/1`
would accept it, uri.ex:461/492 — which is exactly why the earlier bare-`"platform-root"`
form was unsound). `Ezagent.URI.stable_key/1` (uri.ex:475 = `canonical!/1 |> URI.to_string`)
is the canonical string; there is no `canonical_string/1`. The **exact same `trust_domain(...)`
value** is used in HKDF (above), in `key_id` (§5/§6), and at verify (§7) — verify recomputes
`trust_domain(cap.workspace_uri)` and requires it to equal the `key_id`-encoded domain before
resolving a key.

`:crypto.generate_key(:eddsa, :ed25519, <derived-32-byte-seed>)` yields the
`{pub, priv}` pair deterministically from the derived seed; HKDF via
`:crypto.mac(:hmac, :sha256, ...)` extract/expand (no new dep). `u32(n)` = 4-byte
big-endian length prefix.

**Why `workspace_uri` is in the derivation context (federation bake-in #2, lead
2026-07-14):** cost is one extra `info` component — near-zero now. The payoff is
that the derivation **already carries the trust-domain (workspace) dimension**. Phase-4
still uses **one** master seed for all workspaces (blast radius = whole platform,
accepted per OQ-5), but when federation lands, giving each org/workspace its **own
independent seed** is a *config swap* (`master_seed[ws]` instead of a single master)
with **no change to the derivation structure, the cap wire format, or the verify
path** — no re-key migration. `workspace_uri` is already a signed field (§6), and
every authorizer cap is workspace-scoped (`workspace_uri` on the struct), so the
signer always knows the trust-domain. The genesis/system entity (its cap carries
`workspace_uri: :any`) derives under the `:any` trust-domain `"a:*"` (§4).

**Why derived, not a keystore table:** the derivation vs. stored-table choice is
**purely an ops-surface choice, not a trust-model choice** — in *both*, the
platform holds the private material (it signs on entities' behalf; no entity
generates or holds its own key in Phase-4). Derived gives us **one** versioned
secret to guard/rotate — the most faithful asymmetric analogue of the single
versioned pepper — and public keys are *derivable* (no directory sync problem;
see §5). A keystore table would add a KEK (also platform-held → same blast
radius) and a sync surface for no trust gain.

**Honest security property (state plainly, do not oversell):**

- ✅ **Peer tenants cannot forge each other's authorizations.** A verifier holds
  only public keys; ed25519 gives no forge capability from a public key. This is
  the concrete win over the #1361 HMAC model (where a verifier holding the
  symmetric secret could forge).
- ⚠️ **The hosting platform CAN forge**, because it holds `master_seed`. Phase-4
  delivers *platform-attested, peer-non-forgeable* authorization — **not**
  non-repudiation *against the platform.* Full non-repudiation against the
  platform requires **entity-held keys** (entity generates its own keypair,
  platform never sees the private half) → **Phase-5 follow-on**, not here. The
  derived model is forward-compatible: an entity that later registers its own
  public key overrides the derived one at the same `key_id` seam.

**Fail-closed:** if `master_seed_vN` is absent at `issue/3`, signing **raises**
(no unsigned fallback) — mirrors #1361 fail-closed-on-missing-pepper and
`feedback_let_it_crash_no_workarounds`.

---

## 5. Axis 3 — Public-key distribution / directory (SEAM ONLY — deferred to federation)

**Scope (lead 2026-07-14):** the actual external public-key directory endpoint +
trust-anchor is **deferred to Phase-5/federation** — it is the expensive part. What
Phase-4 ships is the **cheap seam** so federation can add the endpoint without
changing the cap wire format: (a) canonical-JSON signed bytes (§6) any verifier can
re-check, and (b) a **directory-lookup-able `key_id`** — `key_id` encodes
`{version, trust-domain}` (bake-in #3) so a future directory entry keyed by
`(entity_uri, workspace_uri, version)` resolves deterministically. Phase-4 verify
resolves the public key by **direct derivation** (it can reach the seed); no
directory is built or required now. §5's directory design below is the **forward
design**, recorded so the seam is intentional, not the Phase-4 deliverable.

Because keys are **derived**, a verifier does not need a per-entity registry
sync. It needs exactly two things:

1. the **master public parameters** for version `vN` — i.e. the platform's
   published trust anchor for that key version;
2. the **derivation rule** (§4) + the cap's `granted_by` URI + `key_id`.

**Correction (codex CRITICAL):** an earlier draft claimed external verification
was impossible under derived keys "without exposing the seed." That is wrong.
HKDF needs the seed to derive a *private* key, but the corresponding **public**
key is safe to publish — publishing it exposes no secret. So platform-custody +
derived keys **can** serve an external, non-platform verifier, via an
**authenticated public-key directory**:

> The platform derives each entity's public key once and publishes
> `(entity_uri, key_id, pub_bytes)` in a directory, each entry **signed by a
> platform trust-anchor key**. A verifier (peer tenant OR external/non-BEAM
> third party) fetches the entry, checks the trust-anchor signature to bind
> `pub_bytes` to `entity_uri`, then `:crypto.verify`s the cap's signature.

- **Peer-tenant on the platform:** may also derive directly (it can reach the
  seed via the platform) — the directory is a convenience, not a requirement.
- **External / non-BEAM third party:** uses the **directory + trust-anchor**
  path. No seed sharing; genuine public-key verification. The only property they
  *cannot* get is **non-repudiation against the platform** — the platform, holding
  the seed, could itself have forged the entity's signature (→ OQ-2 / Phase-5
  entity-held keys). External *verifiability* does not require entity-held keys;
  only non-repudiation-against-the-platform does.

Every cap **carries `granted_by` + `key_id`** (`key_id = {version, trust-domain}`);
a future verifier resolves the public key from (direct derivation | signed directory
entry). Trust anchor = the platform's published trust-anchor public key that signs
directory entries. **In Phase-4 the resolver is direct derivation only**; the
directory + trust-anchor is the deferred federation piece (OQ-1 resolved, §14).

---

## 6. Axis 4 — What exactly is signed (deterministic canonical bytes)

**Do NOT sign `Jason.encode/1` output.** The existing `Jason.Encoder` impl
(capability.ex:569-590) and `to_map/1` (capability.ex:436) are for *storage*, not
signing: JSON key ordering, whitespace, and unicode-escaping are not guaranteed
stable across re-encode, so a round-trip that reorders keys would break every
signature. Signing needs a *deterministic* byte construction.

**Signed message = canonical bytes over the authorization-bearing tuple, in a
fixed field order, wrapped in a versioned envelope:**

```
signing_payload(cap) = {                 # JSON object. Every SCALAR LEAF is a string; the only
                                         # exceptions are the int `v` and the `instance` scope
                                         # array (a list of 2-element [tag,val] string arrays).
  v:            1,                        # signing-format version (bump = new envelope) — the ONLY number
  key_id:       "v<N>|<b64url(trust_domain)>",  # bounded grammar §6.2; SIGNED (in the payload)
  key_id:       "v<N>|<b64url(trust_domain)>",  # bounded grammar, §6.2 below
  kind:         canon_atom(cap.kind),          # "any" | atom-name string
  behavior:     canon_module(cap.behavior),    # "any" | full module-name string
  action:       canon_atom(Capability.action_of(cap)),  # "any" | atom-name string (capability.ex:182)
  instance:     canon_instance(cap.instance),  # "any" | canonical-URI string | ordered scope array
  workspace_uri: canon_workspace(cap.workspace_uri),  # "any" | canonical-URI string  (see note)
  granted_by:   canon_uri(cap.granted_by),     # canonical-URI string (entity://…)
  granted_at:   canon_ts(cap.granted_at)       # fixed-precision ISO8601 UTC string, §6.1
}
```

Note: `workspace_uri` in the *payload* is the canonical original (`"any"` for `:any`,
`stable_key` string for concrete) — it binds the actual field. The **derivation /
key-selection** domain is `trust_domain(cap.workspace_uri)` (§4), which maps `:any` →
`"a:*"` and concrete → `"w:" <> stable_key`. Verify recomputes `trust_domain` from this
payload field and requires it to equal the `key_id`-encoded domain (§6.2, §7).

**Byte construction — LOCKED to canonical-JSON (lead 2026-07-14, bake-in #1).** Sign
over **RFC 8785 JSON Canonicalization Scheme (JCS)** applied to `signing_payload`:
lexicographically sorted keys, no insignificant whitespace, UTF-8, JCS number/string
rules. **NOT** `:erlang.term_to_binary/2` (BEAM-only → not federation-verifiable),
**NOT** `Jason.encode` storage output. JCS is a *named, complete* canonicalization
(codex C) so "canonical JSON" is not left underspecified. Because every payload **scalar
leaf** is reduced to a **string** by `canon_*` below (the only non-string leaves are the
int `v` and the `instance` scope array of `[tag,val]` string pairs), the only JCS-relevant
number is `v` — this sidesteps float/precision hazards entirely.

### 6.1 Normative `canon_*` value schema (codex C — define BEFORE impl, not "during")

| field value | `canon_*` rule → JSON |
|---|---|
| `kind`, `action` atom | `Atom.to_string/1`; the atom `:any` → the string `"any"` |
| `behavior` module atom | full module name via `inspect/1`-free `Atom.to_string` (e.g. `"Elixir.Ezagent.Behavior.Foo"` normalized to `"Ezagent.Behavior.Foo"`) |
| `instance` `%URI{}` | `Ezagent.URI.stable_key/1` (the ONE canonical form = `canonical!/1 \|> URI.to_string`, uri.ex:475 — no ad-hoc `URI.to_string`) |
| `instance` `:any` | `"any"` |
| `instance` scope-tuple list | the ONE structured value: a JSON **array** whose elements are exactly-two-element arrays `[tag_string, stable_value_string]`, tags sorted ascending, mirroring the storage list shape (capability.ex:585-589) but with canonical strings. (`instance` is a single `scope_tuple()` list, capability.ex:48.) |
| `workspace_uri` concrete | `Ezagent.URI.stable_key/1`; `:any` → `"any"` |
| `granted_by` `%URI{}` | `Ezagent.URI.stable_key/1` (always a real `entity://` here, §3) |
| `granted_at` `DateTime` | **UTC, truncated to millisecond**, `DateTime.to_iso8601/1` on the truncated value — pin at sign time and store that exact string as the signed representation (genesis cap already fixed, capability.ex:71) |

Ezagent URIs MUST go through `Ezagent.URI.stable_key/1` (uri.ex:475 — there is NO
`canonical_string/1`), never raw `URI.to_string` — canonical-URI equality is the guard the
whole system already relies on (`[[unify-uri-query]]`). Unicode: NFC-normalize string fields
before JCS. Ship
**cross-language golden vectors** (fixed cap → fixed JCS bytes → fixed hex signature)
as the drift tripwire; a failing vector, not a silent prod verify failure, catches any
`canon_*`/JCS divergence.

### 6.2 Normative `key_id` grammar (codex D — bounded, unambiguous)

```
key_id      = "v" 1*DIGIT "|" b64url( trust_domain )
            ; anchored: /^v(\d+)\|([A-Za-z0-9_-]+)$/ , total length ≤ 512
parse(key_id):
  1. match the anchor; no match → MALFORMED → verify returns false (§7, a deny)
  2. version = the digits; domain = base64url-decode(group 2)
  3. require domain == trust_domain(cap.workspace_uri)  (§4)  else → false (deny)
  4. require version is a CONFIGURED, trusted master version (else deny, §7)
```

base64url-encoding the trust-domain removes the `|`-collision hazard entirely (a raw
`workspace_uri` can legally contain `|` — `Ezagent.URI` segment validation rejects only
empty/`/`, uri.ex:492-504 — so raw concatenation was ambiguous). The `v<digits>|`
prefix is anchored and the remainder is a bounded base64url token; nothing else parses.
This is the "attacker-controlled `key_id` read before auth" input from §7 — a malformed
or domain-mismatched `key_id` is a **deny (`false`)**, never a raise.

**Binding details (must-haves):**

- Sign **after** `granted_by` + `granted_at` are stamped — i.e. the **last step of
  `issue/3`/`prepare_provenance/2`** (cap.ex:67-76), so the signed bytes cover the
  final artifact.
- **Pin `granted_at` precision.** `prepare_provenance/2` uses
  `DateTime.utc_now()` (microsecond). Serialize via a fixed ISO8601 form so
  microsecond drift on any re-derivation cannot break verify; store the exact
  serialized form as the signed representation. (The genesis cap uses a fixed
  `granted_at` already — capability.ex:71 — so it is stable by construction.)
- `key_id` and `granted_at` are **inside** the signed payload → an attacker
  cannot swap the signing key version/trust-domain or backdate without invalidating
  the sig. (`key_id` **must** be signed — it carries the version+domain the
  substitution defense in §6.2 step 3 relies on.)
- The `signature` and `key_id` both live on **new `%Capability{}` fields**
  (`signature: binary | nil`, `key_id: String.t() | nil`), added to the struct. Only
  **`signature` is excluded** from `signing_payload` (you cannot sign the signature);
  **`key_id` IS included** in `signing_payload` (as shown above) — it is a struct field
  *and* a signed payload field, no contradiction.
  `to_map/1` / `from_map/1` / the `Jason.Encoder` (capability.ex:436/450/569) gain
  the two fields for round-trip persistence in `caps_json`.

---

## 7. Axis 5 — Verify at the gate (fail-loud-not-deny)

Fill the `verify/1` seam (cap.ex:43-45). New contract:

```
verify(%Capability{} = cap) :: boolean()   # unchanged signature
  # returns TRUE  — signature present, resolves, and validates
  # returns FALSE — signature absent/malformed/does-not-validate  (a genuine DENY)
  # RAISES        — master seed missing | crypto subsystem error | pubkey
  #                 resolution infra failure                       (fail-LOUD, NOT a deny)
```

The distinction is the whole point (memory: `#1346 CapBAC transient-read
fail-loud`, `feedback_let_it_crash_no_workarounds`): a **transient infra failure
must not collapse to `false`**, because `false` is a silent deny that would strip a
legitimately-authorized cap out of a slice and mis-route delivery. A genuine bad
signature IS a deny (`false`). Only *bad crypto material we can't evaluate* raises.

**`key_id` is attacker-controlled — split it correctly (codex HIGH, DoS guard):**
`key_id` arrives on the *untrusted* artifact, read **before** the signature is
authenticated. If any unrecognized `key_id` raised, a malicious artifact carrying a
bogus `key_id` would crash *every* load/store boundary — fail-loud turned into a
**DoS**. Rule:

- **unknown / malformed `key_id`, absent / malformed `signature`** → return
  `false` (a genuine **deny** — the artifact is simply not validly signed);
- **`key_id` is a configured, trusted version** but its key material is
  *unexpectedly unavailable* (seed missing from secrets-home, crypto subsystem
  error, directory unreachable) → **raise** (fail-loud infra failure).

Only the *trusted-but-unavailable* branch raises. This keeps fail-loud for real
infra faults while denying (not crashing on) hostile input.

**Caller ripple — this changes a documented total-boolean contract; audit every
caller so the raise propagates (does NOT get rescued to `false`):**

- `verified_set/1` (cap.ex:56-62) — the reducer filters non-verifying caps out.
  It MUST let an infra raise propagate (today it would silently drop). Callers:
  `identity.ex:411` (`verified_cap_set/1`), `behavior/identity.ex:167,303`.
- `behavior/identity.ex:614` (`store_verified_cap/2`) — `if Ezagent.Cap.verify(cap)`
  in the self-store path. On infra failure the store must fail loud, not silently
  skip the write.
- `recipe_cap_binding.ex:75` — verify before artifacts enter `:caps`.

**Where VERIFY runs:** unchanged locations — the load/store boundaries that
already call `verified_set/1` / `verify/1`, plus dispatch step 5.5. No new call
sites; we upgrade the one `verify/1` body per the seam's promise (cap.ex:47-53).

**I12 preservation (scoped claim, codex MEDIUM):** signing happens *inside*
`issue/3` (granter artifact), and the **signature travels on the `%Capability{}`
artifact the grantee self-absorbs** (`handle_absorb_cap`/`store_verified_cap`,
behavior/identity.ex:604-614 — the absorb lane only accepts `:vm_internal`). This
phase introduces **no new issuer-driven dispatch in the absorb lane** — the signed
artifact is the same self-absorbed artifact, now carrying a `signature` field. It
does **not** by itself complete universal I12 compliance: `handle_grant_cap/2`
remains a separate store endpoint and the phase-3 plan leaves grantor→grantee sites
still to migrate (`docs/plans/2026-07-11-phase3-cap-self-store-impl-plan.md:30,160`).
Signing neither helps nor harms those; it stays I12-neutral.

---

## 8. Axis 6 — Key rotation + versioning

- Cap carries `key_id = "v<N>|b64url(trust_domain)"` (§6.2), inside the signed payload; the version component `N` selects the master seed.
- Rotation = provision `EZAGENT_SIGNING_SEED_V(N+1)` in secrets-home, set the
  active-signing version to `N+1`. **New** caps sign with `vN+1`; **existing** caps
  keep `vN` and still verify because the verifier retains `vN` params during the
  dual-version window.
- Mirrors the #1361 versioned-pepper rotation (`EZAGENT_PAT_PEPPER_V<N>`): selector
  (here `key_id`) in the artifact picks the key; multiple versions coexist.
- Retire `vN` only after all caps signed under it are re-signed or expired/revoked.

---

## 9. Axis 7 — Revocation

Signatures do not expire, so revocation must come from elsewhere. **Recommendation:
lean on the existing cap-lifecycle revoke** — no new CRL for the common case.

- A signed cap is an **authorizer only while it is present in the authenticated
  holder's `:caps` slice.** `Capability.revoke/2` (capability.ex:216-229) removes
  it from the slice by identity-tuple; once removed it can't authorize regardless
  of a still-valid signature.
- This works because caps are **not bearer tokens** — they live in the holder's
  own authenticated, workspace-scoped slice, and `instance`/`workspace_uri`
  scoping binds them to a target. A signature lifted out of a slice is not
  self-authorizing anywhere.
- **If** a future phase makes signed caps *portable* (a grantee hands a signed cap
  to a third party as a bearer receipt), revocation of a still-valid signature
  needs a **short-TTL + re-sign** loop or a **revocation list**. Flag as Phase-5
  (couples with entity-held keys / external verifiers, §5).

---

## 10. Axis 8 — Migration from unsigned caps (mirror #1361 token migration)

Existing caps (in `caps_json`, in live slices) have `signature: nil`. Rollout in
three ratcheted stages, gated by a config flag `require_signature`:

1. **Dual-read (`require_signature: false`).** `verify/1` accepts a cap if it has a
   **valid signature** OR (no signature AND passes the legacy #154 predicate
   `granted_by = entity://`). New issues sign. **Fail-OPEN window = this stage**
   (unsigned legacy caps still honored) — bounded and documented.
2. **Backfill re-AUTHORIZE + sign (not blind re-sign — codex HIGH).** A blind
   re-sign of whatever sits in a slice would **launder** a possibly-forged legacy
   cap (the very forgeable `granted_by = entity://` predicate this phase exists to
   replace) into a validly-signed artifact that *looks* like proven issuer
   authorization. The backfill MUST therefore re-establish authorization from an
   **authoritative source of truth**, not current slice state: replay each cap's
   originating `:cap_granted` grant event from the **EventLog**
   (`cap_granted`/`cap_revoked` are already emitted — capability.ex:561-568) back
   through `Cap.issue/3` (which re-runs `authorize_grant`), then sign the result.
   A slice cap with **no** corresponding authoritative grant event is **not**
   re-signed — it is quarantined/reported, not blessed. Idempotent by
   identity-tuple (like `recipe_cap_binding` — recipe_cap_binding.ex:12).
   Declared/rule sentinels are skipped (§3).
3. **Enforce (`require_signature: true`).** `verify/1` requires a valid signature;
   an unsigned cap is now a genuine **deny** (`false`), not a raise. This is the
   **fail-closed flip.**

**Fail-open window (stage 1) must be explicitly bounded (codex HIGH):** "dual-read"
is not open-ended. The flip criteria are: (a) a **time bound** (a named cutover
date/window, not "eventually"); (b) a **telemetry gate** — a counter of
`verify`-accepted-via-legacy-fallback must reach ~0 (instrument the fallback branch)
before enforce; (c) a **rollback condition** — if enforce spikes genuine denials,
revert the flag. Enforce only after §11 INV-SIGN-1 is green AND (a)+(b) hold.

The flag is the single switch (dual-read→enforce, in the spirit of the #1361 token
rollout — though token.ex ships no such migration today, so this is designed fresh).

---

## 11. Axis 10 — Invariant / arch-gate

New invariant test (co-located with the existing cap invariants under
`apps/ezagent_core/test/invariants/`, e.g. `caps_data_owner_invariant_test.exs`):

**INV-SIGN-1 (signed-world completeness):** with `require_signature: true`, for
every authorizer cap in any slice, `Cap.verify/1` returns `true` — i.e. it carries
a valid signature under a known `key_id`. Declared/needed sentinels are exempt (§3).

**INV-SIGN-2 (verify never silently denies infra failure):** a `verify/1` (and
`verified_set/1`) call **raises** — never returns `false` — when the master seed is
absent / crypto errors / pubkey resolution fails. Test by injecting a
missing-seed / broken-crypto condition and asserting a raise, not a filtered-out
cap. This is the testable form of fail-loud-not-deny.

**Arch-gate (`ezagent.arch.scan`):** no code path in `verify/1` or its enumerated
callers (§7) rescues a crypto/seed error to `false`. Grep-anchored assertion that
the infra-failure branch raises.

---

## 12. Scope: SCORING is a separate follow-on

cbac Phase-4 was originally scoped as "crypto 签名 + scoring." **This spec is
signing only.** Reputation **scoring on signed receipts** — using verified
signatures as the trust primitive to compute reputation/consent scores
(`project_reputation_primitive_cap_exhaust`, the minimal Receipt landed in
#1193) — is a **separate follow-on spec.** Signing must land, be enforced, and be
proven by §11 *first*; scoring builds on top of the signature it produces. Do not
fold scoring into this spec.

---

## 13. cap.ex seam fill (concrete)

- `issue/3` (cap.ex:30-36) → after `authorize_grant` + `prepare_provenance/2`
  stamp `granted_by`/`granted_at`, compute `signing_payload` (§6), sign with the
  granter's derived private key (§4), set `signature` + `key_id` on the artifact.
  Raise (fail-closed) if the seed is missing.
- `verify/1` (cap.ex:43-45) → resolve the granter's public key from `granted_by` +
  `key_id`, `:crypto.verify` over `signing_payload`. Boolean per §7; **raise** on
  infra failure. In the dual-read stage, fall back to the legacy #154 predicate
  for `signature: nil` caps (§10 stage 1).
- `verified_set/1` (cap.ex:56-62) → unchanged shape; propagates the §7 raise.
- New module `Ezagent.Cap.Signing` (core) holds seed loading (runtime.exs /
  secrets-home), HKDF derivation, `signing_payload/1`, sign/verify — keeping
  `cap.ex` thin and the crypto in one place. Config wired beside the existing
  `config :ezagent_core, Ezagent.Cap, authority_loader: …` (config/config.exs:148),
  e.g. `signing: [seed_provider: …, active_key_version: 1, require_signature: false]`
  — the config carries the master **version** (an integer); each cap's composite
  `key_id` (§6.2) is *built* from `active_key_version` + `trust_domain(cap.workspace_uri)`.

---

## 14. Open Questions — RESOLVED by lead 2026-07-14

All OQs are decided. Guiding principle: **basic mechanism now; only low-cost
federation-friendly bake-ins; defer the expensive parts to Phase-5/federation.**

| OQ | Decision | Consequence in this spec |
|---|---|---|
| **OQ-1** external verifiability + encoding | **BEAM-internal verify now**; the external public-key directory endpoint is **deferred to federation**. But **bake in the cheap seam**: canonical-JSON envelope + directory-lookup-able `key_id`. | §5 reframed to seam-only (deferred endpoint); §6 **locked to canonical-JSON**; `key_id = {version, trust-domain}`. |
| **OQ-2** non-repudiation-against-platform | **Accepted that the platform can forge.** Phase-4 = platform-attested + peer-non-forgeable + externally-*verifiable* (once the directory lands), NOT non-repudiation against the platform. | §4 honest-property note stands; entity-held keys stay Phase-5. |
| **OQ-3** canonical encoding | **Canonical-JSON** (subsumed into OQ-1 / bake-in #1). Not `term_to_binary`. | §6 locked; §2 table updated. |
| **OQ-4** genesis/system signer | Sign the genesis/admin self-granted cap with the **system entity's derived key** (under the `:any` trust-domain `"a:*"`, since the genesis cap carries `workspace_uri: :any`). The system entity's public key is the published anchor; no special unsigned exception. | §3 genesis bullet stands; §4 `trust_domain(:any)` covers the system entity. |
| **OQ-5** blast radius / seed segmentation | **Accept one-seed-forges-all now** (single platform master). Bake in the cheap segmentation seam: **`workspace_uri` in the HKDF context** so per-workspace *independent* seeds later = a config swap, no re-key. Full per-org seeds with distinct custody = federation. | §4 derivation includes `workspace_uri` (bake-in #2). |
| **OQ-6** enforce-flip ownership | **Lead owns** confirming §11 INV-SIGN-1 green + §10 telemetry/time/rollback gates before `require_signature: true`. The live re-authorize-backfill on prod slices is a **separate ops task**, not in the impl PR. | §10/§11 unchanged; called out in the impl plan. |
| **OQ-7** consent depth | **Issuer-accountability is sufficient** for Phase-4. Signed delegation chain (owner → admin → cap) for provable owner-consent is **deferred** (Phase-5-shaped). | §3 issuer-accountability semantics stand. |

**Net design shipped:** ed25519, signer=granter, single platform master seed with
`workspace_uri`-in-context HKDF derivation, canonical-JSON signing envelope,
`{version, trust-domain}` `key_id`, BEAM-internal derive-and-verify, dual-read →
enforce migration, issuer-accountability guarantee, platform-custody accepted. Three
federation seams (canonical-JSON, workspace-in-derivation, directory-lookup-able
`key_id`) are baked in at ~zero cost; the directory endpoint, per-org seeds, and
entity-held keys are Phase-5/federation.

---

## 15. Grounding index (file:line)

- Seam + sign/verify site: `apps/ezagent_core/lib/ezagent/cap.ex:5-9,30-36,43-45,56-62,67-76,78-81`
- Struct + fields + genesis + revoke + serialize: `apps/ezagent_core/lib/ezagent/capability.ex:36-46,66-71,182,216-229,244-254,266-284,436,450,569-590`
- #1361 key-mgmt precedent: `apps/ezagent_domain_identity/lib/ezagent/entity/token.ex:71-94,196-198`
- Self-store / I12 / absorb path: `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:167,303,587-614`
- verify/issue callers: `apps/ezagent_domain_identity/lib/ezagent/identity.ex:411`, `.../identity/grant.ex:232`, `.../identity/recipe_cap_binding.ex:75,144`
- Cap config: `config/config.exs:148`
- Phase-3 plan / I12 / data_owner: `docs/plans/2026-07-11-phase3-cap-self-store-impl-plan.md:30,90,160`

---

## 16. Codex adversarial review

**Reviewer:** codex (rescue), architecture-only static pass. Job thread
`019f5ea8-6d20-7802-9311-6e8b871e64c7`.
**Verdict (initial draft):** **NEEDS-REVISION** — ed25519 direction sound, but the
draft "conflated authorization identity, platform custody, and independent
verification." All findings below were resolved by revising §3–§10 + §14 in this
same commit; the architecture (signer=granter, sign-on-issue, fail-loud verify,
dual-read migration, scoring-separate) **holds** after revision.

### Architecture findings + resolution

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | **CRITICAL** | The OQ-1 "peer-tenant vs external verifier" fork was **false**: publishing a *public* key exposes no secret, so derived platform-custody keys CAN serve external verifiers via an **authenticated public-key directory**. Platform custody limits non-repudiation-against-platform, it does not block external verification. | **§5 rewritten**: added the signed public-key directory + trust-anchor model; external verification is feasible in both worlds. **OQ-1 reframed** to directory-trust-model + encoding, not feasibility. **OQ-2** sharpened to the real limit (platform non-repudiation). |
| 2 | **HIGH** | `signer=granter` correct, but `granter=data_owner` holds only for `:held_by` self-grant; `:admin`/`:rule` issuers are delegated authority. Signature proves **issuer accountability**, not **owner consent**. | **§3 clarified** — precise semantics stated; owner-consent-on-delegated-issuance moved to **OQ-7** (signed delegation chain, Phase-5-shaped). |
| 3 | **HIGH** | Master-seed rotation (§8) is lifecycle mgmt, **not** compromise recovery — forged-`vN` artifacts stay valid through the dual-version window; conflicts with tenant-isolation unless accepted as platform-root compromise. | **OQ-5 rewritten** to name this explicitly + note segmentation only helps with **distinct custody boundaries**, not derivation labels. Accepted as a stated Phase-4 platform-root property pending lead call. |
| 4 | **HIGH** | Migration Stage 2 blind re-sign would **launder** a forged legacy cap into validly-signed "consent"; "bounded" had no actual bound/telemetry/rollback. | **§10 Stage 2 rewritten**: re-**authorize** from EventLog grant events through `Cap.issue/3` (not blind re-sign of slice state); caps with no authoritative grant event are quarantined. Added explicit time-bound + fallback-telemetry gate + rollback condition for the fail-open window. |
| 5 | **HIGH** | Boolean-or-raise is sound, but `key_id` is attacker-controlled and read before authentication → an unknown `key_id` that raises = **DoS** on every load/store boundary. | **§7 refined**: unknown/malformed `key_id` or absent signature → `false` (deny); only a *configured, trusted* `key_id` with unavailable material → raise. |
| 6 | MEDIUM | §7 overstated system-wide I12 coverage; `handle_grant_cap/2` remains a separate endpoint, ~grantor→grantee sites still to migrate. | **§7 scoped** to "no new issuer-driven dispatch in the absorb lane"; signing declared I12-neutral. |
| 7 | MEDIUM | Signing envelope not yet a durable canonical protocol — `canon/1` undefined for atoms/URI/scope/timestamp; cross-OTP `term_to_binary` drift unproven. | **§6 addendum**: normative `canon/1` definition + OTP-compat pin (or canonical-JSON) + **golden test vectors** required before impl. |

### impl-constraints (noted, no respin)

- **#1361 precedent IS a versioned-pepper HMAC store** (`token.ex:3,14,24,77`:
  `token_digest = HMAC-SHA256(pepper_vN, raw)`, `pepper(version)` from runtime
  config, fail-closed on missing pepper, explicitly **no bcrypt fallback**;
  `digest_version` column + migration `20260712010000`). *(The draft's "bcrypt +
  random PAT" note was wrong — verified against main and corrected here + in §4.)*
  So "mirror #1361" is a **literal, direct precedent** for versioned-secret +
  dual-version-selector + dual-read migration + fail-closed; this spec extends
  that symmetric discipline to **asymmetric** (versioned master seed → HKDF ed25519).
- `verify/1` is **no longer total** once infra raises — test four distinct cases:
  bad signature, unknown `key_id`, missing seed, crypto failure (added to §11
  intent).
- Add `signature`/`key_id` consistently to the struct type, `to_map`/`from_map`
  normalization, and the `Jason.Encoder` (capability.ex:36-60,436,450,569-590) +
  golden round-trip vectors.

**Post-revision status (review #1):** architecture **SOUND-WITH-CONSTRAINTS**. CRITICAL
+ all HIGH resolved in-spec; remaining items were impl-constraints + the OQs — which the
lead has now **RESOLVED** (§14, 2026-07-14).

### Review #2 (codex, 2026-07-14) — delta re-review after OQ-lock + 3 federation bake-ins

**Reviewer:** codex (rescue), static-only. Job `task-mrk52qf5-0xy2zt` / session
`019f5ea8`. Scope: only the delta (OQ-lock + canonical-JSON + workspace-in-derivation +
composite key_id). **Verdict: per-workspace-key direction SOUND (axis B), but 3 bake-ins
needed low-cost spec-precision fixes before impl — all applied in this commit.**

| Axis | Finding | Resolution (this commit) |
|---|---|---|
| A | `trust_domain` not total — `:any` is a *legit* cross-workspace/genesis authorizer shape (capability.ex:244-253, identity.ex:240-246), `nil` constructible via struct-bypasses-normalize (normalize.ex:68-70, capability_registry.ex:417-444). Raw-delimiter HKDF info undefined. | §4: **total, domain-separated `trust_domain/1`** (concrete→`"w:" <> stable_key`; `:any` incl genesis→`"a:*"`; `nil`/other→**raise**). Prefixes make the ranges provably disjoint (review #3 fix — see below). HKDF info **length-prefixed** (`u32`), not `\|`-concatenated. |
| B | **SOUND** — per-(entity,workspace) keys coherent with signer=granter; verify uses the signed artifact's domain, never the verifier's ambient workspace. | No change (verify contract §7 already artifact-only). |
| C | Canonical-JSON selected without a normative value schema; "cost = canon+vectors" understated atom/module spelling, `:any`, scope-tags, URI canonicality, Unicode, timestamp precision. | §6.1: **normative `canon_*` table** per field + **RFC 8785 JCS** named algorithm + every value reduced to a string (only `v` is a number) + NFC + cross-language golden vectors. |
| D | `"vN\|<workspace_uri>"` no bounded grammar; `\|` not rejected by URI segment validation (uri.ex:492-504) → ambiguity. | §6.2: **bounded grammar** `v<digits>\|b64url(trust_domain)`, anchored parse, ≤512 len, require decoded == `trust_domain(cap.workspace_uri)`; malformed/mismatch → deny (false), not raise. |
| E | Stale bare-`"vN"` text (§2/§8), config `active_key_id`→`active_key_version`, §16 listed OQs as open. | All reconciled to the composite `key_id` + integer `active_key_version`; §14 OQs marked resolved; this §16 block updated. |

**Post-review-#2 status:** GAPs A/C/D/E fixed; B sound — but a **confirming re-review #3**
(below) caught that the review-#2 A-fix (a bare `"platform-root"` constant) was itself
unsound, plus residual API/consistency drift. Those are now fixed too.

### Review #3 (codex, 2026-07-14) — confirming pass on the A/C/D/E fixes

**Reviewer:** codex (rescue), static-only. Job `task-mrk5hwq2-lwckhl`. Scope: verify each
review-#2 fix actually closes its gap + introduced no new issue. **Verdict: D & E CLOSED;
A/C had residual blockers + 2 new consistency issues — all fixed in this commit.**

| Item | review-#3 finding | resolution (this commit) |
|---|---|---|
| A-b | **load-bearing hole:** `"platform-root"` is *constructible* as a workspace name (`workspace/1`/`segment!/1` accept it, uri.ex:461/492) and a hand-built `%URI{}` bypassing normalization can `stable_key`-collide with a bare constant → the non-collision claim was false. | §4 rewritten to **domain-separated prefixes**: concrete → `"w:" <> stable_key`; `:any` → `"a:*"`. Disjoint **by construction** (different leading char), no non-constructibility assumption. |
| C-1 | `Ezagent.URI.canonical_string/1` **does not exist**; the real canonical API is `stable_key/1` (uri.ex:475). | All spec/plan/handoff refs → `Ezagent.URI.stable_key/1`. |
| C-2 | "every payload value is a string" contradicted the scope-tuple **array**. | §6/§6.1 reworded to "every **scalar leaf** is a string; the one structured value is the `instance` scope array of 2-element `[tag,val]`." |
| new-1 | `key_id` was declared both **signed** (§6 payload) and **excluded** from the payload (§6 binding) — contradiction breaking the substitution defense. | §6 binding fixed: **only `signature` is excluded**; `key_id` **is** signed (struct field *and* payload field, no contradiction). |
| new-2 | impl-plan reintroduced `active_key_id: "v1"` vs the spec's integer `active_key_version`. | plan P2 config → `active_key_version: 1`. |
| D, E | CLOSED (bounded grammar; composite-`key_id` text + `active_key_version` + OQ status all consistent). | no change. |

**Post-review-#3 status:** A (now domain-separated & provably disjoint), C (real `stable_key`
API + scalar-leaf schema), D, E, new-1, new-2 all resolved; B sound. Spec is **ready for
implementation** (plan + handoff aligned).
