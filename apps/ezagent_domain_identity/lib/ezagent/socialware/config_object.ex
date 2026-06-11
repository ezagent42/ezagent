defmodule Ezagent.Socialware.ConfigObject do
  @moduledoc """
  Immutable socialware config object.

  Objects are append-only. Rollback and update semantics are represented by
  repointing `Ezagent.Socialware.ConfigPointer`, never by mutating this row.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "socialware_config_objects" do
    field(:workspace_uri, :string)
    field(:subject_uri, :string)
    field(:key, :string)
    field(:body, :map)
    field(:created_by, :string)
    field(:source_turn_id, :string)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:id, :workspace_uri, :subject_uri, :key, :body, :created_by, :source_turn_id])
    |> validate_required([
      :id,
      :workspace_uri,
      :subject_uri,
      :key,
      :body,
      :created_by,
      :source_turn_id
    ])
  end
end
