# Git Provider V1-A Security Prerequisites Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce executable evidence and an approved GO/NO-GO decision for secret storage, SSH parsing, broker isolation, and the W29 Git transport.

**Architecture:** This plan does not implement the Git domain or user-facing credentials. It inventories current primitives, adds test-only security probes and a provider-independent transport prototype, and records one approved interface/strategy. A missing security boundary ends in NO-GO and a separate prerequisite design; it never degrades to a temp-key workaround.

**Tech Stack:** Elixir/OTP, ExUnit, `Ezagent.Runtime.OsProcess`, Linux process/filesystem inspection, and a pure GitHub Git Data request-plan prototype interpreted by a local fake.

## Global Constraints

- Use sentinel credentials only: `EZAGENT_SECRET_SENTINEL_DO_NOT_SHIP`.
- Do not send network traffic to GitHub or canary in this plan.
- Do not add production credential storage, OAuth routes, migrations, or UI.
- Do not use raw `Port.open`, `System.cmd`, shell command strings, MuonTrap, Docker-in-Docker, raw RPC, arbitrary eval, or live-node mutation.
- Any subprocess uses argv-list `Ezagent.Runtime.OsProcess.spawn/2` and is cleaned through its documented lifecycle.
- A GO claim requires fresh executable evidence; absence of a demonstrated isolation mechanism is NO-GO.
- Do not push, deploy, or merge.

---

### Task 1: Inventory current security and capability primitives

**Files:**
- Create: `docs/superpowers/notes/2026-07-15-git-provider-v1-a-inventory.md`
- Inspect: `apps/ezagent_core/lib/ezagent/runtime/os_process.ex`
- Inspect: `apps/ezagent_core/lib/ezagent/cap.ex`
- Inspect: `apps/ezagent_core/lib/ezagent/cap/signing.ex`
- Inspect: `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_registry.ex`
- Inspect: `apps/ezagent_core/lib/ezagent/plugin.ex`

**Interfaces:**
- Consumes: current `origin/main` repository facts.
- Produces: evidence-backed inventory only; no production interface.

- [ ] **Step 1: Record the exact current Cap interface**

Run:

```bash
sed -n '1,240p' apps/ezagent_core/lib/ezagent/cap.ex
rg -n "def issue|def verify_for|signature|grantee_uri|authorization" \
  apps/ezagent_core/lib/ezagent/{cap,capability}.ex
```

Expected: `issue/3`, signed artifact fields, `verify_for/2`, and accepted authorization tuple forms are visible. Copy exact signatures into the inventory note.

- [ ] **Step 2: Record subprocess guarantees and gaps**

Run:

```bash
sed -n '1,260p' apps/ezagent_core/lib/ezagent/runtime/os_process.ex
rg -n "OsProcess.spawn|System.cmd|Port.open" apps -g '*.ex'
id
uname -a
```

Expected: argv-safe erlexec/process-group guarantees are documented; OS-user, mount namespace, and secret isolation are marked absent unless evidenced by another repository primitive.

- [ ] **Step 3: Record secret and SSH parser candidates**

Run:

```bash
rg -n "SecretStore|secret_store|encrypt|KMS|Vault|credential" apps config -g '*.ex' -g '*.exs'
mix deps | rg 'ssh|pem|jose|cloak|vault|kms|secret' || true
```

Expected: every candidate is named with file/module evidence. “Credential directory exists” must not be classified as encrypted secret storage.

- [ ] **Step 4: Write and verify the inventory note**

The note contains tables for Cap, OS process, secret backend, SSH parser, plugin registration, and current gaps. End with `Inventory complete; no GO decision yet.`

Run:

```bash
git diff --check
rg -n "Inventory complete; no GO decision yet" \
  docs/superpowers/notes/2026-07-15-git-provider-v1-a-inventory.md
```

Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/notes/2026-07-15-git-provider-v1-a-inventory.md
git commit -m "docs(git): inventory provider security primitives"
```

---

### Task 2: Reproduce the same-UID credential exposure

**Files:**
- Create: `apps/ezagent_core/test/security/os_process_secret_isolation_probe_test.exs`
- Create: `docs/superpowers/notes/2026-07-15-git-provider-v1-a-isolation-probe.md`

**Interfaces:**
- Consumes: `Ezagent.Runtime.OsProcess.spawn/2`.
- Produces: a test-only reproduction proving whether a same-UID agent can observe a broker-owned sentinel file/process environment.

- [ ] **Step 1: Write the exposure probe**

The test creates a mode-0600 sentinel file outside the agent cwd, starts an argv-list child under the same runtime identity, and asks the child to read that known path. It uses no real key.

```elixir
test "same uid is not a credential isolation boundary" do
  secret_path = Path.join(tmp_dir(), "broker-secret")
  File.write!(secret_path, "EZAGENT_SECRET_SENTINEL_DO_NOT_SHIP")
  File.chmod!(secret_path, 0o600)

  assert {:ok, output} = Probe.run_argv(["/bin/cat", secret_path])
  assert output == "EZAGENT_SECRET_SENTINEL_DO_NOT_SHIP"
