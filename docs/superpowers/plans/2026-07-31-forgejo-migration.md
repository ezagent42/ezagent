# Forgejo Migration Plan — ezagent off GitHub, onto `code.hyprial.com`

- **Date**: 2026-07-31
- **Status**: PLAN for review — no migration executed
- **Decision owner**: Allen (motivation: GitHub quota running out; ezagent must move to the self-hosted Forgejo; ezagent stays open-source via a core-only public mirror)
- **Scope**: `ezagent42/ezagent` (the umbrella) + `Hyprial/ezagent-deploy`. Plan covers code history, CI, Issues/PRs, the monorepo-vs-split question (#1566), and the stable-release public mirror.
- **Read off**: `origin/main` @ `1f2a804cc`; Forgejo instance probed live 2026-07-31 (version, swagger, runner config, SSH auth). Companion facts: `docs/superpowers/specs/2026-07-29-forgejo-api-probe-findings.md` (#1643), `docs/superpowers/specs/2026-07-24-multi-repo-split-plan.md` (#1566, on branch `docs/multi-repo-split-plan`).

---

## 0. Summary of the recommendation

1. **Migrate the monorepo as-is, first.** One Forgejo GitHub-migration per repo (code + full history + Issues + PRs + tags + wiki), then cut CI over. Do **not** couple the platform move to the #1566 multi-repo split — the split stays sequenced behind the actor-extraction chunks (C4–C7 outstanding) and later executes **on Forgejo** (§4).
2. **Target**: org `ezagent` on `https://code.hyprial.com/` (Forgejo 15.0.5 LTS). The pre-created `ezagent/ezagent` is **empty (0 refs)** — delete it and let the migration API recreate it, because `POST /repos/migrate` creates the repo and is the only path that imports Issues/PRs (§2.2). `ezagent-deploy` migrates too, as `ezagent/ezagent-deploy` (or a separate org — decision D1).
3. **CI transfers almost 1:1** because every ezagent job already runs on the self-hosted macs. The work is: register `forgejo-runner` in **host mode** on the 4 mac runners with the same labels, convert one job (`dispatch-canary`) from `repository_dispatch` — **which this Forgejo does not have** — to the `workflow_dispatch` API it does have, and re-create two secrets (§3, Phase 2).
4. **Open-source mirror = snapshot-per-stable-release, allowlist-based, never full history.** `.gitleaks.toml` itself records that legacy history under `docs/together/**` contains secret-shaped strings pending "history rewrite + rotation" — publishing full history is unsafe until that separate project lands. A release-triggered exporter builds a clean tree from an explicit PUBLIC_EXPORT path allowlist, gitleaks-scans it, and pushes one commit per release to the public GitHub repo (§5).
5. **Rollback is cheap** at every phase: GitHub repos are archived, not deleted; GitHub runners stay registered-but-idle for a grace window; the deploy mac's mirror keeps both remotes (§6).

---

## 1. Facts found (all verified live, 2026-07-31)

### 1.1 The Forgejo instance

| Fact | Value |
|---|---|
| Web / API base | `https://code.hyprial.com/` (Cloudflare Tunnel; `ROOT_URL`) |
| SSH | `git@git.internal.hyprial.com` (**tailnet-only**, A-record → Tailscale IP `100.80.118.8`; SSH auth already works from this machine as `allenwoods`) |
| Version | `15.0.5+gitea-1.22.0` (LTS, supported through 2027-07) |
| Host | `h2oslabs-internal-server` (ARM64 Mac Studio, OrbStack), compose project `~/forgejo` (local copy: `/Users/h2oslabs/forgejo`) |
| Auth posture | `REQUIRE_SIGNIN_VIEW=true` (anonymous API blocked; swagger is public), public registration off, admin `allenwoods` (password in macOS keychain: `security find-generic-password -a allenwoods -s code.hyprial.com`), OIDC login via tsidp (Tailscale identity) |
| Actions | `FORGEJO__actions__ENABLED=true`, `DEFAULT_ACTIONS_URL=https://data.forgejo.org`, LFS server on |
| Target repo | `ezagent/ezagent` exists and is **empty** (`git ls-remote` → 0 refs). No `ezagent-deploy` repo yet. Test repo `gagameow/ezagent-forgejo-test` from the #1643 probe. |

### 1.2 Forgejo runners (already running, on this MacBook's Docker)

`hyprial-forgejo-runner-ezagent-01..05` + `company-01` + one generic — **docker-mode only**, each capacity 1, job containers on an isolated DIND, labels:

```
docker | ubuntu-latest | ubuntu-22.04  → docker.io/library/node:22-bookworm
docker-cli                              → docker.io/library/docker:28-cli
```

Runner cache is **disabled** (`cache.enabled: false` — actions/cache would need a reachable cache endpoint). Job containers get `--memory=4g --cpus=2`, 3h timeout. **No macOS host-mode runner is registered on Forgejo yet** — that is the main missing piece for CI (§3 Phase 0).

### 1.3 What the instance's API can and cannot do (from its own swagger)

- `POST /repos/migrate` — service enum includes `github`; flags: `issues, labels, milestones, pull_requests, releases, wiki, lfs, mirror, private`; `auth_token` = GitHub PAT. **Creates** the repo (cannot import into an existing one).
- **No `repository_dispatch`** — the only dispatch API is `POST /repos/{owner}/{repo}/actions/workflows/{workflowfilename}/dispatches` (`ref` + string `inputs`, optional `return_run_info`).
- `push_mirrors` API — Forgejo can push-mirror a repo outward (to GitHub) on interval: the mechanism for a transition-period backup mirror (§6) — **not** for the public core mirror (it mirrors everything).
- Forgejo Actions supports: `concurrency` (best-effort), `workflow_call` (local reusable workflows), `schedule` cron, `workflow_dispatch` (typed inputs), `services:` containers, `GITHUB_TOKEN`/`FORGEJO_TOKEN` auto-token. Not supported: `repository_dispatch`, GitHub Environments/required-reviewers (deploy.yml already carries its own `confirm=deploy-stable` compensating gate, so nothing is lost).

### 1.4 The repos being migrated

**`ezagent42/ezagent`** (PRIVATE, local checkout `/Users/h2oslabs/Workspace/esr-ng`): ~255 MB, **no submodules, no LFS** → plain-git migration, no special handling. 5,924 tracked files on main (incl. 949 tracked `node_modules/` files and 613 `docs/together/**` files — relevant to §5). **1,542 PRs + 126 issues** (shared number space; Forgejo preserves the numbering on migration), 13 tags, 0 GitHub Releases, wiki n/a.

**`Hyprial/ezagent-deploy`** (PRIVATE, local checkout `/Users/h2oslabs/Workspace/ezagent-deploy`): tiny (68 files), one submodule `.claude/vendor/superpowers → https://github.com/obra/superpowers.git` (public GitHub URL — keeps working post-migration; vendoring it is optional hygiene).

**CI today** (`.github/workflows/` on ezagent main): `ci.yml` (frontend → dockerized gate → sharded full-suite → gitleaks → dispatch-canary), `frontend-ci.yml` (`workflow_call` reusable), `dev-together-return-advisory.yml`, `protect-dev-together-skill.yml`. **Every job `runs-on: [self-hosted, macOS, ARM64]`** — GitHub-hosted minutes usage on main is ~zero; the quota pressure is the plan/seat/storage side, not Actions conversion risk. GitHub self-hosted runners (repo-level, all online): `ezagent-mac`, `ezagent-mac-2`, `ezagent-mac-3` (`self-hosted, macOS, ARM64`) and `ezagent-deploy-mac` (`self-hosted, macOS, ARM64, ezagent-deploy`). deploy repo: `deploy.yml` (self-hosted mac; `schedule` + `repository_dispatch: [main-merged]` + `workflow_dispatch`), `single-domain.yml` (`ubuntu-latest` — maps directly onto the existing Forgejo docker runners).

Cross-repo trigger chain to preserve: ezagent `dispatch-canary` (after full-suite on main) fires `repository_dispatch main-merged` at `Hyprial/ezagent-deploy` with `secrets.DEPLOY_DISPATCH_TOKEN`; deploy.yml deploys canary at `client_payload.sha`. Conversion in §3 Phase 2.

---

## 2. Issues + PRs import — what is kept, what is lost

### 2.1 Mechanism

Forgejo's GitHub migrator (`POST /repos/migrate`, `service: "github"`, or the same via UI "New Migration") imports: full git history + tags, issues + comments, PRs (+ review approvals/comments; PR head refs are stored as `refs/pull/N/head` so diffs render even for deleted branches), labels, milestones, releases, wiki. **Original issue/PR numbers are preserved** — critical here because the codebase, board files, and MEMORY conventions reference `#N` constantly, and issues/PRs share one index space (1,542 + 126 ≈ indices up to ~1670).

Required credentials: a **GitHub PAT with `repo` scope** (passed as `auth_token`; consumed once, then discard/rotate it) and a Forgejo account to own the migration (use `allenwoods` or a dedicated `migrator` PAT with `write:repository` + org create rights).

### 2.2 Known losses / degradations (accept, with mitigations)

| Lost | Impact | Mitigation |
|---|---|---|
| GitHub Actions run history / check statuses | Historic CI evidence unreachable from Forgejo PRs | GitHub org archived read-only, not deleted — history stays browsable at github.com |
| Author attribution | Comments/issues show "original author" annotation instead of binding to Forgejo accounts | Cosmetic. Optional: create the handful of Forgejo accounts (allenwoods exists; bots) before migrating — new activity is what matters |
| Cross-repo references (`ezagent42/ezagent#N` written in deploy repo and vice-versa) | Rendered as plain text/GitHub links | Numbering is preserved, so a mechanical `s/ezagent42\/ezagent#/#/` is possible later; not worth pre-processing |
| Review threads' code anchors on outdated diffs | Some review comments float | Accept — same as GitHub's own behavior on force-push |
| GitHub Projects/boards, repo settings, branch protection, webhooks, secrets | Not migrated | Board truth already lives in-repo (`docs/together/**/board.yaml`). Protection/secrets re-created by hand in Phase 2 (small, enumerated) |
| Open PRs' *branches* vs *PRs* | Migrated PRs are archive objects; in-flight work should not straddle the cutover | Freeze window: merge or park open PRs before Phase 1; re-open stragglers by hand on Forgejo (open PR count is small in practice) |

### 2.3 Scale/robustness

1,542 PRs is well within what the migrator handles (it paginates and respects GitHub rate limits; expect the ezagent migration to take on the order of an hour, server-side). Run it overnight; nothing on the GitHub side is mutated by the migration (read-only). If it fails mid-way: delete the half-created Forgejo repo and re-run — idempotent from zero.

---

## 3. Phased migration plan

### Phase 0 — prove the platform (no freeze, no risk; ~half a day)

0.1 **Decide D1–D3** (§7) — org layout, deploy-repo home, bot accounts.
0.2 **Register a macOS host-mode runner** on one CI mac (dress rehearsal for all four):
```bash
# on ezagent-mac (or -2/-3): forgejo-runner is a single static binary
brew install forgejo-runner   # or download the darwin-arm64 release binary
forgejo-runner register --instance https://code.hyprial.com \
  --token <runner-registration-token from repo/org settings → Actions → Runners> \
  --name ezagent-mac --labels 'self-hosted:host,macOS:host,ARM64:host'
# run it under launchd (NOT nohup — same lesson as the GitHub runners, #215)
```
Registration scope: **org-level** on `ezagent` (one registration serves ezagent + ezagent-deploy + future split repos). The deploy mac's runner adds the fourth label `ezagent-deploy:host`.
0.3 **Verify the two Actions semantics this plan leans on**, with a throwaway workflow in a scratch repo (e.g. reuse `gagameow/ezagent-forgejo-test`): (a) `runs-on: [self-hosted, macOS, ARM64]` (multi-label array) schedules onto the host runner — if the ALL-labels match doesn't behave, fall back to a single `runs-on: self-hosted` label and a one-line edit per workflow; (b) local `workflow_call` (`uses: ./.github/workflows/frontend-ci.yml`) expands. Both are documented-supported in Forgejo 15; verify anyway — this is the only "unknown" in the CI story.
0.4 **Verify mac → Forgejo connectivity path for runners**: the runner long-polls `https://code.hyprial.com` (Cloudflare edge). If GFW flakiness ever hits the CF edge from a runner mac, the fallback is the tailnet path (all macs are on the tailnet; the forgejo container is reachable behind Tailscale node `forgejo`) — do not build this preemptively, just note it as the known fallback.
0.5 Optional (**D6**): enable the runner cache endpoint in `runner-config.yml` if any workflow wants `actions/cache` later; nothing on main uses it today (the gate is docker-cached, full-suite is native) — default: skip.

**Gate to proceed**: 0.3(a) and 0.3(b) green.

### Phase 1 — content migration (freeze window: one quiet evening)

1.1 **Freeze**: announce; merge-or-park open PRs on both repos; stop the nightly deploy cron for the window (it reads GitHub).
1.2 **Delete the empty `ezagent/ezagent`** on Forgejo (Settings → Danger Zone; it has 0 refs, nothing to lose) — the migrate API must create the repo itself.
1.3 **Migrate ezagent** (as `allenwoods`, Forgejo PAT in `$FORGEJO_TOKEN`, GitHub PAT with `repo` scope in `$GH_PAT`):
```bash
curl -sf -X POST https://code.hyprial.com/api/v1/repos/migrate \
  -H "Authorization: token $FORGEJO_TOKEN" -H "Content-Type: application/json" \
  -d '{
    "service": "github",
    "clone_addr": "https://github.com/ezagent42/ezagent",
    "auth_token": "'$GH_PAT'",
    "repo_owner": "ezagent", "repo_name": "ezagent",
    "private": true, "mirror": false,
    "issues": true, "labels": true, "milestones": true,
    "pull_requests": true, "releases": true, "wiki": true, "lfs": false
  }'
```
1.4 **Migrate ezagent-deploy** the same way → owner per D1, `repo_name: "ezagent-deploy"`, same flags.
1.5 **Verify (hard acceptance, §8)**: ref/tag counts match GitHub (`git ls-remote` both sides, 13 tags), issue count 126, PR count 1,542, spot-check `#1566` and `#1643` render with comments and preserved numbers, `main` HEAD SHA identical, clone + `mix compile` from the Forgejo clone.
1.6 **Push local-only state**: the migrator copies what GitHub has. Any local branches never pushed to GitHub (worktree branches in flight) get pushed to Forgejo directly by their owners after cutover — enumerate with `git branch -vv | grep -v origin` per machine. (Deliberately NOT `git push --mirror` from a local clone: the GitHub-side migration is the clean source; the local esr-ng `.git` currently carries tmp-pack garbage.)

### Phase 2 — CI cutover (same window, immediately after Phase 1)

2.1 **Secrets** (the complete list — only two exist):
- ezagent repo (Forgejo): `DEPLOY_DISPATCH_TOKEN` = a Forgejo PAT (scope: `write:repository` on the deploy repo — per the #1643 probe, Forgejo scopes cannot be narrowed per-repo, so mint it on a low-privilege bot account (D3) rather than allenwoods).
- deploy repo: none (grep-verified — `secrets.` appears nowhere in its workflows).
2.2 **Workflow edits — ezagent `ci.yml`** (one job): `dispatch-canary`'s curl changes from GitHub `repository_dispatch` to Forgejo `workflow_dispatch`:
```bash
curl -sf -X POST \
  -H "Authorization: token $TOKEN" -H "Content-Type: application/json" \
  "https://code.hyprial.com/api/v1/repos/<deploy-owner>/ezagent-deploy/actions/workflows/deploy.yml/dispatches" \
  -d "{\"ref\":\"main\",\"inputs\":{\"channel\":\"canary\",\"app_ref\":\"${GITHUB_SHA}\"}}"
```
Everything else in ci.yml (checkout@v4, dockerized gate via `docker compose`, native full-suite, gitleaks-in-docker, `concurrency`, the nightly cron) runs unchanged on the host-mode mac runners. `actions/checkout@v4` / `actions/setup-node@v4` resolve via `data.forgejo.org` (already the instance default); optionally pin them fully-qualified later per Forgejo's own recommendation.
2.3 **Workflow edits — deploy `deploy.yml`**: delete the `repository_dispatch:` trigger block and the `github.event.client_payload.sha` fallback (the dispatch now arrives as a plain `workflow_dispatch` with `inputs.channel=canary, inputs.app_ref=<sha>` — the inputs path already exists). `environment:` is ignored by Forgejo — acceptable because the `confirm=deploy-stable` explicit gate is already the operative stable protection. Update the two SSH checkout URLs and the mirror fetch to Forgejo:
```
git@github.com:Hyprial/ezagent-deploy.git → git@git.internal.hyprial.com:<deploy-owner>/ezagent-deploy.git
~/mirrors/ezagent.git fetch → git@git.internal.hyprial.com:ezagent/ezagent.git
```
(Bonus: the tailnet SSH path replaces the GFW-fragile GitHub path the deploy workflow grew all its armor for.)
2.4 **`single-domain.yml`**: zero changes — `ubuntu-latest` lands on the existing `hyprial-forgejo-runner-ezagent-*` docker runners.
2.5 **Advisory workflows** (`dev-together-return-advisory.yml`, `protect-dev-together-skill.yml`): both shell out to `gh` (7 calls total) against the GitHub API. Convert `gh` calls to `curl` against the Forgejo API (comment-on-PR + label reads — all exist in v1 API), or park them disabled for the first week (they are advisory, not gates). Default: park at cutover, convert within the week.
2.6 **Branch protection on Forgejo `main`**: required approvals + required status check patterns matching the gate jobs (e.g. `gate (deterministic)`, `gitleaks`), push restricted to maintainers — mirrors the GitHub setup; done in repo Settings (or `/repos/{owner}/{repo}/branch_protections` API).
2.7 **Re-register the remaining mac runners** (0.2 recipe ×3, launchd), then **prove the chain end-to-end**: push a trivial commit → gate (mac) → full-suite (mac) → dispatch-canary → deploy.yml fires → canary deploys → browser-smoke green. This is the Phase-2 acceptance.

### Phase 3 — switchover + tooling (days 2–7, no freeze)

3.1 Local remotes: `git remote set-url origin git@git.internal.hyprial.com:ezagent/ezagent.git` on dev machines/worktrees (keep `github` as a second named remote during the grace window).
3.2 **Agent tooling**: the daily driver is `gh` (PR open/review/merge, issue ops) — replace with `fj` (Forgejo's CLI) or `tea`, plus per-agent Forgejo PATs (bot accounts, D3). The coordinator/codex/kimi flows all shell out; this is a prompt/skill update, not code. Note the dogfood angle: #1643 just landed the Forgejo Git Provider — ezagent's own provider work can eventually drive this instance.
3.3 GitHub side: archive `ezagent42/ezagent` and `Hyprial/ezagent-deploy` (read-only; preserves Actions history and old links). Optional transition backup (**D4**): before archiving, configure a Forgejo `push_mirrors` entry pushing to a private GitHub repo for N weeks — zero Actions quota, storage only.
3.4 Retire the GitHub self-hosted runner services on the four macs after one clean week (leave registered-but-stopped until then — instant rollback lever).

### Phase 4 — open-source core mirror (independent; after cutover settles)

See §5. Trigger: first stable release after migration.

### Phase 5 — multi-repo split (#1566), executed on Forgejo

Unchanged in substance, re-homed in mechanism: when the actor-extraction gate clears (C5, ideally C7 — per the split plan's hard rule), each extraction (`git filter-repo` → new repo) creates `ezagent/ezagent-actor`, `ezagent/ezagent-platform`, … under the same org; tag-pinned git deps use the tailnet SSH URLs; per-repo CI reuses the org-level mac runners registered in Phase 0. **The Issues/PR archive stays in `ezagent/ezagent`** (history migrates once, into one place; the split repos start with filtered code history only). The org-level runner registration and the org secrets are the only Forgejo-specific prep the split needs — both fall out of this plan for free.

---

## 4. Monorepo vs split — the call

**Recommendation: migrate the monorepo now; split later, on Forgejo, exactly per #1566's sequencing.** Reasons:

1. **The split is gated and the quota is not.** #1566's own hard rule — no app leaves the umbrella while it holds actor-boundary allowlist debt — has C4–C7 outstanding. Coupling the Forgejo move to that timeline delays quota relief for zero benefit; the two programs are orthogonal (the split plan doesn't care which forge hosts the repos).
2. **Issues/PRs can only migrate cleanly once, into one repo.** The 1,670-index archive maps 1:1 onto the monorepo. Split first and the archive would either fragment or land in a repo that no longer contains the referenced code paths.
3. **Splitting does help the context problem — but it is the #1566 program, not this one.** Allen's concern (large monorepo overflows agent context; concept leak across unrelated edits) is precisely #1566's stated motivation, and its answer — 6 repos along the real dependency DAG, bounded blast radius per change — is the right one. Nothing about Forgejo changes that analysis. What Forgejo *adds*: an org namespace where the 6 repos + deploy live under one roof with shared runners/secrets, and no per-repo quota pressure against creating them. Interim relief before the split lands: sparse checkouts / per-app worktrees for agent sessions (already common practice here).
4. One migration rehearses the mechanism the split will reuse (org, runners, branch protection, per-repo CI shape) on the lowest-risk subject.

---

## 5. Open-source core mirror (GitHub, stable releases only)

### 5.1 Constraint that decides the shape

`.gitleaks.toml` (in-repo, verbatim): historical `docs/together/**` manuscripts contain "secret-shaped strings … handled separately (history rewrite + credential rotation), NOT by this gate". So **full-history publication is off the table** until that rewrite project happens — and the canonical repo's history should **not** be rewritten anyway, because a rewrite would orphan the 1,542 migrated PRs' base/head SHAs. Additionally, main tracks 949 `node_modules/` files and 613 `docs/together/**` team files that have no business in a public mirror.

### 5.2 Mechanism: allowlist snapshot per stable release (fail-closed)

- **`PUBLIC_EXPORT.paths`** (committed, reviewed): an explicit **allowlist** of what the public mirror contains — `apps/**`, `config/**`, `mix.*`, `docker/**` (CI images), selected `docs/` (architecture/GLOSSARY/guides), LICENSE/README. Everything not listed is excluded by construction — an allowlist cannot leak a newly-added sensitive dir the way a blocklist can. Explicitly out: `docs/together/**`, `docs/superpowers/**` (internal plans/handoffs/boards), `.claude/**`, `node_modules/**`, any `priv/**` seed/fixture carrying real identifiers, `.gitleaks.toml` allowlist rationale.
- **Exporter workflow** (Forgejo Actions, on tag `v*-stable` / release publish): `git archive` the tag → apply the allowlist → run **gitleaks over the export** (fail-closed gate, reusing the existing dockerized gitleaks) → commit as **one squashed commit** ("ezagent <tag>") onto the public repo's main → push to GitHub over SSH with a mirror deploy key → tag it.
- **Public repo**: `ezagent42/ezagent` itself, made public *after* it is emptied and re-seeded with the snapshot lineage (keeps the name), or a fresh `ezagent42/ezagent` successor repo — decision **D2**. Zero GitHub Actions run there; quota cost ≈ storage only.
- **Definition of "sensitive/user data"** (the exclusion contract, kept next to `PUBLIC_EXPORT.paths`): anything matching gitleaks rules; team/board/handoff manuscripts; agent/CC configs; deploy credentials or infra endpoints (tailnet names, internal hosts); seeds/fixtures containing real user identifiers, Feishu app/chat ids, or tenant data. The exporter's gitleaks gate enforces the machine-checkable subset; the allowlist review enforces the rest.
- **Later**: if/when the history-rewrite + rotation project executes, a filtered full-history public repo can replace the snapshot lineage; and per the split plan, `ezagent-actor` (R0) is the natural first *true* open-source repo with real history — the snapshot mirror is the bridge until then.

---

## 6. Risks + rollback

| # | Risk | Mitigation |
|---|---|---|
| 1 | `runs-on` array / `workflow_call` semantics differ on Forgejo 15 | Phase 0.3 verifies both on a scratch repo **before** any freeze; fallback edits are one-line |
| 2 | Migration API fails/partial on 1,542 PRs | Read-only vs GitHub; delete Forgejo repo + re-run; run overnight in the freeze window |
| 3 | Runner macs ↔ `code.hyprial.com` path degrades (CF edge + GFW) | Tailnet fallback path exists (all macs on tailnet, Forgejo node reachable); note-only until observed |
| 4 | Canary auto-deploy chain silently broken post-cutover | Phase 2.7 end-to-end proof is a gate; nightly cron re-verifies daily; deploy repo checkout already falls back to cached mirror on fetch failure |
| 5 | Concurrency is best-effort on Forgejo (deploy serialization) | deploy.yml's `cancel-in-progress: false` group is advisory today too; the deploy script's own compose-project locking is the real guard; observe for a week |
| 6 | Secret-history leak via the public mirror | §5 is snapshot-only + allowlist + gitleaks fail-closed; full history categorically excluded until the rewrite project |
| 7 | Forgejo instance is a new single point of failure (it lives on one Mac Studio) | GitHub archives remain as cold copies; optional push-mirror backup (D4); the deploy mac's `~/mirrors/ezagent.git` is a third full copy; instance-level backup (pg_dump + repo volume) should join the existing backup routine — flag to ops |
| 8 | Agent tooling (`gh`) breakage disrupts the dev loop | Phase 3.2 is explicitly scheduled; GitHub stays readable (archived) so nothing hard-fails mid-transition |

**Rollback (any point in week 1)**: flip `origin` remotes back, restart the GitHub runner services (still registered), un-archive the GitHub repos, re-enable the GitHub `repository_dispatch` path (the old ci.yml is in history). Work merged on Forgejo meanwhile is pushed back with a plain `git push github main` — no history divergence because GitHub is frozen/archived during the window.

---

## 7. Decisions for Allen

| # | Decision | Recommendation |
|---|---|---|
| D1 | Deploy repo's home: `ezagent/ezagent-deploy` (one org, shared runners/secrets) vs separate `hyprial` org (mirrors GitHub's Hyprial split) | **`ezagent/ezagent-deploy`** — the GitHub org split existed for billing/visibility boundaries that don't apply on a self-hosted instance; one org keeps runner + secret scope simple. It stays private-in-org either way (Forgejo repo-level visibility) |
| D2 | Public mirror repo identity: reuse `ezagent42/ezagent` (emptied → snapshot lineage) vs fresh repo | Reuse the name — it is the known address of the project; archive-then-replace in one announced step |
| D3 | Bot accounts on Forgejo (dispatch bot, codex, cc/kimi agents): names + which get PATs | Minimum two: `ezagent-ci` (holds `DEPLOY_DISPATCH_TOKEN`) and one shared `ezagent-agents` bot; per-agent accounts can come later. Forgejo PAT scopes are account-wide (per #1643 probe), so low-privilege accounts are the isolation unit |
| D4 | Transition backup: Forgejo → GitHub push-mirror for N weeks before archiving? | Yes, 4 weeks, then remove — costs nothing, buys a warm off-site copy while the instance's own backup routine is being confirmed |
| D5 | Freeze window date + who parks/merges the open PRs | — (calendar call) |
| D6 | Enable runner cache endpoint now? | No — nothing uses `actions/cache` on main; revisit when a workflow wants it |
| D7 | Advisory workflows: park-then-convert (default) vs convert-before-cutover | Park-then-convert |

---

## 8. Acceptance (for the migration as a whole)

1. `git ls-remote` ref+tag sets match GitHub exactly for both repos; `main` HEAD SHAs identical; fresh Forgejo clone passes `mix compile --warnings-as-errors`.
2. Forgejo shows 126 issues + 1,542 PRs with preserved `#N` numbering; #1566/#1643 spot-checks render with comments/reviews.
3. A trivial push to `main` on Forgejo runs frontend → gate → full-suite → dispatch-canary → deploy.yml → canary deploy → browser-smoke, all green, with **zero GitHub involvement** (verified by tailing the GitHub runners: idle).
4. PR flow on Forgejo: open → gate required-check blocks merge until green → merge — proving branch protection parity.
5. First post-migration stable release produces a public GitHub snapshot commit that passes gitleaks and contains only `PUBLIC_EXPORT.paths` content.
6. GitHub repos archived; four launchd-managed forgejo-runners online; GitHub runner services stopped.
