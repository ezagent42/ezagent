# Codex handoff — cap-signing no-tail self-healing upgrade

**Spec (authoritative, build to it):** `docs/superpowers/specs/2026-07-15-cap-signing-no-tail-self-heal.md` (v3, coordinator-verified SOUND after two codex adversarial reviews).
**Owner branch:** `feat/cap-signing-notail-upgrade` — you own it, land sub-steps, coordinator reviews + merges each to `main`. Reuse the artifacts already on that branch (`test/support/caps_json_scanner.ex`, `test/architecture/cap_signing_fail_loud_test.exs`, the investigation test).
**Goal:** every existing authorizer cap becomes signed (0 unsigned tail) so the lead can later flip `require_signature: true`. **This work does NOT flip enforce** (dual-read stays; the flip is a separate manual lead decision).

## Non-negotiable constraints (the 9 hardening fixes — the two review rounds exist because these are subtle)
1. **The one signed-ness classifier is `signed_and_valid?/2` (spec §4.0) — NEVER `verify_for/2`.** `verify_for/2` accepts unsigned legacy caps under dual-read → using it as the keep/audit classifier makes the whole thing a false-zero no-op. `signed_and_valid?` = signature+key_id+grantee present AND `Signing.verify` crypto-passes for the receiver, independent of the enforce flag.
2. **`CapReissuePolicy` returns a tagged action** `{:reissue, tag}` | `{:refresh_binding, ref}` | `{:quarantine, reason}` — per-class, domain-owned resolvers (identity/workspace/session each own their classes). `granted_by` does NOT determine the recipe (creator-Manage → `{:genesis, creator}`; recipe caps → `RecipeCapBinding.issue_and_upsert/4`, not a bare tag).
3. **Audit scans FOUR durable sources:** caps_json + snapshot identity slice + `recipe_cap_bindings` + quarantine ledger.
4. **CAS = exact byte-identical artifact (incl. provenance)**, not `identity_key` (ABA-unsafe vs revoke+regrant-from-different-issuer).
5. **Two-home heal is idempotent + convergent** (caps_json + snapshot commit separately → partial-apply → audit re-detects EITHER-home-unsigned as unsigned>0 → sweeper re-heals).
6. **Quarantine ledger tombstones** on heal/revoke; `--strict` counts OPEN rows only.
7. **A durable cold-entity sweeper is REQUIRED in Phase 3** (not optional) — backstop for never-activated entities, enqueue failures, partial heals; it's what makes the drain truly automatic.
8. **Enforce-flip needs a durable==live fence** (quiesce/restart or live-slice audit) — post-init snapshot failure keeps state live-only + live authz doesn't re-verify. (Phase 4, lead's, not this build.)
9. **Resolver-coverage gate enumerates the FULL `Cap.issue` surface** (incl. responsibility_assignments, world layout_bootstrap), not just §7; unknown class → quarantine + flagged.
Plus: **quarantine-never-blind-sign** (#154); **reads never write** (§4 decision 3); heal is **lifecycle-triggered, background-executed** (sync-in-activate deadlocks); genesis self-signs via `{:genesis, admin}` (no exemption).

## Phasing (each phase = a sub-step: full `mix ci.local` green + rebased on main before self-merge; Elixir via editor; `MIX_TEST_PARTITION`)
- **P0** — fix future issue-sites + seed-writers: route born-unsigned structural classes AND `Users.create`/`create_read_only` through provable-authority `Cap.issue` / validation so new entities are born signed. Dual-read unchanged.
- **P1** — the reconciler (pure `plan/2` keyed on `signed_and_valid?/2`) + `CapReissuePolicy` registry + background-executed heal (enqueue on activate, post-ready worker re-issues via the existing outbox lane) + exact-artifact CAS + two-home convergence. Retire the EventLog `CapSigningBackfill` (module + test + mix task + gate allowlist + the handoff `dry_run` runbook ref).
- **P2** — `mix ezagent.caps.signing_audit [--strict]` (4 sources, `signed_and_valid?`, both buckets) + the durable quarantine ledger with tombstoning + the enforce-mode fail-loud runtime invariant + the resolver-coverage gate. Hermetic tests throughout (no machine-coupled counts).
- **P3** — canary drain in the isolated canary-data env (throwaway PG, restored dump — NEVER live stacks): the write-path self-heal + the REQUIRED sweeper drain the tail automatically; re-run the audit until `--strict` = 0 (both buckets). Quarantined caps investigated + reported to lead, never force-signed.
- **P4** — manual enforce flip (NOT this build): lead decision, after audit=0 on real canary data + a durable==live fence + a real-canary-data E2E.

## Acceptance
Spec §9 — audit=0 (unsigned-authorizer AND open-quarantine both 0, four sources, `signed_and_valid?` classifier) on real canary data; reads-don't-write proven; quarantine upholds #154; genesis signs no-exemption; double gate holds; a test proves the audit is non-zero on a dual-read fixture `verify_for/2` would call "verified"; hermetic + `MIX_TEST_PARTITION`. Enforce NOT flipped.

## Open question for you to resolve in the impl-plan
OQ-1 (spec §11): re-issue-in-place (identity-preserving, recommended default) vs safe-replace (revoke+regrant) per class — decide per class, in-place default; safe-replace only where the original authority is unresolvable-but-re-derivable from live session/membership state.
