defmodule Ezagent.ProviderConnection.Assurance do
  @moduledoc """
  Closed provider-neutral trusted-session proof for assurance-gated commands.

  The proof coordinate belongs to the trusted-session verifier. It is not a
  provider authorization attempt and is intentionally not persisted here.
  """

  @derive {Inspect, except: [:reauth_ref, :signature]}

  @enforce_keys [
    :action,
    :owner_uri,
    :workspace_uri,
    :grantee_uri,
    :connection_id,
    :connection_version,
    :reauth_ref,
    :reauth_version,
    :status,
    :issued_at,
    :expires_at,
    :key_id,
    :signature
  ]
  defstruct @enforce_keys

  @type action :: :reauthorize | :revoke | :disconnect
  @type status :: :valid
  @type t :: %__MODULE__{
          action: action(),
          owner_uri: URI.t(),
          workspace_uri: URI.t(),
          grantee_uri: URI.t(),
          connection_id: String.t(),
          connection_version: non_neg_integer(),
          reauth_ref: String.t(),
          reauth_version: non_neg_integer(),
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

  @doc false
  @spec validate_time(t(), DateTime.t()) :: :ok | {:error, :invalid_assurance_time}
  def validate_time(%__MODULE__{} = assurance, %DateTime{} = now) do
    with {:ok, issued_at} <- canonical_utc(assurance.issued_at),
         {:ok, expires_at} <- canonical_utc(assurance.expires_at),
         {:ok, canonical_now} <- canonical_utc(now),
         {:ok, issued_order} <- safe_compare(issued_at, canonical_now),
         true <- issued_order in [:lt, :eq],
         {:ok, :gt} <- safe_compare(expires_at, canonical_now) do
      :ok
    else
      _ -> {:error, :invalid_assurance_time}
    end
  end

  def validate_time(_assurance, _now), do: {:error, :invalid_assurance_time}

  defp validate_exact(assurance) do
    case assurance |> Map.from_struct() |> build() do
      {:ok, ^assurance} -> :ok
      _ -> {:error, :invalid_assurance}
    end
  end

  defp build(
         %{
           action: action,
           owner_uri: %URI{} = owner,
           workspace_uri: %URI{} = workspace,
           grantee_uri: %URI{} = grantee,
           connection_id: connection_id,
           connection_version: connection_version,
           reauth_ref: reauth_ref,
           reauth_version: reauth_version,
           status: :valid,
           issued_at: %DateTime{} = issued_at,
           expires_at: %DateTime{} = expires_at,
           key_id: key_id,
           signature: signature
         } = attrs
       )
       when action in [:reauthorize, :revoke, :disconnect] and is_binary(connection_id) and
              byte_size(connection_id) > 0 and
              is_integer(connection_version) and connection_version >= 0 and
              is_binary(reauth_ref) and byte_size(reauth_ref) > 0 and
              is_integer(reauth_version) and reauth_version >= 0 and is_binary(key_id) and
              byte_size(key_id) > 0 and is_binary(signature) and byte_size(signature) > 0 do
    with true <- valid_uris?(owner, workspace, grantee),
         {:ok, canonical_issued_at} <- canonical_utc(issued_at),
         {:ok, canonical_expires_at} <- canonical_utc(expires_at),
         {:ok, :lt} <- safe_compare(canonical_issued_at, canonical_expires_at) do
      {:ok,
       struct!(__MODULE__, %{
         attrs
         | owner_uri: owner,
           workspace_uri: workspace,
           grantee_uri: grantee,
           issued_at: canonical_issued_at,
           expires_at: canonical_expires_at
       })}
    else
      _ -> {:error, :invalid_assurance}
    end
  end

  defp build(_attrs), do: {:error, :invalid_assurance}

  defp valid_uris?(owner, workspace, grantee) do
    with {:ok, canonical_owner} <- canonical_user(owner),
         {:ok, canonical_workspace} <- canonical_workspace(workspace),
         {:ok, _canonical_grantee} <- canonical_user(grantee) do
      canonical_workspace == Ezagent.Capability.workspace_of(canonical_owner)
    else
      _ -> false
    end
  end

  defp canonical_user(uri) do
    with {:ok, canonical} <- safe_round_trip(uri),
         true <- Ezagent.URI.scheme?(canonical, :entity),
         true <- Ezagent.URI.type?(canonical, :user),
         true <- Ezagent.URI.instance(canonical) == canonical do
      {:ok, canonical}
    else
      _ -> :error
    end
  end

  defp canonical_workspace(uri) do
    with {:ok, canonical} <- safe_round_trip(uri),
         true <- Ezagent.URI.scheme?(canonical, :workspace),
         true <- Ezagent.URI.instance(canonical) == canonical do
      {:ok, canonical}
    else
      _ -> :error
    end
  end

  defp safe_round_trip(%URI{} = uri) do
    try do
      with true <- Ezagent.URI.canonical?(uri),
           encoded when is_binary(encoded) <- URI.to_string(uri),
           {:ok, parsed} <- Ezagent.URI.parse(encoded),
           true <- parsed == uri do
        {:ok, parsed}
      else
        _ -> :error
      end
    rescue
      _error -> :error
    catch
      _kind, _reason -> :error
    end
  end

  defp safe_round_trip(_uri), do: :error

  defp canonical_utc(
         %DateTime{
           calendar: Calendar.ISO,
           time_zone: "Etc/UTC",
           zone_abbr: "UTC",
           utc_offset: 0,
           std_offset: 0,
           year: year,
           month: month,
           day: day,
           hour: hour,
           minute: minute,
           second: second,
           microsecond: microsecond
         } = datetime
       ) do
    with {:ok, _date} <- Date.new(year, month, day),
         {:ok, _time} <- Time.new(hour, minute, second, microsecond) do
      {:ok, datetime}
    else
      _ -> :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp canonical_utc(_datetime), do: :error

  defp safe_compare(left, right) do
    {:ok, DateTime.compare(left, right)}
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end
end
