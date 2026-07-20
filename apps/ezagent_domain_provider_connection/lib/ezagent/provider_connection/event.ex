defmodule Ezagent.ProviderConnection.Event do
  @moduledoc "Append-only secret-safe provider connection audit event."
  @derive {Inspect,
           only: [
             :id,
             :workspace_uri,
             :connection_id,
             :actor_role,
             :transition_from,
             :transition_to,
             :connection_version,
             :result_class,
             :inserted_at
           ]}
  use Ecto.Schema
  import Ecto.Changeset
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

  @trusted ~w(workspace_uri connection_id actor_role transition_from transition_to connection_version correlation_id result_class provider_request_id)a

  @doc false
  def create_changeset(attrs) do
    %__MODULE__{}
    |> change(Map.take(attrs, @trusted))
    |> validate_required([:workspace_uri, :connection_id])
    |> check_constraint(:transition_from,
      name: :provider_connection_events_transition_from_check
    )
    |> check_constraint(:transition_to,
      name: :provider_connection_events_transition_to_check
    )
    |> foreign_key_constraint(:connection_id,
      name: :provider_connection_events_connection_workspace_fkey
    )
  end
end
