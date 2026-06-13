defmodule Ezagent.Socialware.SettlementRecord do
  @moduledoc """
  The durable settlement record for one socialware turn (`turn_id` PK), driving
  its commit from `:pending` to `:committed`.

  The production commit path (`Ezagent.Socialware.Settlement.commit_after_pointer/2`,
  via `confirm_pointer_advanced/2`) gates ONLY on `target_surface_version`: it
  must equal the session's current approved surface version (`pointer_matches?/2`),
  else a `conflict_reason` is recorded instead of committing. `subwrites_done`
  accumulates the fixed three commit sub-steps (visibility-flip, pointer-advance,
  outbox-emit) already applied, so a retried commit skips done steps and is
  idempotent; `committed_ready?/1` flips to `:committed` only once all three are
  present. The committed record is what `Ezagent.Socialware.CustomerOutbox`
  denormalizes its version / commit-seq from.

  `expected_prior_approved` is a prior-version CAS field checked by
  `prior_matches?/2` — but ONLY via `mark_pointer_advanced/2`, which is not on the
  current production commit path (no `lib` caller); the field is stored for that
  guard, not enforced by `commit_after_pointer/2` today.
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
