defmodule Ezagent.ProviderConnection.AuthorizationAttempt do
  @moduledoc "Public, secret-safe authorization correlation row."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:attempt_ref, Ecto.UUID, autogenerate: false}
  schema "provider_authorization_attempts" do
    field(:workspace_uri, :string)
    field(:backend_pair_id, :string)
    field(:authorization_ref, :string)
    field(:connection_id, Ecto.UUID)
    field(:connection_version, :integer, default: 0)
    field(:bound_subject_digest, :string)
    field(:state_digest, :string)
    field(:pkce_digest, :string)
    field(:correlation_id, :string)
    field(:attempt_version, :integer, default: 0)
    field(:status, :string)
    field(:callback_artifact, :map)
    field(:claim_token, :string)
    field(:claim_until, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @trusted ~w(attempt_ref workspace_uri backend_pair_id authorization_ref connection_id connection_version bound_subject_digest state_digest pkce_digest correlation_id callback_artifact expires_at)a
  def create_changeset(attrs),
    do:
      %__MODULE__{}
      |> cast(attrs, [:status])
      |> change(Map.take(attrs, @trusted))
      |> validate_required(
        ~w(attempt_ref workspace_uri backend_pair_id authorization_ref connection_id bound_subject_digest state_digest correlation_id status expires_at)a
      )
      |> unique_constraint(:authorization_ref,
        name: :provider_authorization_attempts_authorization_ref_index
      )
      |> unique_constraint(:state_digest,
        name: :provider_authorization_attempts_backend_state_index
      )
end
