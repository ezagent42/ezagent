# Git Provider V1 Plan C Task Workspace Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Plan C crash-recoverable and Git-identity-safe by adding a durable start claim, completing only after the real fresh spawn lifecycle, and preparing an exact fetched commit on a deterministic local task branch.

**Architecture:** PostgreSQL remains the source of truth for provision/start/cleanup claims. Core owns only the generic transient pre-start coordinator; Domain Agent owns final spawn obligations; Workspace owns Git proof, durable start state, retirement, and recovery. Git cache mutation remains node-local serialized while durable tokens and leases fence workers across processes.

**Tech Stack:** Elixir 1.19, OTP 28, Ecto/PostgreSQL, ExUnit, erlexec via `Ezagent.Runtime.OsProcess`, native Git CLI, existing Ezagent CapBAC/Kind/Template contracts.

## Global Constraints

- Follow `AGENTS.md`; one module per file and no nested test-support modules.
- Use TDD for every behavior change and `SHELL=/bin/bash` for Mix test commands.
- Add one forward migration; never edit migrations `20260717001000`, `02000`, or `03000`.
- Keep private checkout, credentials, provider writes, push/change-request creation, UI, deployment, cross-node cache locking, and periodic unbounded reaping out of scope.
- Keep `pre_start_ref` trusted-only and absent from recipe/template/plugin data.
- Do not modify `RecipeMaterializer` or add Workspace/Git/task/provider/flavor vocabulary to core.
- Production Git execution remains argv-only, erlexec-backed, anonymous, deadline/output bounded, and environment-cleared.
- Preserve the unrelated untracked handoff `docs/together/2026-07-17/handoffs/gaga-cc-custom-backends-clarify-first.md`.
- Do not push, merge, rebase, or deploy.

---

### Task 1: Add the Durable Starting State and Git Proof Columns

**Files:**
- Create: `apps/ezagent_core/priv/repo_pg/migrations/20260717004000_harden_git_task_workspace_start.exs`
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/provision.ex`
- Modify: `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/store_test.exs`
- Modify: `apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs` only if the migration changes the invariant fixture

**Interfaces:**
- Consumes: existing `git_task_workspace_provisions` rows and `Provision.transition_changeset/2`.
- Produces: status `:starting` and nullable fields `start_claim_token`, `start_lease_until`, `resolved_base_commit`, and `local_branch_ref`.

- [ ] **Step 1: Write the failing schema/state test**

Add assertions to `store_test.exs`:

```elixir
test "provision schema exposes durable start and checkout proof fields" do
  assert :starting in Provision.statuses()

  fields = Provision.__schema__(:fields)

  for field <- [
        :start_claim_token,
        :start_lease_until,
        :resolved_base_commit,
        :local_branch_ref
      ] do
    assert field in fields
  end
end
```

- [ ] **Step 2: Run the RED test**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/store_test.exs`

Expected: FAIL because `:starting` and the four fields do not exist.

- [ ] **Step 3: Add the forward migration and schema fields**

The migration must use explicit columns and invalidate untrusted non-terminal legacy rows:

```elixir
defmodule EzagentCore.Repo.Migrations.HardenGitTaskWorkspaceStart do
  use Ecto.Migration

  def up do
    alter table(:git_task_workspace_provisions) do
      add :start_claim_token, :string
      add :start_lease_until, :utc_datetime_usec
      add :resolved_base_commit, :string
      add :local_branch_ref, :string
    end

    create index(:git_task_workspace_provisions, [:status, :start_lease_until],
             name: :git_task_workspace_provisions_start_recovery_index
           )

    execute """
    UPDATE git_task_workspace_provisions
       SET status = 'cleanup_pending',
           cleanup_reason = 'plan_c_hardening_upgrade',
           claim_token = NULL,
           lease_until = NULL,
           start_token = NULL
     WHERE status NOT IN ('cleaned')
    """
  end

  def down do
    drop_if_exists index(:git_task_workspace_provisions, [:status, :start_lease_until],
                     name: :git_task_workspace_provisions_start_recovery_index
                   )

    alter table(:git_task_workspace_provisions) do
      remove :start_claim_token
      remove :start_lease_until
      remove :resolved_base_commit
      remove :local_branch_ref
    end
  end
end
```

