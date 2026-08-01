defmodule Ezagent.Cap.GrantArtifact do
  @moduledoc """
  Canonical validation boundary for issued capability artifacts.

  Capability requests and declarations may be unsigned and may omit a grant
  identity. Once issued, an artifact must carry the complete signed shape
  validated here before it can be held, persisted, restored, delivered, or
  authorized.
  """

  alias Ezagent.Capability

  @type validation_error ::
          :not_capability
          | :missing_grant_id
          | :invalid_grant_id
          | :missing_signature
          | :missing_key_id
          | :missing_grantee_uri
          | :invalid_term
          | {:invalid_field, atom()}
          | {:invalid_uri, atom()}

  @doc "Decode and validate an issued artifact from its JSON-safe map."
  @spec from_map(map()) :: {:ok, Capability.t()} | {:error, validation_error()}
  def from_map(map) when is_map(map) do
    map
    |> Capability.from_map()
    |> validate()
  rescue
    _ -> {:error, :not_capability}
  end

  @doc "Safely decode and validate one Erlang-term encoded issued artifact."
  @spec from_term(binary()) :: {:ok, Capability.t()} | {:error, validation_error()}
  def from_term(binary) when is_binary(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      %Capability{} = capability -> validate(capability)
      _other -> {:error, :invalid_term}
    end
  rescue
    _ -> {:error, :invalid_term}
  end

  def from_term(_other), do: {:error, :invalid_term}

  @doc "Validate the complete, canonical shape of one issued artifact."
  @spec validate(Capability.t()) :: {:ok, Capability.t()} | {:error, validation_error()}
  def validate(%Capability{} = capability) do
    with :ok <- validate_grant_id(capability.grant_id),
         :ok <- validate_present_binary(capability.signature, :signature, :missing_signature),
         :ok <- validate_present_binary(capability.key_id, :key_id, :missing_key_id),
         :ok <- validate_grantee(capability.grantee_uri),
         :ok <- validate_atom(capability.kind, :kind),
         :ok <- validate_atom(capability.behavior, :behavior),
         :ok <- validate_atom(capability.action, :action),
         :ok <- validate_instance(capability.instance),
         :ok <- validate_workspace(capability.workspace_uri),
         :ok <- validate_uri_field(capability.granted_by, :granted_by),
         :ok <- validate_datetime(capability.granted_at) do
      {:ok, capability}
    end
  end

  def validate(_other), do: {:error, :not_capability}

  @doc "Return true only for the canonical lowercase hyphenated UUID text."
  @spec valid_grant_id?(term()) :: boolean()
  def valid_grant_id?(grant_id) when is_binary(grant_id) do
    Ecto.UUID.cast(grant_id) == {:ok, grant_id}
  end

  def valid_grant_id?(_grant_id), do: false

  @doc "Validate an artifact set atomically, retaining carrier and index context."
  @spec validate_set(Enumerable.t(), term()) ::
          {:ok, MapSet.t(Capability.t())}
          | {:error, {:invalid_grant_artifact, term(), non_neg_integer(), validation_error()}}
  def validate_set(artifacts, carrier) do
    if Enumerable.impl_for(artifacts) do
      artifacts
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, MapSet.new()}, fn {artifact, index}, {:ok, validated} ->
        case validate(artifact) do
          {:ok, capability} ->
            {:cont, {:ok, MapSet.put(validated, capability)}}

          {:error, reason} ->
            {:halt, {:error, {:invalid_grant_artifact, carrier, index, reason}}}
        end
      end)
    else
      {:error, {:invalid_grant_artifact, carrier, 0, :not_capability}}
    end
  end

  defp validate_grant_id(nil), do: {:error, :missing_grant_id}
  defp validate_grant_id(""), do: {:error, :missing_grant_id}

  defp validate_grant_id(grant_id) do
    if valid_grant_id?(grant_id), do: :ok, else: {:error, :invalid_grant_id}
  end

  defp validate_present_binary(nil, _field, missing), do: {:error, missing}
  defp validate_present_binary("", _field, missing), do: {:error, missing}
  defp validate_present_binary(value, _field, _missing) when is_binary(value), do: :ok

  defp validate_present_binary(_value, field, _missing),
    do: {:error, {:invalid_field, field}}

  defp validate_grantee(nil), do: {:error, :missing_grantee_uri}
  defp validate_grantee(value), do: validate_uri_field(value, :grantee_uri)

  defp validate_atom(value, _field) when is_atom(value), do: :ok
  defp validate_atom(_value, field), do: {:error, {:invalid_field, field}}

  defp validate_datetime(%DateTime{}), do: :ok
  defp validate_datetime(_value), do: {:error, {:invalid_field, :granted_at}}

  defp validate_instance(:any), do: :ok
  defp validate_instance(%URI{} = uri), do: validate_uri_field(uri, :instance)

  defp validate_instance({scope, %URI{} = uri})
       when scope in [:within_session, :within_workspace, :spawned_by],
       do: validate_uri_field(uri, :instance)

  defp validate_instance(_value), do: {:error, {:invalid_field, :instance}}

  defp validate_workspace(:any), do: :ok
  defp validate_workspace(%URI{} = uri), do: validate_uri_field(uri, :workspace_uri)
  defp validate_workspace(_value), do: {:error, {:invalid_field, :workspace_uri}}

  defp validate_uri_field(%URI{} = uri, field) do
    if valid_uri?(uri), do: :ok, else: {:error, {:invalid_uri, field}}
  end

  defp validate_uri_field(_value, field), do: {:error, {:invalid_field, field}}

  defp valid_uri?(%URI{} = uri) do
    canonical = uri |> URI.to_string() |> Ezagent.URI.new!()
    Ezagent.URI.stable_key(canonical) == Ezagent.URI.stable_key(uri)
  rescue
    _ -> false
  end
end
