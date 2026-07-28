defmodule EzagentPluginGitWorkflow.PolicyDerivation do
  @moduledoc """
  Builds the authoritative `Ezagent.Entity.GitTaskAccess` policy for one run
  out of the two durable records — a `TaskBinding` row and a `WorkflowRun`
  row — and nothing else (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §3.2, §3.4.2).

  PURE. It reads no `ctx`, mints no capability, starts no process, dispatches
  nothing and writes nothing. That is what lets a denied
  `ExecutionSeam.CapBacked.authorize/2` satisfy §3.1's "任何 backend 在返回
  `{:error, _}` 时都必须零副作用" — the answer is computed before anything
  could have happened.

  ## Every field is READ from a durable row, never derived

  | policy field | source |
  |---|---|
  | `id` | `run.id` (see below) |
  | `task_uri` | `run.source_task_uri` |
  | `generation` | `run.binding_generation` |
  | `workspace_uri` | `binding.workspace_uri` |
  | `credential_owner_uri` | `binding.credential_owner_uri` |
  | `grantee_uri` | `binding.task_receiver_uri` — **the acting principal** |
  | `repository` | `binding`'s seven repository columns |
  | `provider_adapter` | `binding.provider_adapter` |
  | `allowed_head_ref` | `DeterministicRef.derive/2` over `binding.allowed_head_namespace` + `run.id` |
  | `allowed_actions` | the closed list below |
  | `idempotency_inputs` | `run.source_task_uri` + `run.binding_generation` |

  `credential_owner_uri` (who LENDS the credential) and `grantee_uri` (who
  ACTS) are separate columns and stay separate here. Collapsing them — e.g.
  falling back to the credential owner when the receiver looks wrong — is the
  §3.2 "凭空推导 principal" failure this table exists to make impossible to
  write by accident.

  ## `id` must be deterministic

  `Ezagent.Entity.GitTaskAccess` derives the task-access receiver URI by
  hashing the WHOLE policy struct, so `id` is part of that digest. A random
  `id` would produce a different receiver URI on every retry: a second Kind
  would be spawned, the cap would be minted against a different instance, and
  design §8's "one deterministic ref / one PR" assertions would fail in a way
  that looks like a provider bug.

  `id` is therefore `run.id` verbatim. `WorkflowRun.generate_id/3` already
  makes it `"run_" <> sha256_hex(binding_id:generation:external_task_id)` — a
  server-owned value that is byte-identical across every retry of the same run
  and distinct between runs, and that already satisfies the policy's own
  identifier grammar.

  ## `allowed_actions` is SIX of the eight

  Least privilege: an action nobody calls is authority nobody needs. The
  workflow invokes, and only invokes:

    * `:provision_workspace` — `authorized → workspace_ready` (§5.4)
    * `:collect_workspace_changes` — `workspace_ready → changes_ready`
    * `:create_change_request` — `changes_ready → pr_open`
    * `:read_change_request`, `:list_checks`, `:list_reviews` — the one
      observation tick, `pr_open → observations_current` (§6.3)

  Deliberately EXCLUDED:

    * `:resolve_repository` — the repository coordinates are already durable
      on the binding and are carried inside this very policy, so nothing in
      §5.4 or §8's main scenario ever asks a provider to resolve them. §8's
      fault injection additionally forbids any provider call before
      `workspace_ready`, so there is no pre-flight resolve either.
    * `:cleanup_workspace` — §5.4 terminates at `observations_current`; V1
      has no teardown transition, and §8 asserts exactly one workspace
      provision with no matching cleanup.

  Widening this list is a design decision, not an implementation detail: it
  changes the policy digest, hence the task-access URI, hence the run's
  provider idempotency identity.

  ## Denials, never crashes

  Every inconsistency between the two rows is an answer, not an exception.
  The reasons are members of `EzagentPluginGitWorkflow.Blocker.codes/0` so a
  runner can classify them without a second vocabulary.
  """

  alias Ezagent.DomainGit.RepositoryRef
  alias Ezagent.Entity.GitTaskAccess
  alias EzagentPluginGitWorkflow.DeterministicRef
  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowRun

  @allowed_actions [
    :provision_workspace,
    :collect_workspace_changes,
    :create_change_request,
    :read_change_request,
    :list_checks,
    :list_reviews
  ]

  @doc """
  The closed action list every derived policy carries — see the moduledoc for
  why each of the six is in and each of the other two is out.
  """
  @spec allowed_actions() :: [atom()]
  def allowed_actions, do: @allowed_actions

  @doc """
  Derives the exact `GitTaskAccess` policy for `run` under `binding`.

  Both structs are destructured in the head rather than read field-by-field:
  a dot-access receiver is not type-provable by the plugin workspace-locality
  scanner, so every `run.x` would otherwise be booked as dynamic-receiver debt
  (the same fix `AuthorizedTask.new/1` and `Authorization.authorize_run/2`
  already took on this branch).
  """
  @spec derive(WorkflowRun.t(), TaskBinding.t()) ::
          {:ok, GitTaskAccess.t()} | {:error, :not_authorized | :workspace_identity_mismatch}
  def derive(
        %WorkflowRun{
          id: run_id,
          binding_id: run_binding_id,
          binding_generation: generation,
          workspace_uri: run_workspace_uri,
          source_task_uri: task_uri
        },
        %TaskBinding{
          id: binding_id,
          generation: binding_generation,
          enabled: enabled,
          workspace_uri: workspace_uri,
          task_receiver_uri: grantee_uri,
          credential_owner_uri: credential_owner_uri,
          repository_uri: repository_uri,
          provider_adapter: provider_adapter,
          provider_host: provider_host,
          external_id: external_id,
          owner_path: owner_path,
          base_ref: base_ref,
          visibility: visibility,
          allowed_head_namespace: allowed_head_namespace
        }
      ) do
    with :ok <- binding_enabled(enabled),
         :ok <- same_binding(run_binding_id, binding_id),
         :ok <- same_generation(generation, binding_generation),
         :ok <- same_workspace(run_workspace_uri, workspace_uri),
         {:ok, allowed_head_ref} <- head_ref(allowed_head_namespace, run_id),
         {:ok, repository} <-
           repository(%{
             repository_uri: repository_uri,
             provider_adapter: provider_adapter,
             provider_host: provider_host,
             external_id: external_id,
             owner_path: owner_path,
             base_ref: base_ref,
             visibility: visibility
           }) do
      policy(%{
        id: run_id,
        task_uri: task_uri,
        generation: generation,
        workspace_uri: workspace_uri,
        credential_owner_uri: credential_owner_uri,
        grantee_uri: grantee_uri,
        repository: repository,
        provider_adapter: provider_adapter,
        allowed_head_ref: allowed_head_ref,
        allowed_actions: @allowed_actions,
        idempotency_inputs: %{task_uri: task_uri, generation: generation}
      })
    end
  end

  # Anything that is not the two durable structs is not an authorization
  # question this module can answer, and answering it `:ok` would be the
  # worst possible failure mode.
  def derive(_run, _binding), do: {:error, :not_authorized}

  defp binding_enabled(true), do: :ok
  defp binding_enabled(_enabled), do: {:error, :not_authorized}

  # A run may only be authorized against the binding it names. Without this,
  # a caller could pair any run with any binding and the backend would mint a
  # cap for THAT binding's receiver.
  defp same_binding(binding_id, binding_id), do: :ok
  defp same_binding(_run_binding_id, _binding_id), do: {:error, :not_authorized}

  # A run pinned to generation N under a binding that has advanced to N+1 is
  # deterministically stale — re-running it can never agree.
  defp same_generation(generation, generation), do: :ok
  defp same_generation(_run_generation, _binding_generation), do: {:error, :not_authorized}

  defp same_workspace(workspace_uri, workspace_uri), do: :ok

  defp same_workspace(_run_workspace, _binding_workspace),
    do: {:error, :workspace_identity_mismatch}

  # `DeterministicRef.derive/2` accepts only a server-generated run id. A run
  # whose id did not come from `WorkflowRun.generate_id/3` fails closed here
  # instead of raising `FunctionClauseError` several frames deep inside a
  # runner.
  defp head_ref(namespace, "run_" <> _digest = run_id),
    do: {:ok, DeterministicRef.derive(namespace, run_id)}

  defp head_ref(_namespace, _run_id), do: {:error, :not_authorized}

  defp repository(attrs) do
    case RepositoryRef.new(attrs) do
      {:ok, repository} -> {:ok, repository}
      {:error, _reason} -> {:error, :not_authorized}
    end
  end

  # `GitTaskAccess.new/1` is the authority on what a legal policy is — it
  # re-checks the workspace scoping of every URI, that the grantee really is
  # an agent principal, that the head ref is a legal Git ref, and that the
  # idempotency inputs restate the policy's own coordinates. The reason is
  # dropped rather than forwarded: the seam contract (§3.1) has exactly two
  # denial atoms, and a structurally invalid durable row is deterministic, so
  # it takes the terminal one.
  defp policy(attrs) do
    case GitTaskAccess.new(attrs) do
      {:ok, policy} -> {:ok, policy}
      {:error, _reason} -> {:error, :not_authorized}
    end
  end
end
