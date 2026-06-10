defmodule Ezagent.UriQuery do
  @moduledoc """
  Attribute query dispatcher for opaque Ezagent URIs.

  `Ezagent.URI` owns URI construction and structural accessors. `UriQuery`
  owns non-structural attribute lookup: domains/plugins register resolver
  functions for attributes they own, and callers resolve through this single
  dispatcher instead of parsing secondary facts out of URI strings.

  Unregistered resolver is fail-loud and distinct from missing data:

    * `{:error, {:no_resolver, attr}}` means the owning domain/plugin has not
      registered the resolver yet, or the system is miswired.
    * `:none` means the resolver ran and found no value.
  """

  @table :ezagent_uri_query_registry

  @typedoc "Attribute key resolved by a registered owner."
  @type attr :: atom()

  @typedoc "Resolver function result."
  @type result :: {:ok, term()} | :none | {:error, term()}

  @type resolver :: (term() -> result())

  @doc "Return the ETS table name (used by `EzagentCore.EtsOwner`)."
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Idempotently ensure the table exists.

  Normal boot creates the table through `EzagentCore.EtsOwner`; this helper is
  for narrowly-scoped tooling/tests that touch the module before the owner is
  running.
  """
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Register the resolver for an attribute.

  There is one owner per attr. Duplicate registration fails loudly instead of
  silently replacing a resolver from another domain/plugin.
  """
  @spec register(attr(), resolver()) :: :ok | {:error, {:already_registered, attr()}}
  def register(attr, resolver) when is_atom(attr) and is_function(resolver, 1) do
    init()

    if :ets.insert_new(@table, {attr, resolver}) do
      :ok
    else
      {:error, {:already_registered, attr}}
    end
  end

  @doc """
  Resolve `attr` for `arg` via the registered resolver.
  """
  @spec resolve(attr(), term()) :: result() | {:error, {:no_resolver, attr()}}
  def resolve(attr, arg) when is_atom(attr) do
    init()

    case :ets.lookup(@table, attr) do
      [{^attr, resolver}] ->
        resolver
        |> apply_resolver(arg)
        |> normalize_result()

      [] ->
        {:error, {:no_resolver, attr}}
    end
  end

  defp apply_resolver(resolver, arg), do: resolver.(arg)

  defp normalize_result({:ok, _value} = result), do: result
  defp normalize_result(:none), do: :none
  defp normalize_result({:error, _reason} = result), do: result
  defp normalize_result(other), do: {:error, {:invalid_resolver_return, other}}
end
