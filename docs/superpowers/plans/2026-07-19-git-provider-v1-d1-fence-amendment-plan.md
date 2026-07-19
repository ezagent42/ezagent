# Git Provider V1 D1 Fence Amendment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Make callback recovery obey D0.1 stable-input idempotency while fencing stale workers and preserving cleanup obligations.

**Architecture:** Keep Task 7 below pointer CAS/finalization. Separate the stable credential command from a private launch fence; compare the captured launch fence at result commit. A terminal transition and callback claim linearize on the connection row, with Task 8 owning pointer/cleanup consequences.

**Tech Stack:** Elixir/OTP, Phoenix domain code, Ecto/PostgreSQL, Phoenix LiveView test helpers where applicable, telemetry, guarded Mix tests.

## Global Constraints

- Work only in `/home/huangjiajia/ezagent/.worktrees/git-domain-spine` on `feat/git-domain-spine`.
- Never stage/edit/delete protected handoff/report files or any existing unrelated untracked files.
- Never send claim token, attempt version, or lease deadline as D0.1 credential input.
- Never hold a database transaction across provider or credential effects.
- Task 7 ends at `backend_committed` or `cleanup_pending`; Task 8 owns pointer CAS, shred, revoke, attempt terminalization, and finalization.
- Every Mix command uses `systemd-run --user --scope -p MemoryHigh=768M -p MemoryMax=1G -p MemorySwapMax=0 -p MemoryAccounting=yes -p OOMPolicy=kill`, `timeout`, `SHELL=/bin/bash`, and `ERL_FLAGS='+S 4:4'`; tests are serialized.

## Files and responsibilities

- `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/store.ex`: stable operation lookup, launch-fence capture/verification, connection linearization, safe/public receipt separation.
- `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/local_authorization_backend.ex`: stable credential command and begin-time execution-identity binding.
- `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/operation.ex`: stable digest and receipt changeset contract.
- `apps/ezagent_domain_provider_connection/lib/ezagent_domain_provider_connection/connection.ex` and related migration only if the shared connection fence requires a durable field.
- `apps/ezagent_domain_provider_connection/test/integration/callback_recovery_test.exs`: real lease-steal, strict digest, stale-result, terminal barrier tests.
- `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/local_authorization_backend_test.exs`: command digest and execution-identity tests.
- `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/schema_test.exs`: full operation key and conditional constraint tests.
- `docs/superpowers/specs/2026-07-19-git-provider-v1-d1-fence-amendment-design.md`: approved protocol amendment.

### Task 1: RED tests for stable command and true launch fence

**Files:**
- Modify: `apps/ezagent_domain_provider_connection/test/integration/callback_recovery_test.exs`
- Modify: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/local_authorization_backend_test.exs`

**Interfaces:**
- The credential sink records canonical input digest by `{backend_pair_id, operation_class, correlation_id}` and rejects a changed digest.
- The store exposes no new public secret-bearing API; launch fence remains private to the store.

- [ ] Add a test asserting lease renewal produces byte-equivalent credential command input while the local attempt version changes.
- [ ] Add a deterministic barrier that updates both attempt and operation fences, kills or releases the old worker, and asserts its returned result becomes `cleanup_pending`.
- [ ] Add a conflicting-result case that rejects a different credential ref/version for the same stable correlation.
- [ ] Run only the two test files under the guarded 1 GB scope and record the expected RED failures.

### Task 2: Implement stable command and launch-fence commit

**Files:**
- Modify: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/local_authorization_backend.ex`
- Modify: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/store.ex`
- Modify: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/operation.ex`

**Interfaces:**
- `credential_command/3` contains stable scope only.
- Private `launch_fence/3` captures operation id, connection version, attempt version, and claim token.
- `journal_credential_result/5` receives the captured fence and commits only on exact equality; mismatch persists `cleanup_pending`.

- [ ] Remove mutable lease fields from the credential command and include execution identity plus all stable D0 scope fields.
- [ ] Capture the launch fence immediately before the external credential call.
- [ ] Lock connection, attempt, operation in order on return and compare captured versus current fence.
- [ ] Preserve exact result ref/version/correlation for cleanup; allow only exact already-committed result reconciliation.
- [ ] Run the Task 1 focused tests until GREEN.

### Task 3: Bind execution identity at begin and harden stable scope

**Files:**
- Modify: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/local_authorization_backend.ex`
- Modify: `apps/ezagent_domain_provider_connection/lib/ezagent_domain_provider_connection/connection.ex` only if a schema field is required by existing patterns.
- Modify: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/local_authorization_backend_test.exs`

**Interfaces:**
- Begin durable backend rows and authenticated data carry execution identity.
- Callback consume rejects any row/attempt/operation/connection execution-identity drift before driver or credential effects.

- [ ] Add execution identity to begin subject, durable backend record binding, begin/row AAD, and stable operation digest.
- [ ] Add RED then GREEN tests for drift between begin and operation creation and drift after committed receipt.
- [ ] Verify provider-returned execution identity matches the bound value before creating the handoff.

### Task 4: Enforce connection linearization and receipt boundary

**Files:**
- Modify: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/store.ex`
- Modify: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/callback_ingress.ex`
- Modify: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/transition.ex` only for the shared connection lock/generation-fence contract.
- Modify: `apps/ezagent_domain_provider_connection/test/integration/callback_recovery_test.exs`

**Interfaces:**
- Connection transition and callback claim use the connection row lock and generation fence.
- Public callback success contains only connection id, status, and connection version.

- [ ] Add a deterministic claim-versus-terminal barrier proving the first durable linearization point wins and the loser records a safe obligation/error.
- [ ] Recheck the captured connection generation immediately before provider effect.
- [ ] Remove credential ref/version from the public ingress result while retaining them in the internal operation receipt.

### Task 5: Harden operation lookup and schema constraints

**Files:**
- Modify: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/store.ex`
- Modify: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/schema_test.exs`

**Interfaces:**
- All store operation reads use `{backend_pair_id, operation_class: "store", correlation_id}`.
- Existing conditional migration remains fail-closed with no defaults/backfill.

- [ ] Update prepare, reconcile, recovery, and committed fast-path queries to include operation class.
- [ ] Add a schema test with another operation class reusing a correlation id and prove store recovery selects only the store operation.
- [ ] Add committed receipt scope/digest verification using a real calculated digest, not a placeholder string.

### Task 6: Verification, Sol review, and handoff

**Files:**
- Modify: `.superpowers/sdd/task-7-report.md` only after implementation and review; keep it unstaged unless explicitly authorized.

- [ ] Run guarded focused callback/schema/local-backend tests.
- [ ] Run guarded provider app suite and core artifact/signing/Cap suite serially.
- [ ] Run `mix format --check-formatted` and `git diff --check` under the same scope.
- [ ] Stage only intended code/tests/migrations; exclude all protected files and reports.
- [ ] Ask Sol for a fresh independent X-first review of the staged diff.
- [ ] If Sol reports any new Critical, stop and revise the protocol before more code.
- [ ] Commit only after clean review with message `fix(provider-connection): fence callback effect ownership`.

### Guarded command template

```bash
env XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
  systemd-run --user --scope \
    -p MemoryHigh=768M -p MemoryMax=1G -p MemorySwapMax=0 \
    -p MemoryAccounting=yes -p OOMPolicy=kill \
    timeout 180 env SHELL=/bin/bash ERL_FLAGS='+S 4:4' MIX_ENV=test \
    mix test path/to/focused_test.exs --no-start
```
