defmodule Ezagent.DomainGit.TestSupport.WorkspaceChangeProbe do
  @moduledoc false

  @behaviour Ezagent.DomainGit.WorkspaceChangePort

  alias Ezagent.DomainGit.FileChange

  @impl true
  def collect(request) do
    if owner = Process.whereis(:git_task_workspace_effect_probe) do
      send(owner, {:workspace_effect, :collect, request})
    end

    {:ok, change} =
      FileChange.new(%{path: "probe.txt", operation: :upsert, content: request.provision_id})

    {:ok, [change]}
  end
end
