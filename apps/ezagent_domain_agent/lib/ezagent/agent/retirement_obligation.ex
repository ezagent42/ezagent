defmodule Ezagent.Agent.RetirementObligation do
  @moduledoc "Durable recovery record for an incomplete Agent retirement."

  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:pending, :running, :resolved, :failed]

  schema "agent_retirement_obligations" do
    field(:agent_uri, :string)
    field(:workspace_uri, :string)
    field(:provenance_root_uri, :string)
    field(:creation_attempt_id, :string)
    field(:retirement_reason, :string)
    field(:status, Ecto.Enum, values: @statuses, default: :pending)
    field(:pending_steps, :map)
    field(:attempts, :integer, default: 0)
    field(:last_error, :string)
    field(:claim_token, :string)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:resolved_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def create_changeset(obligation, attrs) do
    obligation
    |> cast(attrs, [
      :agent_uri,
      :workspace_uri,
      :provenance_root_uri,
      :creation_attempt_id,
      :retirement_reason,
      :pending_steps
    ])
    |> validate_required([
      :agent_uri,
      :workspace_uri,
      :provenance_root_uri,
      :creation_attempt_id,
      :retirement_reason,
      :pending_steps
    ])
    |> unique_constraint([:agent_uri, :creation_attempt_id, :retirement_reason],
      name: :agent_retirement_obligations_identity_index
    )
  end

  @doc false
  def transition_changeset(obligation, attrs) do
    cast(obligation, attrs, [
      :status,
      :attempts,
      :last_error,
      :claim_token,
      :next_attempt_at,
      :resolved_at,
      :pending_steps
    ])
  end
end
