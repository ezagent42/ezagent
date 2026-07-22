defmodule Ezagent.DomainGit.TestSupport.WorkspaceProvisionProbe do
  @moduledoc false

  @behaviour Ezagent.DomainGit.WorkspaceProvisionPort

  @impl true
  def prepare(request), do: effect(:prepare, request, :ready)

  @impl true
  def cleanup(request), do: effect(:cleanup, request, :cleaned)

  defp effect(operation, request, status) do
    if owner = Process.whereis(:git_task_workspace_effect_probe) do
      send(owner, {:workspace_effect, operation, request})
    end

    {:ok, %{provision_id: request.provision_id, status: status}}
  end
end
