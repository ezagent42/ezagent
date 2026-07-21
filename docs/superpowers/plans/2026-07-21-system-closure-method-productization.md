# System-Closure Method Productization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Productize lessons collected from the Git Provider incident as bilingual forensic/runbook documentation, a bounded single-channel Mix/BEAM runner, and mandatory dev-together Plan-level closure contracts.

**Architecture:** Four layers carry the learning: a forensic record explains why, a runbook defines operator behavior, `scripts/guarded_mix.sh` makes the safe behavior executable, and dev-together templates plus CI contract tests make future Plans inherit it. This is a method-only branch; it never modifies Git Provider runtime code or its frozen D1 spec/plan.

**Tech Stack:** Markdown, Bash 4+, GNU `flock`, user systemd, GNU `time`, GitHub Actions, existing dev-together Markdown contracts.

## Global Constraints

- Before final integration, fetch and rebase `docs/system-closure-method-productization` onto current `origin/main`. The branch began at local snapshot `5afe9aa31` because Git transport could not fetch remote main `0a44d7b5` during design.
- Read `docs/superpowers/specs/2026-07-21-system-closure-method-productization-design.md` completely before editing.
- Use these terms exactly: **X problem = fundamental problem**, **Y problem = engineering problem**, **X-level correction**, **Y-level correction**, **recurrence-prevention proof**. Never substitute “Y engineering trigger.”
- English and `.zh_cn.md` peers have parallel sections and identical commands, limits, paths, SHAs, and evidence claims.
- Do not modify Git Provider production code, its frozen D1 spec/plan, unrelated reports/handoffs, or any `board.html`.
- Do not raise architecture/documentation caps, add `arch-allow`, or weaken gates.
- All real Mix/BEAM verification is serialized with the approved 5 GiB cgroup. Until the runner passes its own contract suite, use the canonical direct guard from the design spec; afterwards use `scripts/guarded_mix.sh`.
- Implementation and repair are serialized. Parallel agents, if used, perform read-only review only after freeze.
- `.claude/skills/dev-together/**` is protected and requires the authorized lead path.
- Use the exact Conventional Commit messages specified below.

---

### Task 1: Preserve the source-incident lessons and operating contract

**Files:**

- Create: `docs/notes/2026-07-21-git-provider-system-closure-retrospective.md`
- Create: `docs/notes/2026-07-21-git-provider-system-closure-retrospective.zh_cn.md`
- Create: `docs/runbook/guarded-mix-execution.md`
- Create: `docs/runbook/guarded-mix-execution.zh_cn.md`

**Interfaces:**

- Consumes: approved X/Y definitions and evidence boundaries from the design spec.
- Produces: the evidence record and operator contract referenced by Tasks 2–3.

- [ ] **Step 1: Write the English retrospective**

Use this exact top-level structure:

```markdown
# Git Provider system-closure retrospective

> Date: 2026-07-21
> Source: Git Provider V1 Plan D1 / PR #1445 working session
> Evidence rule: proven facts, supported inference, and unknowns are labelled separately.

## 1. Outcome and timeline
## 2. Process-loop and WSL OOM
### X problem — fundamental problem
### Y problems — engineering problems
### X-level correction
### Y-level correction
### Recurrence-prevention proof
## 3. Task-local convergence and repeated cross-Task repair
### X problem — fundamental problem
### Y problems — engineering problems
### X-level correction
### Y-level correction
### Recurrence-prevention proof
## 4. Other system findings
## 5. What changed during D1
## 6. What remains process debt
## 7. Requirement-to-evidence matrix
```

Section 4 covers terminal labels versus durable proof, DB/runtime/fixture drift,
proof/publish TOCTOU, historical proof versus stage predicates, late arch/doc
gates, the non-reproduced Identity failure, remote drift, and agent/network
limits. Record guarded runs at approximately 230–350 MiB and observed 6–7 GiB
VmmemWSL growth. State that the original runaway creator was not retained.

- [ ] **Step 2: Write the Chinese retrospective peer**

Use the same order and facts. Translate the five method headings exactly as:

```markdown
### X 问题——根本问题
### Y 问题——工程问题
### X 级修正
### Y 级修正
### 防复发证明
```

- [ ] **Step 3: Write the English guarded-Mix runbook**

Use these sections:

