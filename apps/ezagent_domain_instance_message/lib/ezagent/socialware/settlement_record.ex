defmodule Ezagent.Socialware.SettlementRecord do
  @moduledoc """
  The durable settlement record for one socialware turn (`turn_id` PK); `status`
  moves `:pending` -> `:committed`.

  Production commit is `Ezagent.Socialware.Settlement.commit_after_pointer/2`.
  Via `confirm_pointer_advanced/2` it requires `target_surface_version` to equal
  the session's current approved surface version (`pointer_matches?/2`); on
  mismatch it returns `{:error, :target_version_mismatch}` and does not commit
  (it does NOT write `conflict_reason` — that field is only set by
  `record_conflict/2`, called solely from `mark_pointer_advanced/2`, which has no
  `lib` caller and is not on the production path; `expected_prior_approved` is
  likewise only read there). `subwrites_done` records the three commit sub-steps
  applied so far (visibility-flip, pointer-advance, outbox-emit) for idempotent
  retry; `committed_ready?/1` requires all three before the status flips.
  `Ezagent.Socialware.CustomerOutbox` mirrors only `target_surface_version` (as
  its `surface_version`); the `committed_seq` delivery cursor is assigned and
  owned by CustomerOutbox itself at the commit boundary (`assign_committed_seq/1`,
  max-per-session + 1) — this table has no `committed_seq`.
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
