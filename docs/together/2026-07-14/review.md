# dev-together review — 2026-07-14 (lead close)

**One-line:** the day pivoted hard from the planned tracks into an unplanned but high-value **CapBAC line** — a workspace-admin→global-admin escalation was found and closed, then Phase-4 ed25519 capability signing was designed, codex-built, coordinator-accepted, and merged to main (dual-read) — plus the demo's Hello↔Kanban fusion landed. The plan-vs-actual divergence was security-driven and is the headline.

## §1 What landed (merged to `main`, 2026-07-14)

| area | PRs | who |
|---|---|---|
| **Security (create_user escalation + PTY authority)** | #1379 (create_user no longer a "cap-from-string" oracle), #1375 (terminal belongs to creator + cross-workspace terminal peek hole + #1366 backfill), #1381 (cap-issue gate honest hardening + boundary test) | **gaga** |
| **AgentRuntime boundary + LiveAuth cap-visibility hotfix** | #1402 — only-decrease `agent_runtime_boundary` arch gate (Session-domain calls into Agent lifecycle) + adversarial bypass tests (qualified/alias/import/grouped-alias); **LiveAuth now reads Ed25519-verified live Identity caps** (`Identity.read_entity_caps` → `Cap.verified_set`) instead of stale `users.caps_json` — fixes a real canary bug where a runtime-granted creator cap was invisible in Web/Terminal auth (dual-read-safe: unsigned caps still authorize) | **gaga** |
| **cbac Phase-4 ed25519 signing** | spec #1382; codex build stacked into `feat/cbac-phase4-ed25519` (#1385/#1387/#1390/#1391/#1392/#1393/#1395/#1397/#1398); grantee-binding; feat→main merge **#1399** (dual-read `require_signature:false`) | **allen** (lead spec/accept; codex build) |
| **Demo path (W29)** | #1383 Hello↔Kanban loose-coupled fusion (public/anon entry + one-time login continuation + Hello Dispatcher + 派活 chain) | **zhaomato** |
| **UI fix** | #1389 Session Bindings/Routing tab click handlers | **zyli** |
| **Architecture docs (lead track)** | #1394 entity-caps scoped plan+handoff; #1400 cap-signing no-tail finding+handoff; #1401 handoff amend; #1380 lead track | **allen** |

