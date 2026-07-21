# Carryover → 2026-07-22 (recorded 2026-07-21 evening, Allen resting)

## Needs Allen (human action)
- **Create the `ezagent-git` GitHub App** — deferred to 2026-07-22. Use the one-click file lead sent: `create-ezagent-git-app.html` (pre-filled: name `ezagent-git`, 3 callbacks `https://{canary,beta,app}.ezagent.chat/github/callback`, webhook `app.ezagent.chat/github/webhook`, least-priv perms contents+PR write / checks+metadata read). Open it → GitHub confirm page → Create → hand lead `app_id` + a generated private key + `client_secret` + `webhook_secret`. Full spec: `plans/github-app-ezagent-git.md` (branch `docs/github-app-ezagent-git`).
  - One GitHub App covers all 3 envs (up to 10 callback URLs). The canary **OAuth App** Allen already made (`Ov23liM6…`) works for canary #1445 testing in the meantime; OAuth secret goes in **ezagent-deploy secrets**, and **rotate it for prod** (it was posted in-channel).

## In-flight (lead driving autonomously overnight)
- **#195 unified generation-revocation** — kimi self-driving on PR **#1503** (F→G→D→M→Z). Lead's done-loop watches for the `[DONE]` title → then cc+codex adversarial review + merge. Phase-0 resolution + Allen's 3 product decisions folded (supervisor=per-session reviewer-member; delete_user=agents-revoke + structural-resources-transfer-to-workspace-owner; all-rejoinable via grant-only-join).
- **Merge queue** (gate now reliable after the #1506 CPUSET fix): ✅ merged today `#1505` (hello 官网 self-heal seed), `#1504` (ci.fast + skill rule), `#1500` (ratchet gate), `#1502`+`#1506` (dockerize + concurrency fix), `#1493`/`#1494`/`#1495` (read-plane + F-1 + demo_smoke), `#1477`. Pending:
  - `#1476` (rebased onto fixed main + pushed, gate re-running).
  - `#1445` — the 4 must-fixes are DONE + force-pushed (`2ba826189`): ratchet `authorizing_cap` dropped/grantee-binding kept (ratchet GREEN + companion `cap_verify_load_boundaries_test` updated), gitleaks 0 (placeholders redacted + doc paths allowlisted), credential fail-loud, rebase + `mix.lock req 0.6.3`. Verified DomainGit 155/0, GitHub plugin 63/0, credential 15/0. **BUT 4 more pre-existing baseline-gate collisions remain (NOT from the fixes — proven net-zero-new): `PluginWorkspaceLocalityContractTest` ×2 (branch's new github/cc/codex/feishu plugin sites not in frozen baselines), `DatabaseAgnosticGuardTest`, `UriCanonicalizationInvariantTest`.** → **gaga must register his branch's new sites in those 4 frozen baselines** (delicate enumerate-the-worklist gate work) before #1445 merges. The ratchet/CapBAC diff also wants a review-gate pass (lead or codex).
  - `#1497`/`#1501` — 43 behind → authors must rebase; **#1501's "fixes 41≠39" is efficacy-UNVERIFIED** in review — don't rush.

## Open leads / follow-ups
- **greeter-relay bug (unconfirmed):** a member `:send` succeeds but the greeter relay crashed on `{:unknown_action, :hello_sync_result}` (a HelloOrchestrator action → **hello-component** issue, NOT the 官网 session). Seen only in a harness. **Confirm on canary as a logged-in member;** if it reproduces, open a separate hello-component greeter-relay bug. (Anonymous cold-reply is a NON-goal — hello page is view-only for anon, confirmed with Allen.)
- **CI:** 3 self-hosted mac runners deployed (`ezagent-mac`, `-2`, `-3`); dockerized gate un-pinned so concurrent runs spread across all 28 cores. Safe to scale to **5 runners** now (verified 3×/5× concurrent green) — do it if the queue backs up again.
- **#1482** (populated-DB restart `{:already_registered, workspace://system}`) resurfaced in the hello-seed harness — still open, triage.
- **Board** (`board.yaml`/`board.html`) to be integrated at end-of-cycle per Allen (not refreshed today).

## Allen's own track (from today)
- 对接信息协会 Feishu / 整理创业教具方案 / (ruihua) 信息协会 demo 方案 — his planned items.
