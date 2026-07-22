# PR ledger — 2026-07-22

Durable record of every PR forwarded to the coordinator (cc) + its disposition. Process
(Allen 2026-07-22): **a forwarded PR is reviewed by a SUBAGENT first**, then the coordinator
gates + merges. This ledger is the source of truth for "what's the status of each PR."

## Forwarded teammate PRs

| PR | Author | What | Status | Handling |
|---|---|---|---|---|
| **#1445** | gaga | Git Provider V1 — domain spine + connection framework + GitHub OAuth→App plugin | ✅ MERGED | Reviewed; folded #1509's GitHub App auth in (Allen deleted the OAuth App); regenerated `LegacyDynamicReceiverBaseline`; allowlisted the RS256 `private_key` substring. **Latent cost:** its `after_boot` direct registry calls tripped the mac-only plugin-check → later fixed in #1519. |
| **#1476** | zyli | feat(world): plugin-owned UI surfaces | ✅ MERGED | Did the full **(b) PresenterCaps-DI refactor** to root-cause the layering (not a patch); mix-task exemption for plugin-check #7. |
| **#1499** | ruihuachen | docs(ciia): 信息协会产品展厅 demo | ✅ MERGED | Checked, merged. |
| **#1513** | gaga | fix(pty): redact cmd_env secrets from OTP crash reports | ✅ MERGED | Reviewed; **added the missing regression test**; oversized-modules baseline bump. |
| **#1508** | zyli | Kanban detail workbench polish + World Manage/Admin nav fix (`push_navigate` for `/overview` `/admin` `/admin/*`, `push_patch` for ordinary World) | ✅ MERGED (`cf50753cf`) | Opus adversarial review: nav split **SOUND** (`push_patch` can't cross the `live_session` boundary; predicate exactly matches admin membership; no misroute/open-redirect). Gate red was **stale-base + the nav's +1 line shifting 59 line-anchored baseline sites** → rebased onto main + regenerated the baseline from the scanner's ground truth (no product change). @zyli notified. |

## Coordinator (cc) PRs today — context (my own work)

| PR | What | Status |
|---|---|---|
| #1507 | cap self-target `action_context` consults instance behavior set (greeter relay crash fix) | ✅ MERGED |
| #1510 | ci: protect-dev-together-skill guard handles >300-file PRs (pagination) | ✅ MERGED |
| #1514 | docs(todo): #1445 auth hardening follow-ups + business-code extraction | ✅ MERGED |
| #1516 | arch: reconcile PluginWorkspaceLocality baselines after #1476+#1445 | ✅ MERGED |
| #1517 / #1518 | docs(todo): socialware market (added, then corrected — backend exists, product surface is the gap) | ✅ MERGED |
| #1519 | **main-red fix #1** — github plugin declarative registry ownership (plugin-check gate) | ✅ MERGED |
| #1520 | **main-red fix #2** — drop 3 stale `LegacyDynamicReceiverBaseline` entries after #1519 | ✅ MERGED |
| #1521 | docs(ledger): this PR ledger | ✅ MERGED |
| #1522 | **ci(full-suite): shard the monolith** into re-runnable legs (parity-proven, sequential; `__ENV__.file` arch-gate fix) | ✅ MERGED |
| #1523 | fix(hooks): sub-step-gate skips commits targeting a non-esr-ng repo | ✅ MERGED |
| **#1524** | **hello-A de-hardcode PR-1..3** (官网 → `ezagent-official` in ezagent ws) — kimi/fable-implemented, **opus adversarial review SOUND** | ✅ MERGED (`ba04e931c`) |
| **#1525** | **PR-5 socialware market surface** (browse/install + 上架/下架, #165 admin-gated) — kimi/fable-implemented, **opus §15.3 security review SOUND** | ✅ MERGED (`b36809e6b`) |
| cc-openclaw **#29** | feat(hooks): pr-auto-record — auto-capture forwarded PRs to the day's together inbox | ✅ MERGED |

## In-flight / handed off

| Item | State |
|---|---|
| **#195 unified-revocation** (#1503, Phase M/S) | **Handed to codex** (Allen; kimi ran out of quota). Git side: PR #1503 OPEN, last commit `d5bc0de33` (S-2) — no new commits pushed since codex took over (codex reported ~97% internally, not yet on the branch). cc reviewed the earlier F/G/D phases (`195-fgd-review-for-kimi.md`). cc NOT tracking codex's live progress. |
| **hello-A PR-4** (deploy migration) | DESCRIBE-ONLY, **coordinator-gated** — not executed. §12's 5 steps, canary→beta→stable. MUST-VERIFY precondition (review): a real non-admin founder / `lin_yilun` must exist as a user (+ `add_member`) per-node BEFORE cutover, else the 官网 silently never provisions. |

## Known main state (end of 2026-07-22)

- main (`ba04e931c`): **gate (deterministic) green** through both deliverables. Full-suite is now **SHARDED** (#1522) — it stays red only on the `e2e` shard's ONE deterministic failure `EzagentPluginKb.E2E.AutoserviceTier1SeedTest` (spawned manifest-installer GenServer can't persist in the E2E sandbox — `DBConnection.OwnershipError`; **pre-existing, NOT from any of today's work** — verified the persist fn is pre-existing). Blocks the deploy dispatch (`needs: [full-suite]`) until fixed; deferred to todo.
- `world/ConversationActionsTest` `bindings == []` + `kind_provenance` = confirmed transient sandbox flakes (cleared on re-run).

## Deferred → `docs/futures/todo.md`

Auth hardening (#1514); business-code-out-of-core; **~~socialware market product surface~~ → DONE (PR-5 / #1525)**; **sandbox-ownership E2E fix** (AutoserviceTier1SeedTest + the ConversationActions/kind_provenance flake class — async processes need `Sandbox.allow`/`{:shared,pid}` inheritance — this is what blocks the full-suite/deploy gate); **PresenterCaps session-staleness** (review should-fix: a mount-time bootstrap admin cap snapshot survives a mid-session demotion, so a demoted admin retains publish/admin rights until re-login — pre-existing, repo-wide for ALL world admin actions, not a PR-5 regression).