Add `:starting` to `@statuses`, add the four fields to the schema, and put them in `@transition_fields`, never `@immutable_fields`.

- [ ] **Step 4: Run migration and GREEN tests**

Run:

```bash
SHELL=/bin/bash MIX_ENV=test mix ecto.migrate
SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/store_test.exs
```

Expected: migration succeeds; Store tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/priv/repo_pg/migrations/20260717004000_harden_git_task_workspace_start.exs \
  apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/provision.ex \
  apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/store_test.exs
git commit -m "feat(workspace): persist task start claims"
```

### Task 2: Fence Ready-to-Starting and Starting Completion

**Files:**
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/store.ex`
- Modify: `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/store_test.exs`

**Interfaces:**
- Consumes: Task 1 fields and existing ready `start_token`.
- Produces:
  - `Store.claim_start/3 :: {:ok, Provision.t()} | {:error, term()}`
  - `Store.mark_started/4 :: {:ok, Provision.t()} | {:error, term()}`
  - `Store.fail_start/4 :: {:ok, Provision.t()} | {:error, term()}`
  - `Store.renew_start_claim/3 :: {:ok, Provision.t()} | {:error, term()}`

- [ ] **Step 1: Write RED transition and takeover tests**

Add tests covering success, expiry, replacement, and stale completion:

```elixir
test "claim_start moves ready to a leased starting state" do
  ready = ready_row()

  assert {:ok, starting} =
           Store.claim_start(ready.id, ready.start_token,
             now: at(0),
             lease_seconds: 30
           )

  assert starting.status == :starting
  assert is_binary(starting.start_claim_token)
  assert starting.start_token_consumed_at == at(0)
  assert starting.start_lease_until == at(30)
end

test "stale start claimant cannot complete after lease takeover" do
  ready = ready_row()
  {:ok, first} = Store.claim_start(ready.id, ready.start_token, now: at(0), lease_seconds: 30)
  {:ok, second} = Store.claim_start(ready.id, ready.start_token, now: at(31), lease_seconds: 30)

  assert {:error, :sidecar_start_claim_lost} =
           Store.mark_started(first.id, first.start_claim_token, retirement_handle(), now: at(32))

  assert {:ok, started} =
           Store.mark_started(second.id, second.start_claim_token, retirement_handle(), now: at(32))

  assert started.status == :sidecar_started
end
```

Also assert `fail_start/4` moves only the current claim to `cleanup_pending`, clears start-claim fields, and classifies it `:ambiguous_or_live`.

- [ ] **Step 2: Run RED**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/store_test.exs`

Expected: FAIL on missing arities and `:starting` transitions.

- [ ] **Step 3: Implement locked, lease-fenced transitions**

Use row-lock helpers already present in Store. The core shapes are:

```elixir
def claim_start(id, start_token, opts \\ []) do
  now = Keyword.get(opts, :now, DateTime.utc_now())
  lease_seconds = Keyword.get(opts, :lease_seconds, 60)

  locked(id, fn
    %Provision{status: :ready, start_token: ^start_token, start_token_consumed_at: nil} = row ->
      update_row(row, %{
        status: :starting,
        state_version: row.state_version + 1,
        start_token_consumed_at: now,
        start_claim_token: Ecto.UUID.generate(),
        start_lease_until: DateTime.add(now, lease_seconds, :second)
      })

    %Provision{status: :starting, start_token: ^start_token} = row ->
      claim_expired_start(row, now, lease_seconds)

    %Provision{status: :ready} -> {:error, :start_token_mismatch}
    %Provision{} -> {:error, :invalid_start_transition}
  end)
end
```

`mark_started/4`, `fail_start/4`, and `renew_start_claim/3` must match `status: :starting`, the exact `start_claim_token`, and a current lease. A stale claimant returns `:sidecar_start_claim_lost` and performs no transition.

Update `request_cleanup/2` so `:starting` is always `:ambiguous_or_live` and clears start claim fields.

- [ ] **Step 4: Run GREEN and concurrency tests**

Run:

```bash
SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/store_test.exs
```

Expected: all Store tests pass, including 20 concurrent start claims with one winner.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/store.ex \
  apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/store_test.exs
git commit -m "feat(workspace): fence durable task starts"
```

