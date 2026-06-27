defmodule Ezagent.TestSupport.RoleSeedHookProbe do
  @moduledoc false

  @behaviour Ezagent.Plugin.RoleSeedHook

  @key {__MODULE__, :test_pid}

  def attach(test_pid) when is_pid(test_pid) do
    :persistent_term.put(@key, test_pid)
    :ok
  end

  def detach do
    :persistent_term.erase(@key)
    :ok
  end

  @impl true
  def seed_role(recipe) do
    case :persistent_term.get(@key, nil) do
      pid when is_pid(pid) -> send(pid, {:seed_role, recipe})
      _ -> :ok
    end

    :ok
  end
end
