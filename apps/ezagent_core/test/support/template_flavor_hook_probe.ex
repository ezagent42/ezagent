defmodule Ezagent.TestSupport.TemplateFlavorHookProbe do
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

  def store_attributes(agent_uri, class_module) do
    send_event({:store_flavor_attrs, agent_uri, class_module})
  end

  def delete_attributes(agent_uri) do
    send_event({:delete_flavor_attrs, agent_uri})
  end

  defp send_event(event) do
    case :persistent_term.get(@key, nil) do
      pid when is_pid(pid) -> send(pid, event)
      _ -> :ok
    end

    :ok
  end
end
