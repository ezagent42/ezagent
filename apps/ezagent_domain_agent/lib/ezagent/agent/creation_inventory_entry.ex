defmodule Ezagent.Agent.CreationInventoryEntry do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "agent_creation_inventory" do
    field(:creation_attempt_id, :string)
    field(:agent_uri, :string)
    field(:provenance_root_uri, :string)
    field(:workspace_uri, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:creation_attempt_id, :agent_uri, :provenance_root_uri, :workspace_uri])
    |> validate_required([:creation_attempt_id, :agent_uri, :provenance_root_uri, :workspace_uri])
    |> unique_constraint([:creation_attempt_id, :agent_uri],
      name: :agent_creation_inventory_attempt_agent_index
    )
  end
end