```markdown
# Guarded Mix/BEAM execution runbook

## 1. X problem — an invocation is an owned bounded job
## 2. Y problems this runbook closes
## 3. Mandatory use cases
## 4. Standard command
## 5. Resource-envelope defaults
## 6. Partition and timeout selection
## 7. Before-run checks
## 8. Required result evidence
## 9. After-run orphan checks
## 10. OOM and timeout forensics
## 11. Failure classification
## 12. Prohibited practices
## 13. Changing the envelope
```

The resource table is exact:

```markdown
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
```

Classify failures as product, fixture/model, resource, infrastructure, or
non-reproduced concurrency pollution. Rerunning until green does not erase a
recorded full-suite failure.

- [ ] **Step 4: Write the Chinese runbook peer**

Use the same 13 sections, command, limits, paths, and classifications.

- [ ] **Step 5: Verify bilingual structure and factual parity**

```bash
test "$(rg -c '^## ' docs/notes/2026-07-21-git-provider-system-closure-retrospective.md)" \
  -eq "$(rg -c '^## ' docs/notes/2026-07-21-git-provider-system-closure-retrospective.zh_cn.md)"
test "$(rg -c '^## ' docs/runbook/guarded-mix-execution.md)" \
  -eq "$(rg -c '^## ' docs/runbook/guarded-mix-execution.zh_cn.md)"
for token in 'MemoryHigh=4G' 'MemoryMax=5G' 'MemorySwapMax=0' \
  "ERL_FLAGS='+S 4:4'" '/tmp/ezagent-mix.lock'; do
  rg -F "$token" docs/runbook/guarded-mix-execution.md
  rg -F "$token" docs/runbook/guarded-mix-execution.zh_cn.md
done
! rg -n 'TBD|TODO|Y engineering trigger|工程诱因' \
  docs/notes/2026-07-21-git-provider-system-closure-retrospective* \
  docs/runbook/guarded-mix-execution*
git diff --check
```

Expected: all commands exit `0`; the negative search produces no matches.

- [ ] **Step 6: Commit Task 1**

```bash
git add docs/notes/2026-07-21-git-provider-system-closure-retrospective* \
  docs/runbook/guarded-mix-execution*
git diff --cached --check
git diff --cached --stat
git commit -m "docs: record X/Y system-closure lessons"
```

---

### Task 2: Add the guarded Mix/BEAM runner

**Files:**

- Create: `scripts/guarded_mix.sh`
- Create: `.github/scripts/guarded_mix_test.sh`
- Create: `.github/workflows/guarded-mix-contract.yml`

**Interfaces:**

- Consumes: `scripts/guarded_mix.sh [--timeout SECONDS] [--partition NAME] [--lock-wait SECONDS] <mix args...>`.
- Produces: the child exit code plus an execution summary containing classification and GNU-time evidence.

- [ ] **Step 1: Write failing runner contract tests**

Create `.github/scripts/guarded_mix_test.sh`. Put stubs first on `PATH`, use
`mktemp -d`, and clean it with a trap. Cover these named cases:

```text
passes_exact_resource_envelope
preserves_mix_argv_without_eval
propagates_child_exit_code
classifies_timeout_124
classifies_killed_137_without_claiming_proven_oom
fails_loudly_without_systemd_run
preserves_stderr
serializes_two_invocations
reports_lock_timeout_75
```

The `systemd-run` stub records one argument per line and never starts real Mix.
The serialization test uses a FIFO/handshake: first invocation reports entry and
blocks; second cannot report entry until release. A fixed sleep is not the proof.

Run:

```bash
bash .github/scripts/guarded_mix_test.sh
```

Expected RED: non-zero because `scripts/guarded_mix.sh` is absent.

- [ ] **Step 2: Implement parsing and prerequisites**

Start `scripts/guarded_mix.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

timeout_seconds=900
lock_wait_seconds=60
partition="${MIX_TEST_PARTITION:-guarded_$(id -u)_$$}"
lock_path="${EZAGENT_MIX_LOCK_PATH:-/tmp/ezagent-mix.lock}"

usage() {
  echo "usage: $0 [--timeout SECONDS] [--partition NAME] [--lock-wait SECONDS] <mix args...>" >&2
}

require_positive_integer() {
  case "$2" in
    ''|*[!0-9]*|0) echo "$1 must be a positive integer" >&2; exit 64 ;;
  esac
}
```

Parse options with a `while`/`case`, reject empty Mix argv, and require `flock`,
`systemd-run`, `timeout`, `mix`, and executable `/usr/bin/time`. Missing
prerequisites exit `69`; invalid CLI exits `64`. Never fall back to naked Mix.

