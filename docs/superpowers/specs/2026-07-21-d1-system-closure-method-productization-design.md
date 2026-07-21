# D1 System-Closure Method Productization Design

> **Date:** 2026-07-21
>
> **Status:** Approved in discussion and written-spec review on 2026-07-21
>
> **Source incident:** Git Provider V1 Plan D1, PR #1445 working session
>
> **Branch base:** local `origin/main` snapshot `5afe9aa31`; implementation MUST rebase onto current `origin/main` before work begins because Git transport could not fetch remote main `0a44d7b5` during spec creation.

## 1. Goal

Turn the Git Provider D1 lessons into durable team mechanisms so that future
work does not depend on someone remembering this session. The result must make
the lessons searchable, put the safe execution path behind one command, require
Plan-level closure reasoning in dev-together artifacts, and automatically reject
removal or drift of the new contracts.

The method uses the following terms exactly:

- **X problem — fundamental problem:** the incorrect abstraction, system model,
  responsibility boundary, invariant, or definition of completion that permits
  a class of failures.
- **Y problem — engineering problem:** the concrete code, test, fixture, tool,
  workflow, runtime, or operational defect through which the X problem appears.
- **X-level correction:** a correction to the model, invariant, responsibility
  boundary, or completion rule.
- **Y-level correction:** concrete engineering changes in code, scripts, tests,
  CI, documentation, or workflow.
- **Recurrence-prevention proof:** an automated or mandatory process proof that
  the X problem cannot continue generating equivalent Y problems unnoticed.

“Y engineering trigger” is not an accepted synonym. A trigger is only one
possible Y problem and is too narrow for this method.

## 2. Problem statement

### 2.1 Unbounded Mix/BEAM execution

#### X problem

A Mix/BEAM invocation was treated as a command that had been started, not as an
owned job with a bounded process tree, resource envelope, deadline, cleanup,
and completion evidence. The system could not prove that one verification run
had ended before another began or that a failed run could not take down WSL.

#### Y problems observed

- bare or overlapping Mix/BEAM invocations;
- no process-wide serialization;
- no cgroup memory/swap boundary;
- no scheduler bound or command timeout;
- no unique test partition discipline;
- no standard Max RSS, swap, exit-code, or orphan-process evidence;
- VM-wide OOM presenting as an agent disconnect while waiting;
- insufficient pre-OOM process-tree and BEAM/ETS evidence to name the original
  runaway creator with certainty.

The guarded runs established that focused and provider-domain verification
normally stayed around 230–350 MiB. The observed 6–7 GiB VmmemWSL growth was not
a normal focused-test working set.

### 2.2 Task-local convergence instead of Plan-level closure

#### X problem

Tasks were treated as correctness closures even though D1 correctness lived in
one cross-task state machine: provider ownership, durable journals, credential
effects, recovery, independent compensation, handoff shredding, and terminal
release. The abstraction level of planning and acceptance was lower than the
level of the system invariant.

#### Y problems observed

- repairing failures file-by-file or Task-by-Task;
- DB, runtime, and fixture models drifting into different state machines;
- declaring progress from focused green tests without a Closure checkpoint;
- immutable historical proof mixed with current-stage predicates;
- terminal workflow labels treated as durable proof;
- proof and publication separated by unlock windows;
- reviewers finding cross-Task races only after local implementation froze;
- arch/doc gates deferred until Task 9, revealing structural ownership drift
  only at the end.

## 3. Scope and non-goals

### In scope

1. A bilingual forensic retrospective that preserves the evidence and X/Y
   analysis.
2. A bilingual guarded-Mix runbook.
3. A single guarded local Mix/BEAM runner with contract tests.
4. Dev-together rules and templates requiring X/Y framing, Plan-level closure,
   resource envelopes, Stop Rules, and recurrence-prevention proof.
5. CI contract tests that keep the runner and workflow templates from drifting.

### Out of scope

- changing Git Provider production semantics;
- modifying the frozen D1 spec or implementation plan;
- forcing every existing CI Mix invocation through a user-systemd scope;
- choosing a new global CI architecture;
- fixing the independently observed Identity full-suite concurrency flake;
- claiming the original runaway BEAM creator is known without retained evidence;
- raising architecture/documentation baselines or adding exemptions.

The stronger policy “all local and CI Mix commands must run through the new
runner” is a later adoption decision. This design first makes the safe local
path usable and enforceable in dev-together artifacts.

## 4. Architecture

The learning system has four layers. Each layer answers a different durability
question.

| Layer | Question | Artifact |
|---|---|---|
| Forensic record | Why did this happen? | bilingual retrospective |
| Operating contract | What must an operator do? | bilingual runbook |
| Executable guard | What is the safe default command? | guarded Mix runner + tests |
| Workflow contract | How does every future Plan inherit the lesson? | dev-together templates + CI contract |

No single layer is sufficient. Documentation without the runner remains a
memory exercise; a runner without workflow adoption remains optional; workflow
text without CI can silently disappear.

## 5. Files and responsibilities

