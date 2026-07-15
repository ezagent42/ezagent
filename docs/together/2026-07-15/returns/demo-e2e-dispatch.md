# Return: W29 Demo partial E2E dispatch

> **Task:** W29 Demo P0 — demo-e2e-dispatch
> **Branch:** `feat/demo-e2e-dispatch`
> **PR:** none
> **Dev:** gagameow / Codex
> **returned_at:** 2026-07-15 15:01 +0800
> **deadline:** 2026-07-15 23:59 +0800
> **deadline_status:** deferred

## What was completed

The currently reachable parts of the W29 Demo were exercised on the real canary
surface with the normal user `huang.jiajia@ezagent.chat`:

- authenticated World/Manage/Kanban access via a fresh single-use magic link;
- exact `cc-headless` automatic-materialization failure boundary;
- `cc-headless-deepseek` role materialization, real task dispatch, and SDK-sidecar
  failure transcript;
- real Kanban instance creation plus fail-loud capability checks for board config
  and node creation;
- current Plugins → Kanban configuration surface inspection;
- an existing real PR's head SHA, mergeability, review decision, and PR-head CI
  checks through authenticated `gh` on the developer workstation;
- read-only canary container and database checks for credentials, GitHub tooling,
  and project cwd failures.

No runtime code was changed. No deployment, privilege grant, credential pointer,
PR creation, review, or merge was performed.

Full evidence and reproduction transcript:
[evidence/demo-e2e-dispatch/transcript.md](./evidence/demo-e2e-dispatch/transcript.md).

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | canary 真实路径证据 | met (partial path) | Real World sessions, role materialization, task dispatch, Kanban create, authorization failures, container logs, and DB reads are recorded in the [transcript](./evidence/demo-e2e-dispatch/transcript.md). Full chain remains deferred. |
| 2 | agent-browser 截图和 transcript | met | Four load-bearing screenshots plus the textual [transcript](./evidence/demo-e2e-dispatch/transcript.md). |
| 3 | 真实 PR 链接及 CI/review 状态 | met (seam only) | Existing real [PR #1412](https://github.com/ezagent42/ezagent/pull/1412), head `562df8bfccae3f215da58531da1760d3c6656829`, deterministic gate green, review required. It was not produced by the demo Agent. |
| 4 | Kanban 派发和状态流转截图 | deferred | Real dispatch reached both DeepSeek role agents and failed visibly; a board instance was created, but exact Kanban write cap was denied before card/root/status transitions. Lead must authorize the normal cap-grant flow; no live bypass was used. |
| 5 | 记录每一环结果、阻塞者、复现命令和环境 | met | See transcript sections 1–4 and reproduction commands. |
| 6 | 若修改代码，TDD、相关回归、静态 gate、mix precommit | not applicable | No runtime or test code changed; only return/evidence documentation was added. |
| 7 | dev-together return 标准交接 | met | This return contains metadata, full DoD reconciliation, deferrals, method friction, proof paths, branch/baseline, and merge request. |

**Method friction:** The assigned flow assumed three platform provisions that are
not present on canary: a user-resolvable `cc-headless` credential source, a valid
repository-backed role `project_cwd`, and user GitHub tooling/auth injection. The
follow-up investigation also showed that visibility of Manage/Admin pages and a
legacy workspace wildcard do not prove the exact live Kanban action capability.
These preflights should be explicit gates before a future full demo run.

## Results by seam

| Seam | Result | Blocker |
|------|--------|---------|
| `cc-headless` install | fail-loud / roles skipped | no user-default or workspace-shared `cc-headless` credential source |
| `cc-headless-deepseek` install | roles materialized | deployment API key is usable |
| DeepSeek agent receive | message delivered, both agents replied with SDK error | role cwd directories do not exist |
| Kanban board create | passed | none |
| Kanban config/root/card/status | denied before card creation | current live Identity lacks exact Kanban write cap; dev host also lacks Kanban action |
| GitHub PR facts | passed from developer workstation | canary Agent has no `gh` or GitHub auth injection |
| PR artifact registration | not reached | Kanban write denied |
| Agent-created PR / CI / review / merge | not reached | credential + cwd/repo provisioning + GitHub tooling/auth |

## Branch and verification status

- Worktree: `/home/huangjiajia/ezagent/.worktrees/demo-e2e-dispatch`
- Branch: `feat/demo-e2e-dispatch`
- Canary-test code baseline: `ae5a9bca9b2100cea5214b3c0a4ca513ad4588d7`
- PR rebase base: `ced4195df04341890fd2c9f5332d9cfb054917c5`
- Code PR/CI: none; this is a deferred operational return, not a merge-ready code
  change.
- Documentation verification: `git diff --check` and evidence-file inventory are
  the applicable local gates.

## Deferred follow-ups / lead decisions

1. Choose the user-owned `cc-headless` credential bootstrap model; do not silently
   flow the platform host credential to ordinary users.
2. Define repository provisioning: clone/fetch, allowed storage root, per-task
   worktree/branch lifecycle, and cleanup.
3. Define user GitHub authorization and Agent injection (`gh` installation plus
   OAuth/PAT/GitHub App/SSH ownership and revocation).
4. Grant the normal, scoped Kanban capabilities to the demo owner through the lead
   process, then rerun card creation and status transitions.
5. Rerun the complete chain after those prerequisites are deployed; preserve the
   label “松耦合，非最终挂载（#1360 Layer B 待补）”.

## Merge request

No code merge or deployment is requested. Allen should review this operational
return and evidence, decide the four prerequisite ownership questions above, and
authorize a fresh full-canary rerun. The evidence documentation may be retained on
`feat/demo-e2e-dispatch`; do not merge it as proof that the full E2E passed.