- [ ] **Step 3: Implement bounded execution**

Acquire the lock separately so lock timeout cannot be confused with a child
exit code. Use an argv array and the exact command shape:

```bash
mix_args=("$@")
runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
bus_address="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$runtime_dir/bus}"
time_file="$(mktemp)"
trap 'rm -f "$time_file"' EXIT

exec 9>"$lock_path"
if ! flock -w "$lock_wait_seconds" 9; then
  echo "classification=lock_timeout exit_code=75" >&2
  exit 75
fi

set +e
env XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="$bus_address" \
  systemd-run --user --scope \
    -p MemoryHigh=4G -p MemoryMax=5G -p MemorySwapMax=0 \
    -p MemoryAccounting=yes -p OOMPolicy=kill \
  /usr/bin/time -v -o "$time_file" \
  timeout --signal=TERM --kill-after=15 "$timeout_seconds" \
  env SHELL=/bin/bash ERL_FLAGS='+S 4:4' MIX_ENV=test \
      MIX_TEST_PARTITION="$partition" \
  mix "${mix_args[@]}"
status=$?
set -e
```

Classify `0=success`, `75=lock_timeout`, `124=timeout`,
`137=killed_or_possible_oom`, and all other child codes as `command_failure`.
Never say `137` proves OOM. Print time evidence when present, classification,
exit code, and a host-wide matching-process snapshot via `pgrep -af` when
available. Explicitly state that this snapshot is not invocation-owned proof.
Exit with `status` unchanged. File descriptor 9 holds the lock through reporting
and closes automatically at process exit.

- [ ] **Step 4: Run contract tests to GREEN**

```bash
bash .github/scripts/guarded_mix_test.sh
```

Expected: `guarded Mix contract tests OK`, exit `0`.

- [ ] **Step 5: Add the isolated workflow**

Create `.github/workflows/guarded-mix-contract.yml`:

```yaml
name: Guarded Mix contract
on:
  pull_request:
    paths:
      - scripts/guarded_mix.sh
      - .github/scripts/guarded_mix_test.sh
      - .github/workflows/guarded-mix-contract.yml
      - docs/runbook/guarded-mix-execution.md
      - docs/runbook/guarded-mix-execution.zh_cn.md
  push:
    branches: [main]
    paths:
      - scripts/guarded_mix.sh
      - .github/scripts/guarded_mix_test.sh
      - .github/workflows/guarded-mix-contract.yml
jobs:
  contract:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: bash .github/scripts/guarded_mix_test.sh
```

- [ ] **Step 6: Smoke-test and validate**

```bash
chmod +x scripts/guarded_mix.sh .github/scripts/guarded_mix_test.sh
bash -n scripts/guarded_mix.sh
bash -n .github/scripts/guarded_mix_test.sh
scripts/guarded_mix.sh --timeout 120 --partition method_runner_smoke help
! rg -n 'eval|MemoryMax=[^5]|MemorySwapMax=[^0]' scripts/guarded_mix.sh
git diff --check
```

Expected: all exit `0`; smoke output includes `classification=success` and GNU
time evidence, with no runner-owned residual process.

- [ ] **Step 7: Commit Task 2**

```bash
git add scripts/guarded_mix.sh .github/scripts/guarded_mix_test.sh \
  .github/workflows/guarded-mix-contract.yml
git diff --cached --check
git diff --cached --stat
git commit -m "build: add guarded Mix execution runner"
```

---

### Task 3: Require X/Y Plan-level closure in dev-together

**Files:**

- Modify: `.claude/skills/dev-together/SKILL.md`
- Modify: `.claude/skills/dev-together/commands/plan.md`
- Modify: `.claude/skills/dev-together/commands/review.md`
- Modify: `.claude/skills/dev-together/references/handoff-standard.md`
- Modify: `.claude/skills/dev-together/references/handoff-template.md`
- Modify: `.claude/skills/dev-together/references/plan-template.md`
- Modify: `.claude/skills/dev-together/references/review-template.md`
- Modify: `.claude/skills/dev-together/scripts/render/board.example.yaml`
- Modify: `.claude/skills/dev-together/scripts/render/board2html.py`
- Create: `.github/scripts/dev-together-system-closure-contract_test.sh`
- Create: `.github/workflows/dev-together-system-closure-contract.yml`

**Interfaces:**