### Task 3: Make Core Pre-Start Pending Claims Caller-Owned

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/kind/template/pre_start.ex`
- Modify: `apps/ezagent_core/test/ezagent/kind/template_pre_start_test.exs`

**Interfaces:**
- Consumes: existing generic `prepare/1` and `complete/2` callbacks.
- Produces: caller-monitored in-memory completion claims without Workspace vocabulary.

- [ ] **Step 1: Write RED caller-death tests**

```elixir
test "caller death releases an uncompleted transient claim" do
  :ok = PreStart.register(TemplatePreStartProbe)
  prepare_success()
  owner = self()

  caller =
    spawn(fn ->
      {:ok, %{claim: claim}} = PreStart.prepare(:opaque)
      send(owner, {:prepared_claim, claim})
      Process.sleep(:infinity)
    end)

  assert_receive {:prepared_claim, claim}
  Process.exit(caller, :kill)
  assert eventually(fn -> PreStart.complete(claim, :ok) == {:error, :invalid_template_pre_start_claim} end)
end
```

Add a separate test that normal completion removes the monitor and still calls the downstream callback exactly once.

- [ ] **Step 2: Run RED**

Run: `SHELL=/bin/bash mix test apps/ezagent_core/test/ezagent/kind/template_pre_start_test.exs`

Expected: FAIL because pending claims are not caller-monitored.

- [ ] **Step 3: Store monitor ownership in the GenServer**

Change the registration call to include `self()` and store both indexes:

```elixir
pending[token] = %{implementation: implementation, claim: implementation_claim, monitor: monitor}
monitors[monitor] = token
```

On `{:take_pending, token}`, remove both indexes and `Process.demonitor(monitor, [:flush])`. On `{:DOWN, monitor, :process, _pid, _reason}`, delete the matching pending token. Keep downstream callback execution in the caller process, never inside the GenServer.

- [ ] **Step 4: Run GREEN and vocabulary gate**

Run:

```bash
SHELL=/bin/bash mix test apps/ezagent_core/test/ezagent/kind/template_pre_start_test.exs
! rg -n 'Git|Workspace|Task|provider|flavor|recipe|plugin' apps/ezagent_core/lib/ezagent/kind/template/pre_start.ex
```

Expected: tests pass and `rg` prints no matches. If neutral prose contains a forbidden word, rewrite the prose rather than weakening the gate.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/kind/template/pre_start.ex \
  apps/ezagent_core/test/ezagent/kind/template_pre_start_test.exs
git commit -m "fix(core): release abandoned pre-start claims"
```

### Task 4: Complete Pre-Start After the Real Fresh Spawn Lifecycle

**Files:**
- Modify: `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex`
- Modify: `apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs`
- Create: `apps/ezagent_domain_agent/test/support/fresh_pre_start_template_class.ex`

**Interfaces:**
- Consumes: Core `PreStart.prepare/1`, `complete/2`, and existing `spawn_after_cascade` obligations.
- Produces: exactly-once completion after final successful spawn obligations, with outcome `{:ok, %{workers: [URI.t()]}}`.

- [ ] **Step 1: Write a RED fresh lifecycle ordering test**

The new Template Class must only instantiate; it must not write lineage, binding, inventory, or flavor attributes:

```elixir
defmodule EzagentDomainAgent.TestSupport.FreshPreStartTemplateClass do
  @moduledoc false
  @behaviour Ezagent.Kind.Template

  @impl true
  def instantiate(_name, data, _workspace_uri) do
    owner = Application.fetch_env!(:ezagent_domain_agent, :fresh_pre_start_owner)
    worker = Ezagent.URI.parse!(Map.fetch!(data, "agent_uri"))
    send(owner, {:instantiate_called, worker})

    with {:ok, _pid} <- Ezagent.LocalRuntime.ensure_started(worker) do
      {:ok, [worker], %{fresh?: true}}
    end
  end
end
```

The test asserts that when the downstream `complete/2` callback runs, all of these already hold:

