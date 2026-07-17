defmodule Ezagent.Workspace.TaskWorkspace.Provision do
  @moduledoc "Durable lifecycle record for one task workspace generation."

  use Ecto.Schema

  import Ecto.Changeset

  @statuses [
    :planned,
    :provisioning,
    :ready,
    :sidecar_started,
    :blocked,
    :cleanup_pending,
    :cleaned
  ]

  @immutable_fields [
    :provision_id,
    :workspace_uri,
    :task_uri,
    :generation,
    :task_access_uri,
    :repository_uri,
    :checkout_fingerprint,
    :base_ref,
    :allowed_head_ref
  ]

  @transition_fields [
    :status,
    :state_version,
    :cache_identity,
    :worktree_identity,
    :worktree_path,
    :claim_token,
    :lease_until,
    :start_token,
    :start_token_consumed_at,
    :attempts,
    :blocker_code,
    :cleanup_reason,
    :cleaned_at
  ]

  schema "git_task_workspace_provisions" do
    field(:provision_id, :string)
    field(:workspace_uri, :string)
    field(:task_uri, :string)
    field(:generation, :integer)
    field(:task_access_uri, :string)
    field(:repository_uri, :string)
    field(:checkout_fingerprint, :string)
    field(:base_ref, :string)
    field(:allowed_head_ref, :string)
    field(:status, Ecto.Enum, values: @statuses, default: :planned)
    field(:state_version, :integer, default: 0)
    field(:cache_identity, :string)
    field(:worktree_identity, :string)
    field(:worktree_path, :string)
    field(:claim_token, :string)
    field(:lease_until, :utc_datetime_usec)
    field(:start_token, :string)
    field(:start_token_consumed_at, :utc_datetime_usec)
    field(:attempts, :integer, default: 0)
    field(:blocker_code, :string)
    field(:cleanup_reason, :string)
    field(:cleaned_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc false
  @spec immutable_fields() :: [atom()]
  def immutable_fields, do: @immutable_fields

  @doc false
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(provision, attrs) do
    provision
    |> cast(attrs, @immutable_fields)
    |> validate_required(@immutable_fields)
    |> validate_number(:generation, greater_than: 0)
    |> unique_constraint([:workspace_uri, :task_uri, :generation],
      name: :git_task_workspace_provisions_identity_index
    )
    |> unique_constraint(:provision_id)
  end

  @doc false
  @spec transition_changeset(t(), map()) :: Ecto.Changeset.t()
  def transition_changeset(provision, attrs), do: cast(provision, attrs, @transition_fields)
end
