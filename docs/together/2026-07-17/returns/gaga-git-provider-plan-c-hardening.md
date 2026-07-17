# Return: Git Provider Plan C Hardening

returned_at: 2026-07-17T21:00:00+08:00
baseline_head: `613a1c9da94983bf53a927c11c36e4c1fd478466`
branch: `feat/git-domain-spine`
status: hardening_evidence_complete_with_separated_branch_baselines

## Corrected outcome

This return supersedes only the original Plan C return's unsupported
crash-recovery, fresh-spawn ordering, and exact Git checkout claims. The
hardening adds a durable leased `:starting` state, binds recovery identity before
instantiate, verifies the fetched commit and deterministic local branch at the
last responsible moment, and makes abandoned starts recoverable without a
second instantiate.

No push, merge, rebase, deployment, private checkout, credential flow, Plan D
production backend, Plan E UI, or Kanban behavior was delivered or performed.

## Migration and durable state transitions

Migration `20260717004000_harden_git_task_workspace_start.exs` adds
`start_claim_token`, `start_lease_until`, `resolved_base_commit`,
`local_branch_ref`, and `remote_url`, plus the
`(status, start_lease_until)` recovery index. The status constraint becomes:

`planned → provisioning → ready → starting → sidecar_started`

Failure/recovery lanes are `blocked`, `cleanup_pending`, and terminal `cleaned`.
The forward migration conservatively moves every non-cleaned legacy row to
`cleanup_pending` with `cleanup_reason=plan_c_hardening_upgrade` and clears old
provision/start tokens. Rollback converts `starting` to `cleanup_pending` with
`plan_c_hardening_rollback` before removing the new columns.

At runtime, `claim_start/3` performs the fenced `ready → starting` transition
and records a unique claim plus lease. `mark_started/4` accepts only the current,
unexpired claimant and persists retirement/provenance evidence before
`sidecar_started`. `fail_start/4` and invalid-proof paths atomically invalidate
the claimant and request cleanup. Lease takeover, renewal, cleanup ownership,
and completion are version/token fenced; stale claimants cannot complete,
cancel, retire, or delete a replacement generation.

## Fresh-spawn ordering evidence

The generic core pre-start registry returns an opaque one-use completion claim,
monitors its owner, and releases abandoned claims. Agent template spawn injects
only the authoritative transient `cwd`, then completes the claim after all
fresh-worker obligations. Instantiate error/raise/exit and later obligation
failure complete exactly once; adopted workers do not acquire fresh-worker
obligations.

Fresh tests cover registry callbacks outside the GenServer, caller-death release,
normal completion monitor cleanup, authoritative cwd injection, success only
after every helper-owned spawn obligation, and failure completion after rollback.
The affected core command observed `81 tests, 0 failures`; the full Agent command
observed `154 tests, 1 failure`, where the sole failure is a pre-existing
ReadyGate/DLQ observation race described under baselines below, not a Plan C
spawn-order assertion.

## Fetched branch and commit evidence

The Git runner fetches the requested remote ref before resolving it, records the
resolved commit, derives a deterministic per-generation local branch, and
creates the worktree from that fetched commit. Before instantiate,
`PreStartVerifier` rechecks the complete persisted proof: canonical origin,
exact Git worktree registration, exact HEAD commit, exact branch, and clean
status. Commit, branch, origin, registration, and dirty-tree drift fail closed.

Tests explicitly cover a moved base ref, a newly created remote ref, head/tag
ambiguity, a branch already checked out elsewhere, same-target retry, complete
proof requirements, and signed end-to-end commit/branch/dirty drift rejection.
The fresh Workspace suite observed `310 tests, 0 failures`; Domain Git observed
`114 tests, 0 failures`.

## Crash/restart recovery evidence