```elixir
assert {:ok, _attempt} = Ezagent.Agent.CreationInventory.find_attempt(worker, workspace)
assert {:ok, ^spawned_by} = Ezagent.AgentLineage.lookup(worker)
assert {:ok, ^workspace} = Ezagent.WorkspaceRegistry.lookup(worker)
```

It also covers a post-spawn obligation failure and asserts one error completion plus the existing rollback.

- [ ] **Step 2: Run RED**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs`

Expected: FAIL because completion occurs before the helper-owned records exist.

- [ ] **Step 3: Thread one completion context through `spawn_after_cascade`**

Do not complete inside `instantiate_workers/4`. Return an internal tagged result:

```elixir
{:ok, workers, fresh?, instantiate_meta, pre_start_completion}
```

After the fresh/adopted branch finishes all obligations, call one helper:

```elixir
defp finalize_pre_start(nil, result), do: result

defp finalize_pre_start(%{claim: claim}, {:ok, %{workers: workers}} = result) do
  case PreStart.complete(claim, {:ok, %{workers: workers}}) do
    :ok -> result
    {:error, reason} -> {:error, reason}
  end
end
```

Every error/raise/exit after prepare must route through the same finalizer once. Preserve the original stacktrace for raise/exit after recording the error completion. Do not duplicate rollback ownership.

- [ ] **Step 4: Run GREEN and full Domain Agent tests**

Run:

```bash
SHELL=/bin/bash mix test apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs
SHELL=/bin/bash mix test apps/ezagent_domain_agent/test
```

Expected: focused and full Domain Agent suites pass.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex \
  apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs \
  apps/ezagent_domain_agent/test/support/fresh_pre_start_template_class.ex
git commit -m "fix(agent): complete pre-start after spawn obligations"
```

### Task 5: Fetch and Prepare a Deterministic Local Task Branch

**Files:**
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/git_runner.ex`
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/provisioner.ex`
- Modify: `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/git_runner_test.exs`
- Modify: `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/provisioner_test.exs`

**Interfaces:**
- Consumes: public anonymous remote, canonical paths, `provision_id`, generation, and validated `base_ref`.
- Produces prepared proof containing `resolved_base_commit` and `local_branch_ref`.

- [ ] **Step 1: Write RED real-Git cache refresh and branch tests**

Use local public fixtures to prove both a new ref and a moved ref become visible through an existing cache:

```elixir
test "reused cache fetches a moved base ref and creates the deterministic branch" do
  first = request(base_ref: "main", generation: 1)
  assert {:ok, prepared_one} = GitRunner.prepare(first)

  moved_sha = advance_origin_main!()
  second = request(base_ref: "main", generation: 2)
  assert {:ok, prepared_two} = GitRunner.prepare(second)

  assert prepared_two.resolved_base_commit == moved_sha
  assert prepared_two.local_branch_ref == GitRunner.local_branch_ref(second)
  assert git!(prepared_two.worktree_path, ["symbolic-ref", "HEAD"]) ==
           prepared_two.local_branch_ref
  refute prepared_one.resolved_base_commit == prepared_two.resolved_base_commit
end
```

Add a new-ref case and an argv test proving fetch uses the fixed implementation-owned refspec and the existing anonymous environment.

- [ ] **Step 2: Run RED**

Run: `SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/git_runner_test.exs`

Expected: FAIL because existing caches do not fetch and worktrees are detached.

- [ ] **Step 3: Implement deterministic branch derivation**

Expose a pure helper for testing:

```elixir
@spec local_branch_ref(map()) :: String.t()
def local_branch_ref(%{provision_id: provision_id, generation: generation}) do
  digest = :crypto.hash(:sha256, provision_id) |> Base.encode16(case: :lower) |> binary_part(0, 24)
  "refs/heads/ezagent/task/#{digest}/g#{generation}"
end
```

Within the existing cache lock, execute in order:

