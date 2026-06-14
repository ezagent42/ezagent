defmodule Ezagent.Socialware.SettlementMessage do
  @moduledoc """
  Join rows linking a socialware settlement turn to the messages it settles.

  Each row maps one `turn_id` to one `message_id` (scoped by `workspace_uri`),
  recording which messages a given settlement covers — the many-side of
  `Ezagent.Socialware.SettlementRecord` (one settlement, many messages). No
  primary key: a settlement's message set is the collection of its rows.
  """
  use Ecto.Schema

  @primary_key false

  schema "socialware_settlement_messages" do
    field(:turn_id, :string)
    field(:message_id, :string)
    field(:workspace_uri, :string)
  end
end
