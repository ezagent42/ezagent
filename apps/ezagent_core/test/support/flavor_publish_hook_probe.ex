defmodule Ezagent.TestSupport.FlavorPublishHookProbe do
  @moduledoc false

  @key {__MODULE__, :test_pid}

  def attach(test_pid) when is_pid(test_pid) do
    :persistent_term.put(@key, test_pid)
    :ok
  end

  def detach do
    :persistent_term.erase(@key)
    :ok
  end

  def publish_agent_flavor(decl) do
    case :persistent_term.get(@key, nil) do
      pid when is_pid(pid) -> send(pid, {:publish_agent_flavor, decl})
      _ -> :ok
    end

    :ok
  end
end
