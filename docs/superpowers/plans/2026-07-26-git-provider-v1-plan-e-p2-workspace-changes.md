# Git Provider V1 Plan E — Slice P2: Workspace Change Collection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `ezagent_domain_git` a provider-neutral workspace-change
collection port, and give `ezagent_domain_workspace` the implementation that
fresh-reads an exact ready-provision proof and collects a bounded, V1-only
UTF-8 upsert change envelope from an owned task worktree — the four Slice-P2
deliverables from
`docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md`
§9, reusing the existing `FileChange`/`ChangeLimits`/`WorkspaceProvisionPort`/
`Provision` machinery rather than duplicating it.

**Architecture:** A new `Ezagent.DomainGit.WorkspaceChangePort` behaviour
(one callback: `collect/1`) plus a closed `Request` value object and a
single-implementation `WorkspaceChangeRegistry` — structurally identical to
the existing `WorkspaceProvisionPort`/`WorkspaceProvisionRegistry` pair, but
kept as its own port rather than a third callback bolted onto
`WorkspaceProvisionPort`, because collection is an orthogonal concern from
provisioning `prepare`/`cleanup`. The implementation,
`Ezagent.Workspace.TaskWorkspace.ChangeCollector`, lives beside
`Provisioner` in `ezagent_domain_workspace`: it fresh-reads the exact ready
`Provision` row named by `provision_id`, runs a new bounded
`GitRunner.collect_status/1` (porcelain-v1 `git status`, reusing
`GitRunner`'s existing hardened subprocess plumbing) against the worktree,
classifies every reported path, and normalizes surviving upserts into
`[Ezagent.DomainGit.FileChange.t()]` through `FileChange.new/1` and
`FileChange.validate_many/1` — the same chokepoints `create_change_request`
already uses. Nothing in this slice runs provider HTTP, mints a token, wires
a new `GitTaskAccess` action, or touches the workflow plugin.

**Tech Stack:** Elixir/OTP, `Ecto.Adapters.SQL.Sandbox` via
`EzagentCore.DataCase`, real local Git fixtures through erlexec-backed
`Ezagent.Runtime.OsProcess` (via the existing `GitRunner`), ExUnit.

## Global Constraints

- `ezagent_domain_git` stays provider-neutral: no GitHub installation,
  token, or REST response shape may enter it (design §4.3). The only new
  surface here is the thin `WorkspaceChangePort`/`Request` pair.
- No token or credential touches this path at all (design §3.2). Neither
  new module ever reads a cap, an `%Invocation{}`, or `ctx.caps`.
- Collection rejects, with stable errors, anything outside the V1 envelope
  (out-of-tree paths, symlinks, binaries, deletes, renames, mode changes,
  content over the configured limits) — **never** a silent partial
  collection that drops the offending path and keeps the rest.
- `ezagent_domain_git`'s approved umbrella dependency stays exactly
  `[:ezagent_core]`, enforced by
  `apps/ezagent_domain_git/test/architecture/dependency_boundary_test.exs`.
  Nothing in this plan adds `ezagent_domain_workspace` (or any other
  umbrella app) to `ezagent_domain_git`'s `mix.exs` deps — the dependency
  edge runs the other way (`ezagent_domain_workspace` already depends on
  `ezagent_domain_git`), matching how `WorkspaceProvisionPort` already
  works.
- **Do not add a function named `new_authorized` to the new `Request`
  module.** `apps/ezagent_domain_workspace/test/invariants/task_workspace_boundary_test.exs`
  asserts `Request.new_authorized` (a bare substring, not a fully-qualified
  match) appears in exactly one production file
  (`apps/ezagent_domain_git/lib/ezagent/behavior/git_task_access.ex`). P2's
  collector proves worktree ownership by fresh-reading the exact
  `(task_access_uri, task_uri, generation)` identity off the already-ready
  `provision_id` row, not by re-presenting a `GitTaskAccess` policy, so it
  never needs a policy-carrying authorized constructor — this is a real
  design fit, not a workaround for the test. Task 2 includes a test that
  pins this decision down.
- **Do not add a new action to `Ezagent.ActionSet.GitTaskAccess`.** Design
  §4.3 freezes that action vocabulary at the existing seven
  (`resolve_repository`, `create_change_request`, `read_change_request`,
  `list_checks`, `list_reviews`, `provision_workspace`, `cleanup_workspace`).
  Whether the P4 workflow calls the new port directly or through some other
  seam is a P4 orchestration decision — this plan exposes the port and its
  registry lookup (`WorkspaceChangeRegistry.implementation/0` →
  `impl.collect(request)`) and stops there.
- **No new DB table or migration.** The collector is a stateless read
  against the already-persisted `git_task_workspace_provisions` table (the
  `Provision` schema already carries `workspace_uri NOT NULL` and is
  already listed in
  `apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs`
  §`@per_tenant_schemas`). This plan does not add a field to `Provision` or
  a migration — `apps/ezagent_domain_workspace/test/invariants/task_workspace_boundary_test.exs`'s
  `"durable provision schema contains no credential material"` test hardcodes
  `assert length(schema_names) == 30` / `assert length(migration_names) == 30`
  against the *current* schema + 4 migration files; touching either would
  break those exact-count assertions, so don't.
- Formatter noise policy: run `mix format` only on files this plan touches,
  not the whole project.
- Every task ends by running
  `MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p2 mix ci.fast`
  (pass an explicit `timeout: 300000` if your tool defaults to 120s — a
  killed run proves nothing). This is the umbrella-wide fast gate
  (`ecto.create --quiet`, `ecto.migrate --quiet`,
  `ezagent.check_invariants`, the socialware conformance check,
  `gate.arch`) — running only the touched app's `mix test` would have let
  P1's core-invariant regression hide for three tasks; don't repeat that.
- PostgreSQL for this machine is on port **15432**, not the project default
  55432. Use `MIX_TEST_PARTITION=p2` for every command in this plan — the
  partition database is `ezagent_pg_compat_testp2` and does not exist until
  Task 1 creates it.

## What already exists — reuse map

Read in full before writing any code; do not re-derive what's already
here:

| Requirement | Already met by | Notes |
|---|---|---|
| UTF-8 validation, `:upsert`-only, path safety (no leading `/`, no `\`, no `.`/`..`/`.git` segments, no control bytes) | `Ezagent.DomainGit.FileChange.new/1` (`apps/ezagent_domain_git/lib/ezagent/domain_git/file_change.ex`) | Reused as-is. The collector calls this for every candidate — do not re-implement path validation. |
| File-count / per-file-byte / total-byte limits | `Ezagent.DomainGit.FileChange.validate_many/1` + `Ezagent.DomainGit.ChangeLimits.current/0` | Reused as-is for the final collective check. The collector *additionally* short-circuits on cheap `stat.size` before reading file content, to avoid reading an oversized file into memory — that pre-check is new, the limit values and their config are not. |
| A single-implementation port/registry pattern for a workspace-domain capability | `Ezagent.DomainGit.WorkspaceProvisionPort` + `WorkspaceProvisionPort.Request` + `WorkspaceProvisionRegistry` | Copied structurally (not extended — see Task 2 for why) for the new `WorkspaceChangePort`. |
| A validated, ready `Provision` row keyed by `provision_id` with exact task/generation identity | `Ezagent.Workspace.TaskWorkspace.Provisioner` (`prepare/1`'s `ready_result/1`) + `Store.get_by_provision_id/1` | The collector fresh-reads this row directly; it does not call `Provisioner` or re-derive paths via `Paths.derive/1` — the row already carries `worktree_path`, `task_access_uri`, `task_uri`, `generation`, `status`. |
| Bounded, sandboxed Git subprocess execution (env-scrubbed, timeout, output-capped, erlexec-backed) | `Ezagent.Workspace.TaskWorkspace.GitRunner`'s private `execute/2`/`git_argv/1`/`command_opts/1` | **Not directly reusable from outside the module** (private) — Task 3 adds one new *public* function, `collect_status/1`, inside `git_runner.ex` itself so it shares these private helpers, rather than duplicating subprocess-spawning logic in a new module. |
| A "clean worktree" verifier | `GitRunner.verify/1` | **Not reusable for collection** — `verify/1` requires `git status` output to be *empty* (used before an Agent starts, to prove nothing external touched the checkout). Collection needs the opposite: a non-empty diff is the expected, useful case. This is a real gap, not something to skip; Task 3 adds a sibling function that classifies status instead of demanding emptiness. |
| `EZAGENT_HOME` / local Git fixture test pattern (bare origin + source repo, `task_workspace_remote_builder` env hook, real `GitRunner.prepare/1`) | `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/git_runner_test.exs` and `apps/ezagent_domain_workspace/test/integration/task_workspace_signed_e2e_test.exs` | Reused verbatim as the adversarial-test fixture pattern (Task 4's `ready_fixture!/2`). |

## Relationship to later slices (read before assuming how this gets called)

This plan delivers the port, its registry, and a registered, fully-tested
implementation — but **does not wire a caller**. Design §9 assigns
"provider-neutral change port; ready-provision proof; bounded UTF-8 upsert
collection; adversarial tests" to P2, and assigns "durable stage runner;
workspace/change/provider orchestration" to P4, which depends on P1+P2+P3
already being lead-integrated. Concretely, this means:

- P4's workflow will call `Ezagent.DomainGit.WorkspaceChangeRegistry.implementation/0`
  then `impl.collect(request)`, building the `Request` from whatever
  `provision_id`/`task_uri`/`generation`/`task_access_uri` P1's
  `ExecutionSeam`-authorized task and P2-caller's own `provision_workspace`
  call already gave it. `provision_id` is deterministic
  (`Ezagent.ActionSet.GitTaskAccess`'s private `provision_id/3` — a SHA-256
  of `workspace_uri`/`task_uri`/`generation`) — P4 can either re-derive it
  with the same inputs or read it back off `provision_workspace`'s own
  `{:ok, %{provision_id: ...}}` result.
- Whether P4 calls the registry directly from the workflow app, or routes
  it through some other seam, is P4's call — not fixed here, and not
  something this plan should guess at (guessing risks conflicting with
  whatever P4 actually builds, and P2 must not modify the workflow owner
  per design §9).
- This plan does **not** add an analogous "consumed only by its ActionSet"
  locality assertion (the pattern `task_workspace_boundary_test.exs` uses
  for `WorkspaceProvisionRegistry.implementation`) for the new registry,
  because there is no production call site yet to pin down — P4 should add
  that assertion once it wires the real caller.

---

### Task 1: Create and migrate the `p2` test partition

**Files:** none (environment setup only).

**Interfaces:** none — this task produces a usable database, not code.

- [ ] **Step 1: Create the partition database**

Run from the umbrella root:

```bash
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p2 mix ecto.create
```

Expected: `The database for EzagentCore.Repo has been created.` (or, if a
previous run already created it, `The database for EzagentCore.Repo has
already been created.` — either is fine).

- [ ] **Step 2: Migrate the partition database**

```bash
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p2 mix ecto.migrate
```

Expected: a series of `== Running <timestamp> <Migration> forward` /
`:migrated` lines, ending cleanly with no errors. The migration count
should match every file under
`apps/ezagent_core/priv/repo_pg/migrations/`.

- [ ] **Step 3: Confirm the partition is usable with the fast gate**

```bash
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p2 mix ci.fast
```

Run with an explicit `timeout: 300000` if your tool defaults to 120s.
Expected: PASS — this establishes the clean baseline before any of this
plan's code changes land, so any later red run in this plan is
attributable to this plan's own changes, not a stale/misconfigured
partition.

---

### Task 2: `WorkspaceChangePort` + `Request` + `WorkspaceChangeRegistry` (`ezagent_domain_git`)

**Files:**
- Create: `apps/ezagent_domain_git/lib/ezagent/domain_git/workspace_change_port.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/domain_git/workspace_change_port/request.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/domain_git/workspace_change_registry.ex`
- Create: `apps/ezagent_domain_git/test/ezagent/domain_git/workspace_change_port_test.exs`
- Modify: `apps/ezagent_domain_git/lib/ezagent_domain_git/application.ex` (add `WorkspaceChangeRegistry` to the supervised children)

**Interfaces:**
- Produces: `Ezagent.DomainGit.WorkspaceChangePort` behaviour —
  `@callback collect(Request.t()) :: {:ok, [Ezagent.DomainGit.FileChange.t()]} | {:error, term()}`.
  `Ezagent.DomainGit.WorkspaceChangePort.Request` — closed struct
  `%{task_access_uri: URI.t(), task_uri: URI.t(), generation: pos_integer(), provision_id: String.t()}`
  with `new/1 :: map() -> {:ok, t()} | {:error, term()}` (per-field typed
  validation, not just presence). `Ezagent.DomainGit.WorkspaceChangeRegistry` —
  `register/1`, `implementation/0 :: {:ok, module()} | {:error, :workspace_change_collector_not_registered}`,
  and (test-only) `replace_for_test/1`.
- Consumed by: Task 4's `ChangeCollector` (`@behaviour` + registration) and
  Task 4's `EzagentDomainWorkspace.Application` (calls `register/1` at
  boot). No production caller exists yet within this plan — see
  "Relationship to later slices" above.

- [ ] **Step 1: Write the failing tests**

```elixir
# apps/ezagent_domain_git/test/ezagent/domain_git/workspace_change_port_test.exs
defmodule Ezagent.DomainGit.WorkspaceChangePortTest do
  use ExUnit.Case, async: false

  alias Ezagent.DomainGit.WorkspaceChangePort
  alias Ezagent.DomainGit.WorkspaceChangeRegistry

  defmodule FakeCollector do
    @behaviour WorkspaceChangePort

    @impl true
    def collect(request),
      do: {:ok, [%{path: "fake.txt", operation: :upsert, content: request.provision_id}]}
  end

  setup do
    original = WorkspaceChangeRegistry.implementation()
    restart_registry()

    on_exit(fn ->
      restart_registry()

      case original do
        {:ok, implementation} -> :ok = WorkspaceChangeRegistry.register(implementation)
        {:error, :workspace_change_collector_not_registered} -> :ok
      end
    end)
  end

  test "registers exactly one conforming implementation idempotently" do
    assert :ok = WorkspaceChangeRegistry.register(FakeCollector)
    assert :ok = WorkspaceChangeRegistry.register(FakeCollector)
    assert {:ok, FakeCollector} = WorkspaceChangeRegistry.implementation()

    assert {:error, :conflicting_workspace_change_collector} =
             WorkspaceChangeRegistry.register(__MODULE__)
  end

  test "rejects an unregistered lookup with a stable error" do
    assert {:error, :workspace_change_collector_not_registered} =
             WorkspaceChangeRegistry.implementation()
  end

  test "request rejects caller-selected repository and path coordinates" do
    assert {:error, :unknown_fields} =
             WorkspaceChangePort.Request.new(%{
               task_access_uri: URI.parse("entity://ws/worker/gta_#{String.duplicate("a", 64)}"),
               task_uri: URI.parse("resource://ws/kanban-task/t"),
               generation: 1,
               provision_id: "provision",
               local_path: "/tmp/forged"
             })
  end

  test "request requires every field" do
    assert {:error, {:missing_field, :provision_id}} =
             WorkspaceChangePort.Request.new(%{
               task_access_uri: URI.parse("entity://ws/worker/gta_#{String.duplicate("a", 64)}"),
               task_uri: URI.parse("resource://ws/kanban-task/t"),
               generation: 1
             })
  end

  test "request validates the type of every field, not just presence" do
    base = %{
      task_access_uri: URI.parse("entity://ws/worker/gta_#{String.duplicate("a", 64)}"),
      task_uri: URI.parse("resource://ws/kanban-task/t"),
      generation: 1,
      provision_id: "provision"
    }

    assert {:ok, %WorkspaceChangePort.Request{}} = WorkspaceChangePort.Request.new(base)

    assert {:error, {:invalid_field, :task_access_uri}} =
             WorkspaceChangePort.Request.new(%{base | task_access_uri: "not-a-uri"})

    assert {:error, {:invalid_field, :task_uri}} =
             WorkspaceChangePort.Request.new(%{base | task_uri: "not-a-uri"})

    assert {:error, {:invalid_field, :generation}} =
             WorkspaceChangePort.Request.new(%{base | generation: 0})

    assert {:error, {:invalid_field, :generation}} =
             WorkspaceChangePort.Request.new(%{base | generation: "1"})

    assert {:error, {:invalid_field, :provision_id}} =
             WorkspaceChangePort.Request.new(%{base | provision_id: ""})

    assert {:error, {:invalid_field, :provision_id}} =
             WorkspaceChangePort.Request.new(%{base | provision_id: :not_a_string})
  end

  test "request has no authorized constructor — collection proves ownership by fresh-read, not policy re-presentation" do
    # Deliberate: adding `new_authorized/2` here would also make
    # apps/ezagent_domain_workspace/test/invariants/task_workspace_boundary_test.exs's
    # bare-substring `assert_only_production_calls("Request.new_authorized",
    # [...])` check see a second call site (any file that aliases this
    # module as `Request` and calls `.new_authorized` would match, since
    # that assertion matches text, not a fully-qualified module). Collection
    # doesn't need policy-bound construction, so this stays absent.
    refute function_exported?(WorkspaceChangePort.Request, :new_authorized, 2)
  end

  defp restart_registry do
    :ok = Supervisor.terminate_child(EzagentDomainGit.Application, WorkspaceChangeRegistry)
    {:ok, _pid} = Supervisor.restart_child(EzagentDomainGit.Application, WorkspaceChangeRegistry)
    :ok
  end
end
```

- [ ] **Step 2: Run to confirm it fails**

```bash
cd apps/ezagent_domain_git && mix test test/ezagent/domain_git/workspace_change_port_test.exs
```

Expected: FAIL — `Ezagent.DomainGit.WorkspaceChangePort` is not available
(module doesn't exist yet), and `Supervisor.terminate_child` fails to find
`WorkspaceChangeRegistry` as a child of `EzagentDomainGit.Application`.

- [ ] **Step 3: Implement the port**

```elixir
# apps/ezagent_domain_git/lib/ezagent/domain_git/workspace_change_port.ex
defmodule Ezagent.DomainGit.WorkspaceChangePort do
  @moduledoc """
  Closed contract for workspace-change collection implementations.

  An implementation fresh-reads the exact ready workspace-provision proof
  named by the request's `provision_id` + task/generation identity (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §4.2) and returns the bounded, normalized
  `[Ezagent.DomainGit.FileChange.t()]` V1 upsert envelope for that
  worktree, or a stable rejection when any reported change falls outside
  the V1 envelope (§2.2) or the configured `Ezagent.DomainGit.ChangeLimits`.
  Implementations never accept a caller-chosen filesystem path, never run
  provider HTTP, and never see a token.
  """

  alias __MODULE__.Request
  alias Ezagent.DomainGit.FileChange

  @type result :: {:ok, [FileChange.t()]} | {:error, term()}

  @callback collect(Request.t()) :: result()
end
```

```elixir
# apps/ezagent_domain_git/lib/ezagent/domain_git/workspace_change_port/request.ex
defmodule Ezagent.DomainGit.WorkspaceChangePort.Request do
  @moduledoc """
  Closed request accepted by the workspace-change collection port.

  Mirrors `Ezagent.DomainGit.WorkspaceProvisionPort.Request`'s closed-field
  discipline but carries no `task_policy` — collection proves worktree
  ownership by fresh-reading the exact `(task_access_uri, task_uri,
  generation)` identity off the already-ready `provision_id` row (design
  §4.2), not by re-presenting a CapBAC policy. The shape deliberately
  excludes repository URLs, provider selection, and filesystem paths —
  those coordinates are resolved by the workspace-owning domain from the
  persisted provision row.
  """

  @enforce_keys [:task_access_uri, :task_uri, :generation, :provision_id]
  defstruct @enforce_keys

  @fields @enforce_keys

  @type t :: %__MODULE__{
          task_access_uri: URI.t(),
          task_uri: URI.t(),
          generation: pos_integer(),
          provision_id: String.t()
        }

  @doc "Builds a request only when every key belongs to the closed contract and is well-typed."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    keys = Map.keys(attrs)

    cond do
      Enum.any?(keys, &(not is_atom(&1))) ->
        {:error, :invalid_attributes}

      Enum.any?(keys, &(&1 not in @fields)) ->
        {:error, :unknown_fields}

      missing = Enum.find(@fields, &(not Map.has_key?(attrs, &1))) ->
        {:error, {:missing_field, missing}}

      not match?(%URI{}, attrs.task_access_uri) ->
        {:error, {:invalid_field, :task_access_uri}}

      not match?(%URI{}, attrs.task_uri) ->
        {:error, {:invalid_field, :task_uri}}

      not (is_integer(attrs.generation) and attrs.generation > 0) ->
        {:error, {:invalid_field, :generation}}

      not (is_binary(attrs.provision_id) and attrs.provision_id != "") ->
        {:error, {:invalid_field, :provision_id}}

      true ->
        {:ok, struct!(__MODULE__, attrs)}
    end
  end

  def new(_attrs), do: {:error, :invalid_attributes}
end
```

```elixir
# apps/ezagent_domain_git/lib/ezagent/domain_git/workspace_change_registry.ex
defmodule Ezagent.DomainGit.WorkspaceChangeRegistry do
  @moduledoc """
  Owns the single workspace-change collection implementation registration.

  Registration validates the implementation contract without executing any
  implementation callback. Structurally mirrors
  `Ezagent.DomainGit.WorkspaceProvisionRegistry` for the orthogonal
  `WorkspaceChangePort` contract — collection is a separate concern from
  provisioning `prepare`/`cleanup` (design §4.2/§4.3), so it gets its own
  port and its own single-implementation registry rather than a third
  callback bolted onto `WorkspaceProvisionPort`.
  """

  use GenServer

  alias Ezagent.DomainGit.WorkspaceChangePort

  @type registration_error ::
          :conflicting_workspace_change_collector
          | {:invalid_workspace_change_collector, term()}
          | {:missing_behaviour, module()}
          | {:missing_callbacks, [{atom(), non_neg_integer()}]}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Registers the sole conforming implementation, idempotently."
  @spec register(term()) :: :ok | {:error, registration_error()}
  def register(implementation) do
    GenServer.call(__MODULE__, {:register, implementation})
  end

  @doc "Returns the registered implementation."
  @spec implementation() :: {:ok, module()} | {:error, :workspace_change_collector_not_registered}
  def implementation, do: GenServer.call(__MODULE__, :implementation)

  if Mix.env() == :test do
    @doc false
    def replace_for_test(implementation) do
      GenServer.call(__MODULE__, {:replace_for_test, implementation})
    end
  end

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call({:register, implementation}, _from, nil) do
    case validate_implementation(implementation) do
      :ok -> {:reply, :ok, implementation}
      {:error, _reason} = error -> {:reply, error, nil}
    end
  end

  def handle_call({:register, implementation}, _from, implementation),
    do: {:reply, :ok, implementation}

  def handle_call({:register, _implementation}, _from, registered),
    do: {:reply, {:error, :conflicting_workspace_change_collector}, registered}

  if Mix.env() == :test do
    def handle_call({:replace_for_test, nil}, _from, _registered),
      do: {:reply, :ok, nil}

    def handle_call({:replace_for_test, implementation}, _from, registered) do
      case validate_implementation(implementation) do
        :ok -> {:reply, :ok, implementation}
        {:error, _reason} = error -> {:reply, error, registered}
      end
    end
  end

  def handle_call(:implementation, _from, nil),
    do: {:reply, {:error, :workspace_change_collector_not_registered}, nil}

  def handle_call(:implementation, _from, implementation),
    do: {:reply, {:ok, implementation}, implementation}

  defp validate_implementation(implementation) when is_atom(implementation) do
    case Code.ensure_loaded(implementation) do
      {:module, ^implementation} ->
        with :ok <- validate_behaviour(implementation),
             :ok <- validate_callbacks(implementation) do
          :ok
        end

      {:error, _reason} ->
        {:error, {:invalid_workspace_change_collector, implementation}}
    end
  end

  defp validate_implementation(implementation),
    do: {:error, {:invalid_workspace_change_collector, implementation}}

  defp validate_behaviour(implementation) do
    behaviours =
      implementation.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    if WorkspaceChangePort in behaviours do
      :ok
    else
      {:error, {:missing_behaviour, implementation}}
    end
  end

  defp validate_callbacks(implementation) do
    missing =
      WorkspaceChangePort.behaviour_info(:callbacks)
      |> Enum.reject(fn {name, arity} -> function_exported?(implementation, name, arity) end)
      |> Enum.sort()

    if missing == [], do: :ok, else: {:error, {:missing_callbacks, missing}}
  end
end
```

- [ ] **Step 4: Wire the registry into the application supervisor**

In `apps/ezagent_domain_git/lib/ezagent_domain_git/application.ex`, add the
new registry next to the existing two:

```elixir
      case Supervisor.start_link(
             [
               {Ezagent.DomainGit.AdapterRegistry, []},
               {Ezagent.DomainGit.WorkspaceProvisionRegistry, []},
               {Ezagent.DomainGit.WorkspaceChangeRegistry, []}
             ],
             strategy: :one_for_one,
             name: __MODULE__
           ) do
```

- [ ] **Step 5: Run the new tests to confirm they pass**

```bash
cd apps/ezagent_domain_git && mix test test/ezagent/domain_git/workspace_change_port_test.exs
```

Expected: PASS (7 tests, 0 failures).

- [ ] **Step 6: Run the full app suite to confirm nothing else broke**

```bash
cd apps/ezagent_domain_git && mix test
```

Expected: PASS, 0 failures — in particular
`test/architecture/dependency_boundary_test.exs` (deps unchanged) and
`test/ezagent_domain_git/application_boot_test.exs` (child lookups are
by-name, not by position or count, so adding a sibling child doesn't
disturb them).

- [ ] **Step 7: Format, run the umbrella gate, and commit**

```bash
mix format apps/ezagent_domain_git/lib/ezagent/domain_git/workspace_change_port.ex \
            apps/ezagent_domain_git/lib/ezagent/domain_git/workspace_change_port/request.ex \
            apps/ezagent_domain_git/lib/ezagent/domain_git/workspace_change_registry.ex \
            apps/ezagent_domain_git/lib/ezagent_domain_git/application.ex \
            apps/ezagent_domain_git/test/ezagent/domain_git/workspace_change_port_test.exs
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p2 mix ci.fast
```

Expected: PASS (use `timeout: 300000` if your tool defaults to 120s).

```bash
git add apps/ezagent_domain_git/lib/ezagent/domain_git/workspace_change_port.ex \
        apps/ezagent_domain_git/lib/ezagent/domain_git/workspace_change_port/request.ex \
        apps/ezagent_domain_git/lib/ezagent/domain_git/workspace_change_registry.ex \
        apps/ezagent_domain_git/lib/ezagent_domain_git/application.ex \
        apps/ezagent_domain_git/test/ezagent/domain_git/workspace_change_port_test.exs
git commit -m "feat(domain-git): add provider-neutral WorkspaceChangePort + registry"
```

---

### Task 3: `GitRunner.collect_status/1` (`ezagent_domain_workspace`)

**Files:**
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/git_runner.ex` (add `collect_status/1`, a `status_entry` type, and two private parse helpers)
- Modify: `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/git_runner_test.exs` (add a `describe "collect_status/1"` block)

**Interfaces:**
- Produces: `Ezagent.Workspace.TaskWorkspace.GitRunner.collect_status(map()) :: {:ok, [status_entry()]} | {:error, term()}`
  where `status_entry :: %{path: String.t(), index_status: String.t(), worktree_status: String.t()}`.
  Accepts the same "ready proof" shape `verify/1` does (must contain
  `:worktree_path`; `:runner_opts` optional, same executor-injection test
  seam).
- Consumed by: Task 4's `ChangeCollector.collect/1`.

- [ ] **Step 1: Write the failing tests**

Add this `describe` block to
`apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/git_runner_test.exs`,
just before the final `defp request(overrides) do` private-helpers section
(so it can reuse the file's existing `local_origin!/1`/`request/1` helpers
and the top-level `setup`'s `%{root: root}`):

```elixir
  describe "collect_status/1" do
    test "classifies untracked, modified, deleted, and unknown status codes" do
      executor = fn argv, _opts ->
        assert "-C" in argv
        assert "status" in argv
        assert "-z" in argv

        entries =
          Enum.join(
            [
              "?? new_file.txt",
              " M modified.txt",
              "M  staged_modified.txt",
              " D deleted.txt",
              "!! ignored.log"
            ],
            <<0>>
          ) <> <<0>>

        {:ok, %{stdout: entries, stderr: "", exit_status: 0}}
      end

      assert {:ok, entries} =
               GitRunner.collect_status(%{
                 worktree_path: "/worktree",
                 runner_opts: %{executor: executor}
               })

      assert entries == [
               %{path: "new_file.txt", index_status: "?", worktree_status: "?"},
               %{path: "modified.txt", index_status: " ", worktree_status: "M"},
               %{path: "staged_modified.txt", index_status: "M", worktree_status: " "},
               %{path: "deleted.txt", index_status: " ", worktree_status: "D"},
               %{path: "ignored.log", index_status: "!", worktree_status: "!"}
             ]
    end

    test "requires an exact worktree_path key" do
      assert {:error, :invalid_ready_workspace} = GitRunner.collect_status(%{})
    end

    test "maps a git exit failure to a stable checkout-mismatch error" do
      executor = fn _argv, _opts -> {:error, {:git_exit, 128}} end

      assert {:error, :workspace_checkout_mismatch} =
               GitRunner.collect_status(%{
                 worktree_path: "/worktree",
                 runner_opts: %{executor: executor}
               })
    end

    test "propagates infrastructure executor failures unchanged" do
      executor = fn _argv, _opts -> {:error, :git_command_timeout} end

      assert {:error, :git_command_timeout} =
               GitRunner.collect_status(%{
                 worktree_path: "/worktree",
                 runner_opts: %{executor: executor}
               })
    end

    test "reports a real untracked file and a real modified file from a live worktree", %{
      root: root
    } do
      origin = local_origin!(root)

      assert {:ok, ready} =
               GitRunner.prepare(request(remote_url: origin, allow_local_fixture: true))

      File.write!(Path.join(ready.worktree_path, "untracked.txt"), "new\n")
      File.write!(Path.join(ready.worktree_path, "README.md"), "changed\n")

      assert {:ok, entries} = GitRunner.collect_status(ready)
      paths = entries |> Enum.map(& &1.path) |> Enum.sort()
      assert paths == ["README.md", "untracked.txt"]

      assert %{path: "untracked.txt", index_status: "?", worktree_status: "?"} =
               Enum.find(entries, &(&1.path == "untracked.txt"))

      assert %{path: "README.md", worktree_status: "M"} =
               Enum.find(entries, &(&1.path == "README.md"))
    end
  end
```

- [ ] **Step 2: Run to confirm it fails**

```bash
cd apps/ezagent_domain_workspace && mix test test/ezagent/workspace/task_workspace/git_runner_test.exs
```

Expected: FAIL — `GitRunner.collect_status/1` is undefined.

- [ ] **Step 3: Add the type and public function**

In `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/git_runner.ex`,
add the type next to the existing `@type command_result` (after line 25):

```elixir
  @type status_entry :: %{
          path: String.t(),
          index_status: String.t(),
          worktree_status: String.t()
        }
```

Add the public function right after `verify_absent/1` ends (after line 211,
before `defp remove_if_unregistered`):

```elixir
  @doc """
  Collects the porcelain-v1 worktree status of a prepared worktree against
  its current index (design §4.2 — the raw material the workspace-change
  collector classifies into V1 upsert candidates or rejections). Unlike
  `verify/1`, a non-empty result is the expected, useful case — this
  function does not require a clean tree.
  """
  @spec collect_status(map()) :: {:ok, [status_entry()]} | {:error, term()}
  def collect_status(%{worktree_path: worktree} = ready) when is_binary(worktree) do
    opts = command_opts(Map.get(ready, :runner_opts, %{}))

    status_argv =
      git_argv(["-C", worktree, "status", "--porcelain=v1", "-z", "--untracked-files=all"])

    case execute(status_argv, opts) do
      {:ok, %{stdout: stdout}} -> {:ok, parse_status_entries(stdout)}
      {:error, {:git_exit, _status}} -> {:error, :workspace_checkout_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def collect_status(_ready), do: {:error, :invalid_ready_workspace}
```

Add the private parsing helpers next to `listed_worktree?/2`:

```elixir
  defp parse_status_entries(stdout) do
    stdout
    |> String.split(<<0>>, trim: true)
    |> Enum.map(&parse_status_entry/1)
  end

  defp parse_status_entry(
         <<index_status::binary-size(1), worktree_status::binary-size(1), " ",
           path::binary>>
       ) do
    %{path: path, index_status: index_status, worktree_status: worktree_status}
  end
```

Update the moduledoc's first line to mention the new capability (keep the
rest unchanged):

```elixir
  @moduledoc """
  Executes bounded anonymous Git argv plans for task workspace preparation
  and status collection.
```

- [ ] **Step 4: Run to confirm it passes**

```bash
cd apps/ezagent_domain_workspace && mix test test/ezagent/workspace/task_workspace/git_runner_test.exs
```

Expected: PASS — all prior tests in this file still pass (nothing existing
was changed, only added-to), plus the 5 new `collect_status/1` tests.

- [ ] **Step 5: Run the full app suite**

```bash
cd apps/ezagent_domain_workspace && mix test
```

Expected: PASS, 0 failures — in particular
`test/invariants/task_workspace_boundary_test.exs`'s
`"production source has no shell, System.cmd, or naked Port entry"` test
still passes (the new function reuses the existing `execute/2` private
helper; it introduces no new `System.cmd`/`Port.open`/`sh -c`), and its
`"task workspace production code uses approved URI parsers"` test still
passes (no bare `URI.new`/`URI.new!` was added — this file doesn't parse
any URI at all).

- [ ] **Step 6: Format, run the umbrella gate, and commit**

```bash
mix format apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/git_runner.ex \
            apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/git_runner_test.exs
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p2 mix ci.fast
```

Expected: PASS (use `timeout: 300000` if your tool defaults to 120s).

```bash
git add apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/git_runner.ex \
        apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/git_runner_test.exs
git commit -m "feat(domain-workspace): add GitRunner.collect_status/1 for change collection"
```

---

### Task 4: `ChangeCollector` happy path + Application wiring

**Files:**
- Create: `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/change_collector.ex`
- Create: `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/change_collector_test.exs`
- Modify: `apps/ezagent_domain_workspace/lib/ezagent_domain_workspace/application.ex` (register `ChangeCollector` as the `WorkspaceChangeRegistry` implementation)
- Modify: `apps/ezagent_domain_workspace/test/ezagent_domain_workspace/application_boot_test.exs` (add a boot-registration proof test)

**Interfaces:**
- Consumes: `Ezagent.DomainGit.WorkspaceChangePort` (Task 2),
  `Ezagent.DomainGit.WorkspaceChangePort.Request` (Task 2),
  `Ezagent.DomainGit.FileChange.new/1` + `.validate_many/1` (existing),
  `Ezagent.DomainGit.ChangeLimits.current/0` (existing),
  `GitRunner.collect_status/1` (Task 3), `Ezagent.Workspace.TaskWorkspace.Store.get_by_provision_id/1` (existing),
  `Ezagent.Workspace.TaskWorkspace.Provision` (existing schema, read-only).
- Produces: `Ezagent.Workspace.TaskWorkspace.ChangeCollector.collect/1` —
  implements `WorkspaceChangePort`. Closed result vocabulary:
  `{:ok, [FileChange.t()]}` | `{:error, :workspace_not_ready}` |
  `{:error, :workspace_identity_mismatch}` | `{:error, :no_changes_collected}` |
  `{:error, :unsupported_workspace_change}` | `{:error, :change_limit_exceeded}` |
  `{:error, :workspace_read_failed}` | `{:error, :invalid_change_limits_config}` |
  `{:error, :invalid_change_request}`.
- Consumed by: Tasks 5 and 6 (more tests against the same module, appended
  to the same test file), and eventually P4 (see "Relationship to later
  slices").

- [ ] **Step 1: Write the failing happy-path tests**

```elixir
# apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/change_collector_test.exs
defmodule Ezagent.Workspace.TaskWorkspace.ChangeCollectorTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.DomainGit.RepositoryRef
  alias Ezagent.DomainGit.WorkspaceChangePort.Request
  alias Ezagent.DomainGit.WorkspaceProvisionPort.Request, as: ProvisionRequest
  alias Ezagent.Entity.GitTaskAccess
  alias Ezagent.Workspace.TaskWorkspace.{ChangeCollector, Provisioner}
  alias EzagentDomainWorkspace.TestSupport.FakeTaskWorkspaceGitRunner

  setup do
    previous_home = System.get_env("EZAGENT_HOME")

    root =
      Path.join(System.tmp_dir!(), "change-collector-#{System.unique_integer([:positive])}")

    System.put_env("EZAGENT_HOME", root)

    Application.put_env(
      :ezagent_domain_workspace,
      :task_workspace_git_runner,
      Ezagent.Workspace.TaskWorkspace.GitRunner
    )

    on_exit(fn ->
      if is_nil(previous_home),
        do: System.delete_env("EZAGENT_HOME"),
        else: System.put_env("EZAGENT_HOME", previous_home)

      Application.delete_env(:ezagent_domain_workspace, :task_workspace_git_runner)
      Application.delete_env(:ezagent_domain_workspace, :task_workspace_remote_builder)
      Application.delete_env(:ezagent_domain_workspace, :provisioner_test_collect_status_result)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  describe "collect/1 happy path" do
    test "collects a single new UTF-8 file as one upsert", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      File.write!(Path.join(worktree_path, "notes.md"), "hello from the task\n")

      assert {:ok, [change]} = ChangeCollector.collect(change_request)
      assert change.path == "notes.md"
      assert change.operation == :upsert
      assert change.content == "hello from the task\n"
    end

    test "collects a modified tracked file as an upsert", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      File.write!(Path.join(worktree_path, "README.md"), "modified by the task\n")

      assert {:ok, [change]} = ChangeCollector.collect(change_request)
      assert change.path == "README.md"
      assert change.content == "modified by the task\n"
    end

    test "rejects an empty diff", %{root: root} do
      %{change_request: change_request} = ready_fixture!(root)

      assert {:error, :no_changes_collected} = ChangeCollector.collect(change_request)
    end

    test "rejects when no ready provision matches provision_id", %{root: root} do
      %{change_request: change_request} = ready_fixture!(root)

      unready = %{
        change_request
        | provision_id: "never-provisioned-#{System.unique_integer([:positive])}"
      }

      assert {:error, :workspace_not_ready} = ChangeCollector.collect(unready)
    end

    test "rejects when generation does not match the provisioned identity", %{root: root} do
      %{change_request: change_request} = ready_fixture!(root)

      mismatched = %{change_request | generation: change_request.generation + 1}

      assert {:error, :workspace_identity_mismatch} = ChangeCollector.collect(mismatched)
    end

    test "rejects a malformed argument closed to the port contract" do
      assert {:error, :invalid_change_request} = ChangeCollector.collect(:not_a_request)
    end
  end

  defp ready_fixture!(root, suffix \\ "one") do
    origin = local_origin!(root)
    workspace = "change-collector-#{suffix}-#{System.unique_integer([:positive])}"
    workspace_uri = Ezagent.URI.workspace(workspace)
    task_id = "task-#{suffix}"

    {:ok, repository} =
      RepositoryRef.new(%{
        repository_uri: Ezagent.URI.resource(workspace, "git-repository", "widgets"),
        provider_adapter: :fixture,
        provider_host: "git.example.test",
        external_id: "repo-1",
        owner_path: "acme/widgets",
        base_ref: "main",
        visibility: :public
      })

    {:ok, policy} =
      GitTaskAccess.new(%{
        id: "task-access-#{suffix}-#{System.unique_integer([:positive])}",
        task_id: task_id,
        generation: 1,
        workspace_uri: workspace_uri,
        credential_owner_uri: Ezagent.URI.user(workspace, "owner"),
        grantee_uri: Ezagent.URI.agent(workspace, "worker"),
        repository: repository,
        provider_adapter: :fixture,
        allowed_head_ref: "task/#{task_id}",
        allowed_actions: [:provision_workspace, :cleanup_workspace],
        idempotency_inputs: %{task_id: task_id, generation: 1}
      })

    task_access_uri = GitTaskAccess.uri_from_args(policy)
    assert {:ok, _pid} = Ezagent.DomainGit.TaskAccessSupervisor.ensure_started(policy)
    on_exit(fn -> Ezagent.DomainGit.TaskAccessSupervisor.teardown(task_access_uri) end)

    task_uri = Ezagent.URI.resource(workspace, "kanban-task", task_id)
    provision_id = "provision-#{suffix}-#{System.unique_integer([:positive])}"

    {:ok, provision_request} =
      ProvisionRequest.new_authorized(
        %{
          task_access_uri: task_access_uri,
          task_uri: task_uri,
          generation: 1,
          operation: :prepare,
          provision_id: provision_id
        },
        policy
      )

    Application.put_env(:ezagent_domain_workspace, :task_workspace_remote_builder, fn _, _ ->
      %{remote_url: origin, allow_local_fixture: true}
    end)

    assert {:ok, %{status: :ready, cwd: worktree_path}} = Provisioner.prepare(provision_request)

    {:ok, change_request} =
      Request.new(%{
        task_access_uri: task_access_uri,
        task_uri: task_uri,
        generation: 1,
        provision_id: provision_id
      })

    %{
      worktree_path: worktree_path,
      change_request: change_request,
      task_access_uri: task_access_uri,
      task_uri: task_uri
    }
  end

  defp local_origin!(root) do
    origin = Path.join(root, "origin-#{System.unique_integer([:positive])}.git")
    source = Path.join(root, "source-#{System.unique_integer([:positive])}")
    File.mkdir_p!(source)

    git!(root, ["init", "--bare", origin])
    git!(source, ["init", "-b", "main"])
    File.write!(Path.join(source, "README.md"), "fixture\n")
    git!(source, ["add", "README.md"])

    git!(source, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.test",
      "commit",
      "-m",
      "fixture"
    ])

    git!(source, ["remote", "add", "origin", origin])
    git!(source, ["push", "origin", "main"])
    git!(root, ["--git-dir", origin, "symbolic-ref", "HEAD", "refs/heads/main"])
    origin
  end

  defp git!(cd, args) do
    {output, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    output
  end
end
```

- [ ] **Step 2: Run to confirm it fails**

```bash
cd apps/ezagent_domain_workspace && mix test test/ezagent/workspace/task_workspace/change_collector_test.exs
```

Expected: FAIL — `Ezagent.Workspace.TaskWorkspace.ChangeCollector` is not
available.

- [ ] **Step 3: Implement `ChangeCollector`**

```elixir
# apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/change_collector.ex
defmodule Ezagent.Workspace.TaskWorkspace.ChangeCollector do
  @moduledoc """
  Collects the V1 bounded UTF-8 upsert change envelope from an owned, ready
  task workspace (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §2.2, §4.2).

  `collect/1` fresh-reads the exact ready `Provision` row named by the
  request's `provision_id`, cross-checks it against the request's
  `task_access_uri`/`task_uri`/`generation` identity (the "ready-provision
  proof"), then classifies every path `GitRunner.collect_status/1` reports
  against the worktree's index:

    * untracked (`??`) or modified (`M`/`A` on either side) regular files
      become upsert candidates;
    * anything else outside the V1 envelope — deleted (`D`), renamed or
      copied (`R`/`C`, which without `--find-renames` present as a delete
      plus an untracked add and are caught by the delete half), unmerged
      (`U`), a symlink, a non-regular path (a submodule mount is a
      directory on disk — the same "must be a regular file" check that
      rejects symlinks rejects it too), an executable-mode file, or
      content that is not valid UTF-8 or contains an embedded NUL byte —
      rejects the WHOLE collection with
      `{:error, :unsupported_workspace_change}`. This module never
      silently drops an offending path and returns the rest.

  Every candidate is also re-validated through
  `Ezagent.DomainGit.FileChange.new/1` (path traversal, `.git` segments,
  control bytes) and the batch through
  `Ezagent.DomainGit.FileChange.validate_many/1` (`ChangeLimits`) — both
  chokepoints this module reuses rather than re-implements.

  Closed result vocabulary:

    * `{:ok, [FileChange.t()]}` — one or more upserts.
    * `{:error, :workspace_not_ready}` — no ready provision matches
      `provision_id`.
    * `{:error, :workspace_identity_mismatch}` — a ready provision exists
      for `provision_id` but its task_access/task/generation identity does
      not match the request exactly.
    * `{:error, :no_changes_collected}` — the worktree has zero changes
      against its index.
    * `{:error, :unsupported_workspace_change}` — see above.
    * `{:error, :change_limit_exceeded}` — `ChangeLimits` breached (a
      single file's bytes, the file count, or the total bytes).
    * `{:error, :workspace_read_failed}` — a reported path could not be
      read (a filesystem race between enumeration and read).
    * `{:error, :invalid_change_limits_config}` — propagated from
      `Ezagent.DomainGit.ChangeLimits.current/0`.

  Never runs provider HTTP, never accepts a caller-chosen filesystem path,
  never sees a token.
  """

  @behaviour Ezagent.DomainGit.WorkspaceChangePort

  import Bitwise

  alias Ezagent.DomainGit.{ChangeLimits, FileChange, WorkspaceChangePort}
  alias Ezagent.Workspace.TaskWorkspace.{GitRunner, Provision, Store}

  @impl true
  @spec collect(WorkspaceChangePort.Request.t()) :: WorkspaceChangePort.result()
  def collect(%WorkspaceChangePort.Request{} = request) do
    with {:ok, row} <- fresh_ready_provision(request),
         {:ok, limits} <- ChangeLimits.current(),
         {:ok, entries} <- runner().collect_status(%{worktree_path: row.worktree_path}),
         {:ok, candidate_paths} <- classify(entries),
         :ok <- at_least_one_change(candidate_paths),
         {:ok, changes} <- read_candidates(row.worktree_path, candidate_paths, limits),
         :ok <- FileChange.validate_many(changes) do
      {:ok, changes}
    end
  end

  def collect(_request), do: {:error, :invalid_change_request}

  defp fresh_ready_provision(request) do
    case Store.get_by_provision_id(request.provision_id) do
      %Provision{status: :ready} = row -> exact_identity(row, request)
      %Provision{} -> {:error, :workspace_not_ready}
      nil -> {:error, :workspace_not_ready}
    end
  end

  defp exact_identity(row, request) do
    if row.task_access_uri == URI.to_string(request.task_access_uri) and
         row.task_uri == URI.to_string(request.task_uri) and
         row.generation == request.generation do
      {:ok, row}
    else
      {:error, :workspace_identity_mismatch}
    end
  end

  defp at_least_one_change([]), do: {:error, :no_changes_collected}
  defp at_least_one_change(_paths), do: :ok

  defp classify(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case classify_entry(entry) do
        {:upsert, path} -> {:cont, {:ok, [path | acc]}}
        :ignored -> {:cont, {:ok, acc}}
        :unsupported -> {:halt, {:error, :unsupported_workspace_change}}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.reverse(paths)}
      {:error, _reason} = error -> error
    end
  end

  defp classify_entry(%{index_status: "?", worktree_status: "?", path: path}),
    do: {:upsert, path}

  defp classify_entry(%{index_status: "!", worktree_status: "!"}), do: :ignored

  defp classify_entry(%{index_status: x, worktree_status: y})
       when x in ~w(D R C U) or y in ~w(D R C U),
       do: :unsupported

  defp classify_entry(%{index_status: x, worktree_status: y, path: path})
       when x in ~w(M A) or y in ~w(M A),
       do: {:upsert, path}

  defp classify_entry(_entry), do: :unsupported

  defp read_candidates(worktree_path, paths, limits) do
    worktree_root = Path.expand(worktree_path)

    paths
    |> Enum.reduce_while({:ok, [], 0, 0}, fn path, {:ok, acc, count, total_bytes} ->
      read_one(worktree_root, path, limits, acc, count, total_bytes)
    end)
    |> case do
      {:ok, changes, _count, _total_bytes} -> {:ok, Enum.reverse(changes)}
      {:error, _reason} = error -> error
    end
  end

  defp read_one(worktree_root, path, limits, acc, count, total_bytes) do
    with {:ok, full_path} <- contained_path(worktree_root, path),
         {:ok, stat} <- safe_lstat(full_path),
         :ok <- regular_file(stat),
         :ok <- not_executable(stat),
         :ok <- within_file_limit(stat.size, limits.max_file_bytes),
         next_count = count + 1,
         next_total = total_bytes + stat.size,
         :ok <- within_batch_limits(next_count, next_total, limits),
         {:ok, content} <- read_file(full_path),
         :ok <- not_binary(content),
         {:ok, change} <- FileChange.new(%{path: path, operation: :upsert, content: content}) do
      {:cont, {:ok, [change | acc], next_count, next_total}}
    else
      {:error, :change_limit_exceeded} -> {:halt, {:error, :change_limit_exceeded}}
      {:error, :workspace_read_failed} -> {:halt, {:error, :workspace_read_failed}}
      {:error, _reason} -> {:halt, {:error, :unsupported_workspace_change}}
    end
  end

  defp contained_path(_worktree_root, "/" <> _rest), do: {:error, :path_escapes_worktree}

  defp contained_path(worktree_root, relative_path) do
    full_path = Path.expand(Path.join(worktree_root, relative_path))

    if full_path == worktree_root or String.starts_with?(full_path, worktree_root <> "/") do
      {:ok, full_path}
    else
      {:error, :path_escapes_worktree}
    end
  end

  defp safe_lstat(path) do
    case File.lstat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, _reason} -> {:error, :workspace_read_failed}
    end
  end

  defp regular_file(%File.Stat{type: :regular}), do: :ok
  defp regular_file(%File.Stat{}), do: {:error, :not_regular_file}

  defp not_executable(%File.Stat{mode: mode}) do
    if (mode &&& 0o111) == 0, do: :ok, else: {:error, :executable_mode}
  end

  defp within_file_limit(size, max_file_bytes) do
    if size <= max_file_bytes, do: :ok, else: {:error, :change_limit_exceeded}
  end

  defp within_batch_limits(count, total_bytes, limits) do
    if count <= limits.max_files and total_bytes <= limits.max_total_bytes,
      do: :ok,
      else: {:error, :change_limit_exceeded}
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _reason} -> {:error, :workspace_read_failed}
    end
  end

  defp not_binary(content) do
    if String.valid?(content) and not String.contains?(content, <<0>>),
      do: :ok,
      else: {:error, :binary_content}
  end

  defp runner do
    if Mix.env() == :test,
      do: Application.get_env(:ezagent_domain_workspace, :task_workspace_git_runner, GitRunner),
      else: GitRunner
  end
end
```

- [ ] **Step 4: Register the implementation at application boot**

In `apps/ezagent_domain_workspace/lib/ezagent_domain_workspace/application.ex`,
add to `register_task_workspace_infrastructure/0`, right before its final
`:ok`:

```elixir
    :ok =
      Ezagent.DomainGit.WorkspaceChangeRegistry.register(
        Ezagent.Workspace.TaskWorkspace.ChangeCollector
      )

    :ok
```

- [ ] **Step 5: Run the new tests to confirm they pass**

```bash
cd apps/ezagent_domain_workspace && mix test test/ezagent/workspace/task_workspace/change_collector_test.exs
```

Expected: PASS (6 tests, 0 failures).

- [ ] **Step 6: Add a boot-registration proof test**

In `apps/ezagent_domain_workspace/test/ezagent_domain_workspace/application_boot_test.exs`,
add this test right after `"production boot registers the task path
authority and provision port"`:

```elixir
  test "production boot registers the change collector" do
    assert {:ok, Ezagent.Workspace.TaskWorkspace.ChangeCollector} =
             Ezagent.DomainGit.WorkspaceChangeRegistry.implementation()
  end
```

- [ ] **Step 7: Run the full app suite**

```bash
cd apps/ezagent_domain_workspace && mix test
```

Expected: PASS, 0 failures — in particular
`test/invariants/task_workspace_boundary_test.exs`'s
`"workspace domain never invokes provider adapters"` test (the new file
references no `AdapterRegistry`/`.create_change_request(`/`.resolve_repository(`)
and `"task workspace production code uses approved URI parsers"` (the new
file uses only `URI.to_string/1`, never bare `URI.new`/`URI.new!`), and
`"durable provision schema contains no credential material"`'s
`assert length(schema_names) == 30` / `assert length(migration_names) == 30`
(unaffected — `Provision` and its migrations are untouched).

- [ ] **Step 8: Format, run the umbrella gate, and commit**

```bash
mix format apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/change_collector.ex \
            apps/ezagent_domain_workspace/lib/ezagent_domain_workspace/application.ex \
            apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/change_collector_test.exs \
            apps/ezagent_domain_workspace/test/ezagent_domain_workspace/application_boot_test.exs
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p2 mix ci.fast
```

Expected: PASS (use `timeout: 300000` if your tool defaults to 120s).

```bash
git add apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/change_collector.ex \
        apps/ezagent_domain_workspace/lib/ezagent_domain_workspace/application.ex \
        apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/change_collector_test.exs \
        apps/ezagent_domain_workspace/test/ezagent_domain_workspace/application_boot_test.exs
git commit -m "feat(domain-workspace): add ChangeCollector happy path + registry wiring"
```

---

### Task 5: Adversarial rejections — filesystem shape

**Files:**
- Modify: `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/change_collector_test.exs` (append a new `describe "collect/1 rejects filesystem-shape violations"` block)
- Modify: `apps/ezagent_domain_workspace/test/support/fake_task_workspace_git_runner.ex` (add a `collect_status/1` fake, additive — does not change any existing function)

**Interfaces:**
- Consumes: `ChangeCollector.collect/1` (Task 4), the `ready_fixture!/2` /
  `local_origin!/1` / `git!/2` private helpers already defined in
  `change_collector_test.exs` by Task 4.
- Produces: no new production code — this task is test-only, proving the
  rejection rules Task 4's `classify_entry/1` and `read_one/6` already
  implement.

- [ ] **Step 1: Extend the shared fake Git runner with `collect_status/1`**

Append to `apps/ezagent_domain_workspace/test/support/fake_task_workspace_git_runner.ex`,
inside the existing module (this is purely additive — `prepare/1`,
`verify/1`, `remove/1`, and `verify_absent/1` are untouched, so
`ProvisionerTest`/`ReconcilerTest`, which also configure this fake, are
unaffected):

```elixir
  def collect_status(ready) do
    owner = Application.get_env(:ezagent_domain_workspace, :provisioner_test_owner)
    if owner, do: send(owner, {:git_collect_status, ready})

    Application.get_env(
      :ezagent_domain_workspace,
      :provisioner_test_collect_status_result,
      {:ok, []}
    )
  end
```

- [ ] **Step 2: Write the failing adversarial tests**

Append to `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/change_collector_test.exs`,
after the `describe "collect/1 happy path"` block and before the private
helper functions:

```elixir
  describe "collect/1 rejects filesystem-shape violations" do
    test "rejects a symlink even when it points inside the worktree", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      target = Path.join(worktree_path, "README.md")
      link = Path.join(worktree_path, "shortcut.md")
      File.ln_s!(target, link)

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end

    test "rejects a deleted tracked file", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      File.rm!(Path.join(worktree_path, "README.md"))

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end

    test "rejects a rename (seen as a delete plus an untracked add, since V1 disables rename detection)",
         %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      old_path = Path.join(worktree_path, "README.md")
      new_path = Path.join(worktree_path, "RENAMED.md")
      File.rename!(old_path, new_path)

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end

    test "rejects an executable mode change on an otherwise-unmodified file", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      File.chmod!(Path.join(worktree_path, "README.md"), 0o755)

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end

    test "rejects content containing an embedded NUL byte, even though it is valid UTF-8", %{
      root: root
    } do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      File.write!(Path.join(worktree_path, "binary.dat"), "abc" <> <<0>> <> "def")

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end

    test "rejects content that is not valid UTF-8", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      File.write!(Path.join(worktree_path, "invalid_utf8.dat"), <<255, 254, 253>>)

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end

    test "rejects a reported path that is a directory — the shape a submodule mount takes", %{
      root: root
    } do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      vendor = Path.join(worktree_path, "vendor")
      File.mkdir_p!(vendor)
      File.write!(Path.join(vendor, "nested.txt"), "not part of the parent tree\n")

      Application.put_env(
        :ezagent_domain_workspace,
        :task_workspace_git_runner,
        FakeTaskWorkspaceGitRunner
      )

      Application.put_env(
        :ezagent_domain_workspace,
        :provisioner_test_collect_status_result,
        {:ok, [%{path: "vendor", index_status: "?", worktree_status: "?"}]}
      )

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end

    test "rejects a relative path that climbs out of the worktree", %{root: root} do
      %{change_request: change_request} = ready_fixture!(root)

      Application.put_env(
        :ezagent_domain_workspace,
        :task_workspace_git_runner,
        FakeTaskWorkspaceGitRunner
      )

      Application.put_env(
        :ezagent_domain_workspace,
        :provisioner_test_collect_status_result,
        {:ok, [%{path: "../../etc/passwd", index_status: "?", worktree_status: "?"}]}
      )

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end

    test "rejects an absolute path reported in place of a worktree-relative one", %{root: root} do
      %{change_request: change_request} = ready_fixture!(root)

      Application.put_env(
        :ezagent_domain_workspace,
        :task_workspace_git_runner,
        FakeTaskWorkspaceGitRunner
      )

      Application.put_env(
        :ezagent_domain_workspace,
        :provisioner_test_collect_status_result,
        {:ok, [%{path: "/etc/passwd", index_status: "?", worktree_status: "?"}]}
      )

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end
  end
```

- [ ] **Step 3: Run to confirm the new tests fail for the right reason**

```bash
cd apps/ezagent_domain_workspace && mix test test/ezagent/workspace/task_workspace/change_collector_test.exs
```

Expected: FAIL initially — `FakeTaskWorkspaceGitRunner.collect_status/1` is
undefined until Step 1's fake extension is in place (if you completed Step
1 first, these tests should already pass, since Task 4's implementation
already contains the rejection logic; this step exists to prove the tests
actually exercise the rejection path — temporarily comment out the
`classify_entry`/`regular_file`/`not_executable`/`not_binary`/`contained_path`
guards one at a time locally to confirm each test fails without its
corresponding guard, then restore them. Do not leave the code
commented out.).

- [ ] **Step 4: Run to confirm all tests pass**

```bash
cd apps/ezagent_domain_workspace && mix test test/ezagent/workspace/task_workspace/change_collector_test.exs
```

Expected: PASS (14 tests total, 0 failures — 6 from Task 4 + 8 new).

- [ ] **Step 5: Run the full app suite**

```bash
cd apps/ezagent_domain_workspace && mix test
```

Expected: PASS, 0 failures — confirm
`test/ezagent/workspace/task_workspace/provisioner_test.exs` and any other
test configuring `FakeTaskWorkspaceGitRunner` still pass unchanged (the
fake's extension is additive-only).

- [ ] **Step 6: Format, run the umbrella gate, and commit**

```bash
mix format apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/change_collector_test.exs \
            apps/ezagent_domain_workspace/test/support/fake_task_workspace_git_runner.ex
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p2 mix ci.fast
```

Expected: PASS (use `timeout: 300000` if your tool defaults to 120s).

```bash
git add apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/change_collector_test.exs \
        apps/ezagent_domain_workspace/test/support/fake_task_workspace_git_runner.ex
git commit -m "test(domain-workspace): adversarial filesystem-shape coverage for ChangeCollector"
```

---

### Task 6: Adversarial rejections — limits, read races, and final verification

**Files:**
- Modify: `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/change_collector_test.exs` (append a new `describe "collect/1 rejects limit and read-failure violations"` block plus a `restore_change_limits/1` helper)

**Interfaces:**
- Consumes: same as Task 5 — no new production code.

- [ ] **Step 1: Write the failing tests**

Append to `apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/change_collector_test.exs`,
after the `describe "collect/1 rejects filesystem-shape violations"` block
and before the private helper functions:

```elixir
  describe "collect/1 rejects limit and read-failure violations" do
    setup do
      previous = Application.get_env(:ezagent_domain_git, :change_limits, :absent)
      on_exit(fn -> restore_change_limits(previous) end)
      :ok
    end

    test "rejects a single file over max_file_bytes", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      Application.put_env(:ezagent_domain_git, :change_limits, %{
        max_files: 100,
        max_file_bytes: 10,
        max_total_bytes: 1_000
      })

      File.write!(Path.join(worktree_path, "too_big.txt"), String.duplicate("a", 11))

      assert {:error, :change_limit_exceeded} = ChangeCollector.collect(change_request)
    end

    test "rejects when the file count exceeds max_files", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      Application.put_env(:ezagent_domain_git, :change_limits, %{
        max_files: 2,
        max_file_bytes: 1_000,
        max_total_bytes: 1_000_000
      })

      for n <- 1..3 do
        File.write!(Path.join(worktree_path, "file-#{n}.txt"), "content #{n}\n")
      end

      assert {:error, :change_limit_exceeded} = ChangeCollector.collect(change_request)
    end

    test "rejects when total bytes exceed max_total_bytes", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      Application.put_env(:ezagent_domain_git, :change_limits, %{
        max_files: 100,
        max_file_bytes: 1_000,
        max_total_bytes: 15
      })

      File.write!(Path.join(worktree_path, "a.txt"), String.duplicate("a", 10))
      File.write!(Path.join(worktree_path, "b.txt"), String.duplicate("b", 10))

      assert {:error, :change_limit_exceeded} = ChangeCollector.collect(change_request)
    end

    test "surfaces a vanished reported path as workspace_read_failed, not a false rejection", %{
      root: root
    } do
      %{change_request: change_request} = ready_fixture!(root)

      Application.put_env(
        :ezagent_domain_workspace,
        :task_workspace_git_runner,
        FakeTaskWorkspaceGitRunner
      )

      Application.put_env(
        :ezagent_domain_workspace,
        :provisioner_test_collect_status_result,
        {:ok, [%{path: "vanished.txt", index_status: "?", worktree_status: "?"}]}
      )

      assert {:error, :workspace_read_failed} = ChangeCollector.collect(change_request)
    end
  end

  defp restore_change_limits(:absent), do: Application.delete_env(:ezagent_domain_git, :change_limits)
  defp restore_change_limits(value), do: Application.put_env(:ezagent_domain_git, :change_limits, value)
```

- [ ] **Step 2: Run to confirm it fails**

```bash
cd apps/ezagent_domain_workspace && mix test test/ezagent/workspace/task_workspace/change_collector_test.exs
```

Expected: FAIL — `restore_change_limits/1` undefined until this step's
code is in place (if written correctly per Step 1, this should already
compile and the four new tests should already pass, since Task 4's
`read_one/6` already implements the limit and read-failure checks; if any
of the four fail, that indicates a real gap in Task 4's implementation to
fix before proceeding, not a plan bug to route around).

- [ ] **Step 3: Run to confirm all tests pass**

```bash
cd apps/ezagent_domain_workspace && mix test test/ezagent/workspace/task_workspace/change_collector_test.exs
```

Expected: PASS (18 tests total, 0 failures — 6 from Task 4 + 8 from Task 5
+ 4 new).

- [ ] **Step 4: Run the full domain_git and domain_workspace suites**

```bash
cd apps/ezagent_domain_git && mix test
cd ../ezagent_domain_workspace && mix test
```

Expected: PASS, 0 failures in both.

- [ ] **Step 5: Run the specific invariant tests this plan's constraints depend on**

From the umbrella root (these are `:umbrella_only` cross-tier suites — run
from the root, not from inside a single app):

```bash
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p2 mix test \
  apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs \
  apps/ezagent_domain_workspace/test/invariants/task_workspace_boundary_test.exs \
  apps/ezagent_domain_git/test/architecture/dependency_boundary_test.exs
```

Expected: PASS, 0 failures — confirms this plan added no table without
categorizing it, broke no locality/URI-parser/secret-field scan, and added
no forbidden umbrella dependency.

- [ ] **Step 6: Format, run the full umbrella gate, and commit**

```bash
mix format apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/change_collector_test.exs
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p2 mix ci.fast
```

Expected: PASS (use `timeout: 300000` if your tool defaults to 120s).

```bash
git add apps/ezagent_domain_workspace/test/ezagent/workspace/task_workspace/change_collector_test.exs
git commit -m "test(domain-workspace): adversarial limit and read-failure coverage for ChangeCollector"
```

- [ ] **Step 7: Full-suite sanity pass**

Run the slow, full local gate once at the end of the slice (not per task):

```bash
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p2 mix precommit
```

Run with `timeout: 600000` or `run_in_background: true` and poll — this
takes 500s+. Expected: PASS. A killed/timed-out run is not a pass; if it
doesn't finish, say so and re-run correctly rather than assuming green.

---

## Self-review notes (for whoever executes this plan)

- **Spec coverage:** design §9 Slice P2 lists four deliverables — the
  provider-neutral change port (Task 2), the ready-provision proof (Task
  4's `fresh_ready_provision/1` + `exact_identity/2`), bounded UTF-8 upsert
  collection (Tasks 3–4), and traversal/symlink/binary/delete/rename/mode/limit
  adversarial tests (Tasks 5–6, plus the submodule-shaped-directory case
  design §2.2 calls out that the task's own enumeration didn't separately
  name — flagged to the requester, see the handoff summary).
- **No placeholders:** every step above shows complete code, not a
  reference to "similar to Task N" — each task's test file is either
  created fresh (Task 4) or appended to with fully-written `describe`
  blocks (Tasks 5–6), because they share one fixture helper
  (`ready_fixture!/2`) defined once.
- **Type consistency check:** `WorkspaceChangePort.Request`'s four fields
  (`task_access_uri`, `task_uri`, `generation`, `provision_id`) are used
  identically in Task 2 (definition), Task 4 (`ChangeCollector.collect/1`,
  the test fixture), and Tasks 5–6 (mutating the same struct via `%{... |
  ...}`). `GitRunner.collect_status/1`'s `status_entry` shape (`path`,
  `index_status`, `worktree_status`) is produced in Task 3, consumed by
  `classify_entry/1` in Task 4, and matched exactly by the synthetic
  entries `FakeTaskWorkspaceGitRunner.collect_status/1` returns in Tasks
  5–6.
