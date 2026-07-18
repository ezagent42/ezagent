defmodule Ezagent.ProviderConnection.Event do
  @moduledoc "Append-only secret-safe provider connection audit event."
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "provider_connection_events" do
    field(:workspace_uri, :string)
    field(:connection_id, Ecto.UUID)
    field(:actor_role, :string)
    field(:transition_from, :string)
    field(:transition_to, :string)
    field(:connection_version, :integer)
    field(:correlation_id, :string)
    field(:result_class, :string)
    field(:provider_request_id, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
