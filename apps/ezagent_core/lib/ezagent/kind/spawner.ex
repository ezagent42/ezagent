defmodule Ezagent.Kind.Spawner do
  @moduledoc false

  @doc false
  def spawn(kind_module, params, opts, strategy, await_ready) do
    if Keyword.has_key?(opts, :launch_context) and not match?({:standard, _}, strategy) do
      {:error, :launch_context_unsupported}
    else
      do_spawn(kind_module, params, opts, strategy, await_ready)
    end
  end

  defp do_spawn(kind_module, params, opts, strategy, await_ready) do
    {params, relay} = relay_params(params, opts)

    try do
      result = start(kind_module, params, strategy)
      acknowledge(relay, result)
      if match?({:standard, _}, strategy), do: await_ready.(result, params)
      result
    after
      if relay, do: Ezagent.Kind.LaunchContextRelay.discard(relay)
    end
  end

  defp relay_params(params, opts) do
    case Keyword.fetch(opts, :launch_context) do
      :error ->
        {params, nil}

      {:ok, context} ->
        relay = Ezagent.Kind.LaunchContextRelay.issue(context)
        {Map.put(params, :launch_context_relay, relay), relay}
    end
  end

  defp start(kind_module, params, {:standard, supervisor}) do
    DynamicSupervisor.start_child(supervisor, {Ezagent.Kind.Server, {kind_module, params}})
  end

  defp start(_kind_module, params, {:custom, module, function}),
    do: apply(module, function, [params])

  defp acknowledge(nil, _result), do: :ok
  defp acknowledge(relay, {:ok, child}), do: Ezagent.Kind.LaunchContextRelay.commit(relay, child)
  defp acknowledge(relay, _result), do: Ezagent.Kind.LaunchContextRelay.force_discard(relay)
end
