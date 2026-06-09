defmodule Ezagent.Socialware.CustomerOutbox do
  use Ecto.Schema

  @primary_key {:turn_id, :string, []}

  schema "socialware_customer_outbox" do
    field(:session_uri, :string)
    field(:workspace_uri, :string)
    field(:message_ids, {:array, :string}, default: [])
    field(:emitted_at, :utc_datetime_usec)
  end
end
