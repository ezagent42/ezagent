defmodule Ezagent.Kind.Termination do
  @moduledoc false

  @doc false
  @spec standard(Supervisor.supervisor(), pid()) :: :ok | {:error, term()}
  def standard(supervisor, pid) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(supervisor, pid) do
      :ok -> verify_dead(pid)
      {:error, :not_found} -> exit_and_verify(pid)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec custom(module(), atom(), URI.t(), pid()) :: :ok | {:error, :still_alive}
  def custom(mod, fun, uri, pid) when is_atom(mod) and is_atom(fun) and is_pid(pid) do
    # The custom callback owns the whole aggregate. Stopping only an inner
    # permanent Kind.Server can make its supervisor restart it.
    _ = apply(mod, fun, [uri, pid])
    verify_dead(pid)
  end

  defp exit_and_verify(pid) do
    _ = Process.exit(pid, :shutdown)
    verify_dead(pid)
  end

  defp verify_dead(pid) do
    budget_ms = Application.get_env(:ezagent_core, :terminate_verify_ms, 200)
    if wait_dead(pid, budget_ms), do: :ok, else: {:error, :still_alive}
  end

  defp wait_dead(pid, budget_ms)
       when is_pid(pid) and is_integer(budget_ms) and budget_ms >= 0 do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> true
    after
      budget_ms ->
        Process.demonitor(ref, [:flush])
        not Process.alive?(pid)
    end
  end
end
