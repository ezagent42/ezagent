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
          op: :absorb_cap | :revoke_cap | nil,
          payload: binary() | nil,
          payload_identity: String.t() | nil,
          status: :pending | :applied,
          attempts: non_neg_integer(),
          next_retry_at: DateTime.t() | nil,
          last_error: String.t() | nil,
          applied_at: DateTime.t() | nil
        }

  schema "cap_delivery_outbox" do
    field :workspace_uri, :string
    field :target_uri, :string
    field :op, Ecto.Enum, values: [:absorb_cap, :revoke_cap]
    field :payload, :binary
    field :payload_identity, :string
    field :status, Ecto.Enum, values: [:pending, :applied], default: :pending
    field :attempts, :integer, default: 0
    field :next_retry_at, :utc_datetime_usec
    field :last_error, :string
    field :applied_at, :utc_datetime_usec

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
      :payload_identity,
      :status,
      :attempts,
      :next_retry_at,
      :last_error,
      :applied_at
    ])
    |> validate_required([
      :workspace_uri,
      :target_uri,
      :op,
      :payload,
      :payload_identity,
      :status,
      :attempts,
      :next_retry_at
    ])
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
  end
end
