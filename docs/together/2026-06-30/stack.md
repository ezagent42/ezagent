# 2026-06-30 Dev-Together Push / Close Stack

Date: 2026-06-30
Lead: linyilun / Codex
Source of truth for this push: Feishu merged-forward return messages + GitHub PR state on 2026-07-01.

## Reconciliation

| Return / PR | Owner | Scope | Status | Reason |
|---|---|---|---|---|
| #1106 `T1: AutoService answer-soul GREEN e2e` | gaga | AutoService seed verification + seed-only fixes; socialware chat render; world session-name input guard | stacked | CI green, mergeable, direct DoD evidence. No core/domain architecture rewrite; changes are seed/plugin/input-layer. Needs review for scope creep because two side fixes ride along. |
| #1105 `feat(world): add admin user management UI` | zyli | Admin user creation/edit/reset/disable/enable in World UI + disabled-user metadata | stacked | CI green, mergeable, production-enabling for dev-team account management. Touches identity/domain + migrations + World UI, so must merge before larger World UI refactors. |
| #1103 `feat(website): 官网 demo 内容 + 暗黑玻璃原型 v2` | ruihua | Website design/demo docs, Cases/dogfooding metrics drafts, 0630 design returns | stacked as design asset, not deployment code | Draft but CI green and docs/demo isolated. Conflicts with #1107 in `docs/website-demo`; should either merge before #1107 or be explicitly superseded with copied design artifacts. |
| #1107 `feat(website): T4 官网框架 + hello 渲染 ruihua 官网支撑` | zhaomato | Runtime hello-site support script, static assets, docs/website-demo updates | blocked pending #1103 decision/rebase | CI green and mergeable now, but overlaps #1103 heavily. Merging in the wrong order can drop design docs or force manual conflict resolution. Also production page state is DB/runtime, not in PR. |
| #1104 `docs(world): add June 30 UI redesign prototype` | zyli | World IM redesign prototype plus live World UI refactor, loading skeleton, deadline fix, screenshots | blocked pending dedicated UI review/rebase | CI green, mergeable, but scope expanded from prototype to large production World UI rewrite and overlaps #1105/#1020 World surfaces. Needs human visual review and branch refresh after safer PRs. |
| #1020 `feat(kanban): team dev flow` | jjkysy | Kanban-driven dev workflow, PM/dev recipes, CLI verbs, GitHub plugin, World nav/surfaces, domain agent materialization | blocked / next-day architecture close | CI green, mergeable, but very large cross-tier change touching core/domain/plugin/CLI/World. It includes useful architecture follow-ups, but should not be merged in the same close batch as #1104/#1105 without a focused architecture review. |
| #1112 `T2: Agent Console completeness 复核收口与 IA 设计梳理` | fatnine | Agent Console completeness review, F1-F6 evidence, remaining gap classification, IA prototype/design direction | late 0630 return / open | CI green. Return arrived after the initial close ledger. It reframes the remaining Agent Console work: F1-F6 are small fixed/validated gaps; the main remaining gap is session delete/archive and broader IA/UX design, not another batch of small fixes. |

No return file existed in the local checkout at `docs/together/2026-06-30/` before this push. The returns existed in PRs and Feishu. This is a process gap: dev-together should require each developer to land a return artifact in the PR branch and the lead should pull those artifacts into the local ledger before close.

## Quality And Risk Analysis

### #1106 AutoService

Quality:
- Strongest DoD evidence in the batch: natural customer question, live cc/Sonnet run, KB retrieval, screenshot, logs, DB evidence, and cleanup note.
- The important architectural result is negative-space useful: current architecture works; the previous failure was seed/config/persona/session-manager wiring, not a need for core dispatch changes.
- The implementation stays out of core/domain architecture for the AutoService path; the seed now follows the existing orchestrator-session mechanics instead of adding a new dispatch path.

Risks:
- The PR includes two opportunistic fixes outside the core AutoService objective: socialware chat legacy-node normalization and World session short-name validation. They are valid but should be called out in merge notes because they expand blast radius.
- The bridge `10042` finding is documented but not fixed generically. Follow-up: derive default `EZAGENT_BRIDGE_WS_URL` from `PORT` or runtime endpoint config instead of relying on operators to run on 10042.

