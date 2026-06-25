defmodule Ezagent.Kind.Template.FlavorHook do
  @moduledoc """
  Registered hook for agent-flavor launch attributes emitted by Template Classes.

  Core owns the generic `Ezagent.Kind.Template` provisioning wrapper, but the
  agent flavor attribute store is a domain-agent concern. Downstream modules
  register here at boot; with no registered implementation, calls are no-ops.
  """

  @hooks_key {__MODULE__, :hooks}

  @callback store_flavor_attrs(agent_uri :: URI.t(), class_module :: module()) ::
              :ok | {:error, term()}
  @callback delete_flavor_attrs(agent_uri :: URI.t()) :: :ok | {:error, term()}

  @doc "Register a downstream Template flavor hook implementation."
  @spec register(module()) :: :ok
  def register(module) when is_atom(module) do
    hooks = hooks()
    :persistent_term.put(@hooks_key, Enum.uniq([module | hooks]))
    :ok
  end

  @doc false
  @spec store(URI.t(), module()) :: :ok | {:error, term()}
  def store(%URI{} = agent_uri, class_module) when is_atom(class_module) do
    invoke_hooks(:store_flavor_attrs, [agent_uri, class_module])
  end

  @doc false
  @spec delete(URI.t()) :: :ok | {:error, term()}
  def delete(%URI{} = agent_uri) do
    invoke_hooks(:delete_flavor_attrs, [agent_uri])
  end

  defp invoke_hooks(function, args) do
    Enum.reduce_while(hooks(), :ok, fn module, :ok ->
      case invoke(module, function, args) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
        other -> {:halt, {:error, {:invalid_flavor_hook_return, module, function, other}}}
      end
    end)
  end

  defp invoke(module, function, args) do
    arity = length(args)

    if Code.ensure_loaded?(module) and function_exported?(module, function, arity) do
      apply(module, function, args)
    else
      :ok
    end
  end

  defp hooks do
    :persistent_term.get(@hooks_key, [])
  end
end
