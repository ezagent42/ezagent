# Durable Session Team Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure every successfully created Session with declared immediate agent roles has a durable, restart-recoverable installation job instead of relying on a one-shot Task.

**Architecture:** Persist one installation obligation per Session before the create handler reports success. An immediate supervised Task and a periodic sweeper both claim the obligation through a lease, run the existing idempotent `SessionCreator.install_session_socialware/2`, resolve it on success, and persist retry state with exponential backoff on returned errors, exceptions, exits, or process restarts.

**Tech Stack:** Elixir 1.19, OTP/GenServer/Task.Supervisor, Ecto/PostgreSQL, ExUnit.

## Global Constraints

- Preserve asynchronous agent materialization so Session creation does not wait for agent startup.
- Do not report create success unless the durable installation obligation exists.
- Reuse the existing idempotent socialware installation path; do not add a second agent-spawn writer.
- Credential-gated role admission remains a successful terminal installation outcome.
- Preserve workspace → session runtime dependency injection.
- Run focused tests only; do not run `mix precommit`.
- Preserve unrelated dirty-worktree changes and do not commit.

---

### Task 1: Durable obligation persistence

**Files:**
- Create: `apps/ezagent_core/priv/repo_pg/migrations/20260731170000_create_session_socialware_install_obligations.exs`
- Create: `apps/ezagent_domain_session/lib/ezagent/session/socialware_install_obligation.ex`
- Create: `apps/ezagent_domain_session/lib/ezagent/session/socialware_install_obligations.ex`
- Test: `apps/ezagent_domain_session/test/ezagent/session/socialware_install_obligations_test.exs`

**Interfaces:**
- Produces: `ensure_pending/3`, `claim/2`, `record_failure/3`, `resolve/2`, and `list_due/1`.

- [ ] Write a failing DataCase test proving `ensure_pending/3` is idempotent, `claim/2` leases a row, stale claim tokens cannot resolve it, and expired leases are reclaimable.
- [ ] Run the focused test in an isolated migrated test database and verify RED because the modules/table do not exist.
- [ ] Add the PostgreSQL table with unique `session_uri`, workspace/actor identity, status, attempts, error, claim token, retry/lease time, resolved time, and timestamps.
- [ ] Implement transactional claim and compare-and-set transitions, following `Ezagent.Agent.RetirementObligations`.
- [ ] Run the focused test and verify GREEN.

### Task 2: Recoverable installer and sweeper

**Files:**
- Create: `apps/ezagent_domain_session/lib/ezagent/session/socialware_install_sweeper.ex`
- Test: `apps/ezagent_domain_session/test/ezagent/session/socialware_install_sweeper_test.exs`

**Interfaces:**
- Consumes: Task 1 persistence functions and an injected two-argument install function in tests.
- Produces: `retry/2`, `run_due/1`, and the periodic GenServer.

- [ ] Write failing tests proving a returned installation error is persisted and retried, a crash is persisted, and a later idempotent success resolves the same obligation.
- [ ] Verify RED because the sweeper does not exist.
- [ ] Implement claimed execution around `SessionCreator.install_session_socialware/2`, including rescue/catch, exponential retry scheduling, and resolution on `{:ok, summary}`.
- [ ] Run the focused test and verify GREEN.

### Task 3: Creation boundary and immediate wake-up

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex`
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/application.ex`
- Modify: `apps/ezagent_domain_session/test/architecture/session_create_no_agent_spawn_test.exs`
- Test: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/template/hello_session_test.exs`

**Interfaces:**
- `SessionCreator.install_session_socialware_async/1` persists first and returns `:ok | {:error, term()}`.
- The Task is an immediate wake-up only; the database obligation remains authoritative.

- [ ] Extend the Hello workspace-create test to assert that an obligation exists immediately when create returns and eventually resolves with both declared members present.
- [ ] Add a restart-recovery test that leaves an obligation pending, runs the sweeper, and observes automatic member installation.
- [ ] Verify RED against the current one-shot Task implementation.
- [ ] Change `install_session_socialware_async/1` to persist the obligation before starting the immediate retry Task.
- [ ] Propagate persistence failure through both workspace create paths instead of returning false success.
- [ ] Start the sweeper under the Session application after the Task supervisor.
- [ ] Update the architecture gate wording/assertions so failure means a durable pending obligation, never an untracked owner-only Session.
- [ ] Run the focused Session and Hello tests and verify GREEN.

### Task 4: Runtime migration and end-to-end verification

**Files:**
- Verify all files from Tasks 1–3.

**Interfaces:**
- Produces: a migrated local service whose newly created Hello Session automatically reaches owner + front-desk + llm.

- [ ] Format only touched files.
- [ ] Run the focused obligation, sweeper, architecture, and Hello creation tests with zero failures.
- [ ] Run `mix ecto.migrate` against the port-55432 development database.
- [ ] Reload or restart the service with the existing normal configuration.
- [ ] Create a fresh Hello Session through `Workspace.handle_create_session`, without manually invoking installation.
- [ ] Verify the obligation is resolved and the Session has exactly the owner plus its two declared role agents.
- [ ] Review `git diff --check` and the exact touched-file diff; do not run precommit.
