defmodule Ezagent.Plugin.FlavorPublishHook do
  @moduledoc """
  Registered hook for publishing `agent_flavors/0` declarations.

  Core owns the plugin contract and validates declarations, but the flavor
  registry is a domain-agent concern. Downstream modules register here at boot;
  with no registered implementation, calls are no-ops.
  """

  @hooks_key {__MODULE__, :hooks}

  @callback publish_agent_flavor(Ezagent.Plugin.agent_flavor_decl()) :: :ok | {:error, term()}
  @callback after_plugin_publish(module()) :: :ok | {:error, term()}

  @optional_callbacks after_plugin_publish: 1

  @doc "Register a downstream agent-flavor publish hook implementation."
  @spec register(module()) :: :ok
  def register(module) when is_atom(module) do
    hooks = hooks()
    :persistent_term.put(@hooks_key, Enum.uniq([module | hooks]))
    :ok
  end

  @doc false
  @spec publish_agent_flavor(Ezagent.Plugin.agent_flavor_decl()) :: :ok | {:error, term()}
  def publish_agent_flavor(decl) when is_map(decl) do
    invoke_hooks(:publish_agent_flavor, [decl])
  end

  @doc false
  @spec after_plugin_publish(module()) :: :ok | {:error, term()}
  def after_plugin_publish(plugin_module) when is_atom(plugin_module) do
    invoke_hooks(:after_plugin_publish, [plugin_module])
  end

  defp invoke_hooks(function, args) do
    Enum.reduce_while(hooks(), :ok, fn module, :ok ->
      case invoke(module, function, args) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
        other -> {:halt, {:error, {:invalid_flavor_publish_hook_return, module, function, other}}}
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
