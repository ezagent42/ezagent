defmodule Ezagent.Socialware.CompositionConsentCommand do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:idempotency_key, :string, autogenerate: false}

  schema "socialware_composition_consent_commands" do
    field(:workspace_uri, :string)
    # A composition command references its binding; a URI-share command
    # references its consent directly. Exactly one is set.
    field(:binding_id, :string)
    field(:consent_id, :string)
    field(:side, Ecto.Enum, values: [:target, :source])
    field(:command, Ecto.Enum, values: [:approve, :deny, :revoke])
    field(:actor_uri, :string)
    field(:result_state, Ecto.Enum, values: [:pending, :approved, :denied, :revoked, :superseded])
    field(:inserted_at, :utc_datetime_usec)
  end

  @fields ~w(idempotency_key workspace_uri binding_id consent_id side command actor_uri result_state inserted_at)a
  # `binding_id`/`consent_id` are contextual (composition vs URI-share) — not
  # required here; the caller sets exactly one.
  @required ~w(idempotency_key workspace_uri side command actor_uri result_state inserted_at)a

  @doc false
  def changeset(command, attrs) do
    command
    |> cast(attrs, @fields)
    |> validate_required(@required)
  end
end
