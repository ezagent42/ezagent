defmodule EzagentPluginGitWorkflow.Authorization do
  @moduledoc """
  Drives a run's `accepted -> authorized` transition through the
  fail-closed `ExecutionSeam` (design §3.1/§5.4). Zero provider/workspace
  side effects — those belong to later slices.
  """

  alias EzagentPluginGitWorkflow.ExecutionSeam
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowRun

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
