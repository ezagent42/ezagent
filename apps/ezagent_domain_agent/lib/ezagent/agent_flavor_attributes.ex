defmodule Ezagent.AgentFlavorAttributes do
  @moduledoc """
  Stored launch attributes for agent flavor lookup.

  Agent flavor is not part of the URI. Template classes write the stored
  flavor for an agent URI before first spawn so `Ezagent.UriQuery` can resolve
  the backing Kind module without parsing the URI name. Once the Kind is live,
  its persisted sandbox slice remains the durable restart source; this table is
  the first-spawn launch attribute bridge.
  """

  @table :ezagent_agent_flavor_attributes

  @doc "Return the ETS table name (used by `EzagentDomainAgent.EtsOwner`)."
  @spec table() :: atom()
  def table, do: @table

  @doc "Store the launch flavor for an agent URI."
  @spec put(URI.t(), String.t()) :: :ok
  def put(%URI{} = agent_uri, flavor) when is_binary(flavor) and flavor != "" do
    :ets.insert(@table, {Ezagent.URI.stable_key(agent_uri), flavor})
    :ok
  end

  @doc """
  Store launch flavor by looking up the registered template class.

  Use this in agent Template Classes. A missing class registration is a plugin
  wiring error and fails loudly.
  """
  @spec put_from_template_class(URI.t(), module()) :: :ok | {:error, term()}
  def put_from_template_class(%URI{} = agent_uri, template_class) when is_atom(template_class) do
    case flavor_for_template_class(template_class) do
      {:ok, flavor} -> put(agent_uri, flavor)
      :error -> {:error, {:unknown_agent_template_class, template_class}}
    end
  end

  @doc """
  Store launch flavor if `template_class` is a registered agent flavor class.

  Generic non-agent template classes intentionally no-op.
  """
  @spec maybe_put_from_template_class(URI.t(), module()) :: :ok
  def maybe_put_from_template_class(%URI{} = agent_uri, template_class)
      when is_atom(template_class) do
    case flavor_for_template_class(template_class) do
      {:ok, flavor} -> put(agent_uri, flavor)
      :error -> :ok
    end
  end

  @doc "Resolve the stored launch flavor for an agent URI."
  @spec get(URI.t()) :: {:ok, String.t()} | :none
  def get(%URI{} = agent_uri) do
    case :ets.lookup(@table, Ezagent.URI.stable_key(agent_uri)) do
      [{_key, flavor}] when is_binary(flavor) and flavor != "" -> {:ok, flavor}
      _ -> :none
    end
  end

  @doc "Delete any stored launch flavor for an agent URI."
  @spec delete(URI.t()) :: :ok
  def delete(%URI{} = agent_uri) do
    :ets.delete(@table, Ezagent.URI.stable_key(agent_uri))
    :ok
  end

  defp flavor_for_template_class(template_class) do
    Ezagent.AgentFlavorRegistry.list_all()
    |> Enum.find_value(fn
      {flavor, %{template_class: ^template_class}} -> {:ok, flavor}
      _ -> nil
    end)
    |> case do
      {:ok, _flavor} = ok -> ok
      nil -> :error
    end
  end
end