- Consumes: approved X/Y terminology, guarded runner, and closure matrix.
- Produces: mandatory planning/handoff/review fields plus a CI drift contract.

- [ ] **Step 1: Write the failing workflow contract**

Create `.github/scripts/dev-together-system-closure-contract_test.sh` with a
`require_text FILE TEXT` helper using `grep -Fq`. Create `test_tmp` with
`mktemp -d` and remove it in an EXIT trap. Assert:

```text
SKILL.md: Plan-level closure; guarded_mix.sh; frozen implementation; parallel read-only review
handoff-standard.md: X problem — fundamental problem; Y problem — engineering problem; Stop Rule; failure -> Plan invariant -> one root cause -> one integrated repair surface
handoff-template.md: ## X/Y problem framing; ## Plan-level system closure; ## Execution resource envelope; ## Recurrence-prevention proof
plan-template.md: Plan-level system closure; Durable proof; Integration evidence
review-template.md: X problem; Y problem; X-level correction; Y-level correction; Recurrence-prevention proof; Owner
board.example.yaml: system_closures:; x_problem:; plan_invariant:; durable_proof:; integration_evidence:; resource_envelope:
board.example.yaml review.method_deltas: finding:; y_problem:; recurrence_prevention_proof:; owner:
board.example.yaml cards: id:; closures:
```

Reject `工程诱因` and `Y engineering trigger` in all five files.

```bash
bash .github/scripts/dev-together-system-closure-contract_test.sh
```

Expected RED: first missing contract item.

- [ ] **Step 2: Update the skill contract**

Add `## Plan-level system closure` to `SKILL.md` stating:

```markdown
- Task is an implementation slice; the applicable Plan Closure is the correctness unit.
- Shared-state implementation and repair are serialized.
- After freeze, independent reviewers may work in parallel read-only mode.
- The lead combines findings into one integrated repair batch.
- A Closure is reopened only by an invariant/acceptance failure, not style churn.
- Applicable Mix/BEAM commands use `scripts/guarded_mix.sh`.
```

Define X/Y and link both new retrospective/runbook peers.

- [ ] **Step 3: Add discuss-first triggers and the Stop Rule**

In `handoff-standard.md`, add triggers for cross-Task state machines,
recovery/compensation, destructive terminal operations, multiple durable stores,
and proof/publish transaction boundaries. Add:

```markdown
### Stop Rule — stop local patching after the second cross-Task regression

When the same Closure exposes a second cross-Task regression, stop production
edits. Before continuing, write and review:

`failure -> Plan invariant -> one root cause -> one integrated repair surface`

The repair is serialized. Parallel agents may perform read-only review only
after the implementation is frozen.
```

- [ ] **Step 4: Extend the handoff template**

Insert before DoD:

```markdown
## X/Y problem framing
### X problem — fundamental problem
### Y problem — engineering problem
### X-level correction
### Y-level correction

## Plan-level system closure
| Closure | X problem | Plan invariant | Related Tasks | Durable proof | Integration evidence |
|---|---|---|---|---|---|

## Execution resource envelope
- Guarded runner: `scripts/guarded_mix.sh`
- MemoryHigh: `4G`
- MemoryMax: `5G`
- MemorySwapMax: `0`
- Timeout: <seconds and reason>
- Partition: <unique value>
- Serialization: `/tmp/ezagent-mix.lock`

## Recurrence-prevention proof
<Machine gate or mandatory workflow proof, with owner and evidence.>
```

Mechanical/non-Mix tasks may mark a section not applicable only with a reason.

- [ ] **Step 5: Extend plan and review templates**

Add after the plan conflict map:

```markdown
## §3a Plan-level system closure
| Closure | X problem | Plan invariant | Related tracks | Durable proof | Integration evidence |
|---|---|---|---|---|---|
**Closure checkpoints:** <freeze commits and gates>
**Stop Rule owner:** <lead>
```

Change review method-deltas to:

```markdown
| # | Finding | X problem | Y problem | X-level correction | Y-level correction | Recurrence-prevention proof | Owner / destination |
|---|---|---|---|---|---|---|---|
```

State that “be careful”, “add tests”, or “review harder” is incomplete without an
owner and a docs/runner/CI/skill/process-debt destination.

- [ ] **Step 6: Make `board.yaml` the structured Plan-level source of truth**

Update `commands/plan.md` to require new applicable boards to write:

