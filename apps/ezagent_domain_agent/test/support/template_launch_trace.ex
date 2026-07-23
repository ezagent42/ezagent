defmodule Ezagent.Agent.TemplateLaunchTrace do
  @moduledoc false

  def trace_call(module, function, arity, callback) do
    owner = self()
    tracer = spawn_link(fn -> forward(owner) end)
    :erlang.trace(owner, true, [:call, {:tracer, tracer}])
    :erlang.trace_pattern({module, function, arity}, true, [])

    try do
      callback.()
    after
      :erlang.trace_pattern({module, function, arity}, false, [])
      :erlang.trace(owner, false, [:call])
      send(tracer, :stop)
    end
  end

  defp forward(owner) do
    receive do
      :stop ->
        :ok

      message ->
        send(owner, message)
        forward(owner)
    end
  end
end
