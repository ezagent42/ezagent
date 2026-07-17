# Return: Git Provider Plan C Task Workspace

returned_at: 2026-07-17T16:15:00+08:00
deadline_status: completed_with_branch_baseline_gate

## Outcome

> **Hardening amendment:** the crash-recovery, fresh-spawn ordering, and exact
> Git checkout claims in this original return were not supported by the evidence
> available when it was written. They are superseded by the fresh machine
> evidence and corrected claim boundaries in
> [gaga-git-provider-plan-c-hardening.md](gaga-git-provider-plan-c-hardening.md).

Plan C is implemented on `feat/git-domain-spine`. A receiver-bound
`GitTaskAccess` capability now gates public-repository workspace provisioning
and cleanup. The Workspace Domain owns durable generation state, canonical
paths, anonymous Git execution, exactly-once sidecar start, sanctioned Agent
retirement, and bounded boot recovery.

No push, merge, rebase, deployment, private checkout, credential use, Plan D
production backend, Plan E UI, or Kanban behavior is included.

## Definition of Done evidence

- The closed provision port and singleton registry reject caller-selected
  repository/path coordinates. The authorized ActionSet supplies a validated
  internal policy envelope; public request construction still rejects policy
  injection.
- `:provision_workspace` and `:cleanup_workspace` require exact receiver-bound
  signed capabilities and exact task URI/generation coordinates.
- `git_task_workspace_provisions` durably records tenant, generation, checkout
  fingerprint, lease/token fencing, canonical paths, cleanup state, and Agent
  retirement intent. Three forward migrations are included.
- Public anonymous checkout and exact Git state are claimed only to the extent
  demonstrated by the hardening return linked above.
- Provision claims are token/lease fenced. A stale worker cannot cancel a new
  claim or delete its artifact. Final policy reload rechecks public visibility
  and the immutable checkout fingerprint.
- The generic core pre-start gate accepts only an opaque trusted option,
  injects only transient `cwd`, wraps the one Template instantiate seam, and
  completes exactly once without downstream vocabulary in core.
- Start lifecycle, crash/restart recovery, fresh-spawn ordering, and fetched
  branch/commit evidence are claimed only in the hardening return linked above.
- Cleanup is idempotent and token fenced. Ambiguous/live starts use
  `Ezagent.Domain.Agent.retire_spawned/2` with durable held authority; cleanup
  derives and matches canonical paths, removes under the cache lock, and proves
  absence. Recovery is durable-row-only, bounded, prioritizes expired effects,
  and performs at most one bounded deferred boot pass for active orphan leases.
- Structural gates keep Git details out of `plugin_cc`, keep provider adapter
  operations out of Workspace, forbid secret-bearing provision fields, and
  constrain registry/policy-envelope call sites.
- The end-to-end proof uses a real signed capability, real `GitTaskAccess`, real
  store, a local public Git repository, the real Git runner, a probe Template
  Class, and terminal signed cleanup. Unauthorized and private cases assert zero
  durable/filesystem/process/sidecar effects.

## Verification

- Formatting: touched-file `mix format`, full `mix format --check-formatted`,
  and `git diff --check` passed.
- Affected suites before the final isolation fix: core pre-start `5/0`,
  DomainGit `114/0`, plugin cc-headless `19/0`.
- Workspace full suite after the final isolation fix: `277 tests, 0 failures`.
- Final focused boundary/recovery suite: DomainGit `5/0`, Workspace `19/0`.
- Tenant-table invariant after classifying the new table: `74 tests, 0 failures`.
- D0 contract/security after URI cleanup: `18 tests, 0 failures`.
- `mix ezagent.arch.scan`: pass.
- `mix ezagent.doc.scan`: pass.
- `mix ezagent.check_invariants`: pass.
- `mix ezagent.check_invariants.lifecycle`: pass.
- `mix ezagent.uri_query.scan`: Plan C and D0 are clean; one pre-existing
  violation remains at
  `apps/ezagent_domain_agent/lib/ezagent/home/skill_reconcile.ex:142`.

`SHELL=/bin/bash mix precommit` was run. It exposed and allowed correction of
the in-scope uncategorized tenant table. The run was then manually stopped after
the remaining branch baseline was reproduced: the local SkillRegistry seed
bundle differs from derived runtime refs, and the pre-existing
`skill_reconcile.ex:142` URI violation makes the URI scan tests fail. Suites
observed after those failures included Domain Identity `500/0`, Domain Agent
`151/0`, Domain External Mirror `258/0`, Domain PTY `118/0`, and Domain Python
`73/0`. The project-wide gate is therefore not claimed green.

## Commits

- `85e836c20` provision port
- `4f66dda68` task-workspace authorization
- `6d19db6a3` durable lifecycle store
- `5860f1081` anonymous Git worktrees
- `f4ff1e093` provision state machine
- `7202619f6` lease/policy/cache fencing fixes
- `d0d33cb27` generic template pre-start
- `2c05834d1` exactly-once sidecar start and retirement intent
- `a159822c3` cleanup and boot recovery
- `0baf347a2` adversarial recovery hardening
- `df7cec6b8` structural and signed end-to-end proofs
- `f0cf6fa6b` full-suite singleton isolation
- `b2c096677` tenant-table invariant classification

## Residual blockers and deferrals

- Project-wide precommit remains blocked by the two baseline items above.
- Private checkout and all credential flows remain absent by design.
- The boot reconciler is bounded and not a periodic reaper; rows outside its
  configured recovery window remain operator-visible durable work.
- Node-local cache locking does not claim cross-node serialization; durable
  claim fencing remains authoritative across workers.
- Integration, push, merge, and deployment require lead/user authorization.

## Method friction

- The original provisioner attempted a synchronous read from its owning
  `GitTaskAccess` GenServer while already inside that handler. The signed E2E
  exposed the self-call; the validated policy is now passed through a closed,
  trusted internal envelope and revalidated by Workspace.
- Full-suite execution exposed singleton registry state leakage that focused
  tests did not. The E2E now saves/restores the exact prior registry state.
- Adversarial review found stale-lease deletion, transient-proof deletion,
  recovery starvation, and crash-window retirement gaps before return; each now
  has a regression test.
