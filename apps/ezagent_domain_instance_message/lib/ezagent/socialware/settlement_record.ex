defmodule Ezagent.Socialware.SettlementRecord do
  @moduledoc """
  The durable two-phase settlement record for one socialware turn (`turn_id` PK).

  Tracks a turn's commit from `:pending` to `:committed`: `target_surface_version`
  (the page version this turn produces) is checked against
  `expected_prior_approved` for optimistic concurrency — a mismatch records a
  `conflict_reason` instead of committing. `subwrites_done` accumulates the
  idempotency keys of side-writes already applied, so a retried commit is
  safe. The committed record is what `Ezagent.Socialware.CustomerOutbox`
  denormalizes its version/commit-seq from.
  """
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
