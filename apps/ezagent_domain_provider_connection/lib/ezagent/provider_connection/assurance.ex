defmodule Ezagent.ProviderConnection.Assurance do
  @moduledoc "Closed provider-neutral evidence for destructive connection commands."

  @enforce_keys [
    :owner_uri,
    :workspace_uri,
    :grantee_uri,
    :connection_id,
    :connection_version,
    :attempt_ref,
    :attempt_version,
    :status,
    :issued_at,
    :expires_at,
    :key_id,
    :signature
  ]
  defstruct @enforce_keys

  @type status :: :valid
  @type t :: %__MODULE__{
          owner_uri: URI.t(),
          workspace_uri: URI.t(),
          grantee_uri: URI.t(),
          connection_id: String.t(),
          connection_version: non_neg_integer(),
          attempt_ref: String.t(),
          attempt_version: non_neg_integer(),
          status: status(),
          issued_at: DateTime.t(),
          expires_at: DateTime.t(),
          key_id: String.t(),
          signature: binary()
        }

  @keys MapSet.new(@enforce_keys)
  @struct_keys MapSet.put(@keys, :__struct__)

  @doc "Constructs assurance evidence only when its closed shape and values are valid."
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_assurance_shape | :invalid_assurance}
  def new(attrs) when is_map(attrs) do
    if MapSet.new(Map.keys(attrs)) == @keys do
      build(attrs)
    else
      {:error, :invalid_assurance_shape}
    end
  end

  def new(_attrs), do: {:error, :invalid_assurance_shape}

  @doc "Revalidates a struct at the trust boundary so struct updates cannot bypass construction."
  @spec validate(t()) :: :ok | {:error, :invalid_assurance}
  def validate(%{__struct__: __MODULE__} = assurance) do
    if MapSet.new(Map.keys(assurance)) != @struct_keys do
      {:error, :invalid_assurance}
    else
      validate_exact(assurance)
    end
  end

  def validate(_assurance), do: {:error, :invalid_assurance}

  defp validate_exact(assurance) do
    case assurance |> Map.from_struct() |> build() do
      {:ok, ^assurance} -> :ok
      _ -> {:error, :invalid_assurance}
    end
  end

  defp build(
         %{
           owner_uri: %URI{} = owner,
           workspace_uri: %URI{} = workspace,
           grantee_uri: %URI{} = grantee,
           connection_id: connection_id,
           connection_version: connection_version,
           attempt_ref: attempt_ref,
           attempt_version: attempt_version,
           status: :valid,
           issued_at: %DateTime{} = issued_at,
           expires_at: %DateTime{} = expires_at,
           key_id: key_id,
           signature: signature
         } = attrs
       )
       when is_binary(connection_id) and byte_size(connection_id) > 0 and
              is_integer(connection_version) and connection_version >= 0 and
              is_binary(attempt_ref) and byte_size(attempt_ref) > 0 and
              is_integer(attempt_version) and attempt_version >= 0 and is_binary(key_id) and
              byte_size(key_id) > 0 and is_binary(signature) and byte_size(signature) > 0 do
    if DateTime.compare(issued_at, expires_at) == :lt do
      {:ok,
       struct!(__MODULE__, %{
         attrs
         | owner_uri: owner,
           workspace_uri: workspace,
           grantee_uri: grantee
       })}
    else
      {:error, :invalid_assurance}
    end
  end

  defp build(_attrs), do: {:error, :invalid_assurance}
end
