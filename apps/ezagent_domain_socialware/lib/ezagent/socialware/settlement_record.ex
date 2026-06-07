defmodule Ezagent.Socialware.SettlementRecord do
  use Ecto.Schema

  @primary_key {:turn_id, :string, []}

  schema "socialware_settlements" do
    field(:session_uri, :string)
    field(:workspace_uri, :string)
    field(:target_surface_version, :integer)
    field(:expected_prior_approved, :integer)
    field(:subwrites_done, {:array, :string}, default: [])

    field(:status, Ecto.Enum,
      values: [:pending, :committed],
      default: :pending
    )

    field(:committed_at, :utc_datetime_usec)
    field(:conflict_reason, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
