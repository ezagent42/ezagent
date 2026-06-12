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
    # CE-2 (PR-6) — one delta per turn per (workspace, subject, key). The
    # partial unique index (migration name
    # `socialware_config_objects_unique_source_turn`) rejects a CONCURRENT
    # duplicate dispatch at the DB; surface it as a changeset error (not a raw
    # SQLite raise) so the handler can treat the collision as "already
    # applied".
    #
    # NOTE: the exqlite adapter does NOT read the violated index's real name
    # back from SQLite — it reconstructs Ecto's DEFAULT name from the column
    # list. So the `name:` here must be that reconstructed default
    # (`<table>_<col1>_<col2>..._index`), NOT the migration's custom `name:`.
    |> unique_constraint(:source_turn_id,
      name: :socialware_config_objects_workspace_uri_subject_uri_key_source_turn_id_index,
      message: "already applied for this turn"
    )
  end
end
