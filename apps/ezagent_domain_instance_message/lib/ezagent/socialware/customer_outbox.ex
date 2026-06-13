defmodule Ezagent.Socialware.CustomerOutbox do
  @moduledoc """
  Durable per-turn delivery rows for socialware customer-facing output.

  One row per settled turn (`turn_id` PK) holds the `message_ids` to deliver plus,
  since P2.5b, the COMMIT-ORDER metadata that makes a delivery committed-visible:
  `committed_seq` (a per-session monotonic cursor, NULL until the settlement
  commits — `committed_seq != nil` IS the commit-visible flag) and
  `surface_version` (the committed page version this delivery carries). Both are
  denormalized here from `Ezagent.Socialware.SettlementRecord` so a delivery
  reader never has to join back to the settlement.
  """
  use Ecto.Schema

  @primary_key {:turn_id, :string, []}

  schema "socialware_customer_outbox" do
    field(:session_uri, :string)
    field(:workspace_uri, :string)
    field(:message_ids, {:array, :string}, default: [])
    # P2.5b — the committed page version this delivery carries (nil = messages
    # only). Mirrors SettlementRecord.target_surface_version, denormalized onto
    # the durable delivery row; read back only when committed_seq is set.
    field(:surface_version, :integer)
    # P2.5b — per-session monotonic COMMIT-ORDER cursor. NULL until the settlement
    # commits (assigned at the commit boundary in commit_after_pointer).
    # committed_seq != nil <=> the delivery is committed-visible.
    field(:committed_seq, :integer)
    field(:emitted_at, :utc_datetime_usec)
  end
end