```elixir
head_ref = "refs/ezagent/origin/heads/#{request.base_ref}"
tag_ref = "refs/ezagent/origin/tags/#{request.base_ref}"

remote_argv = git_argv(["--git-dir", paths.cache_path, "remote", "get-url", "origin"])

fetch_argv =
  git_argv([
    "--git-dir",
    paths.cache_path,
    "fetch",
    "--prune",
    "origin",
    "+refs/heads/*:refs/ezagent/origin/heads/*",
    "+refs/tags/*:refs/ezagent/origin/tags/*"
  ])

head_probe = git_argv(["--git-dir", paths.cache_path, "show-ref", "--verify", head_ref])
tag_probe = git_argv(["--git-dir", paths.cache_path, "show-ref", "--verify", tag_ref])
{:ok, resolved_ref} = resolve_exactly_one_ref(head_ref, head_probe, tag_ref, tag_probe, opts)

resolve_argv =
  git_argv(["--git-dir", paths.cache_path, "rev-parse", "--verify", "#{resolved_ref}^{commit}"])

branch_argv =
  git_argv(["--git-dir", paths.cache_path, "branch", "-f", local_branch, resolved_sha])

worktree_argv =
  git_argv([
    "--git-dir",
    paths.cache_path,
    "worktree",
    "add",
    paths.worktree_path,
    local_branch
  ])
```

Implement the named resolver without raising on expected absence:

```elixir
defp resolve_exactly_one_ref(head_ref, head_argv, tag_ref, tag_argv, opts) do
  head? = match?({:ok, _}, execute(head_argv, opts))
  tag? = match?({:ok, _}, execute(tag_argv, opts))

  case {head?, tag?} do
    {true, false} -> {:ok, head_ref}
    {false, true} -> {:ok, tag_ref}
    {false, false} -> {:error, :base_ref_not_found}
    {true, true} -> {:error, :ambiguous_base_ref}
  end
end
```

Use a ref-safe validated short name derived from `local_branch_ref`; never pass a caller-provided local branch. Return the full 40/64-hex resolved object id reported by Git. Reject unexpected object-id shape.

`base_ref` is already restricted by `RepositoryRef.valid_ref?/1` to a short
branch-or-tag name. Resolve it only inside the two fetched namespaces above:
exactly one branch/tag match succeeds; zero matches returns
`:base_ref_not_found`; two matches returns `:ambiguous_base_ref`. Never use Git
DWIM resolution against local refs.

Before `branch -f`, fail with `:workspace_branch_conflict` if the deterministic branch is checked out by a different recorded worktree. Do not reset an active branch owner.

- [ ] **Step 4: Persist the proof in `mark_ready`**

Extend `Store.ready_values/1` and the Provisioner ready attrs:

```elixir
resolved_base_commit: prepared.resolved_base_commit,
local_branch_ref: prepared.local_branch_ref
```

Update `GitRunner.maximum_provision_duration_ms/0` and the lease-budget test to include remote check, fetch, resolve, branch, add, and both verification command groups.

- [ ] **Step 5: Run GREEN**

Run:

```bash
SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/git_runner_test.exs \
  apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/provisioner_test.exs
```

Expected: all tests pass; command probes show no shell, credentials, inherited env, or caller-selected refspec.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/git_runner.ex \
  apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/provisioner.ex \
  apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/store.ex \
  apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/git_runner_test.exs \
  apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/provisioner_test.exs \
  apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/store_test.exs
git commit -m "feat(workspace): pin task worktrees to fetched branches"
```

### Task 6: Enforce Exact Git Proof Before Sidecar Instantiate

**Files:**
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/git_runner.ex`
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/pre_start.ex`
- Modify: `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/git_runner_test.exs`
- Modify: `apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs`
- Modify: `apps/ezagent_domain_workspace/test/support/task_workspace_proof_runner.ex`
- Modify: `apps/ezagent_domain_workspace/test/support/failing_task_workspace_proof_runner.ex`

**Interfaces:**
- Consumes: Task 2 `:starting` claim and Task 5 persisted commit/branch proof.
- Produces: instantiate permission only after exact, clean worktree verification.

- [ ] **Step 1: Write RED mutation tests**

Add real-Git tests for each mutation between ready and start:

```elixir
test "commit, branch, and dirty-tree drift each prevent instantiate" do
  for mutation <- [:other_commit, :other_branch, :dirty_file] do
    ready = ready_fixture()
    mutate_worktree!(ready.worktree_path, mutation)

    assert {:error, reason} = AgentStart.start(content(), agent_uri(), owner_uri(), workspace_uri(), identity(ready))
    assert reason in [:workspace_checkout_mismatch, :workspace_not_clean]
    refute_receive {:instantiate_called, _}
    assert Repo.get!(Provision, ready.id).status == :cleanup_pending
  end
