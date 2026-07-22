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
| **#1508** | zyli | Kanban detail workbench polish + World Manage/Admin nav fix (`push_navigate` for `/overview` `/admin` `/admin/*`, `push_patch` for ordinary World) | 🔵 OPEN — under review | `gate` currently FAILING, but branch last updated 10:17Z (BEFORE the #1516/#1519/#1520 main-red fixes) → likely **stale-base inherited red, not its own defect**. **Subagent review in flight** (per subagent-first rule); expected plan = rebase onto current main → re-run gate → merge if green + review-clean. |

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

## In-flight (not PRs yet)

| Item | State |
|---|---|
| **hello-A epic** (spec `spec/hello-A-de-hardcode`, PR-1..4 migration + PR-5 market surface) | Spec finalized + adversarially reviewed (fixes folded). **Handed to kimi** (Allen dispatching); expect branches `feat/hello-A-de-hardcode` + `feat/socialware-market-surface` back → cc gate + review + merge. |
| **CI sharding** (split monolithic full-suite → re-runnable shards; sequential parity first, parallel later) | **Subagent in flight** (branch `ci/shard-full-suite`) → cc review + merge. |
| **#195 unified-revocation** (Phase M/S) | Allen driving via kimi. cc reviewed prior phases (F/G/D) → `195-fgd-review-for-kimi.md`. |

## Known main state (2026-07-22)

- main (`1ed5c739a`): **gate green; github/invariants/socialware green.** Full-suite still red on ONE deterministic E2E failure — `EzagentPluginKb.E2E.AutoserviceTier1SeedTest` (spawned manifest-installer GenServer can't persist in the E2E sandbox — `DBConnection.OwnershipError`). **NOT** caused by my changes or #1445 (verified: the persist fn is pre-existing). It blocks the deploy dispatch (`needs: [full-suite]`). Deferred to todo (sandbox-ownership E2E fix); the CI-sharding work will isolate it into a re-runnable shard.
- The `world/ConversationActionsTest` `bindings == []` failure is a confirmed transient sandbox flake (cleared on re-run).

## Deferred → `docs/futures/todo.md`

Auth hardening (#1514); business-code-out-of-core; socialware market product surface; **sandbox-ownership E2E flake/failure fix** (AutoserviceTier1SeedTest + the ConversationActions flake class — async processes need `Sandbox.allow`/`{:shared,pid}` inheritance).