The start claim and complete Git proof exist durably before verification and
instantiate. Caller death after prepare leaves `:starting`, preserving exact
Agent retirement identity. The boot reconciler is a temporary bounded one-shot
child: it prioritizes cleanup/expired effects, waits at most one bounded pass for
active orphan leases, then reclaims expired or nil-lease starts. Recovery
transfers retirement evidence before Git cleanup and never invokes instantiate
again. A competing reclaim turns a stale recovery snapshot into a benign skip.

Tests cover caller death after real prepare, supervised restart recovery of an
expired start, one deferred pass for an active lease, stale original-claimant
fencing, nil-lease conservative recovery, cleanup takeover, and terminal cleanup
idempotency.

## Fresh verification ledger

- `mix format <brief touched-file list>`: exit 0; no tracked churn.
- `mix format --check-formatted`: exit 0.
- `git diff --check`: exit 0.
- Initial `git status --short`: only the preserved unrelated untracked
  `docs/together/2026-07-17/handoffs/gaga-cc-custom-backends-clarify-first.md`.
- `SHELL=/bin/bash mix test apps/ezagent_domain_git/test`: `114 tests, 0 failures`.
- `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test`:
  `310 tests, 0 failures`.
- `SHELL=/bin/bash mix test apps/ezagent_domain_agent/test`: twice observed
  `154 tests, 1 failure`; see separated baseline below.
- Core pre-start plus tenant-table invariant: `81 tests, 0 failures`.
- plugin cc headless-agent test: `19 tests, 0 failures`.
- `mix ezagent.arch.scan`: exit 0, all 35 counters pass.
- `mix ezagent.doc.scan`: initially `408/404`; the four hardening APIs were
  documented and the fresh rerun passes at the unchanged `404/404` baseline.
- `mix ezagent.uri_query.scan`: exit 1 only for the separated pre-existing
  `skill_reconcile.ex:142` violation.
- `mix ezagent.check_invariants`: exit 0.
- `mix ezagent.check_invariants.lifecycle`: exit 0.
- The sole `SHELL=/bin/bash mix precommit` run occurred before the four API
  documentation fixes and exited 2. It ran all umbrella apps; core observed
  `2 doctests, 2134 tests, 6 failures`, including the then-current `408/404`
  documentation regression. No second full precommit was run after the API docs
  were fixed, so this return does not claim that final documentation state was
  covered by precommit. After the fixes, only `mix format --check-formatted`,
  `git diff --check`, and the five independent architecture/static gates were
  rerun. The project-wide gate is not claimed green. Exact classifications
  follow.

Repeated startup warnings were the stored/code `orchestrator` socialware
divergence and operator-edited `dev-together` / `kanban-assistant` seed bundles
being preserved. Workspace also emitted existing test compile warnings and
expected exercised-failure logs; none counted as test failures.

## Baselines separated from hardening

- SkillRegistry seed mismatch: configured seed refs are
  `["dev-together", "ezagent-session-orchestrator", "kanban-assistant"]`, while
  derived runtime refs are `["ezagent-session-orchestrator"]`.
- URI query baseline: one raw construction at
  `apps/ezagent_domain_agent/lib/ezagent/home/skill_reconcile.ex:142`; this causes
  the direct scan and four core scan-related test failures.
- Agent full-suite baseline: the test at
  `transport_readiness_test.exs:194` polls `ReadyGate.status == :failed`, but the
  implementation commits that status inside the transition locks and writes
  DLQ afterward. Both fresh failures logged that dead-lettering started, while
  the immediate query raced and saw `[]`. Both the test and ordering originate
  in pre-hardening commit `46f26a3b30`; no Plan C fix was made.
- The first full precommit additionally exposed order/global-state failures not
  reproduced by the independent affected suites: Identity `500/1`, Workspace
  `310/1` (provision registry cleared), plugin cc `402/1`, and Web `362/62`
  (predominantly authenticated test connections redirected to `/login`). These
  are reported, not attributed to or hidden by Plan C.

The hardening-specific documentation regression was fixed without raising the
ratchet baseline. No other in-scope gate failure remains.

## Complete hardening commit set

### Design and plan