end
```

`Probe.run_argv/1` is test support around `Ezagent.Runtime.OsProcess.spawn/2`; it traps exits, bounds output/time, and always calls `OsProcess.stop/1`.

- [ ] **Step 2: Run the focused reproduction**

Run:

```bash
MIX_ENV=test mix test apps/ezagent_core/test/security/os_process_secret_isolation_probe_test.exs --trace
```

Expected on the current same-UID runtime: PASS, proving the child can read the sentinel and therefore mode 0600 is not isolation. If the environment contradicts this, record exact UID/mount evidence rather than changing the assertion silently.

- [ ] **Step 3: Probe environment and process visibility safely**

Extend the test with sentinel-only cases for a known environment variable and `/proc/<pid>/environ` when permitted. Fixed expected outcomes are recorded in the note; permission denial is evidence, not automatically a sufficient boundary.

- [ ] **Step 4: Write the reproduce-first note and commit**

The note records commands, OS/UID, observed output, and conclusion:

```text
Current OsProcess boundary: lifecycle-safe, credential-isolation NO-GO by itself.
```

Run:

```bash
git diff --check
git add apps/ezagent_core/test/security/os_process_secret_isolation_probe_test.exs \
  docs/superpowers/notes/2026-07-15-git-provider-v1-a-isolation-probe.md
git commit -m "test(git): reproduce same-uid secret exposure"
```

---

### Task 3: Evaluate concrete broker isolation candidates

**Files:**
- Create: `docs/superpowers/notes/2026-07-15-git-provider-v1-a-broker-options.md`
- Create only if supported by the host: `apps/ezagent_core/test/security/os_process_isolation_candidate_test.exs`

**Interfaces:**
- Consumes: Task 2 reproduction and repository-approved deployment constraints.
- Produces: one evidence-backed broker candidate or explicit SSH broker NO-GO.

- [ ] **Step 1: Evaluate candidates without adding dependencies**

Evaluate exactly these candidates:

```text
A. separate OS user with inaccessible secret directory and controlled broker IPC
B. existing container/sandbox boundary already used by production agents
C. remote signer/credential service with structured Git-only requests
D. no approved boundary available
```

For A/B/C, record provisioning ownership, IPC authentication, host-key policy, crash cleanup, deployment support, and how an agent is prevented from reusing the interface.

- [ ] **Step 2: Prototype only candidates already supported by the host**

Do not use `sudo` or mutate host users. If the current test environment already exposes an approved boundary, create a test using sentinel material and assert both direct read and interface reuse fail. Otherwise select D without fabricating a prototype.

- [ ] **Step 3: Write the decision**

The note ends with exactly one decision line. A GO line starts with `SSH broker
isolation: GO —` and then names candidate A, B, or C plus the exact evidence test
path. A NO-GO line is exactly:

```text
SSH broker isolation: NO-GO — no approved agent-inaccessible credential boundary exists
```

- [ ] **Step 4: Verify and commit**

Run:

```bash
git diff --check
rg -n "SSH broker isolation: (GO|NO-GO)" \
  docs/superpowers/notes/2026-07-15-git-provider-v1-a-broker-options.md
git add docs/superpowers/notes/2026-07-15-git-provider-v1-a-broker-options.md \
  apps/ezagent_core/test/security/os_process_isolation_candidate_test.exs
