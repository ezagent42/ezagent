defmodule Ezagent.Socialware.ConfigChangeRequest do
  @moduledoc """
  The CR (change-request) draft ENVELOPE — minimal config governance (SPEC
  `docs/together/2026-06-26/specs/cr-config-governance.md`, rev 3).

  A CR aggregates N staged config deltas (`ConfigChangeItem`) under one envelope
  for ONE agent-subject, so they can be staged → previewed → published as one
  unit (or rejected wholesale, or rolled back after publish).

  Lifecycle (minimal — no review state, no two-person rule):

      open ──stage/unstage──▶ open
        │                       │ publish (manage-cap; flips pointer + fires
        │ reject                │          existing sandbox materialization)
        ▼                       ▼
      rejected              published ──rollback (existing repoint)──▶ rolled_back

  Per-tenant ⇒ `workspace_uri NOT NULL` (invariant #14). Agent-subject only
  (v1): `subject_uri` names the agent being changed.

  The durable per-slot rollback target (`published_prev_object_id`) lives on
  `ConfigChangeItem`, NOT here (a multi-slot CR has one prior object per slot).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(open published rejected rolled_back)

  schema "socialware_config_change_requests" do
    field(:workspace_uri, :string)
    field(:subject_uri, :string)
    field(:status, :string)
    field(:opened_by, :string)
    field(:published_by, :string)
    field(:published_turn_id, :string)
    field(:title, :string)
    field(:note, :string)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "The valid CR lifecycle statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :id,
      :workspace_uri,
      :subject_uri,
      :status,
      :opened_by,
      :published_by,
      :published_turn_id,
      :title,
      :note
    ])
    |> validate_required([:id, :workspace_uri, :subject_uri, :status, :opened_by])
    |> validate_inclusion(:status, @statuses)
    # One ACTIVE (open) CR per agent-subject (partial unique index
    # `WHERE status = 'open'`). Two concurrent open CRs would race the same
    # pointers at publish.
    |> unique_constraint([:workspace_uri, :subject_uri],
      name: :socialware_config_change_requests_one_open_per_subject,
      message: "an open change request already exists for this subject"
    )
  end

  @spec status_changeset(t(), map()) :: Ecto.Changeset.t()
  def status_changeset(%__MODULE__{} = cr, attrs) when is_map(attrs) do
    cr
    |> cast(attrs, [:status, :published_by, :published_turn_id])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
  end
end