- `f1fed04a3` docs(git): design task workspace hardening
- `eb32b4898` docs(git): plan task workspace hardening

### Implementation and tests

- `d0dca6690` feat(workspace): persist task start claims
- `a08bc4e69` feat(workspace): fence durable task starts
- `f594da731` fix(core): release abandoned pre-start claims
- `2cd41ef1c` fix(agent): complete pre-start after spawn obligations
- `1bcd50490` fix(agent): preserve pre-start completion outcome
- `f21f3d9a8` feat(workspace): pin task worktrees to fetched branches
- `6f584643e` fix(workspace): converge fetched branch preparation
- `52963f541` fix(workspace): prove task checkout before start
- `b187caa95` test(workspace): prove start rejects checkout drift
- `685cfe29e` test(workspace): restore pre-start test registry
- `dcf8718e1` feat(workspace): recover abandoned task starts
- `6a3100d7f` test(workspace): harden abandoned start recovery
- `5450bafb5` test(workspace): prove hardened task lifecycle
- `613a1c9da` fix(workspace): parse secret fields from AST

### Return documentation

- `2498f9479` docs(together): return git provider plan c hardening

Commit `2498f9479` contains the four API documentation annotations that restored
the `404/404` doc baseline plus the two return artifacts. This post-review
correction follows it as a separate docs-only commit; its SHA is intentionally
reported in the execution report after creation rather than recursively listed
inside itself.

## Final re-review correction

Commit `6379ab19b` closes the final ownership and verification findings.

- Workspace completion now uses the provision row's prebound
  `creation_attempt_id` and verifies that exact inventory fact. A later inventory
  entry cannot replace it, and `Store.mark_started/4` rejects a mismatched handle
  without overwriting the reservation.
- The generic template pre-start outcome now carries `fresh?`. Workspace accepts
  only `fresh?: true`; an adopted worker releases the start reservation back to
  retryable `ready`, remains live, and is never treated as retirement-owned by
  the provision.
- Git proof-command exits (origin, registration list, rev-parse, symbolic-ref,
  and status) are positive checkout mismatches and enter the invalid-checkout
  cleanup lane. Spawn, timeout, output-limit, signal, and transport failures stay
  `checkout_unavailable` and non-destructive. Detached HEAD is covered as a
  symbolic-ref mismatch.
- Exact `now == start_lease_until` tests prove completion/renewal fail and a new
  claimant may take over at the boundary.

TDD RED observed Agent TemplateSpawn `14 tests, 2 failures` and the focused
Workspace set `66 tests, 5 failures`, each failing on the missing re-review
behavior. GREEN observed Agent TemplateSpawn `14/0`, focused Workspace `66/0`,
adopted TemplateSpawn integration `15/0`, and the fresh full Workspace suite
`319 tests, 0 failures`. Full Agent remained `154 tests, 1 failure` at the same
pre-existing ReadyGate/DLQ observation race.

The five fresh static gates observed: doc `404/404` pass; invariant and lifecycle
pass; architecture failed only `oversized_modules_gt_1000` at `5/4`; URI-query
failed only the existing `skill_reconcile.ex:142` raw-construction baseline.
The post-correction fresh `SHELL=/bin/bash mix precommit` completed non-zero.
It reproduced the same architecture `5/4`, SkillRegistry seed-set, and single
URI-query baselines in core, then accumulated shared-state/order failures in
later apps. The independently green Workspace result remained `319/0`; the
aggregate run later contaminated Web (`362 tests, 63 failures`, predominantly
`/login` redirects, plus one teardown timeout). This is recorded as non-green;
no project-wide success is claimed.

## Residual concerns and non-deliverables

- Project precommit remains red for the explicitly separated baselines and
  order/global-state failures above; no project-wide green claim is made.
- Private Git checkout and every credential path remain absent by design.
- Recovery is bounded boot reconciliation, not a periodic reaper.
- Node-local cache locking is not cross-node serialization; durable fencing is
  authoritative across competing workers.
- No integration action, push, merge, rebase, or deployment was performed.