end
```

Also assert the transition reaches `:starting` before the proof runner is called, so a second caller cannot pass the proof concurrently.

- [ ] **Step 2: Run RED**

Run:

```bash
SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs \
  apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/git_runner_test.exs
```

Expected: FAIL because verify checks only worktree membership.

- [ ] **Step 3: Implement exact `GitRunner.verify/1`**

Require the proof map keys and run bounded commands:

```elixir
%{
  cache_path: cache,
  worktree_path: worktree,
  remote_url: remote,
  resolved_base_commit: commit,
  local_branch_ref: branch
}
```

Verify exact origin, porcelain registration, `rev-parse HEAD`, `symbolic-ref -q HEAD`, and `status --porcelain=v1 --untracked-files=all`. Map mismatch to `:workspace_checkout_mismatch` and non-empty status to `:workspace_not_clean`.

- [ ] **Step 4: Update Workspace pre-start ordering and test seam**

`PreStart.prepare/1` must:

```text
load exact row/ref identity
-> Store.claim_start(... lease_seconds: start_lease_seconds())
-> GitRunner.verify(proof_from(starting_row))
-> return cwd + {row id, start claim token}
```

On proof failure call `Store.fail_start/4` with the same claim token; a lost claim performs no cleanup transition.

Make the runner selection compile-time test-only:

```elixir
if Mix.env() == :test do
  defp runner, do: Application.get_env(:ezagent_domain_workspace, :task_workspace_git_runner, GitRunner)
else
  defp runner, do: GitRunner
end
```

- [ ] **Step 5: Run GREEN and full Workspace tests**

Run:

```bash
SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs \
  apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/git_runner_test.exs
SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test
```

Expected: focused and full Workspace suites pass.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/git_runner.ex \
  apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/pre_start.ex \
  apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/git_runner_test.exs \
  apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs \
  apps/ezagent_domain_workspace/test/support/task_workspace_proof_runner.ex \
  apps/ezagent_domain_workspace/test/support/failing_task_workspace_proof_runner.ex
git commit -m "fix(workspace): prove task checkout before start"
```

### Task 7: Recover Expired Starting Rows Conservatively

**Files:**
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/reconciler.ex`
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/reconciler_boot.ex`
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/store.ex`
- Modify: `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_test.exs`
- Modify: `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_boot_test.exs`
- Modify: `apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs`

**Interfaces:**
- Consumes: expired `:starting` rows with durable Agent intent and start lease.
- Produces: sanctioned retirement followed by exact cleanup, never a second instantiate.

- [ ] **Step 1: Write RED process-death and boot-restart tests**

```elixir
test "expired starting is retired and cleaned after caller death" do
  starting = start_then_kill_before_complete()
  assert starting.status == :starting

  now = DateTime.add(starting.start_lease_until, 1, :second)
  assert %{cleaned: 1, failed: 0} = Reconciler.recover_once(limit: 10, now: now)

  assert_receive {:retire_agent, starting.agent_uri, _attempt}
  assert_receive {:git_remove, %{worktree_path: starting.worktree_path}}
  assert Repo.get!(Provision, starting.id).status == :cleaned
  refute_receive {:instantiate_called, _}
end
```

Add a stale-worker race: recovery takes cleanup ownership after expiry; the old start claimant cannot `mark_started`, `fail_start`, retire, or remove.

- [ ] **Step 2: Run RED**

Run:

```bash
SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_test.exs \
  apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_boot_test.exs \
  apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs
```

Expected: FAIL because recovery does not select `:starting`.

- [ ] **Step 3: Add starting to effect and deferred-lease queries**

Extend `list_effect_recovery_candidates/2` with:

```elixir
(p.status == :starting and
   (is_nil(p.start_lease_until) or p.start_lease_until <= ^now))
