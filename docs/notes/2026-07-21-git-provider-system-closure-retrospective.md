# Git Provider system-closure retrospective

> Date: 2026-07-21
> Source: Git Provider V1 Plan D1 / PR #1445 working session
> Evidence rule: proven facts, supported inference, and unknowns are labelled separately.

## 1. Outcome and timeline

**Proven facts.** D1 was implemented and reviewed as several Tasks, but its
correctness depended on one system-wide lifecycle: provider ownership, durable
journals, credential effects, recovery, independent compensation, handoff
shredding, and terminal release. Focused checks could become green while later
cross-Task review still found violations of that lifecycle. Architecture and
documentation gates ran late, after much of the implementation had frozen.

The same working session also observed WSL resource loss while Mix/BEAM checks
were being run. Subsequent guarded focused and provider-domain runs used
approximately 230–350 MiB, while VmmemWSL had previously grown by 6–7 GiB.

**Supported inference.** The guarded working set makes ordinary focused tests an
implausible explanation for the 6–7 GiB growth. Both incidents point to the
same method gap: work was considered locally complete without a Plan-level
owner and proof for the whole lifecycle.

**Unknown.** The original runaway process tree and its creator were not
retained, so this record does not name a process, command, or agent as the
cause. It also does not reconstruct exact timestamps or claim that every D1
repair had one root cause.

## 2. Process-loop and WSL OOM

### X problem — fundamental problem

A Mix/BEAM invocation was modelled as a command that had started, rather than
an owned bounded job with one process tree, serialization, a resource envelope,
a deadline, cleanup, and completion evidence.

### Y problems — engineering problems

- Bare or overlapping Mix/BEAM invocations had no process-wide lock.
- There was no cgroup memory/swap boundary, scheduler bound, or standard timeout.
- Test partitions were not required to be unique.
- Exit code, elapsed time, Max RSS, swap, and orphan evidence were not recorded
  consistently.
- VM-wide OOM could present to an agent as a disconnect while it was waiting.
- Pre-OOM process-tree and BEAM/ETS evidence was insufficient to identify the
  original runaway creator.

### X-level correction

Define every local Mix/BEAM verification as an owned job. Its completion
includes exclusive admission, a bounded process tree, explicit deadline and
resource limits, an unmodified child exit status, and post-run orphan evidence.

### Y-level correction

Adopt the guarded-Mix runbook and the single runner specified by the approved
method-productization design. Use `/tmp/ezagent-mix.lock`, a user-systemd scope,
`MemoryHigh=4G`, `MemoryMax=5G`, `MemorySwapMax=0`, `ERL_FLAGS='+S 4:4'`, a
unique partition, and an explicit timeout. Preserve resource and failure
evidence rather than replacing it with the result of a rerun.

### Recurrence-prevention proof

The runner contract suite must check serialization, the exact envelope, argv
preservation, exit-code propagation, timeout/resource classification, missing
prerequisites, stderr, and lock timeout. Dev-together handoffs must name the
runner, limits, timeout, partition, and serialization rule. CI must reject
removal or drift of those contracts.

## 3. Task-local convergence and repeated cross-Task repair

### X problem — fundamental problem

Tasks were treated as independent correctness closures even though D1
correctness lived in one cross-Task state machine. The planning and acceptance
unit was smaller than the invariant being proved.

### Y problems — engineering problems

- Repairs converged file-by-file or Task-by-Task and repeatedly exposed another
  cross-Task edge.
- DB, runtime, and fixture representations drifted into different state machines.
- Focused green checks were treated as closure without an integration checkpoint.
- Immutable historical proof was mixed with mutable current-stage predicates.
- Terminal workflow labels were accepted where durable proof was required.
- Proof and publication were separated by an unlock window, creating TOCTOU.
- Parallel reviews found races after local implementation had frozen.
- Late architecture/documentation gates exposed ownership drift near the end.

### X-level correction

Plan the work around explicit system closures. Each closure owns one X problem,
one Plan invariant, its related Tasks, durable proof, integration evidence, and
resource envelope. A Task implements cells of that matrix; it cannot alone
declare the Plan closed.

### Y-level correction

