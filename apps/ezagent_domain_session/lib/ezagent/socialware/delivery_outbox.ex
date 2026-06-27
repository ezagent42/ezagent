defmodule Ezagent.Socialware.DeliveryOutbox do
  @moduledoc """
  Durable per-turn delivery rows for socialware external-facing output.

  One row per settled turn (`turn_id` PK) holds the `message_ids` to deliver plus,
  since P2.5b, the COMMIT-ORDER metadata that makes a delivery committed-visible
  (`committed_seq != nil` IS the commit-visible flag):

    * `committed_seq` — a per-session monotonic cursor, NULL until commit. It is
      assigned ON this row at the commit boundary as `max(committed_seq for the
      session) + 1` (see `Ezagent.Socialware.Settlement` `assign_committed_seq`);
      the outbox row is the SOURCE OF TRUTH for the cursor — `SettlementRecord`
      has no `committed_seq`.
    * `surface_version` — the committed page version this delivery carries,
      mirrored from `Ezagent.Socialware.SettlementRecord.target_surface_version`
      so a reader need not join back to the settlement.
  """
  use Ecto.Schema

  @primary_key {:turn_id, :string, []}

  schema "socialware_delivery_outbox" do
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
