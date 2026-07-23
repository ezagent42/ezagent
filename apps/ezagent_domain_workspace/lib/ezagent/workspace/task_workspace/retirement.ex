defmodule Ezagent.Workspace.TaskWorkspace.Retirement do
  @moduledoc "Transfers matching-generation Agent retirement to the durable sanctioned lifecycle."

  alias Ezagent.Workspace.TaskWorkspace.Provision

  @doc "Retires the Agent named by a durable task-workspace provision."
  @spec retire(Provision.t(), map()) :: :ok | {:error, term()}
  def retire(%Provision{} = row, %{
        attempt_id: attempt_id,
        agent_uri: agent_uri,
        root_uri: provenance_root,
        workspace_uri: workspace_uri
      }) do
    with :ok <- exact_row(row, attempt_id, agent_uri, provenance_root, workspace_uri),
         {:ok, caps} <-
           Ezagent.Domain.Agent.read_caps(provenance_root, %{
             caller: provenance_root,
             # #195 authz contract: read_caps + Agent.Retirement.retire both
             # require the authenticated holder. This is a self-read/self-retire
             # by the provenance root, so it is the authenticated principal.
             authenticated_principal: provenance_root,
             caps: MapSet.new()
           }) do
      interpret(
        Ezagent.Domain.Agent.retire_spawned(agent_uri, %{
          caller: provenance_root,
          authenticated_principal: provenance_root,
          caps: caps,
          workspace_uri: workspace_uri,
          provenance_root: provenance_root,
          creation_attempt_id: attempt_id,
          reason: :task_workspace_cleanup
        })
      )
    end
  end

  defp exact_row(row, attempt_id, agent_uri, root_uri, workspace_uri) do
    if row.creation_attempt_id == attempt_id and row.agent_uri == URI.to_string(agent_uri) and
         row.provenance_root_uri == URI.to_string(root_uri) and
         row.workspace_uri == URI.to_string(workspace_uri),
       do: :ok,
       else: {:error, :invalid_retirement_handle}
  end

  defp interpret({:ok, %{termination: :destroyed}}), do: :ok

  defp interpret({:partial, %{termination: :destroyed, obligation_id: id}}) when is_integer(id),
    do: :ok

  defp interpret({:error, report}), do: {:error, {:agent_retirement_failed, report}}
  defp interpret(other), do: {:error, {:agent_retirement_failed, other}}
end