### 5.1 Forensic record

Create:

- `docs/notes/2026-07-21-git-provider-d1-system-closure-retrospective.md`
- `docs/notes/2026-07-21-git-provider-d1-system-closure-retrospective.zh_cn.md`

Both files have parallel headings and cover:

1. session/PR timeline and frozen commits;
2. process-loop/OOM evidence;
3. Task-local convergence evidence;
4. DB/runtime/fixture model drift;
5. ownership, recovery, compensation, terminal-proof, and TOCTOU examples;
6. architecture/doc gate timing, remote drift, and infrastructure limitations;
7. X problem, Y problems, X-level correction, Y-level correction, and
   recurrence-prevention proof for every lesson;
8. completed and outstanding process-productization work.

The retrospective distinguishes proven facts from inference. In particular, it
must say that the exact original runaway process creator was not preserved, while
the guarded reruns disprove a normal 6–7 GiB working-set explanation.

### 5.2 Operating contract

Create:

- `docs/runbook/guarded-mix-execution.md`
- `docs/runbook/guarded-mix-execution.zh_cn.md`

The runbook defines:

- mandatory use cases: test, compile, migration verification, and precommit;
- one serialized Mix/BEAM channel;
- the standard resource envelope;
- partition naming and timeout selection;
- required command/result evidence;
- pre-run and post-run orphan checks;
- OOM/timeout diagnosis and evidence capture;
- failure classification: product, fixture/model, resource, infrastructure, or
  non-reproduced concurrency pollution;
- explicit prohibitions against parallel Mix, naked precommit, baseline raising,
  and repeated reruns used to erase a flake.

### 5.3 Executable guard

Create:

- `scripts/guarded_mix.sh`
- `.github/scripts/guarded_mix_test.sh`
- `.github/workflows/guarded-mix-contract.yml`

The intended CLI is:

```bash
scripts/guarded_mix.sh \
  --timeout 900 \
  --partition d1_provider_full \
  test apps/ezagent_domain_provider_connection/test
```

The runner:

1. accepts Mix arguments as an argv array and never uses `eval`;
2. serializes via `/tmp/ezagent-mix.lock`;
3. invokes `systemd-run --user --scope` with:
   - `MemoryHigh=4G`;
   - `MemoryMax=5G`;
   - `MemorySwapMax=0`;
   - `MemoryAccounting=yes`;
   - `OOMPolicy=kill`;
4. uses `ERL_FLAGS='+S 4:4'`, `MIX_ENV=test`, and the requested unique
   `MIX_TEST_PARTITION`;
5. applies an explicit timeout;
6. records elapsed time, Max RSS, swap, and the child exit code;
7. returns the Mix exit code unchanged;
8. fails loudly when a required Linux/user-systemd prerequisite is missing;
9. reports matching Mix/BEAM processes after completion without killing
   unrelated processes.

The contract test stubs external commands so CI does not require user systemd.
It covers exact cgroup arguments, argv preservation, error propagation,
timeout/OOM classification, missing prerequisites, stderr preservation, and
serialization. A separate workflow runs only this shell contract test.

### 5.4 Workflow contract

Modify:

- `.claude/skills/dev-together/SKILL.md`
- `.claude/skills/dev-together/commands/plan.md`
- `.claude/skills/dev-together/commands/review.md`
- `.claude/skills/dev-together/references/handoff-standard.md`
- `.claude/skills/dev-together/references/handoff-template.md`
- `.claude/skills/dev-together/references/plan-template.md`
- `.claude/skills/dev-together/references/review-template.md`
- `.claude/skills/dev-together/scripts/render/board.example.yaml`
- `.claude/skills/dev-together/scripts/render/board2html.py`

Create:

- `.github/scripts/dev-together-system-closure-contract_test.sh`
- `.github/workflows/dev-together-system-closure-contract.yml`

The workflow contract adds the following requirements.

#### X/Y framing

Every non-mechanical incident/finding records:

```text
X problem — fundamental problem
Y problem — engineering problem
X-level correction
Y-level correction
Recurrence-prevention proof
```

“Be more careful”, “add more tests”, and “review harder” are not accepted
recurrence-prevention proofs without an owner and an executable or mandatory
workflow destination.

#### Plan-level closure matrix

Plans with cross-task state, recovery, authorization, destructive operations,
multiple durable stores, or external effects must include:

| Closure | X problem | Plan invariant | Related Tasks | Durable proof | Integration evidence |
|---|---|---|---|---|---|

Tasks state which matrix cells they implement. They do not independently claim
that the Plan is closed.

The current dev-together single source of truth is `board.yaml`, not the legacy
`plan.md`/`review.md` pair. Its schema therefore carries a top-level
`system_closures` list with stable closure ids, X problem, Plan invariant,
related cards, durable proof, integration evidence, and resource envelope.
Cards refer to closure ids. `board2html.py` renders the closure summary so the
team-facing artifact exposes the same Plan-level contract instead of hiding it
in a handoff.

#### Execution resource envelope

