# Guarded Mix/BEAM execution runbook

## 1. X problem — an invocation is an owned bounded job

The fundamental problem is treating a Mix/BEAM invocation as a command that was
started. It is instead an owned bounded job: one serialized process tree, one
resource envelope, one deadline, one partition, cleanup evidence, and a result
whose original exit status is preserved.

## 2. Y problems this runbook closes

This contract closes bare or overlapping Mix, absent cgroup/scheduler limits,
unbounded waits, partition collisions, missing resource evidence, ambiguous
agent disconnects, and unchecked orphan processes. It does not diagnose a
product failure or kill a process it did not start.

## 3. Mandatory use cases

Use the guarded runner for local test, compile, migration verification, and
precommit work. Use it whenever a dev-together handoff requires Mix/BEAM. A
mechanical or non-Mix handoff may mark the envelope not applicable only with a
reason. The decision to route every existing CI invocation through this runner
is outside this first adoption step.

## 4. Standard command

Run from the umbrella root:

```bash
scripts/guarded_mix.sh \
  --timeout 900 \
  --partition provider_full \
  test apps/ezagent_domain_provider_connection/test
```

The effective bounded command must include these literal settings:

```text
MemoryHigh=4G MemoryMax=5G MemorySwapMax=0 MemoryAccounting=yes OOMPolicy=kill
ERL_FLAGS='+S 4:4' MIX_ENV=test
```

Pass Mix arguments after runner options. The runner preserves them as argv and
never evaluates a command string.

## 5. Resource-envelope defaults

| Setting | Value |
|---|---|
| Lock | `/tmp/ezagent-mix.lock` |
| MemoryHigh | `4G` |
| MemoryMax | `5G` |
| MemorySwapMax | `0` |
| MemoryAccounting | `yes` |
| OOMPolicy | `kill` |
| ERL_FLAGS | `+S 4:4` |
| MIX_ENV | `test` |

These are one contract. Do not selectively omit a setting.

## 6. Partition and timeout selection

Give every run a unique, descriptive partition containing the work or closure
name, for example `provider_full`; never reuse one across concurrent jobs.
Choose the smallest defensible timeout from prior evidence and record it in the
handoff. The default is 900 seconds. A longer timeout requires a reason; it does
not authorize a larger memory envelope.

## 7. Before-run checks

1. Confirm the command is run from the umbrella root and the intended Git SHA
   and working tree are recorded.
2. Confirm `flock`, `systemd-run`, `timeout`, `mix`, and executable
   `/usr/bin/time` are available, and the user systemd manager works.
3. Check matching Mix/BEAM processes and record anything already present; do not
   kill processes merely because they match.
4. Confirm no other owned job should hold `/tmp/ezagent-mix.lock` and select a
   unique partition.
5. Record timeout, exact Mix argv, resource envelope, database/fixture setup,
   and the expected proof.

Missing prerequisites are setup failures. Do not fall back to naked Mix.

## 8. Required result evidence

Retain the start/end time, Git SHA, exact argv, partition, timeout, child exit
code, elapsed time, Max RSS, swap, result classification, and post-run matching
process report. Retain the first failing output and stderr even if a later run
passes. For a test, record the suite/file and counts; for compile, migration, or
precommit, record the named gate and its exit result.

## 9. After-run orphan checks

After every exit, report matching Mix/BEAM processes and compare them with the
before-run record. Do not use a broad kill command and do not kill unrelated
processes. If the owned systemd scope remains, capture its status and process
tree before stopping only that scope. A run is not complete until this check is
recorded and the lock is released.

## 10. OOM and timeout forensics

On timeout, retain exit `124`, scope status, child process tree, resource
summary, last stdout/stderr, and the requested timeout. On signal exit such as
`137`, record that the job was killed; do not call it proven OOM without cgroup
or kernel evidence. Capture cgroup memory events, systemd scope properties, and
available kernel/journal messages before cleanup. Record Max RSS and swap.
Agent disconnect alone is infrastructure evidence, not an OOM diagnosis.

## 11. Failure classification

Classify the recorded result as exactly one of these, or keep it unresolved:

- **product:** reproducible behavior violates the product contract.
- **fixture/model:** DB, runtime, fixture, or test assumptions disagree.
- **resource:** the bounded job reaches a proven resource or deadline limit.
- **infrastructure:** prerequisites, user systemd, database, transport, host, or
  agent connectivity prevents a valid run.
- **non-reproduced concurrency pollution:** a recorded failure does not recur
  under isolated guarded conditions and lacks evidence for another class.

Later evidence may reclassify a failure but must not erase the original record.
Rerunning until green does not erase a recorded full-suite failure.

## 12. Prohibited practices

- No parallel, overlapping, or naked local Mix/BEAM invocation.
- No naked `mix precommit`.
- No fallback when the lock, user systemd, timeout, or accounting is unavailable.
- No shared test partition for jobs that can overlap.
- No broad process kill, workspace cleanup, baseline raising, `arch-allow`, or
  gate weakening to obtain green output.
- No repeated reruns presented as proof that a prior failure did not happen.
- No claim that exit `137`, agent disconnect, or VmmemWSL growth alone proves OOM
  or identifies the creating process.

## 13. Changing the envelope

Do not change limits ad hoc. Propose a contract change with the workload,
guarded measurements, reason, risk, owner, expiry/permanence decision, and
updates to the runner, both runbooks, tests, workflow templates, and CI contract.
Review it as a method change. Until merged, use the standard envelope or report
the workload blocked; never silently raise a baseline or bypass the guard.
