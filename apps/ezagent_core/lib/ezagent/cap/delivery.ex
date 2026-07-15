defmodule Ezagent.Cap.Delivery do
  @moduledoc """
  Durable delivery row for issued capability self-storage and revocation.

  The serialized payload is the original `%Ezagent.Invocation{}`. Rows remain
  `:pending` until the target Kind finishes its handler and commits the updated
  slice; a producer-side cast acknowledgement never marks a row applied.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          workspace_uri: String.t() | nil,
          target_uri: String.t() | nil,
          op: :absorb_cap | :revoke_cap | :heal_cap | nil,
          payload: binary() | nil,
          payload_version: pos_integer(),
          payload_identity: String.t() | nil,
          idempotency_key: String.t() | nil,
          status: :pending | :applied | :dead,
          attempts: non_neg_integer(),
          next_retry_at: DateTime.t() | nil,
          claim_token: String.t() | nil,
          lease_until: DateTime.t() | nil,
          last_error: String.t() | nil,
          applied_at: DateTime.t() | nil,
          dead_at: DateTime.t() | nil
        }

  schema "cap_delivery_outbox" do
    field :workspace_uri, :string
    field :target_uri, :string
    field :op, Ecto.Enum, values: [:absorb_cap, :revoke_cap, :heal_cap]
    field :payload, :binary
    field :payload_version, :integer, default: 1
    field :payload_identity, :string
    field :idempotency_key, :string
    field :status, Ecto.Enum, values: [:pending, :applied, :dead], default: :pending
    field :attempts, :integer, default: 0
    field :next_retry_at, :utc_datetime_usec
    field :claim_token, :string
    field :lease_until, :utc_datetime_usec
    field :last_error, :string
    field :applied_at, :utc_datetime_usec
    field :dead_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :workspace_uri,
      :target_uri,
      :op,
      :payload,
      :payload_version,
      :payload_identity,
      :idempotency_key,
      :status,
      :attempts,
      :next_retry_at,
      :claim_token,
      :lease_until,
      :last_error,
      :applied_at,
      :dead_at
    ])
    |> validate_required([
      :workspace_uri,
      :target_uri,
      :op,
      :payload,
      :payload_version,
      :payload_identity,
      :status,
      :attempts,
      :next_retry_at
    ])
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> validate_number(:payload_version, greater_than: 0)
    |> validate_length(:idempotency_key, max: 255)
  end
end
