defmodule Ezagent.Socialware.SettlementRecord do
  @moduledoc """
  The durable settlement record for one socialware turn (`turn_id` PK), driving
  its commit from `:pending` to `:committed`.

  Two independent checks gate the commit, each comparing a stored field against
  the session's CURRENT approved surface version (see `Ezagent.Socialware.Settlement`):
  `target_surface_version` must match it (`pointer_matches?` — the page this turn
  produces is the one being approved) and `expected_prior_approved` must match it
  (`prior_matches?` — optimistic concurrency: the world is still where this turn
  expected when it started). Either mismatch records a `conflict_reason` instead
  of committing. `subwrites_done` accumulates the fixed three commit sub-steps
  (visibility-flip, pointer-advance, outbox-emit) already applied, so a retried
  commit skips done steps and is idempotent; the turn is commit-ready only once
  all three are present. The committed record is what
  `Ezagent.Socialware.CustomerOutbox` denormalizes its version / commit-seq from.
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