Verdict: merge early. It validates the architecture, fixes the seed, and avoids core leakage.

### #1105 Admin User Management UI

Quality:
- Directly supports the production bootstrap need: create and manage dev-team users from the UI instead of ad hoc backend provisioning.
- Includes migrations for SQLite/Postgres, backend tests, UI tests, and browser evidence.
- CI green.

Risks:
- Touches identity behavior and auth-blocking semantics. The disabled-user path must be treated as security-sensitive.
- Overlaps #1104 in `Identities.tsx`, `main.tsx`, World routes/data. Merge before #1104 so the UI refactor rebases on the production user-management shape.

Verdict: merge after #1106, before World UI refactors.

### #1103 Website Design Assets

Quality:
- Docs/demo isolated, deliberately rebased onto clean main to avoid reverting older DS/spec work.
- Captures design direction, website priorities, dogfooding metrics draft, and Cases variants. This is process/design memory, not just static HTML.

Risks:
- Draft PR. If merged as-is, lead should mark ready first and note that it is a design asset close, not production deployment.
- Overlaps #1107 on `docs/website-demo`. If #1107 merges first, #1103 becomes conflict-heavy and some design artifacts may be lost unless copied.

Verdict: merge as design archive before #1107, or explicitly mark #1107 as superseding it after verifying all design artifacts were carried. Recommended close path: merge #1103 first.

### #1107 Website Hello Support

Quality:
- CI green and mostly isolated to docs/static assets plus `scripts/refresh_hello_site.exs`.
- Useful bridge from design demo to a real hello page backed by GitHub data.

Risks:
- Runtime page itself is DB state and not in PR, so merging code does not by itself prove production is updated.
- Heavy overlap with #1103. Needs rebase after #1103 and a short smoke of `scripts/refresh_hello_site.exs` against a non-prod target or documented dry-run.

Verdict: defer until after #1103 merge/rebase. Do not merge in same blind batch.

### #1104 World UI IM Refactor

Quality:
- CI green, extensive screenshots, live evidence, and a clear prototype artifact.
- Addresses the product issue Allen raised: current UI is far from IM expectations.

Risks:
- The title still reads like docs/prototype, but the diff includes a production World UI rewrite and a domain workspace deadline fix. That mismatch is a review smell.
- Overlaps #1105 and #1020 in World UI/data/routing surfaces.
- Requires visual/product review of the HTML/screenshots before merge; code green is not enough for a UI shell replacement.

Verdict: keep open. Rebase on #1105 and split/retitle if needed: prototype docs vs production UI refactor.

### #1020 Kanban Team Development Flow

Quality:
- Large amount of test coverage and E2E evidence. CI green.
- It answers a real product gap: Kanban/team-development socialware and role-driven agents.
- PR body explicitly discusses socialware boundaries and architecture follow-ups.

Risks:
- Extremely broad: core plugin contract, domain agent defaults, CLI verbs, cc plugin, GitHub plugin, Kanban plugin, World UI, dev-together skill/docs.
- This is exactly the kind of PR where "business logic leaked to core" must be checked carefully. The PR removes some UI contract from core, but still edits core plugin interfaces and invariant baselines.
- Must be reviewed against the three-tier rule: core may only hold shared primitives; PM/Kanban/dev-together concepts must not enter core.
- Overlaps #1104/#1105 World surfaces and dev-together process docs.

Verdict: not a same-day close merge. Make it the next architecture close target with a dedicated review pass focused on core/domain/plugin boundaries, CapBAC, and World UI overlap.

### #1112 Agent Console Completeness / IA

Quality:
- The return usefully separates "small completeness gaps" from "design/IA gaps".
- F1-F6 are reported as fixed or validated with evidence, so the remaining work is
  no longer best handled as more one-off patches.
- The important residual issue is session delete/archive, which needs product
  semantics before implementation.
- The PR includes a new Agent Console IA direction and demo link, intended to
  answer homepage guidance, left-rail direct access, and overall information
  architecture.

Risks:
- The PR is large for a review/design return: 30 files, about +3709 lines.
- IA/prototype work can easily fan out. Lead comment on the PR: implement one
  prototype to completion instead of building many prototypes that leave zero
  completed path.
