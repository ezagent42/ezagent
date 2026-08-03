defmodule Ezagent.Session.SocialwareInstallObligation do
  @moduledoc "Durable recovery record for a Session's declared-role installation."

  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:pending, :running, :resolved, :failed]

  schema "session_socialware_install_obligations" do
    field(:session_uri, :string)
    field(:workspace_uri, :string)
    field(:actor_uri, :string)
    field(:status, Ecto.Enum, values: @statuses, default: :pending)
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
    |> cast(attrs, [:session_uri, :workspace_uri, :actor_uri])
    |> validate_required([:session_uri, :workspace_uri])
    |> unique_constraint(:session_uri)
  end

  @doc false
  def transition_changeset(obligation, attrs) do
    cast(obligation, attrs, [
      :workspace_uri,
      :actor_uri,
      :status,
      :attempts,
      :last_error,
      :claim_token,
      :next_attempt_at,
      :resolved_at
    ])
  end
end
