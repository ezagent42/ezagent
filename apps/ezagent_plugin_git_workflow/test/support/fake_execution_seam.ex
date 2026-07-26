defmodule EzagentPluginGitWorkflow.FakeExecutionSeam do
  @moduledoc false
  @behaviour EzagentPluginGitWorkflow.ExecutionSeam

  @impl true
  def authorize(%{binding_id: "bnd_denied"}, _binding), do: {:error, :not_authorized}
  def authorize(_run, _binding), do: {:ok, %{authorized: true}}

  @impl true
  def invoke(_authorized_task, _action, _typed_args), do: {:ok, %{}}
end
