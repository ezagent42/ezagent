defmodule EzagentPluginGitWorkflow.FakeExecutionSeam do
  @moduledoc false
  @behaviour EzagentPluginGitWorkflow.ExecutionSeam

  @impl true
  def authorize(%{binding_id: "bnd_denied"}, _binding), do: {:error, :not_authorized}
  def authorize(_run, _binding), do: {:ok, %{authorized: true}}

  # Echoes what it received so a test can prove the call REACHED the backend
  # for this specific action, rather than only that it did not raise.
  @impl true
  def invoke(authorized_task, action, typed_args),
    do: {:ok, %{reached: :backend, action: action, task: authorized_task, args: typed_args}}
end
