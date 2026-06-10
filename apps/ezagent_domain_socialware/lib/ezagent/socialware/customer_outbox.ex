defmodule Ezagent.Socialware.CustomerOutbox do
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
