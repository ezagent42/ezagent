defmodule Ezagent.Workspace.TaskWorkspace.ReconcilerBoot do
  @moduledoc "Runs one bounded task-workspace recovery batch at application boot."

  alias Ezagent.Workspace.TaskWorkspace.Reconciler

  @default_limit 50

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc false
  def start_link(opts) do
    limit = Keyword.get(opts, :limit, configured_limit())
    Task.start_link(fn -> Reconciler.recover_once(limit: limit) end)
  end

  defp configured_limit do
    Application.get_env(
      :ezagent_domain_workspace,
      :task_workspace_boot_recovery_limit,
      @default_limit
    )
  end
end