- Session delete/archive should not be patched in ad hoc until the destructive
  action semantics are clear.

Verdict: record as a late 0630 return. Keep open for review; do not merge only
because CI is green. Ask fatnine to choose one prototype path and drive it to a
usable/verifiable state.

## Merge Order

Recommended safe order:

1. #1106 AutoService seed verification and fixes.
2. #1105 Admin user management UI.
3. #1103 Website design/demo archive, after marking ready for review if merging through GitHub.

Deferred / next stack:

4. #1107 Website hello support: rebase after #1103, verify design artifacts preserved, smoke the refresh script.
5. #1104 World UI IM refactor: rebase after #1105, retitle/split if production UI remains in scope, visual review required.
6. #1020 Kanban team development flow: dedicated architecture review before merge; likely after #1104 conflict resolution or split out non-World/core-safe slices.
7. #1112 Agent Console completeness / IA: review as the late T2 return; require
   one prototype direction to be implemented through a usable state before merge.

## Process Deltas To Carry Forward

1. Feishu-only returns are not enough. Every dev return must include a `docs/together/YYYY-MM-DD/returns/*.md` file in the PR branch with `returned_at`, `deadline_status`, DoD, gates, evidence, and linked PR.
2. PR titles must match scope. A "docs prototype" PR that also rewrites production World UI should be retitled or split before close.
3. Large cross-tier PRs need an architecture-close lane. CI green is insufficient when a PR touches core + domain + plugin + UI + CLI.
4. Design assets and implementation branches that edit the same demo directory need an explicit owner/winner rule before either branch accumulates more work.
5. Dev-together close should record both merge decisions and the collaboration lessons; otherwise the team repeats the same missing-ledger and branch-overlap problems the next day.

## Close Outcome

Executed on 2026-07-01 via GitHub squash/admin merge.

| PR | Outcome | Merge SHA / State | Notes |
|---|---|---|---|
| #1106 | merged | `b73cb247165d6841e9d61df084ffc377728481a4` | AutoService current-architecture verification closed. Follow-up remains for generic bridge URL derivation from `PORT`. |
| #1105 | merged | `8a8e0b688ca68b8f56bef11a77e2f95c2565364d` | Admin user management UI landed before the larger World UI rewrite. |
| #1103 | merged | `0d20fa191f9135420e6b9b2187aacde1250d55dd` | Marked ready from draft, then merged as the 0630 website design/demo archive. |
| #1107 | left open | `OPEN`, mergeability recalculating after #1103 | Rebase/refresh required against `main` after #1103. Must verify all ruihua design artifacts remain available and smoke `scripts/refresh_hello_site.exs` before production rollout. |
| #1104 | left open | `OPEN`, mergeability recalculating after #1105 | Needs rebase on #1105 and product/visual review. Consider split/retitle because it is no longer docs-only. |
| #1020 | left open | `OPEN`, mergeability recalculating after safe stack | Needs dedicated architecture close review. Focus checks: no business logic in core, CapBAC boundaries, plugin isolation, World UI overlap with #1104/#1105. |
| #1112 | late return, left open | `OPEN`, CI green | Added to the 0630 ledger after close. Review direction: finish one Agent Console IA prototype path instead of expanding multiple prototypes. |

`origin/main` after the safe-stack close: `0d20fa191f9135420e6b9b2187aacde1250d55dd`.

## Next Lead Actions

1. Ask zhaomato to rebase #1107 on `main` and explicitly state whether it supersedes or consumes all #1103 website-demo artifacts.
2. Ask zyli to rebase #1104 on `main`, retitle/split if production UI remains in scope, and provide a short visual-review checklist against the HTML prototype.
3. Run a dedicated #1020 architecture review before merge. The review should enumerate core changes and prove every new core abstraction is plugin-agnostic and shared by more than one downstream surface.
4. Add a dev-together return gate that fails PRs whose Feishu return is not mirrored into `docs/together/YYYY-MM-DD/returns/`.
5. Ask fatnine to turn #1112 into one finished Agent Console prototype path, with
   session delete/archive kept as a design decision rather than a drive-by fix.
