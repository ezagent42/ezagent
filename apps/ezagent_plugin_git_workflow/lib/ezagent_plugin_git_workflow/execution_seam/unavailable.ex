defmodule EzagentPluginGitWorkflow.ExecutionSeam.Unavailable do
  @moduledoc """
  Production default execution seam. Permanently fail-closed, zero side
  effects. See `EzagentPluginGitWorkflow.ExecutionSeam` for the contract
  this satisfies.
  """

  @behaviour EzagentPluginGitWorkflow.ExecutionSeam

  @impl true
  def authorize(_run, _binding), do: {:error, :authorization_unavailable}

  @impl true
  def invoke(_authorized_task, _action, _typed_args), do: {:error, :authorization_unavailable}
end