```

Extend `latest_active_recovery_lease_deadline/2` so active `:starting` rows use `start_lease_until`, while provisioning/cleanup continue using `lease_until`. Keep one bounded query/window.

- [ ] **Step 4: Reconcile starting through cleanup pending**

For an expired starting row, atomically move only the expected `state_version` and start claim into `cleanup_pending`, classify `:ambiguous_or_live`, then reuse `claim_and_clean/3`. Retirement remains before Git removal and every destructive effect remains cleanup-token fenced.

- [ ] **Step 5: Run GREEN and Workspace full suite**

Run:

```bash
SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_test.exs \
  apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/reconciler_boot_test.exs \
  apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs
SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test
```

Expected: all tests pass; expired starting never retries instantiate.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/{store,reconciler,reconciler_boot}.ex \
  apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/{reconciler,reconciler_boot}_test.exs \
  apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs
git commit -m "feat(workspace): recover abandoned task starts"
```

### Task 8: Strengthen Structural Gates and the Signed End-to-End Proof

**Files:**
- Modify: `apps/ezagent_domain_workspace/test/invariants/task_workspace_boundary_test.exs`
- Modify: `apps/ezagent_domain_workspace/test/integration/task_workspace_signed_e2e_test.exs`
- Modify: `apps/ezagent_domain_workspace/test/support/task_workspace_template_class.ex`
- Modify: `apps/ezagent_domain_agent/test/support/fresh_pre_start_template_class.ex` if the cross-app fixture is shared through Domain Agent instead

**Interfaces:**
- Consumes: Tasks 1-7 production contracts.
- Produces: invariant tests that fail on the reviewed regression classes.

- [ ] **Step 1: Add RED structural call-site and seam tests**

Add exact production scans:

```elixir
assert_only_production_calls("pre_start_ref:", [
  "apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/agent_start.ex"
])

assert_only_production_calls("AgentStart.start(", [])

refute_source_under(
  "apps/ezagent_core/lib/ezagent/kind/template",
  ~r/Git|Workspace|Task|provider|flavor|recipe|plugin/
)

refute_source_under(
  "apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/pre_start.ex",
  ~r/Application\.get_env.*task_workspace_git_runner/s
)
```

Use explicit approved callers discovered at implementation time; do not add a wildcard directory allowlist.

- [ ] **Step 2: Replace the exact-name secret check with schema and migration token scans**

Extract `field(:name, ...)` and migration `add :name` tokens, then reject patterns:

```elixir
@forbidden_secret_field ~r/(^|_)(access_token|auth_blob|key_material|credential_ref|authorization_header|private_key|secret|credential|environment)($|_)/
```

Explicitly allow lifecycle fencing names `claim_token`, `start_token`, and `cleanup` tokens; the allowance must compare exact field names, not skip every name containing `token`.

- [ ] **Step 3: Make signed E2E use the real fresh lifecycle**

Remove lineage/inventory/workspace writes from `TaskWorkspaceTemplateClass.instantiate/3`. It should return `fresh?: true` and let `TemplateSpawn` own those records. The E2E must assert:

```elixir
assert {:ok, attempt_id} = CreationInventory.find_attempt(agent_uri, workspace_uri)
assert {:ok, owner_uri} = AgentLineage.lookup(agent_uri)
assert Repo.get_by!(Provision, provision_id: ready.provision_id).status == :sidecar_started
```

Then perform signed cleanup and assert sanctioned retirement, exact worktree absence, and terminal `:cleaned`.

- [ ] **Step 4: Run RED then GREEN invariant/E2E tests**

Run before production/test-fixture adjustment and confirm the new tests fail. After adjustment run:

```bash
SHELL=/bin/bash mix test \
  apps/ezagent_domain_workspace/test/invariants/task_workspace_boundary_test.exs \
  apps/ezagent_domain_workspace/test/integration/task_workspace_signed_e2e_test.exs \
  apps/ezagent_domain_git/test/architecture/dependency_boundary_test.exs
```

Expected: all tests pass and the E2E no longer performs helper-owned writes in its Template Class.

- [ ] **Step 5: Run the complete hardening suite**

Run:

