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
    # P0 §3.2/§11.1 — first-class, queryable content-hash artifact identity
    # (`sha256` of the canonical body). Nullable: legacy rows predate the column;
    # every NEW write populates it via `Ezagent.Socialware.ContentHash.of/1`.
    field(:content_hash, :string)
    field(:created_by, :string)
    field(:source_turn_id, :string)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :id,
      :workspace_uri,
      :subject_uri,
      :key,
      :body,
      :content_hash,
      :created_by,
      :source_turn_id
    ])
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
    # partial unique index (`socialware_config_objects_unique_source_turn`)
    # rejects a CONCURRENT
    # duplicate dispatch at the DB; surface it as a changeset error (not a raw
    # DB constraint raise) so the handler can treat the collision as "already
    # applied".
    #
    # The explicit short name avoids PostgreSQL identifier truncation while
    # still allowing Ecto to convert the violation into a changeset error.
    |> unique_constraint(:source_turn_id,
      name: :socialware_config_objects_unique_source_turn,
      message: "already applied for this turn"
    )
  end
end
