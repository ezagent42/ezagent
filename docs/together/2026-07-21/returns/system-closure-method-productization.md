# Return: system-closure method productization

- returned_at: 2026-07-21T15:32:48+08:00
- branch: `docs/system-closure-method-productization`
- base: `origin/main` at `0a44d7b5ea9245b1828143f997e8ca7884b01b8f`
- implementation_head: `5dafb0132`
- return_artifact_commit: `7d735be80`
- status: `blocked_on_upstream_precommit`
- protected_owner_path: lead review required for `.claude/skills/dev-together/**`

## Outcome

The method implementation is frozen and has two independent final approvals.
It adds bilingual incident evidence and guarded-Mix operating guidance, an
executable single-channel 5 GiB Mix runner, and structured Plan-level Closure
contracts for dev-together. Git Provider Plan D1 / PR #1445 is evidence source
only; it is not this work item's identity.

This return is not marked return-ready because current `origin/main` has a
focused, reproducible capability pending/held convergence regression that makes
the repository-wide `mix precommit` red. The method branch has no `apps/**`
diff, and the failing expectation is structurally shared with the production
desired-cap formula; changing the expected count here would hide a production
duplicate grant.

## Commits

- `0d9075bf7` — `docs: design system-closure method productization`
- `6cda52cfc` — `docs: plan system-closure method productization`
- `779f4e846` — `docs: record X/Y system-closure lessons`
- `bcf7a1b12` — `docs: name system-closure method independently`
- `adf10ab13` — `build: add guarded Mix execution runner`
- `21c327b4c` — `test: make guarded Mix serialization proof deterministic`
- `7ed3d8028` — `docs(dev-together): require X/Y plan-level closure`
- `42f0804bc` — `fix(dev-together): close system-closure contract gaps`
- `5dafb0132` — `fix(method): strengthen system-closure proof contracts`

The final subject-only history rewrite preserved the exact tree:
`351c7ff4e987397457072def5d6e9385e350d3e5` before and after.

## Acceptance reconciliation

| Requirement | Evidence | Status |
|---|---|---|
| Bilingual retrospective and runbook | English and `.zh_cn.md` peers; terminology and safety contracts checked by CI scripts | pass |
| Guarded runner | exact ordered cgroup argv, lock, timeout, exit and mutation contracts | pass |
| Real guarded smoke | `mix help`, exit 0, Max RSS 108920 KiB, swap 0 | pass |
| dev-together Plan Closure | skill, commands, templates, structured board schema, renderer and mutation tests | pass |
| Historical board compatibility | legacy string `method_deltas` render in independent wrappers | pass |
| Current-main rebase | clean rebase onto `0a44d7b5e`; remote API and authenticated HTTPS fetch agreed | pass |
| Architecture scan | 36 checks pass; Max RSS 432260 KiB; swap 0 | pass |
| Documentation scan | 3 checks pass; Max RSS 142216 KiB; swap 0 | pass |
| URI scan | no violations; Max RSS 124008 KiB; swap 0 | pass |
| Invariants | all in-scope invariants clean; Max RSS 112532 KiB; swap 0 | pass |
| Repository precommit | guarded run, Max RSS 1265120 KiB, swap 0; current-main regression remains | blocked |
| Final runner review | APPROVED, no remaining findings | pass |
| Final process review | APPROVED, no remaining findings | pass |

All real Mix commands were serialized through `scripts/guarded_mix.sh` with
`MemoryHigh=4G`, `MemoryMax=5G`, `MemorySwapMax=0`, `OOMPolicy=kill`,
`ERL_FLAGS='+S 4:4'`, a unique partition, and `/tmp/ezagent-mix.lock`.

## Precommit failure classification

The first guarded precommit also exposed a fresh-worktree frontend prerequisite;
`pnpm install --frozen-lockfile` under the same cgroup envelope resolved the
missing `xterm` dependency without changing tracked files.

Three test failures were then classified:

- owner-rooted join timeout: focused pass; full-suite concurrency pollution;
- Feishu orphan reaper timeout: focused pass; full-suite timing pollution;
- orchestrator cap count: focused failure (`40` pending versus `39` expected),
  reproducible with no method-branch `apps/**` diff.

Root cause of the deterministic failure:

- **X problem — fundamental problem:** grant idempotence observes held caps but
  not one unified held + pending/in-flight effective-grant state.
- **Y problem — engineering problem:** current main's exact identity/current
  signature membership check cannot see the not-ready orchestrator's already
  durable pending `:join`, so it issues another grant.
- **Required destination:** a separate capability convergence repair on current
  main, followed by this branch rebasing and rerunning guarded precommit.

## Final review evidence

- Runner reviewer: `/tmp/system-closure-final-runner-review.md` — APPROVED.
- Process reviewer: `/tmp/system-closure-final-process-review.md` — APPROVED.
- Upstream diagnosis: `/tmp/main-cap-count-diagnosis.md` — production-model
  repair required; do not change the test count.

## Deferred decision

CI-wide enforcement that every Mix command must use the guarded runner remains
explicitly deferred. This increment provides the runner, operator contract, and
focused workflows without rewriting unrelated CI jobs.

## Resume condition

After the upstream pending/held convergence repair lands on `main`:

1. fetch and rebase this branch onto the new `origin/main`;
2. rerun the two shell contracts and `validate_skill.sh`;
3. rerun guarded arch/doc/URI/invariants/precommit serially;
4. refresh both final reviews if the content tree changes;
5. change this return from `blocked_on_upstream_precommit` to `ready` only when
   guarded precommit exits 0.
