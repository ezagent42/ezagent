defmodule Ezagent.ProviderConnection.Driver do
  @moduledoc """
  Provider-owned connection-flow contract and immutable driver declaration.

  Drivers own provider protocol semantics. Their declarations contain only
  stable, non-secret data and are indexed by the exact
  `{provider_id, acquisition_method}` pair.

  Begin and consume callbacks receive a stable correlation id and private
  exchange frame so a driver can reconcile retries with provider-side state.
  A committed effect whose response was lost must return the same result on an
  exact retry. If the provider outcome is ambiguous before the local journal
  commits, the driver must fail closed and restart authorization unless the
  provider exposes an authoritative reconciliation mechanism.
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
  @type error ::
          :backend_unavailable
          | :provider_denied
          | :provider_protocol_failed
          | :correlation_conflict
  @type result :: {:ok, map()} | {:error, error()}
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
  @callback reconcile_callback(context()) :: result() | {:ok, :not_completed}
  @callback refresh(context()) :: result()
  @callback reconcile_refresh(context()) :: result() | {:ok, :not_completed}
  @callback discard_callback_result(context()) :: :ok | {:error, error()}
  @callback discard_refresh_result(context()) :: :ok | {:error, error()}
  @callback revoke(context()) :: result()

  @callbacks [
    begin_authorization: 1,
    consume_callback: 1,
    reconcile_callback: 1,
    refresh: 1,
    reconcile_refresh: 1,
    discard_callback_result: 1,
    discard_refresh_result: 1,
    revoke: 1
  ]

  @callback_discard_keys MapSet.new(
                           ~w(owner_uri workspace_uri provider_id acquisition_method governed_host backend_pair_id operation_id connection_id expected_connection_version attempt_ref authorization_ref expected_authorization_version correlation_id command_digest expected_credential_version provider_result_ref discard_idempotency_key)a
                         )
  @refresh_discard_keys MapSet.delete(@callback_discard_keys, :attempt_ref)

  @doc false
  def validate_discard_context(kind, context)
      when kind in [:callback, :refresh] and is_map(context) do
    expected = if kind == :callback, do: @callback_discard_keys, else: @refresh_discard_keys

    with true <- MapSet.new(Map.keys(context)) == expected,
         true <- Enum.all?(expected, &valid_discard_value?(&1, Map.get(context, &1))) do
      :ok
    else
      _other -> {:error, :correlation_conflict}
    end
  end

  def validate_discard_context(_kind, _context), do: {:error, :correlation_conflict}

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
    validate_normalization_schemas!(declaration.metadata)
    struct!(__MODULE__, Map.put(declaration, :fingerprint, derive_fingerprint(declaration)))
  end

  @doc false
  def matches_schema?(value, %{type: :string}), do: is_binary(value)
  def matches_schema?(value, %{type: :integer}), do: is_integer(value)
  def matches_schema?(value, %{type: :boolean}), do: is_boolean(value)

  def matches_schema?(value, %{type: :map, fields: fields})
      when is_map(value) and is_map(fields) do
    with {:ok, normalized} <- canonical_map(value),
         true <- MapSet.new(Map.keys(normalized)) == MapSet.new(Map.keys(fields)) do
      Enum.all?(fields, fn {key, schema} -> matches_schema?(normalized[key], schema) end)
    else
      _error -> false
    end
  end

  def matches_schema?(_value, _schema), do: false

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

  defp valid_discard_value?(key, value)
       when key in [
              :expected_connection_version,
              :expected_authorization_version,
              :expected_credential_version
            ],
       do: is_integer(value) and value >= 0

  defp valid_discard_value?(_key, value), do: is_binary(value) and value != ""

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

  defp validate_normalization_schemas!(metadata) do
    with %{authorization_redirect_schema: redirect, provider_metadata_schema: provider} <-
           metadata,
         true <- valid_schema?(redirect),
         true <- valid_schema?(provider) do
      :ok
    else
      _other ->
        raise ArgumentError,
              "driver metadata must declare closed authorization redirect and provider metadata schemas"
    end
  end

  defp valid_schema?(%{type: type} = schema) when type in [:string, :integer, :boolean],
    do: map_size(schema) == 1

  defp valid_schema?(%{type: :map, fields: fields} = schema) when is_map(fields) do
    map_size(schema) == 2 and
      Enum.all?(fields, fn {key, child} ->
        is_binary(key) and key != "" and valid_schema?(child)
      end)
  end

  defp valid_schema?(_schema), do: false

  defp canonical_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn
      {key, item}, {:ok, normalized} when is_binary(key) or is_atom(key) ->
        canonical_key = to_string(key)

        if Map.has_key?(normalized, canonical_key) do
          {:halt, {:error, :canonical_key_collision}}
        else
          {:cont, {:ok, Map.put(normalized, canonical_key, item)}}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_map_key}}
    end)
  end

  defp safe_term?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp safe_term?(value) when is_atom(value), do: true
  defp safe_term?(value) when is_list(value), do: Enum.all?(value, &safe_term?/1)

  defp safe_term?(%_struct{}), do: false

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