```yaml
system_closures:
  - id: "closure-a"
    x_problem: "Task-local completion cannot prove the cross-task invariant."
    plan_invariant: "One durable owner exists for every external result."
    related_cards: ["provider-result-ownership"]
    durable_proof: "operation journal + exact cleanup state"
    integration_evidence: "focused + provider-full + frozen read-only review"
    resource_envelope:
      runner: "scripts/guarded_mix.sh"
      memory_high: "4G"
      memory_max: "5G"
      memory_swap_max: "0"
      lock: "/tmp/ezagent-mix.lock"
```

Cards for applicable work have a stable `id` and add
`closures: ["closure-a"]`. Update
`commands/review.md` to require structured new method deltas:

```yaml
review:
  method_deltas:
    - finding: "Task-local green missed a cross-task terminal race."
      x_problem: "Task was treated as the correctness closure."
      y_problem: "Proof and publication were reviewed in separate files."
      x_level_correction: "Plan Closure is the correctness unit."
      y_level_correction: "Add frozen Closure review and a Stop Rule."
      recurrence_prevention_proof: "dev-together contract workflow"
      owner: "lead"
      destination: "skill-change"
```

Put both forms into `scripts/render/board.example.yaml` as the canonical schema.

- [ ] **Step 7: Render structured closures and method deltas**

In `board2html.py`, add pure helpers:

```python
def render_system_closures(closures):
    items = []
    for closure in closures or []:
        envelope = closure.get("resource_envelope", {}) or {}
        resource_text = " · ".join(
            f"{key}={value}" for key, value in envelope.items()
        )
        related = ", ".join(closure.get("related_cards", []) or [])
        items.append(
            '<div class="closure">'
            f'<b>{e(closure.get("id"))}</b>'
            f'<div><strong>X problem:</strong> {e(closure.get("x_problem"))}</div>'
            f'<div><strong>Invariant:</strong> {e(closure.get("plan_invariant"))}</div>'
            f'<div><strong>Cards:</strong> {e(related)}</div>'
            f'<div><strong>Durable proof:</strong> {e(closure.get("durable_proof"))}</div>'
            f'<div><strong>Integration evidence:</strong> {e(closure.get("integration_evidence"))}</div>'
            f'<div><strong>Resource envelope:</strong> {e(resource_text)}</div>'
            '</div>'
        )
    if not items:
        return ""
    return '<section class="closures"><h2>Plan-level system closure · 系统闭环</h2>' + "".join(items) + "</section>"

def render_method_delta(delta):
    if isinstance(delta, str):
        return "• " + e(delta)
    labels = [
        ("Finding", "finding"),
        ("X problem", "x_problem"),
        ("Y problem", "y_problem"),
        ("X-level correction", "x_level_correction"),
        ("Y-level correction", "y_level_correction"),
        ("Recurrence-prevention proof", "recurrence_prevention_proof"),
        ("Owner", "owner"),
        ("Destination", "destination"),
    ]
    return "<div class=\"method-delta\">" + "".join(
        f"<div><strong>{e(label)}:</strong> {e(delta.get(key))}</div>"
        for label, key in labels
    ) + "</div>"
```

Add focused `.closures`, `.closure`, and `.method-delta` CSS using existing
colors/spacing. Compute `closures_html = render_system_closures(b.get("system_closures"))`
and insert it between hero and kanban columns. Replace the existing method-delta
join with:

```python
md = "".join(render_method_delta(x) for x in (rv.get("method_deltas", []) or []))
```

Do not change unrelated board layout or hand-edit generated HTML.

Extend the shell contract test to render the example deterministically:

```bash
rendered_board="$test_tmp/board.html"
uv run --with pyyaml python \
  .claude/skills/dev-together/scripts/render/board2html.py \
  .claude/skills/dev-together/scripts/render/board.example.yaml \
  "$rendered_board"
grep -Fq 'Plan-level system closure' "$rendered_board"
grep -Fq 'X problem' "$rendered_board"
grep -Fq 'Recurrence-prevention proof' "$rendered_board"
```

Also render a temporary legacy board containing a string `method_deltas` entry
and assert that the string remains visible.

- [ ] **Step 8: Run the contract to GREEN**

```bash
bash .github/scripts/dev-together-system-closure-contract_test.sh
```

Expected: `dev-together system-closure contract tests OK`, exit `0`.

- [ ] **Step 9: Add the isolated workflow**

Create `.github/workflows/dev-together-system-closure-contract.yml`:

