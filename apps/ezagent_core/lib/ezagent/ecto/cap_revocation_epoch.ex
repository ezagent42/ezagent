defmodule Ezagent.Ecto.CapRevocationEpoch do
  @moduledoc """
  Durable singleton that records activation of the per-cap revocation protocol.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "cap_revocation_epoch" do
    field :activated_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
