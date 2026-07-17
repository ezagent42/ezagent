defmodule Ezagent.Kind.Template.AttributeHook do
  @moduledoc "Registered downstream hook for attributes emitted by Template Classes."

  @hooks_key {__MODULE__, :hooks}

  @callback store_attributes(URI.t(), module()) :: :ok | {:error, term()}
  @callback delete_attributes(URI.t()) :: :ok | {:error, term()}

  @spec register(module()) :: :ok
  def register(module) when is_atom(module) do
    :persistent_term.put(@hooks_key, Enum.uniq([module | hooks()]))
    :ok
  end

  @spec store(URI.t(), module()) :: :ok | {:error, term()}
  def store(%URI{} = instance_uri, class_module) when is_atom(class_module),
    do: invoke_hooks(:store_attributes, [instance_uri, class_module])

  @spec delete(URI.t()) :: :ok | {:error, term()}
  def delete(%URI{} = instance_uri), do: invoke_hooks(:delete_attributes, [instance_uri])

  defp invoke_hooks(function, args) do
    Enum.reduce_while(hooks(), :ok, fn module, :ok ->
      case invoke(module, function, args) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
        other -> {:halt, {:error, {:invalid_attribute_hook_return, module, function, other}}}
      end
    end)
  end

  defp invoke(module, function, args) do
    arity = length(args)

    if Code.ensure_loaded?(module) and function_exported?(module, function, arity),
      do: apply(module, function, args),
      else: :ok
  end

  defp hooks, do: :persistent_term.get(@hooks_key, [])
end