git commit -m "docs(git): decide broker isolation boundary"
```

If the optional test file does not exist, omit it from `git add`.

---

### Task 4: Prototype GitHub API commit transport without credentials

**Files:**
- Create: `apps/ezagent_core/test/support/github_git_data_plan.ex`
- Create: `apps/ezagent_core/test/security/github_api_commit_transport_test.exs`
- Create: `docs/superpowers/notes/2026-07-15-git-provider-v1-a-github-api-transport.md`

**Interfaces:**
- Consumes: normalized file changes and base/ref metadata; no HTTP dependency.
- Produces: test-only `GithubGitDataPlan.build/2` plus a local interpreter demonstrating blob/tree/commit/ref/PR sequencing and redacted results. Plan D later implements the approved requests with Req.

- [ ] **Step 1: Write the fake-server contract test**

Build a pure request plan and interpret it with a local fake. The plan must contain this sequence:

```text
GET base ref -> POST blobs -> POST tree -> POST commit -> POST ref -> POST pull
```

The request planner accepts normalized file changes and returns no Authorization header or token field. The local interpreter injects sentinel authentication internally and returns only change-request ID/URL/head SHA.

- [ ] **Step 2: Add security cases**

Test path traversal rejection, symlink/submodule rejection, bounded file/count/total bytes, base-SHA mismatch, ref-name validation, replay idempotency key, partial failure, token/header redaction, and no raw GitHub response leakage.

- [ ] **Step 3: Run the prototype**

Run:

```bash
MIX_ENV=test mix test apps/ezagent_core/test/security/github_api_commit_transport_test.exs --trace
```

Expected: PASS using only the local fake server; no GitHub network call.

- [ ] **Step 4: Write limitations and commit**

The note explicitly states:

```text
public anonymous checkout only; GitHub-specific; no private-repository checkout;
not final provider-neutral SSH transport; OAuth lifecycle remains Plan D.
```

Run:

```bash
git diff --check
git add apps/ezagent_core/test/support/github_git_data_plan.ex \
  apps/ezagent_core/test/security/github_api_commit_transport_test.exs \
  docs/superpowers/notes/2026-07-15-git-provider-v1-a-github-api-transport.md
git commit -m "test(git): prototype API commit transport"
```

---

### Task 5: Select the W29 transport and define downstream interfaces

**Files:**
- Create: `docs/superpowers/specs/2026-07-15-git-provider-v1-a-decisions.md`
- Modify: `docs/superpowers/specs/2026-07-15-git-provider-v1-design.md`
- Modify: `docs/superpowers/plans/2026-07-15-git-provider-v1.md`

**Interfaces:**
- Consumes: Tasks 1–4 evidence.
- Produces: approved GO/NO-GO matrix and exact interfaces that Plan B may consume.

- [ ] **Step 1: Write the decision matrix**

```markdown
| Concern | Decision | Evidence | Consequence |
|---|---|---|---|
| Encrypted secret backend | GO/NO-GO | exact module/test or missing primitive | self-service credentials allowed/blocked |
| SSH parser | GO/NO-GO | exact dependency/probe | accepted formats or import blocked |
| SSH broker isolation | GO/NO-GO | Task 3 | generic SSH transport allowed/blocked |
| GitHub API transport | GO/NO-GO | Task 4 | W29 public-repo path allowed/blocked |
```

At least one W29 transport row must be GO before Plan B can include a real change-request path.

- [ ] **Step 2: Define exact downstream interfaces**

The decision spec names concrete modules/types for only approved mechanisms. It must include normalized `RepositoryRef`, `FileChange`, `ChangeRequest`, error union, secret-use boundary, and transport callback signatures. No `map()` callback or raw secret getter is allowed.

- [ ] **Step 3: Update design and roadmap**

Mark the selected W29 strategy, blocked strategies, private-repository status, and which Plans B–E are now eligible to be written. Do not write those plans in this task.

- [ ] **Step 4: Run plan verification**

Run:

```bash
MIX_ENV=test mix test \
  apps/ezagent_core/test/security/os_process_secret_isolation_probe_test.exs \
  apps/ezagent_core/test/security/github_api_commit_transport_test.exs
git diff --check
rg -n "GO|NO-GO" docs/superpowers/specs/2026-07-15-git-provider-v1-a-decisions.md
```

Expected: tests exit 0 and every decision row is explicit.

- [ ] **Step 5: Request review and commit**

Request architecture/security review of the evidence and decisions. Fix every Critical/Important finding, rerun Step 4, then:

```bash
git add docs/superpowers/specs/2026-07-15-git-provider-v1-a-decisions.md \
  docs/superpowers/specs/2026-07-15-git-provider-v1-design.md \
  docs/superpowers/plans/2026-07-15-git-provider-v1.md
git commit -m "docs(git): select provider V1 transport"
```

## Completion gate

Plan A is complete only when:

- same-UID exposure has a reproducible test;
- an SSH broker GO has agent-inaccessible evidence, otherwise it is NO-GO;
- GitHub API transport has a local fake-server prototype and explicit limitations;
- secret backend/parser decisions are explicit;
- design and roadmap match current signed Cap semantics;
- no production credential, OAuth, domain, UI, deploy, or merge change was made.