Every applicable handoff names the guarded runner, memory limits, timeout,
partition, and serialization rule. Mechanical/non-Mix work may mark this
section not applicable with a reason; it may not silently omit the section.

#### Stop Rule

When a Closure produces a second cross-Task regression, local patching stops.
Before more production edits, the owner must write:

```text
failure -> Plan invariant -> one root cause -> one integrated repair surface
```

#### Review topology

- implementation and repair are serialized per shared state machine;
- a frozen implementation may receive parallel read-only reviews;
- reviewers do not independently edit the same state machine;
- the lead integrates findings into one repair batch;
- original reviewers re-review only their blocking findings plus regression of
  already-closed invariants;
- open-ended style churn does not reopen an approved Closure.

#### Method writeback

Review `method-deltas` records the X/Y pair, both correction levels,
recurrence-prevention proof, owner, and destination: documentation, runner, CI,
skill change, or tracked process debt.

The `board.yaml` `review.method_deltas` schema uses structured maps for these
fields. The renderer remains backward-compatible with historical string entries
but the plan/review commands require new boards to write the structured form.

The CI contract test asserts that the required concepts remain present in the
skill and templates. It checks the contract, not prose formatting.

## 6. Data and control flow

### 6.1 Guarded execution

```text
developer/agent
  -> scripts/guarded_mix.sh
  -> validate argv + prerequisites
  -> acquire global Mix lock
  -> start bounded user-systemd scope
  -> execute timeout -> mix argv
  -> collect resource/exit evidence
  -> report remaining processes
  -> release lock
```

The runner owns only process execution. It does not interpret ExUnit results,
change test semantics, clean databases, or kill processes it did not start.

### 6.2 Method learning

```text
return captures friction
  -> review classifies X and Y
  -> method-delta chooses correction + owner
  -> process PR changes docs/tool/skill/CI
  -> contract test prevents silent removal
  -> future plan/handoff inherits the rule
```

## 7. Error handling and safety

- Missing `flock`, `systemd-run`, `/usr/bin/time`, or `timeout` is a loud setup
  error, never a fallback to naked Mix.
- Failure to acquire the lock within the configured wait is reported distinctly
  from a Mix failure.
- The runner uses no broad kill command, unresolved glob, `$HOME` deletion, or
  workspace cleanup.
- OOM/timeout terminates only the systemd scope.
- Contract tests never launch real Mix or systemd; one guarded `mix help` smoke
  is run manually on supported WSL/Linux during verification.
- Existing unrelated reports, handoffs, and `board.html` files are not staged,
  modified, or deleted.
- The process PR must pass the protected dev-together owner gate.

## 8. Verification

### Documentation

- English and Chinese retrospective headings are structurally parallel.
- English and Chinese runbook commands and numeric limits are identical.
- No `TBD`, `TODO`, ambiguous X/Y terminology, or unsupported causal claim.
- Every lesson has an X problem, Y problem, both correction levels, and a
  recurrence-prevention proof.

### Runner

- shell contract suite passes;
- guarded `mix help` smoke passes on the target WSL/Linux environment;
- an intentionally failing stub returns the original non-zero code;
- argv with whitespace and shell metacharacters is not reinterpreted;
- two invocations demonstrate serialization without concurrent Mix children;
- result summary includes exit status and resource evidence.

### Workflow

- dev-together contract suite passes;
- handoff, plan, and review templates contain the new mandatory sections;
- the example `board.yaml` carries structured system closures and method deltas;
- deterministic rendering shows both structures in `board.html`, while an old
  string method-delta fixture still renders without error;
- the Stop Rule and review topology are unambiguous;
- protected skill workflow is green under an authorized lead review.

### Repository

- implementation branch is rebased on current main before execution and return;
- `git diff --check` passes;
- relevant shell and workflow syntax checks pass;
- existing repository gates required by the handoff standard pass through the
  guarded runner;
- the Git Provider feature branch and its protected untracked artifacts remain
  untouched.

## 9. Delivery and commit structure

The work ships as a separate method-productization PR with three logical
commits:

1. `docs: record D1 X/Y system-closure lessons`
2. `build: add guarded Mix execution runner`
3. `docs(dev-together): require X/Y plan-level closure`

The PR description links PR #1445 as the source incident but does not make the
method PR part of Git Provider runtime delivery.

## 10. Acceptance criteria

The design is complete only when all of the following are true:

- the source incident is preserved in bilingual, evidence-disciplined form;
- X and Y use the approved definitions everywhere;
- the safe Mix path is one executable command with tested resource semantics;
- future applicable plans/handoffs cannot omit Plan-level closure or resource
  envelope without explicitly declaring non-applicability;
- a second cross-Task regression triggers the Stop Rule;
- frozen implementation and parallel read-only review are distinct phases;
- method findings must produce an owner and recurrence-prevention destination;
- CI contract tests detect deletion or drift of these rules;
- the method work is isolated from the Git Provider feature PR;
- final return is rebased on current main and carries gate evidence.
