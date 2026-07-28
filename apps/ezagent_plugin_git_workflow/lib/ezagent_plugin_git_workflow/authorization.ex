defmodule EzagentPluginGitWorkflow.Authorization do
  @moduledoc """
  Drives a run's `accepted -> authorized` transition through the
  fail-closed `ExecutionSeam` (design §3.1/§5.4). Zero provider/workspace
  side effects — those belong to later slices.
  """

  alias EzagentPluginGitWorkflow.AuthorizedTask
  alias EzagentPluginGitWorkflow.ExecutionSeam
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowRun

  @doc """
  Reads `run`'s binding row and derives the authorized task from it, returning
  BOTH.

  Every stage of `StageRunner` and every tick of `Observation` starts here, and
  each re-asks rather than caching: `ExecutionSeam.authorize/2` is pure and
  side-effect free by contract (§3.1), so re-deriving costs nothing and means a
  binding disabled or re-generated since the last step denies the NEXT one
  instead of the run continuing under a stale authorization.

  The `binding` comes back alongside the task because it is the row the
  authorization was derived FROM, and a caller needing a column the policy does
  not carry (`allowed_head_namespace`) would otherwise read the same row twice.

  A run whose binding row is GONE cannot be authorized and cannot be repaired by
  retrying. The store's reason is dropped — it names a row, and the run already
  names the binding — and the answer is `:internal_error`, a terminal code in
  `Blocker`, so the caller records it and stops rather than spinning.
  """
  @spec authorized_task(WorkflowRun.t()) ::
          {:ok, TaskBinding.t(), AuthorizedTask.t()}
          | {:error, :internal_error}
          | {:error, :authorization_unavailable}
          | {:error, :not_authorized}
  def authorized_task(%WorkflowRun{binding_id: binding_id} = run) do
    with {:ok, binding} <- read_binding(binding_id),
         {:ok, task} <- ExecutionSeam.authorize(run, binding) do
      {:ok, binding, task}
    end
  end

  defp read_binding(binding_id) do
    case Store.read_binding(binding_id) do
      {:ok, binding} -> {:ok, binding}
      {:error, _reason} -> {:error, :internal_error}
    end
  end

  @doc """
  Attempts to authorize `run` against `binding` via the configured seam.

  On `{:ok, _authorized_task}`: CAS-transitions the run to "authorized" and
  returns the updated run. The authorized_task itself is not persisted —
  later slices re-derive it from the same seam call.

  On `{:error, :authorization_unavailable}` or `{:error, :not_authorized}`:
  performs no transition; the run stays "accepted" for a later retry
  (design §5.4).
  """
  @spec authorize_run(WorkflowRun.t(), TaskBinding.t()) ::
          {:ok, WorkflowRun.t()}
          | {:error, :authorization_unavailable}
          | {:error, :not_authorized}
          | {:error, term()}
  def authorize_run(
        %WorkflowRun{status: "accepted", id: id, state_version: state_version} = run,
        %TaskBinding{} = binding
      ) do
    case ExecutionSeam.authorize(run, binding) do
      {:ok, _authorized_task} ->
        Store.transition(id, state_version, "accepted", "authorized")

      {:error, _reason} = error ->
        error
    end
  end

  def authorize_run(%WorkflowRun{status: status}, %TaskBinding{}),
    do: {:error, {:invalid_run_status, status}}
end
