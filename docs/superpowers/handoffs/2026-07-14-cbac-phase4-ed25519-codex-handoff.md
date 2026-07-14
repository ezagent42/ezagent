# Codex Handoff — cbac Phase-4 ed25519 Signing

**Spec:** `docs/superpowers/specs/2026-07-14-cbac-phase4-ed25519-signing.md` (lead-locked 2026-07-14, OQs resolved in §14).
**Plan:** `docs/superpowers/plans/2026-07-14-cbac-phase4-ed25519-impl-plan.md` (P1–P6 + DoD).
**Repo:** esr-ng. **Target branch:** `feat/cbac-phase4-ed25519`.

## Your role (codex)

Implement Phase-4 cryptographic signing of capabilities per the spec + plan. You **own** the target branch `feat/cbac-phase4-ed25519`: create it off current `main`, land P1–P6 as **bounded sub-step commits/PRs onto that ONE branch continuously** (no inter-phase wait, do NOT open one giant PR, do NOT merge to `main` — the coordinator merges to `main` after end-to-end validation). Self-merge your own sub-steps onto the target branch only.

## Non-negotiable constraints (spec-locked — do NOT re-litigate)

1. **No new dependency.** ed25519 + HKDF via OTP `:crypto` only.
2. **Signing envelope = canonical-JSON via RFC 8785 JCS** over the §6 payload; every **scalar leaf** reduced to a string by the normative `canon_*` schema (§6.1) — only `v` is an int and the `instance` scope array is the one structured value. **Never** `:erlang.term_to_binary`, **never** `Jason.encode` output. Ezagent URIs via `Ezagent.URI.stable_key/1` (uri.ex:475 — there is NO `canonical_string/1`), never raw `URI.to_string`. NFC string fields. `key_id` **is** signed (in the payload); only `signature` is excluded. Ship **cross-language golden vectors** (fixed cap → fixed JCS bytes → fixed hex signature).
3. **`trust_domain/1` is TOTAL and domain-separated (§4):** concrete `%URI{}` → `"w:" <> Ezagent.URI.stable_key(ws)`; **every** `:any` (incl the genesis cap and explicit cross-workspace grants) → `"a:*"`; `nil` / any other shape → **raise (fail-closed), do not sign**. The `"w:"`/`"a:"` prefixes make the concrete and `:any` ranges provably disjoint (do NOT use a bare `"platform-root"` — it is a constructible workspace name and would collide). HKDF `info` is **length-prefixed** (`u32` sizes), NOT raw-`|`-concatenated. The same `trust_domain` value feeds HKDF, `key_id`, and verify. One master seed this phase.
4. **`key_id` bounded grammar (§6.2):** `"v<digits>|" <> b64url(trust_domain)`; parse anchored `^v(\d+)\|([A-Za-z0-9_-]+)$`, len ≤512, decode domain, require `== trust_domain(cap.workspace_uri)` before resolving a key. Malformed / domain-mismatch → `false` (deny), never raise. (b64url removes the `|`-in-URI ambiguity — `Ezagent.URI` does not reject `|`.)
5. **`verify/1` = boolean-or-raise (§7):** bad/absent signature OR unknown/malformed `key_id` → `false` (deny); a **configured, trusted** `key_id` whose key material is unavailable (seed missing, crypto error) → **raise** (fail-loud-not-deny). NEVER rescue a crypto/seed error to `false` anywhere in `verify/1` or its callers.
6. **Fail-closed at `issue/3`** if the active seed is missing — raise, no unsigned fallback.
7. **Migration = dual-read → enforce**, default `require_signature: false`. Backfill **re-authorizes from the EventLog** (`:cap_granted` replayed through `Cap.issue/3`) — NOT a blind re-sign of slice state; a cap with no authoritative grant event is **quarantined/reported, not signed**. The **prod enforce-flip + live backfill are OUT of your scope** — lead-owned ops (OQ-6). You ship the mechanism + the dry-run backfill task only.
8. **Declared/needed sentinels are NOT signed** (`granted_by: :plugin_declared`, capability.ex:66-67) — only authorizer caps that live in an entity's `:caps` slice.
9. Per sub-step: full static gate **`mix ci.local`** (the whole set, not a subset — `arch.scan + doc.scan + uri_query.scan + check_invariants`) green + rebased on current `main` before self-merge. Edit Elixir with an editor, never `cat >>` (SyntaxError). Add `MIX_TEST_PARTITION` for any parallel test runs.

## The `workspace_uri: :any` derivation gap (codex re-review CONFIRMED — resolution is in-spec)

Codex's delta re-review (spec §16 review #2) confirmed this is real: `workspace_uri: :any` is a **legitimate** authorizer shape — the genesis cap carries it (capability.ex:244-253), ordinary grants may request cross-workspace `:any` (identity.ex:240-246), and `nil` is constructible because struct inputs bypass normalization (normalize.ex:68-70, capability_registry.ex:417-444). The **resolution is already normative in §4**: implement `trust_domain/1` as a **total, domain-separated** function (concrete→`"w:" <> stable_key`; every `:any` incl genesis→`"a:*"`; `nil`/other→**raise before signing**) and feed its value — never a raw `workspace_uri` — into HKDF (length-prefixed), `key_id` (b64url), and verify. The `"w:"`/`"a:"` prefixing is load-bearing (a bare `"platform-root"` constant is unsound — codex review #3 — because that string IS a constructible workspace name). Cover totality + disjointness in P2 tests (constraint 3). Do NOT feed `:any`/`nil` into the derivation.

## Sub-steps

Follow `docs/superpowers/plans/2026-07-14-cbac-phase4-ed25519-impl-plan.md` P1→P6 verbatim (struct fields → Signing module → sign-on-issue → verify-at-gate+caller-audit → migration/enforce-flag → arch-gate/invariants). Each phase's **Gate** line is your acceptance bar for that sub-step.

## Definition of Done

The plan's **Definition of Done** (closed set, 7 items). Return per the `dev-together return` contract: `mix ci.local` URL/log + rebase-base SHA, DoD reconciliation line-by-line, and the merge request (target branch → main). Do NOT self-declare "ready to merge to main" — hand the validated target branch to the coordinator.

## Grounding index

See spec §15. Key seams: `apps/ezagent_core/lib/ezagent/cap.ex:30-36,43-45,56-62,67-76`; `capability.ex:36-46,66-71,182,216-229,244,436,450,569-590`; `token.ex:71-94` (versioned-secret precedent); `behavior/identity.ex:167,303,614`; `recipe_cap_binding.ex:75`; `config/config.exs:148`.
