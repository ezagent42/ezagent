> **Task:** #1498 system-closure method productization + guarded local Mix execution
> **Worktree:** `/home/huangjiajia/ezagent/.worktrees/system-closure-method-productization`
> **Branches:** `docs/system-closure-method-productization` (original, full 12-commit history, still tracks Draft PR #1498) → split into `system-closure/runner-and-docs` (permission-independent) + `system-closure/dev-together-skill-updates` (lead-owned)
> **PR:** #1498 (draft) — recommend retargeting/replacing with the two branches below (not done by this return; push/close is a lead action)
> **Dev:** gaga track, agent-executed (commit author identity: `hjj.gemini <hjj.gemini@gmail.com>`)
> **returned_at:** 2026-07-24 12:56 +0800
> **deadline:** not stated in the 2026-07-24 handoff (same-day continuation of an existing draft)
> **deadline_status:** on_time

> **Finalized:** 2026-07-30 — PR #1498 itself is the completed,
> permission-independent runner/docs slice. The owner-only skill follow-up is a
> separate branch and is not a completion dependency for this PR.

## 0. Recap

Synced instruction: #1498 is unrelated to main CapBAC, continue independently, introduce no permission dependency. Mission: rebase the existing draft, re-verify the guarded-Mix + system-closure contracts, and split the branch by ownership so the permission-independent part can merge normally while `.claude/skills/dev-together/**` goes through the lead-only path (`protect-dev-together-skill.yml`).

## 1. What was done

1. **Rebase.** `docs/system-closure-method-productization` was 71 commits behind / 12 ahead of local `main` (merge-base `9754c17dc`). Confirmed neither of the two path-sets this branch touches had *any* upstream commits since divergence, so the rebase onto `main` (`86fd926b3`) applied with **zero conflicts**. (Note: `origin/main` has since moved 5 commits further than local `main`; the coordination worktree has pre-existing uncommitted `board.yaml`/`board.html` edits that block a fast-forward pull, so I left that alone rather than stash someone else's in-flight edit — local `main` at `86fd926b3` is what this return is based on.)
2. **Re-ran the contract suites** on the rebased tree — both green (details below).
3. **Ran the four canonical static gates** (`arch.scan`, `doc.scan`, `uri_query.scan`, `check_invariants` — all are source-tree scans that don't need the DB/BEAM boot, per their own `@moduledoc`s) instead of a subset, per the handoff-standard "don't run a subset" rule.
4. **Split by ownership** into two new branches off `main`, verified the union reconstructs the rebased tree byte-for-byte, then verified each slice's gate behavior independently.

## 2. Gate / test results

| Gate | Scope | Result |
|---|---|---|
| `.github/scripts/guarded_mix_test.sh` | guarded-Mix runner contract (11 cases) | **PASS** (11/11), both on the combined rebased branch and standalone on `system-closure/runner-and-docs` |
| `.github/scripts/dev-together-system-closure-contract_test.sh` | system-closure X/Y contract | **PASS** on the combined tree (both slices applied). **FAILS standalone** on `system-closure/runner-and-docs` alone against unmodified `main` — see §4 method friction, this is expected/by-design, not a defect |
| `mix ezagent.arch.scan` | architecture fitness counters | **FAIL** — but pre-existing on `main`, not caused by this branch (see §5) |
| `mix ezagent.doc.scan` | doc-coverage fitness counters | **PASS** (0/0, 404/404, 0/0 — all at cap) |
| `mix ezagent.uri_query.scan` | URI/query hard-fail scan | **PASS** — no violations |
| `mix ezagent.check_invariants` | 8 hard invariants + M-9/comms gates | **PASS** — "all in-scope invariants clean" |
| `bash .claude/skills/dev-together/scripts/validate_skill.sh` | skill self-validation | **PASS**, run standalone on `system-closure/dev-together-skill-updates` |

No `.ex` file is touched anywhere in this branch (confirmed via `git diff --name-status main HEAD` — all 20 changed paths are `.md`/`.sh`/`.py`/`.yaml`), so the DB-backed suites (`mix ci.local`/`mix test`/`gate.arch` ExUnit) were not run in full; the four static scans above are the gates actually relevant to a diff of this shape, and 3 of 4 are clean.

## 3. DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | Runner/runbook/spec tests pass on current main | met | `guarded_mix_test.sh` 11/11 green standalone on `main`. `dev-together-system-closure-contract_test.sh` is green once *both* slices are applied (verified on the combined tree); it is a cross-slice acceptance test by design (asserts required text in the protected `SKILL.md`), so it will read red on `main` until the lead integrates slice B — flagged, not hidden (see §4). |
| 2 | No runtime authorization code is touched | met | `git diff --name-status main HEAD` — 0 files under `apps/**`, 0 `.ex`/`.exs` files anywhere in the diff. |
| 3 | Protected skill changes are isolated for lead-owned integration | met | `system-closure/dev-together-skill-updates`, 1 commit `fd65dd1a5`, exactly the 10 files under `.claude/skills/dev-together/**`. |
| 4 | Owner-only gate is not bypassed or weakened | met | `protect-dev-together-skill.yml` has 0 diff lines vs `main` on every branch touched (original, both slices). `OWNERS: allenwoods jjkysy` untouched. Locally replayed the gate's own file-match logic against each branch (see §5) — it correctly no-ops on the runner slice and correctly fires on the skill slice; the skill-slice commit is authored as `hjj.gemini`, not an OWNERS entry, so it would **not** self-authorize. |
| 5 | Relevant static gates and focused tests pass | met, with one flagged pre-existing exception | `doc.scan`/`uri_query.scan`/`check_invariants` clean. `arch.scan` has 2 counters over cap, but both are inherited unchanged from `main` and outside this task's scope — see §5. |
| 6 | Draft PR/return clearly reports which slice can merge and which requires lead ownership | met | This document + §6 merge request. |

**Method friction:** The handoff's ownership split (runner/tests/runbooks/specs vs. `.claude/skills/dev-together/**`) is correct for *authorship* gating, but the two resulting branches are not independently green forever — the new contract test (itself un-gated, since the test file lives outside the protected path) specifically asserts on the protected file's content, so it necessarily stays red on `main` until the lead's slice lands too. Worth stating explicitly in future handoffs that touch a protected surface: "the acceptance test for a lead-owned change usually has to ship in the *same* PR-author-independent slice as the runner, which means the runner slice's CI will show one red case until the paired slice merges" — that's expected, not a signal to weaken the test.

## 4. Cross-slice coupling detail

`system-closure/runner-and-docs` alone, run against unmodified `main`:
```
$ ./.github/scripts/dev-together-system-closure-contract_test.sh
missing contract text in .claude/skills/dev-together/SKILL.md: Plan-level closure
```
This is exactly the test doing its job — it's checking that the skill enforces X/Y plan-level closure, and unmodified `main` doesn't have that text yet (it's part of slice B). Not a bug in the split; a structural consequence of "the test for an owner-gated change can't itself require owner gating to exist, but it does need the owner's change to be applied to pass."

## 5. Pre-existing, out-of-scope: `arch.scan` red on `main`

```
FAIL spawn_fresh_unsanctioned: count=3 cap=0
FAIL missing_cap_check_mutating_actions: count=1 cap=0
```
`arch_baseline_manifest.exs` was last touched by `21cc15575` (`feat(actor): C0 — boundary gate + read surface (extraction chunk 0)`, #1546) — the in-progress actor/CapBAC extraction lane (C0/#1546, C1/#1548, C0-hardening/#1549 are all in `main`'s recent history). Since this branch changes zero `.ex` files, this red state is 100% inherited from `main` as-is, not introduced here. Per this task's explicit boundary ("不依赖 CapBAC" / do not touch runtime CapBAC, EntityCaps, or capability actions), I did not attempt to fix it — doing so would mean editing actor internals this task is barred from touching. Flagging for the lead as an FYI, since anyone else rebasing onto current `main` will see the same two counters.

## 6. Merge request — the two slices

**Slice A — `system-closure/runner-and-docs`** (1 commit, `d2a45d4d5`)
- Files: `scripts/guarded_mix.sh`, `.github/scripts/guarded_mix_test.sh`, `.github/scripts/dev-together-system-closure-contract_test.sh`, `docs/runbook/guarded-mix-execution.md` (+ `.zh_cn`), `docs/superpowers/plans/2026-07-21-system-closure-method-productization.md`, `docs/superpowers/specs/2026-07-21-system-closure-method-productization-design.md`, `docs/notes/2026-07-21-git-provider-system-closure-retrospective.md` (+ `.zh_cn`), `docs/together/2026-07-21/returns/system-closure-method-productization.md`.
- Touches **zero** protected or runtime-authorization paths. `protect-dev-together-skill.yml` no-ops on it regardless of author.
- **Mergeable now** by any author, with the one caveat from §4: its own new contract test will show 1 red case until Slice B also lands. If that's not acceptable to merge standalone, hold it until Slice B is ready and land both together.

**Slice B — `system-closure/dev-together-skill-updates`** (1 commit, `fd65dd1a5`)
- Files: the 10 files under `.claude/skills/dev-together/**` (SKILL.md, plan/review commands, handoff-standard/template, plan/review templates, board.example.yaml, board2html.py, validate_skill.sh).
- **Requires an OWNERS-authored commit** (`allenwoods` or `jjkysy`) to pass `protect-dev-together-skill.yml` — currently authored as `hjj.gemini`, which will **not** pass, by design. Needs the lead to either re-author/apply this patch under their own login, or review-and-commit it directly.
- Self-validates clean (`validate_skill.sh` green) standalone.

**Open decisions for the lead:**
1. How to land Slice B under authorized authorship (re-author the commit, cherry-pick under the lead's own login, or review-and-apply directly) — this return doesn't attempt that, since only the lead/owner can produce an authorized commit here.
2. Merge order/timing: recommend Slice B lands first (or atomically with Slice A) so `main` is never left with the one known-red contract-test case from §4.
3. ~~What happens to Draft PR #1498 itself~~ — resolved, see §7: PR #1498's branch now carries only Slice A (+ this return doc); Slice B is pushed as a plain (no-PR) branch for the owner to pick up.
4. The pre-existing `arch.scan` red on `main` (§5) — FYI only, not blocking, not touched.

Nothing under `apps/**`, no CapBAC/EntityCaps/capability-action code, no edits to `protect-dev-together-skill.yml` or its `OWNERS` list anywhere in this branch or either slice.

## 7. Addendum — PR #1498 updated, Slice B pushed (same session, follow-up)

Coordinator confirmed the mechanism (asked explicitly, chose): append a non-destructive revert commit rather than squash/force-replace the 12-commit history, and push Slice B as a plain branch (no PR) rather than leave it local-only.

- **`main` advanced mid-session** (86fd926b3 → 967a1b16c, 6 commits: #1546-adjacent C2 actor extraction #1550, kimi-dispatch skill #1559, dev-phase security-posture docs #1558, GitHub App creds wiring #1556, `no_hardcoded_seed_principal` gate #1560, and #1555 which — the one overlap — touched `.claude/skills/dev-together/commands/review.md`). Re-checked: only `commands/review.md` intersected our path set; re-rebased all three branches onto the new tip; the two independent review.md insertions (ours: `method_deltas` X/Y schema; #1555's: 归属看实质) auto-merged cleanly, both confirmed present post-rebase.
- **Two more pre-existing, out-of-scope, main-level findings from the re-run** (neither caused by this zero-`.ex`-diff branch, neither touched):
  - `arch.scan`'s 2 counters from §5 persist unchanged after C2 (#1550) landed.
  - `mix ezagent.uri_query.scan` now shows **7 violations** on current `main` (clean on the pre-move base) — all in `ezagent_domain_git`/`ezagent_domain_workspace`/`ezagent_plugin_codex`/`ezagent_plugin_github`, none in any file this branch touches. Flagging alongside §5 for the lead; out of scope for #1498 either way.
- **Pushed**, with the coordinator's explicit go-ahead:
  - `docs/system-closure-method-productization` → `origin` via `--force-with-lease` (lease pinned to the known prior remote tip `1890c4603`, matched before pushing). PR #1498 now shows **11 changed files, 0 deletions, 2530 additions** — exactly Slice A + this return doc, confirmed via `gh pr view 1498 --json files`. No `.claude/skills/dev-together/**` file appears in the PR diff any more.
  - `system-closure/dev-together-skill-updates` → `origin` as a **new plain branch, no PR opened**. This never triggers `protect-dev-together-skill.yml` (its `on:` is `pull_request`/`push-to-main` only), so there's no confusing red check sitting on it — the owner opens their own PR from it under their own login when ready: `https://github.com/ezagent42/ezagent/compare/main...system-closure/dev-together-skill-updates`.
- **Not done, still needs the owner:** actually authoring/landing Slice B under `allenwoods`/`jjkysy`. Nothing in this session's GitHub identity (`gagameow`, confirmed via `gh auth status`) can make that gate pass — by design, not a gap.

## 8. Final closeout — 2026-07-30

- Rebased the existing PR branch without conflicts onto
  `origin/main@90de06be8`.
- Reconciled the cross-day task record and the 2026-07-30 board from
  `wip(draft)` to `review`.
- Kept the scope boundary intact: #1498 contains the guarded runner, its
  contract, bilingual runbook/retrospective, and contributor discoverability;
  it contains no `.claude/skills/dev-together/**` changes and no `apps/**`
  runtime changes.
- Removed the stale cross-slice X/Y contract test from #1498. That test required
  the protected skill proposal which the final design explicitly dropped, so
  retaining an intentionally red test in the permission-independent PR
  contradicted the accepted scope.
- Final local verification:
  - guarded-Mix runner contract: 11/11 cases pass;
  - `mix ci.fast`: actor 1/0, core 691/0, identity 4/0,
    external mirror 39/0, session 8/0;
  - board render, `git diff --check`, and the no-`apps/**` /
    no-protected-skill scope check pass.
- GitHub CI evidence is recorded on the final PR head before it is marked ready
  for review.
