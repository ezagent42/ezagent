defmodule Ezagent.ProviderConnection.Driver do
  @moduledoc """
  Provider-owned connection-flow contract and immutable driver declaration.

  Drivers own provider protocol semantics. Their declarations contain only
  stable, non-secret data and are indexed by the exact
  `{provider_id, acquisition_method}` pair.
  """

  @enforce_keys [
    :provider_id,
    :acquisition_method,
    :provider_fingerprint,
    :implementation,
    :backend_pair_ids,
    :metadata,
    :fingerprint
  ]
  defstruct @enforce_keys

  @type context :: map()
  @type result :: {:ok, map()} | {:error, atom()}
  @type t :: %__MODULE__{
          provider_id: String.t(),
          acquisition_method: String.t(),
          provider_fingerprint: String.t(),
          implementation: module(),
          backend_pair_ids: [String.t()],
          metadata: map(),
          fingerprint: String.t()
        }

  @callback begin_authorization(context()) :: result()
  @callback consume_callback(context()) :: result()
  @callback refresh(context()) :: result()
  @callback revoke(context()) :: result()

  @callbacks [
    begin_authorization: 1,
    consume_callback: 1,
    refresh: 1,
    revoke: 1
  ]

  @doc "Builds a closed, immutable, non-secret driver declaration."
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    declaration = %{
      provider_id: fetch_string!(attrs, :provider_id),
      acquisition_method: fetch_string!(attrs, :acquisition_method),
      provider_fingerprint: fetch_string!(attrs, :provider_fingerprint),
      implementation: Map.fetch!(attrs, :implementation),
      backend_pair_ids: normalize_pair_ids!(Map.fetch!(attrs, :backend_pair_ids)),
      metadata: Map.fetch!(attrs, :metadata)
    }

    validate_implementation!(declaration.implementation)
    validate_safe_metadata!(declaration.metadata)
    struct!(__MODULE__, Map.put(declaration, :fingerprint, derive_fingerprint(declaration)))
  end

  @doc false
  @spec verify_fingerprint(t()) :: :ok | {:error, {:declaration_drift, String.t(), String.t()}}
  def verify_fingerprint(%__MODULE__{} = driver) do
    expected =
      driver
      |> Map.from_struct()
      |> Map.delete(:fingerprint)
      |> derive_fingerprint()

    if driver.fingerprint == expected do
      :ok
    else
      {:error, {:declaration_drift, driver.fingerprint, expected}}
    end
  end

  defp fetch_string!(attrs, key) do
    case Map.fetch!(attrs, key) do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _value -> raise ArgumentError, "#{key} must be a non-empty string"
    end
  end

  defp normalize_pair_ids!(ids) when is_list(ids) and ids != [] do
    ids = Enum.map(ids, &non_empty_string!/1)

    if length(ids) == MapSet.size(MapSet.new(ids)) do
      Enum.sort(ids)
    else
      raise ArgumentError, "backend_pair_ids must be unique"
    end
  end

  defp normalize_pair_ids!(_ids),
    do: raise(ArgumentError, "backend_pair_ids must be a non-empty list")

  defp non_empty_string!(value) when is_binary(value) and byte_size(value) > 0, do: value
  defp non_empty_string!(_value), do: raise(ArgumentError, "backend id must be a string")

  defp validate_implementation!(implementation) when is_atom(implementation) do
    with {:module, _module} <- Code.ensure_loaded(implementation),
         true <-
           Enum.all?(@callbacks, fn {name, arity} ->
             function_exported?(implementation, name, arity)
           end) do
      :ok
    else
      _ -> raise ArgumentError, "driver implementation does not implement the exact contract"
    end
  end

  defp validate_implementation!(_implementation),
    do: raise(ArgumentError, "driver implementation must be a module")

  defp validate_safe_metadata!(metadata) when is_map(metadata) do
    if safe_term?(metadata),
      do: :ok,
      else: raise(ArgumentError, "driver metadata must be non-secret data")
  end

  defp validate_safe_metadata!(_metadata),
    do: raise(ArgumentError, "driver metadata must be a map")

  defp safe_term?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp safe_term?(value) when is_atom(value), do: true
  defp safe_term?(value) when is_list(value), do: Enum.all?(value, &safe_term?/1)

  defp safe_term?(value) when is_map(value) do
    Enum.all?(value, fn {key, item} -> safe_term?(key) and safe_term?(item) end)
  end

  defp safe_term?(_value), do: false

  defp derive_fingerprint(declaration) do
    declaration
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
