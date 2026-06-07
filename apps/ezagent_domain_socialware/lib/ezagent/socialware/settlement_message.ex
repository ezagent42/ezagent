defmodule Ezagent.Socialware.SettlementMessage do
  use Ecto.Schema

  @primary_key false

  schema "socialware_settlement_messages" do
    field(:turn_id, :string)
    field(:message_id, :string)
    field(:workspace_uri, :string)
  end
end