```bash
SHELL=/bin/bash mix test \
  apps/ezagent_core/test/ezagent/kind/template_pre_start_test.exs \
  apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs \
  apps/ezagent_domain_git/test/ezagent/action_set/git_task_access_test.exs \
  apps/ezagent_domain_git/test/integration/git_task_dispatch_test.exs \
  apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace \
  apps/ezagent_domain_workspace/test/integration/task_workspace_sidecar_gate_test.exs \
  apps/ezagent_domain_workspace/test/integration/task_workspace_signed_e2e_test.exs \
  apps/ezagent_domain_workspace/test/invariants/task_workspace_boundary_test.exs
```

Expected: zero failures.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_domain_workspace/test apps/ezagent_domain_agent/test/support/fresh_pre_start_template_class.ex
git commit -m "test(workspace): prove hardened task lifecycle"
```

### Task 9: Final Verification and Return Amendment

**Files:**
- Modify: `docs/together/2026-07-17/returns/gaga-git-provider-plan-c.md`
- Create: `docs/together/2026-07-17/returns/gaga-git-provider-plan-c-hardening.md`

**Interfaces:**
- Consumes: Tasks 1-8 and the approved hardening design.
- Produces: fresh machine evidence and corrected Plan C return claims; no integration action.

- [ ] **Step 1: Format touched files and verify no unrelated churn**

Run:

```bash
mix format \
  apps/ezagent_core/lib/ezagent/kind/template/pre_start.ex \
  apps/ezagent_core/priv/repo_pg/migrations/20260717004000_harden_git_task_workspace_start.exs \
  apps/ezagent_core/test/ezagent/kind/template_pre_start_test.exs \
  apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex \
  apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs \
  apps/ezagent_domain_agent/test/support/fresh_pre_start_template_class.ex \
  apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/*.ex \
  apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/*.exs \
  apps/ezagent_domain_workspace/test/integration/task_workspace_*test.exs \
  apps/ezagent_domain_workspace/test/invariants/task_workspace_boundary_test.exs
mix format --check-formatted
git diff --check
git status --short
```

Expected: format and diff checks pass; only intended files plus the preserved unrelated handoff appear.

- [ ] **Step 2: Run affected full app suites**

Run:

```bash
SHELL=/bin/bash mix test apps/ezagent_domain_git/test
SHELL=/bin/bash mix test apps/ezagent_domain_workspace/test
SHELL=/bin/bash mix test apps/ezagent_domain_agent/test
SHELL=/bin/bash mix test apps/ezagent_core/test/ezagent/kind/template_pre_start_test.exs \
  apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs
SHELL=/bin/bash mix test apps/ezagent_plugin_cc/test/ezagent/template/cc_headless_agent_test.exs
```

Expected: zero failures in every affected suite.

- [ ] **Step 3: Run architecture and static gates independently**

Run every command even if another fails:

```bash
SHELL=/bin/bash mix ezagent.arch.scan
SHELL=/bin/bash mix ezagent.doc.scan
SHELL=/bin/bash mix ezagent.uri_query.scan
SHELL=/bin/bash mix ezagent.check_invariants
SHELL=/bin/bash mix ezagent.check_invariants.lifecycle
```

Expected: Plan C hardening introduces zero violations. Record the exact remaining pre-existing baseline separately.

- [ ] **Step 4: Run project precommit**

Run: `SHELL=/bin/bash mix precommit`

Expected: exit 0. If the known SkillRegistry seed or `skill_reconcile` baseline remains, record exact output and do not claim the project-wide gate green. Fix every in-scope failure before continuing.

- [ ] **Step 5: Correct the original return and write the hardening return**

In the original return, replace the invalid crash-recovery and Git-proof claims with a link to the hardening return. The new return must include:

- exact migration and state transitions;
- fresh-spawn ordering proof;
- fetched branch/commit proof;
- crash/restart recovery evidence;
- commands and observed counts;
- commit list;
- baseline failures separated from hardening;
- explicit non-deliverables and no push/merge/deploy statement.

- [ ] **Step 6: Commit return artifacts**

```bash
git add docs/together/2026-07-17/returns/gaga-git-provider-plan-c.md \
  docs/together/2026-07-17/returns/gaga-git-provider-plan-c-hardening.md
git commit -m "docs(together): return git provider plan c hardening"
```

Do not push until the user/lead explicitly authorizes it.