(Note: PRs authored as `allenwoods` in the cbac stack #1385-#1398 are codex dev-agent commits under the lead track; #1382/#1394/#1400/#1401 are lead-track docs.)

## §2 Accounting (plan vs actual — two sources: no `returns/` dir today, reconciled from GitHub merges + chat returns)

- **Planned tracks (2026-07-14 plan §5):** zyli 前端CI · gaga AgentRuntime SPEC+creds · zhaomato hello E2E+融合 · jjkysy 检查补位+#1360形式化 · ruihua 飞轮接入 · allen #1376裁定+cbac Phase-4.
- **Actual:** the day was dominated by an **unplanned CapBAC security+signing line** (gaga's #1379 escalation find → coordinator Phase-4 spec → codex build → merge) that pulled in the lead + codex + gaga. Of the planned tracks: zhaomato **hit** (fusion #1383 + demo path); zyli shipped a UI fix (#1389) not the frontend-CI track; **gaga delivered BOTH** — the security triage (#1375/#1379/#1381) AND the planned AgentRuntime boundary gate (#1402), the latter also carrying a canary-found LiveAuth cap-visibility hotfix; jjkysy's #1376 was **held** (superseded); ruihua's #1378/#1388 are **pending/WIP**.
- **Held / not merged:** #1376 (jjkysy mount — superseded by entity-caps, held draft), #1374 (kanban, stacked on #1376, held), #1378 (ruihua, CONFLICTING — needs rebase), #1388 (ruihua DealScout WIP), #1386 (grantee-binding docs, open).
- **No `returns/` dir** today — devs returned via chat/PR-description; reconciled from `gh pr list --state merged`.

## §3 Quality & risk

- **Real security hole closed:** workspace admin could mint a global-admin cap (#1379). Root cause is deeper (source-scan can't prove a runtime property) → the structural fix is Phase-4 signing (a forged cap is cryptographically inert at the gate).
- **Phase-4 landed dual-read (`require_signature:false`) — deploy-safe:** signing happens, not enforced; existing caps still authorize; crypto proven 22/0; **zero schema change** (signature lives in `caps_json` JSON).
- **⚠ Enforce is NOT ready — caught by real-data E2E.** Restoring the canary DB into an isolated stack and running the backfill dry-run showed it signs only **6/196** real caps (189 quarantine: malformed/missing grant events, unsupported shapes). The unit tests were green (22/0 on clean fixtures) but missed this. Enforce stays off; a "no-tail" re-provision-signed pass is handed to codex to investigate. **This is the day's most important risk catch.**
- **Coordinator process risk (owned):** the entity-caps design went through 2 codex NEEDS-REVISION rounds with repeated false code premises before an advisor-guided stop → read the code → re-scope from a grand unification to a scoped patch. Corrected in-flight; no bad code shipped.

## §4 Method deltas (Act — promote, not just collect)

1. **NEW rule → process-debt (owner: lead):** *any change to a security/authorization invariant or a data migration must get a real-canary-data E2E before enforce/flip is considered.* Green unit tests on clean fixtures are necessary, not sufficient — the 6/196 backfill gap only appeared on real data. (Would have caught: an over-optimistic "backfill signs everything" assumption.)
2. **Reinforced rule ([[feedback_doc_why_must_be_code_verified]] / reproduce-before-benchmark):** *read the code before speccing behavior; do not outsource code-reading to the reviewer.* The entity-caps spec-thrashing (3 false premises: "agents have no durable store", "activation overwrites", "migrate push→pull") all came from asserting code behavior unread. Rule already exists — the lapse is the signal; the fix that stuck was calling the advisor to stop the loop.
3. **Reinforced rule ([[feedback_subagent_worktree_wrong_repo]]):** *verify `git remote -v` before push/PR from a scratchpad worktree* — the cbac spec was authored in a cc-openclaw worktree and nearly PR'd to the wrong repo (caught by "all sibling specs live in esr-ng"). Memory updated.
4. **Confirmed-good pattern:** empirical differential testing (re-issue → audit unsigned = find bypass paths, lead's idea) beats code-audit — folded into the cap-signing investigation handoff.

## §5 Suggestions for 2026-07-15

- **Sequence the W29 demo end-to-end at least once** — Hello↔Kanban fusion (#1383) landed; the missing leg is 派活→平台 agent 出 PR→合→看板流转. Ownership: **gaga** tests the demo path → **allen** verifies → **ruihua** polishes from the product angle. (jjkysy likely unavailable tomorrow.)
- **gaga: AgentRuntime boundary landed (#1402, merged);** next = ARB-2~5 存量迁移 + the deferred LiveAuth/caps audit items — **⚠ coordinate the "EntityCaps 持久化统一" item vs codex's entity-caps D so they don't both edit the cap-persistence surface.**
- **bridge-join is NOT a demo blocker (routed around, not forgotten):** the acute half (create-timeout + @orchestrator-mute) was fixed (#1294, canary-proven #1367); the residual cc-PTY bridge-join slow-activation is bypassed by cc-headless (`:in_process_sync`, no bridge-join risk). Deferred as a cc-PTY-specific latent item (fix only when real PTY agents go to prod). Demo runs on cc-headless.
- **Await codex's two returns** (entity-caps A/B/D; cap-signing no-tail findings doc) → lead accepts + decides the re-provision-signed build + enforce timing. Enforce stays off until an audit proves 0 unsigned authorizer caps.
- **ruihua: rebase #1378** (CONFLICTING) → lead merges; continue #1388.
- **Process:** adopt §4 rule 1 (real-data E2E before any auth-invariant/migration enforce) as a standing gate.
