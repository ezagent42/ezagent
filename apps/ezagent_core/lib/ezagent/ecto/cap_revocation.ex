defmodule Ezagent.Ecto.CapRevocation do
  @moduledoc """
  An absorbing durable marker for one signed capability grant.

  Markers are append-only and globally keyed by the framework-minted
  `grant_id`. `workspace_uri` is retained as the tenant boundary for every
  authorization and persistence query.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:grant_id, :string, autogenerate: false}
  schema "cap_revocations" do
    field :workspace_uri, :string
    field :holder_uri, :string
    field :cap_identity_key, :binary
    field :revoked_at, :utc_datetime_usec
    field :target_uri, :string
    field :key_id, :string

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          grant_id: String.t(),
          workspace_uri: String.t(),
          holder_uri: String.t() | nil,
          cap_identity_key: binary() | nil,
          revoked_at: DateTime.t(),
          target_uri: String.t() | nil,
          key_id: String.t() | nil
        }

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(revocation, attrs) do
    revocation
    |> cast(attrs, [
      :grant_id,
      :workspace_uri,
      :holder_uri,
      :cap_identity_key,
      :revoked_at,
      :target_uri,
      :key_id
    ])
    |> validate_required([:grant_id, :workspace_uri, :revoked_at])
    |> unique_constraint(:grant_id, name: :cap_revocations_pkey)
  end
end
