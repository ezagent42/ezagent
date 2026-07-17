defmodule Ezagent.Workspace.TaskWorkspace.Retirement do
  @moduledoc "Transfers matching-generation Agent retirement to the durable sanctioned lifecycle."

  alias Ezagent.Workspace.TaskWorkspace.Provision

  @doc "Retires the Agent named by a durable task-workspace provision."
  @spec retire(Provision.t()) :: :ok | {:error, term()}
  def retire(%Provision{} = row) do
    with {:ok, agent_uri} <- parse_uri(row.agent_uri),
         {:ok, workspace_uri} <- parse_uri(row.workspace_uri),
         {:ok, provenance_root} <- parse_uri(row.provenance_root_uri),
         {:ok, attempt_id} <- creation_attempt(row, agent_uri, workspace_uri),
         {:ok, caps} <-
           Ezagent.Domain.Agent.read_caps(provenance_root, %{
             caller: provenance_root,
             caps: MapSet.new()
           }) do
      interpret(
        Ezagent.Domain.Agent.retire_spawned(agent_uri, %{
          caller: provenance_root,
          caps: caps,
          workspace_uri: workspace_uri,
          provenance_root: provenance_root,
          creation_attempt_id: attempt_id,
          reason: :task_workspace_cleanup
        })
      )
    end
  end

  defp creation_attempt(%Provision{creation_attempt_id: id}, _agent, _workspace)
       when is_binary(id) and id != "",
       do: {:ok, id}

  defp creation_attempt(_row, agent, workspace),
    do: Ezagent.Agent.CreationInventory.find_attempt(agent, workspace)

  defp interpret({:ok, %{termination: :destroyed}}), do: :ok

  defp interpret({:partial, %{termination: :destroyed, obligation_id: id}}) when is_integer(id),
    do: :ok

  defp interpret({:error, report}), do: {:error, {:agent_retirement_failed, report}}
  defp interpret(other), do: {:error, {:agent_retirement_failed, other}}

  defp parse_uri(value) when is_binary(value) and value != "" do
    {:ok, Ezagent.URI.new!(value)}
  rescue
    _ -> {:error, :invalid_retirement_handle}
  end

  defp parse_uri(_value), do: {:error, :invalid_retirement_handle}
end