```yaml
name: Dev-together system-closure contract
on:
  pull_request:
    paths:
      - .claude/skills/dev-together/**
      - .github/scripts/dev-together-system-closure-contract_test.sh
      - .github/workflows/dev-together-system-closure-contract.yml
  push:
    branches: [main]
    paths:
      - .claude/skills/dev-together/**
jobs:
  contract:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: astral-sh/setup-uv@v5
      - run: bash .github/scripts/dev-together-system-closure-contract_test.sh
```

- [ ] **Step 10: Validate and commit Task 3**

```bash
chmod +x .github/scripts/dev-together-system-closure-contract_test.sh
bash .claude/skills/dev-together/scripts/validate_skill.sh
bash .github/scripts/dev-together-system-closure-contract_test.sh
git diff --check
git add .claude/skills/dev-together/SKILL.md \
  .claude/skills/dev-together/commands/plan.md \
  .claude/skills/dev-together/commands/review.md \
  .claude/skills/dev-together/references/handoff-standard.md \
  .claude/skills/dev-together/references/handoff-template.md \
  .claude/skills/dev-together/references/plan-template.md \
  .claude/skills/dev-together/references/review-template.md \
  .claude/skills/dev-together/scripts/render/board.example.yaml \
  .claude/skills/dev-together/scripts/render/board2html.py \
  .github/scripts/dev-together-system-closure-contract_test.sh \
  .github/workflows/dev-together-system-closure-contract.yml
git diff --cached --check
git diff --cached --stat
git commit -m "docs(dev-together): require X/Y plan-level closure"
```

---

### Task 4: Integrated verification and return package

**Files:**

- Verify: all Task 1–3 files.
- Create via dev-together return: `docs/together/2026-07-21/returns/system-closure-method-productization.md`.

**Interfaces:**

- Consumes: three frozen implementation commits.
- Produces: rebased, guarded, independently reviewed return evidence.

- [ ] **Step 1: Rebase on current main**

```bash
git fetch origin main
git rebase origin/main
```

Expected: clean rebase. If transport is unavailable, do not claim return-ready.

- [ ] **Step 2: Run shell/skill contracts**

```bash
bash .github/scripts/guarded_mix_test.sh
bash .github/scripts/dev-together-system-closure-contract_test.sh
bash .claude/skills/dev-together/scripts/validate_skill.sh
```

Expected: all exit `0`.

- [ ] **Step 3: Run repository gates through the runner, serially**

```bash
scripts/guarded_mix.sh --timeout 300 --partition method_arch_scan ezagent.arch.scan
scripts/guarded_mix.sh --timeout 300 --partition method_doc_scan ezagent.doc.scan
scripts/guarded_mix.sh --timeout 300 --partition method_uri_scan ezagent.uri_query.scan
scripts/guarded_mix.sh --timeout 900 --partition method_invariants ezagent.check_invariants
scripts/guarded_mix.sh --timeout 1800 --partition method_precommit precommit
```

Expected: all exit `0`, with classification, Max RSS, swap, and no runner-owned
residual process. Never run them in parallel.

- [ ] **Step 4: Verify boundaries**

```bash
git status --short
git diff --check origin/main...HEAD
git log --oneline origin/main..HEAD
git diff --name-only origin/main...HEAD
```

Expected: only approved method files; no Git Provider runtime file, unrelated
handoff/report, or `board.html`.

- [ ] **Step 5: Run two frozen read-only reviews**

Reviewer A checks runner argv safety, locking, limits, exit propagation, timeout,
and honest OOM classification. Reviewer B checks X/Y terminology, closure matrix,
Stop Rule, method writeback, bilingual parity, and protected-skill scope. Neither
edits files or runs Mix. Findings go to one serialized repair owner, then back to
the original reviewers. Both final verdicts must be `APPROVED`.

- [ ] **Step 6: Write the return artifact and completion evidence**

Record commit SHAs, line-by-line acceptance, contract outputs, guarded gate/RSS
evidence, review verdicts, current-main rebase, protected-skill owner requirement,
and the deferred decision about CI-wide runner enforcement.

Do not declare complete unless all are true:

```text
bilingual retrospective and runbook present
runner contracts and real guarded smoke green
dev-together contract green
arch/doc/uri/invariants/precommit green under guard
two read-only reviewers APPROVED
branch rebased on current main
return artifact present
protected skill owner path acknowledged
```
