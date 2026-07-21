# Handoff → jjkysy: #1470 rebased onto green main (2026-07-21)

**What lead did**: rebased your `infra/mount-teardown-provision-deadline` (#1470) onto the latest `main` (`ffcdd7c1e`) — the branch was 38 commits behind (your PR is from 07-19; 14 PRs landed 07-20/21). **Rebase was clean, zero conflicts**; force-pushed. Your 2 commits are intact:
- `unmount_all_for_target/1` — 宿主退场清光名下全部挂载
- 冷建 provisioning deadline — 修 5s 超时崩出孤儿/幽灵

Branch is now **0 behind main / 2 ahead**; CI is re-running on the rebased tip.

**Please do before merge:**
1. **Confirm CI green** on the rebased branch (it re-ran; check `gh pr checks 1470`).
2. **Semantic sanity-check (rebase only resolves TEXT conflicts, not semantics)** — main moved a lot under you today, specifically in areas adjacent to yours:
   - **Read-plane authz** landed (message/attachment reads now cap/membership-gated via `SessionReads`/`AgentReads`/`OperatorReads` chokepoints; PR-5 `InternalReads` gateway for framework-internal reads is in review as #1494). If your teardown/provisioning code does any raw-store reads on the session/mount planes, confirm they go through a chokepoint or the internal gateway (else the new arch gate reds).
   - **member-cap** semantics: at-join now grants a born-signed `cap(:session, Session, :receive, S)`; a cutover backfill exists for legacy rosters. Confirm `unmount_all_for_target` teardown doesn't strand or double-revoke member-caps.
   - **cap-signing Phase F** (`authorize/3` foundation, #1493) merged — additive, no live callers yet, shouldn't affect you, but be aware `verify_against_current` is the new revocation-correct verify.
3. **Merge path**: green + sanity → adversarial review gate (`/codex:adversarial-review` or ping lead) → merge. It's your PR — you own the merge.

Questions → ping lead. The rebase is the only thing lead touched; all logic is yours.
