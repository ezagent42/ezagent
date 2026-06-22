defmodule Ezagent.ProtocolApi.ApiKeyStore do
  @moduledoc """
  Ecto schema + queries for `protocol_api_keys`.

  Token format: `pk_<key_id>_<secret>` — the `key_id` prefix enables
  indexed lookup without full-table bcrypt scan.
  """

  use Ecto.Schema

  alias EzagentCore.Repo

  @primary_key {:key_id, :string, autogenerate: false}
  schema "protocol_api_keys" do
    field :secret_hash, :string
    field :entity_uri, :string
    field :workspace_uri, :string
    field :label, :string
    field :allowed_models, {:array, :string}, default: []
    field :cap_policy, :map, default: %{}
    field :revoked_at, :utc_datetime
    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Verify a Bearer token against the API key store.

  Returns `{:ok, entity_uri, workspace_uri, caps}` on success,
  `{:error, reason}` on failure.
  """
  @spec verify(String.t()) ::
          {:ok, URI.t(), URI.t(), MapSet.t()}
          | {:error, :invalid_token | :revoked}
  def verify(token) when is_binary(token) do
    with {:ok, key_id, secret} <- parse_token(token),
         {:ok, row} <- lookup(key_id),
         :ok <- verify_secret(secret, row.secret_hash),
         :ok <- check_not_revoked(row) do
      entity_uri = Ezagent.URI.new!(row.entity_uri)
      workspace_uri = Ezagent.URI.new!(row.workspace_uri)
      caps = MapSet.new()
      {:ok, entity_uri, workspace_uri, caps}
    end
  end

  @doc """
  List active keys for an entity (for operator UI, P1).
  """
  def list_for_entity(entity_uri) when is_binary(entity_uri) do
    import Ecto.Query

    Repo.all(
      from k in __MODULE__,
        where: k.entity_uri == ^entity_uri and is_nil(k.revoked_at),
        select: [:key_id, :label, :allowed_models, :inserted_at]
    )
  end

  defp parse_token("pk_" <> rest) do
    # Split on LAST underscore: everything before is key_id, after is secret.
    # This allows key_ids to contain underscores (e.g. "ik_12345").
    case :binary.matches(rest, "_") do
      [] -> {:error, :invalid_token}
      matches ->
        {pos, 1} = List.last(matches)
        key_id = binary_part(rest, 0, pos)
        secret = binary_part(rest, pos + 1, byte_size(rest) - pos - 1)
        if key_id != "" and secret != "", do: {:ok, key_id, secret}, else: {:error, :invalid_token}
    end
  end

  defp parse_token(_), do: {:error, :invalid_token}

  defp lookup(key_id) do
    case Repo.get(__MODULE__, key_id) do
      nil -> {:error, :invalid_token}
      %__MODULE__{} = row -> {:ok, row}
    end
  end

  defp verify_secret(secret, hash) do
    if Bcrypt.verify_pass(secret, hash) do
      :ok
    else
      {:error, :invalid_token}
    end
  end

  defp check_not_revoked(%{revoked_at: nil}), do: :ok
  defp check_not_revoked(_), do: {:error, :revoked}
end
