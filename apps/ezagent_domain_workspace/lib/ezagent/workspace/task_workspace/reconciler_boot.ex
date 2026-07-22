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
    Task.start_link(fn -> run(opts) end)
  end

  @doc false
  def run(opts) do
    limit = Keyword.get(opts, :limit, configured_limit())
    now_fun = Keyword.get(opts, :now_fun, &DateTime.utc_now/0)
    wait_fun = Keyword.get(opts, :wait_fun, &wait/1)
    now = now_fun.()
    first = Reconciler.recover_once(limit: limit, now: now)

    case Ezagent.Workspace.TaskWorkspace.Store.latest_active_recovery_lease_deadline(limit,
           now: now
         ) do
      %DateTime{} = deadline ->
        delay = max(DateTime.diff(deadline, now, :millisecond) + 1, 1)
        :ok = wait_fun.(delay)
        %{first: first, second: Reconciler.recover_once(limit: limit, now: now_fun.())}

      nil ->
        %{first: first, second: :not_needed}
    end
  end

  defp wait(milliseconds) do
    receive do
    after
      milliseconds -> :ok
    end
  end

  defp configured_limit do
    Application.get_env(
      :ezagent_domain_workspace,
      :task_workspace_boot_recovery_limit,
      @default_limit
    )
  end
end
