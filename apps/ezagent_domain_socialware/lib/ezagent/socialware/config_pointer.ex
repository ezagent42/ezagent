defmodule Ezagent.Socialware.ConfigPointer do
  @moduledoc """
  High-layer pointer to an immutable socialware config object.

  The pointed config id is the mutable cascade layer value. The config object
  itself is retained forever and is never overwritten.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "socialware_config_pointers" do
    field(:layer, :string)
    field(:workspace_uri, :string)
    field(:subject_uri, :string)
    field(:key, :string)
    field(:config_id, :string)
    field(:previous_config_id, :string)
    field(:pointed_by, :string)
    field(:source_turn_id, :string)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @spec id(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def id(layer, workspace_uri, subject_uri, key) do
    Enum.join([layer, workspace_uri, subject_uri, key], "|")
  end

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :id,
      :layer,
      :workspace_uri,
      :subject_uri,
      :key,
      :config_id,
      :previous_config_id,
      :pointed_by,
      :source_turn_id
    ])
    |> validate_required([
      :id,
      :layer,
      :workspace_uri,
      :subject_uri,
      :key,
      :config_id,
      :pointed_by,
      :source_turn_id
    ])
    |> validate_inclusion(:layer, ["workspace", "user", "session"])
  end
end
