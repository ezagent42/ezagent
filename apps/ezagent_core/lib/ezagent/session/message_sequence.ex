defmodule Ezagent.Session.MessageSequence do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "session_message_sequences" do
    field :session_uri, Ezagent.Ecto.URI, primary_key: true
    field :workspace_uri, :string
    field :last_seq, :integer, default: 0
  end
end
