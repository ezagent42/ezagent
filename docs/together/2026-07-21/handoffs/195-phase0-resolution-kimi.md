# #195 Phase-0 Resolution & GREEN-LIGHT (for kimi)

Your Phase-0 grounding is confirmed — high quality. Every gap + decision is resolved below. After reading this: **set your goal and run F → G → D → M → Z end-to-end, self-driven, no more Phase-0 halts.**

## Source plans — AUTHORIZED
The 3 delegated source plans are reviewed (34 / 24 / 22 codex/MF markers) and landed on branch `docs/195-source-plans`, SHA-pinned matching your report (membership `e324abe8`, delete-user `53d7966b`, epoch `9ce0c88b`). Pull them into your worktree:
```
git fetch origin docs/195-source-plans
git checkout origin/docs/195-source-plans -- \
  docs/superpowers/plans/2026-07-20-membership-cap-as-truth-implementation.md \
  docs/superpowers/plans/2026-07-20-delete-user-invalidation-implementation.md \
  docs/superpowers/plans/2026-07-20-epoch-revocation-implementation.md
```
Authoritative for M-2..M-9/S + D-3.

## Coordinator-confirmed mechanism (execute as written)
- **Gap 2 (re-mint):** standalone-revoke → normal `Token.mint` REJECTED; ONLY a genuine recreate/reprovision (`create_freshness == :created` + proper authority) mints under the new generation. No general re-mint after a bump.
- **Gap 3 (D order):** D-5's durable-fence schema/API/enforcement foundation lands BEFORE D-2 (`D-1 → D-5-foundation → D-2 → D-3 → D-4`). D-2's cascade consumes the fence.
- **Gap 4 (F-6 holder):** add `ctx.authenticated_principal`, set at the external boundary; machinery forwards it EXPLICITLY; NO fallback to `ctx.caller`. Only a genuinely-autonomous internal principal may use its own URI.
- **Gap 7 (uploads):** the uploads path on current main is a grantee-bound download token (equality) — do NOT force `authorize/3` onto the serve-time equality. Keep the token binding; wire the unified auth at token MINT + `SessionReads` + the legacy attachment participant path.
- **Verifier delegation → fold into F-2** (deferred by #1493). **Decision #7:** composed seams. **Decision #8:** join cursor = monotonic sequence (NOT timestamp).

## Gap 5 (owner structural bypass) — REMOVE, but ONLY paired (critical)
The bypass is real and pinned: `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex:997` (`caller == owner_uri` OR cap-check), `.../session/membership_predicate.ex:103` (`owner?/2 = owner == caller`), `.../behavior/socialware_publisher_read.ex:68/195`. A generation-bumped owner passes `caller == owner_uri` and **bypasses the generation gate**. Remove these structural short-circuits so the owner branch runs the holder/self-license gate like everyone else.

**MANDATORY pairing — do NOT remove the bypass without BOTH, or you recreate the member-cap lockout (now for owners):**
1. At session creation, grant the owner a **born-signed tier-1 member cap** (guaranteed) so the owner always authorizes through the cap gate.
2. **Backfill existing owners** with that cap (same pattern as the read-plane member-cap backfill).

## Product decisions (Allen — RESOLVED)
1. **Supervisor (Decision #5 / S-2):** supervisor = a **per-session reviewer-member** (Option 1/1a). Confirmed — implement S-2.
2. **delete_user cascade (Decision #10B / gap 6):** delete_user gen-bumps ONLY the user's owned/lineage **agents** (revoked). Do NOT gen-bump shared session/workspace/forked-template. **INSTEAD, TRANSFER OWNERSHIP** of the deleted user's owned **session / workspace / forked-template** to the **workspace owner** — the resources survive and other members keep access; only the deleted user's ownership moves. Rule:
   - session & forked-template owned by the deleted user → transfer `owner_uri` to the owner of the **workspace they live in**.
   - a **workspace** owned by the deleted user → transfer to **admin** (system authority — there is no higher workspace owner).
   - if a transfer target is itself being deleted in the same cascade → transfer up to admin.
   This makes delete_user two-mode: **agents = revoke (gen-bump)**, **owned structural resources = re-own (transfer)**. The derivation-edge closure (D-1) must classify each descendant into revoke-vs-transfer. Verify against the real ownership model; if a resource kind's transfer target is ambiguous, apply this rule and note it in your report.
3. **Rejoin (MF8):** **ALL cases are rejoinable** — DROP membership on BOTH voluntary leave AND delete/offboard. **NO EJECT, NO durable rejoin bar** — remove that mechanism entirely (Allen: non-rejoin has no product necessity and only adds protection surface). **Security invariant that keeps this safe (must hold):** join is strictly **grant-gated** (grant-only join, M) AND reconciliation requires **CURRENT entitlement** (M-10, a live cap — never a stale roster/replay). So a dropped member cannot self-rejoin; they rejoin only when someone grants them again. Removing the durable bar does NOT open a rejoin hole *because* grant-only-join + current-entitlement-reconciliation already close it — keep those two airtight.

## GREEN LIGHT
All Phase-0 gaps resolved. Set your goal; run F → G → D → M → Z to completion. cc + codex run the adversarial review + pre-merge gate on your hand-back. The security-critical properties we will verify (build tests that fail-before/pass-after for each): revoke denies old-gen caps (both axes); self-license un-re-mintable (+ the marker-preservation enumerator gate); **owner has NO structural bypass** (owner authorizes via cap); membership == holds-cap with current-entitlement reconciliation (no stale-roster re-add); delete_user = agents-revoked + structural-resources-re-owned; and the Z-1 enumerator empty-allowlist (note: cc has landed a RATCHET precursor of Z-1 on `feat/anti-bypass-ratchet-gate`/#1500 — consume + zero it, do not build a second gate).
