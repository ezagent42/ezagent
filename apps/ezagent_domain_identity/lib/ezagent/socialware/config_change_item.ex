defmodule Ezagent.Socialware.ConfigChangeItem do
  @moduledoc """
  A staged delta in a CR (SPEC §3.2). Each item references a REAL immutable
  `Ezagent.Socialware.ConfigObject` (`staged_object_id`) that was written at
  stage time with NO pointer aimed at it (inert until publish). This is the key
  reuse: staging does not invent a "draft body" column — it writes a normal
  append-only object that no cascade layer resolves to yet.

  Fields:

    * `staged_object_id` — the immutable proposed object (already written).
    * `base_object_id` — the object the slot pointed at when staged (diff base +
      publish-time drift guard). `nil` if the slot was empty (a brand-new key).
    * `published_prev_object_id` — the object the slot pointed at IMMEDIATELY
      BEFORE publish (the durable per-slot rollback target; recorded at publish
      from `put_pointer`'s returned `previous_config_id` — NOT read from the
      live pointer later, which the next flip overwrites). `nil` ⇒ the slot was
      empty at publish (rollback leaves the new pointer in place; SPEC §4.5 Q2).

  Unique `(change_request_id, layer, key)`: one staged item per slot per CR;
  re-staging the same slot replaces `staged_object_id`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "socialware_config_change_items" do
    field(:change_request_id, :string)
    field(:workspace_uri, :string)
    field(:layer, :string)
    field(:key, :string)
    field(:staged_object_id, :string)
    field(:base_object_id, :string)
    field(:published_prev_object_id, :string)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :id,
      :change_request_id,
      :workspace_uri,
      :layer,
      :key,
      :staged_object_id,
      :base_object_id,
      :published_prev_object_id
    ])
    |> validate_required([
      :id,
      :change_request_id,
      :workspace_uri,
      :layer,
      :key,
      :staged_object_id
    ])
    |> unique_constraint([:change_request_id, :layer, :key],
      name: :socialware_config_change_items_unique_slot,
      message: "this slot is already staged in this change request"
    )
  end

  @spec publish_changeset(t(), map()) :: Ecto.Changeset.t()
  def publish_changeset(%__MODULE__{} = item, attrs) when is_map(attrs) do
    cast(item, attrs, [:published_prev_object_id])
  end
end
