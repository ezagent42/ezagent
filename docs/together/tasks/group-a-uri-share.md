# Handoff → jjkysy: Group A (URI-share) — codex FIX-NEEDED, fixes + Allen decisions

- **id**: `group-a-uri-share`
- **owner**: jjkysy
- **status**: review
- **历史**: started 2026-07-26 · est_done 2026-07-29 · actual —（07-30 未完 = 已滑期, 不顺延估期）
- **关联**: merged: #1596(A2-1) · #1597(A3) · #1611(A4-1) · #1612(share-config) — 07-29 合入; open 复审中: #1594(A1) · #1606(A2-2) — post-#1621 rebase 后合并就绪核查跑动中; design-first drafts: #1619(A5 匿名) · #1620(A4-2 roster)

codex adversarial review of the 4 merged PRs (#1594 A1 / #1596 A2-1 / #1606 A2-2 / #1597 A3) =
**FIX-NEEDED, merge blocked.** Compile + compose are clean; the blockers are Cap-security. Fix
the must-fixes + apply Allen's design decisions, then it goes back to codex → cc gates + merges.

**The core problem:** the signed share token authenticates grant *intent* but not *who
authorized it*. Claim then resolves the target owner and mints the token's declared actions — so
a valid server-signed token can grant authority its creator never held.

## Allen's design decisions (authoritative)

- **D1** A1 (share-token → claim → mint) IS the *pre-authorized-link* mode, a peer of A3
  (request → owner-approval). The link mode is made safe by **M1**: the token MUST carry an
  issuer identity and mint MUST verify the issuer held the delegable authority (granter ≡
  data_owner). This is a required fix, not optional.
- **D2** **anon claim = unified with user claim; NO separate implementation.** An anon visitor is
  first materialized as a read-only anon entity (`Users.create_read_only`, cookie-bound — the
  existing socialware anon mechanism), then claim proceeds identically to a logged-in user. Move
  `/socialware/claim` off the `RequireEntity`-only path onto one that materializes an anon entity
  first; add a per-share "allow anon claim?" policy flag (business declares it — platform only
  provides the mechanism). anon IS in scope for this batch.
- **D3** Reusable-link vs one-shot is your call. If one-shot, add a JTI/redemption state (there
  is none today; every verify immediately mints).

## MUST-FIX (block merge)

- **M1 [CRITICAL · A1] Bind + verify issuer authority.** `ShareToken.mint_link!/4` is a pure
  signer (issuer-authz only a comment); the token carries no issuer field
  (`share_token.ex:56-92`). `Share.claim/2` passes declared actions straight to `mint_cap/4`
  (`share.ex:42-46`), which uses the resolved target owner as BOTH `target_owner` and
  `configurer` → same-owner branch, consent bypassed (`composition_caps.ex:140-171`, `:296-315`);
  `TargetAuthority.ensure/2` even lets admin mint grant-authority to that owner
  (`target_authority.ex:20-46`). Add an issuer to the signed payload; verify at mint that the
  issuer held the delegable (behavior, actions) authority on the target.
- **M2 [CRITICAL · A1] Mint is not URI-kind-agnostic.** Claim hardcodes `kind: :agent`
  (`composition_caps.ex:140-152`); runtime matches all five axes incl. kind (`match.ex:7-38`), so
  session:// / resource:// tokens verify but produce non-authorizing caps. Derive `kind` from the
  target URI; run the target-conformance validation the generic path has
  (`composition_caps.ex:206-218`) on the claim path.
- **M3 [HIGH · A3] Approval is unauthenticated / stale / unbound.** `request/3` records the
  arbitrary `grantee` arg as source owner+approver with no authenticated requester
  (`composition_consent.ex:174-201`). `decide/4` checks the actor against the request-time owner,
  not the target's *current* owner (`:240-259`). Approval identity is only `(target, grantee)` —
  store behavior + actions too (`:168-178`, `:234-238`) so one approval can't cover broader
  authority than intended.
- **M4 [HIGH · A3] Migration has no shape invariant.** `20260728000000_...:25-48` drops both
  `binding_id` constraints + adds nullable columns with no exactly-one-shape CHECK; changesets/
  commands require neither shape. Add a DB CHECK (binding XOR uri-share) + changeset validation.

## HARDENING (fix or explicitly defer with a note)

- **H1 [HIGH · A2-2]** `grantees_of` is not the promised non-bypassable single-funnel projection:
  reindex is best-effort/​swallows failures (`grantee_index.ex:50-78`), commits before user-cap
  persist (`identity.ex:761-772`), and alternate writers bypass it (recipe reconcile
  `identity.ex:645-665`, legacy revoke `:729-751`). (The security-critical current-generation
  revocation FILTER is correct ✓.) Route all writers through the funnel, or document the
  eventual-consistency + a reconcile.
- **H2 [MEDIUM · A2-2]** `grantees_of(target, behavior)` has no caller/workspace authorization
  (`grantee_index.ex:89-108`) → any in-VM caller who knows a target URI enumerates its grantees.
  Add caller authorization.
- **H3 [MEDIUM · A2-1]** `caps_toward/2` filters only behavior+instance, no signature/current-
  generation verification (`visibility.ex:29-35`), while dispatch verifies against current
  authority (`authorize.ex:44-67`). A revoked cap stays "visible" forward while `grantees_of`
  correctly hides it. Align forward visibility with current-gen verification.

## Per-PR map
- **#1594 (A1)**: M1, M2, D1, D2, D3.
- **#1596 (A2-1)**: H3.
- **#1606 (A2-2)**: H1, H2.
- **#1597 (A3)**: M3, M4.

Re-run codex after the fixes; cc gates + merges on a clean pass. Full original findings + line
cites are on #1583 and each PR's comment thread.
