defmodule Ezagent.Kind.LaunchContextInit do
  @moduledoc false

  @doc false
  def prepare(kind_module, args) do
    {taken, relay, clean_args} = take(args)

    case taken do
      {:ok, context} ->
        run(kind_module, Map.put(clean_args, :launch_context, context), clean_args, relay)

      :consumed ->
        run(kind_module, clean_args, clean_args, relay)

      :absent ->
        run(kind_module, clean_args, clean_args, relay)

      {:error, :launch_context_lost} ->
        {:error, :launch_context_lost}
    end
  end

  defp take(args) do
    case Map.pop(args, :launch_context_relay) do
      {nil, clean} -> {:absent, nil, clean}
      {relay, clean} -> {Ezagent.Kind.LaunchContextRelay.take(relay), relay, clean}
    end
  end

  defp run(kind_module, hook_args, clean_args, relay) do
    result =
      if function_exported?(kind_module, :before_start, 1),
        do: kind_module.before_start(hook_args),
        else: :ok

    if result == :ok, do: {:ok, clean_args, relay}, else: result
  end
end