Add a structured closure matrix to the dev-together board and reference closure
ids from cards and handoffs. Serialize implementation and repair for a shared
state machine. After a second cross-Task regression, stop local patching and
write `failure -> Plan invariant -> one root cause -> one integrated repair surface`.
Freeze implementation before parallel read-only review, then integrate findings
as one repair batch.

### Recurrence-prevention proof

The board schema, renderer, handoff/review templates, and CI contract must all
require Plan-level closures and structured method deltas. Review must reconcile
durable proof and integration evidence for every closure before the Plan is
called complete.

## 4. Other system findings

| Finding | Evidence status | Method implication |
|---|---|---|
| Terminal labels versus durable proof | **Proven:** a workflow label did not itself prove durable effects, recovery, compensation, shredding, or release. | Name the durable record and the query/assertion that proves it. |
| DB/runtime/fixture drift | **Proven:** the three representations encoded divergent lifecycle assumptions during D1 repair. | Maintain one explicit state model and test all representations against it. |
| Proof/publish TOCTOU | **Proven:** proving, unlocking, and publishing as separate phases admitted a change window. | Couple proof to publication or revalidate under the publication guard. |
| Historical proof versus stage predicates | **Proven:** immutable evidence was used interchangeably with a current-stage condition. | Store historical facts immutably; evaluate current predicates from current state. |
| Late architecture/documentation gates | **Proven:** late gates found structural ownership drift after local work froze. | Run structural gates at the first closure checkpoint and again at final integration. |
| Identity full-suite failure | **Proven:** a failure was observed; **unknown:** it was not reproduced under the guarded rerun, so no product or fixture cause is assigned. | Preserve it as non-reproduced concurrency pollution until evidence reclassifies it. |
| Remote drift | **Proven:** the design branch began from local `origin/main` snapshot `5afe9aa31` because remote main `0a44d7b5` could not be fetched during design. | Record base and remote state, then rebase before implementation/return when transport is available. |
| Agent/network limits | **Proven:** agent disconnect and unavailable Git transport constrained observation. **Unknown:** neither proves the underlying product cause. | Separate infrastructure evidence from product evidence and do not fill gaps by inference. |

## 5. What changed during D1

**Proven facts.** D1 repairs addressed concrete ownership, journal, credential,
recovery, compensation, shredding, release, fixture, and gate findings. Focused
and provider-domain checks were rerun inside a guarded resource envelope. The
working session also produced the X/Y analysis and the approved four-layer
productization design: forensic record, operating contract, executable guard,
and workflow contract.

This retrospective records method evidence; it does not change Git Provider
runtime semantics or amend the frozen D1 specification or implementation plan.

## 6. What remains process debt

- Deliver and enforce the guarded runner and its CI contract.
- Add Plan-level closure, resource-envelope, Stop Rule, review-topology, and
  method-delta requirements to dev-together artifacts.
- Decide separately whether every local and CI Mix command must use the runner;
  the approved first step covers the safe local path and applicable handoffs.
- Investigate the Identity full-suite failure only if it recurs with retained
  process, partition, database, and test evidence.
- Preserve remote/base drift evidence and verify rebases at handoff boundaries.
- Do not claim the original runaway creator unless new retained evidence proves it.

## 7. Requirement-to-evidence matrix

| Requirement | Evidence from D1 | Durable destination | Closure proof |
|---|---|---|---|
| Owned bounded Mix job | 230–350 MiB guarded runs contrasted with observed 6–7 GiB VmmemWSL growth; original creator unknown | bilingual runbook + guarded runner | runner contract suite and result summary |
| Exact X/Y framing | repeated local repairs did not express the Plan invariant | retrospective + dev-together templates | CI contract rejects missing fields/terminology |
| Plan-level closure | ownership through terminal release crossed Task boundaries | `board.yaml` closure matrix + handoff references | review reconciles durable and integration evidence |
| Durable proof | labels and historical facts were confused with current predicates | closure matrix and review method delta | named durable query/assertion per closure |
| TOCTOU-safe publication | proof and publish admitted an unlock window | Plan invariant and integrated repair surface | publication under guard or guarded revalidation |
| Failure integrity | Identity failure did not reproduce; rerun could not erase it | runbook classification and retained evidence | recorded first failure plus later run outcomes |
| Early structural gates | late gates found ownership drift | handoff/Plan checkpoints | gates run at closure checkpoint and integration |
