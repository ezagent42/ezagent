defmodule Ezagent.ProviderConnection.Test.D1OperationFixtures do
  @moduledoc false

  alias Ezagent.ProviderConnection.{AuthorizationAttempt, Connection}
  alias EzagentCore.Repo

  def connection(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          connection_id: Ecto.UUID.generate(),
          workspace_uri: URI.to_string(Ezagent.URI.workspace("acme")),
          owner_uri: URI.to_string(Ezagent.URI.user("acme", "alice")),
          provider_id: "task8-provider",
          governed_host: "git.example",
          external_account_id: "account-#{System.unique_integer([:positive])}",
          display_login: "alice",
          execution_identity: "connected_user_account_1",
          requested_execution_identity_class: "connected_user",
          acquisition_method: "oauth_user",
          authorization_backend_ref: "authorization-ref",
          credential_backend_ref: "credential-ref-old",
          backend_pair_id: "pair-task8-v1",
          authorization_backend_id: "local-authorization-v1",
          credential_backend_id: "credential-task8-v1",
          status: "active"
        },
        overrides
      )

    attrs =
      if attrs.status == "pending_authorization" do
        Map.merge(attrs, %{
          external_account_id: nil,
          display_login: nil,
          execution_identity: nil,
          authorization_backend_ref: nil,
          credential_backend_ref: nil,
          backend_pair_id: nil,
          authorization_backend_id: nil,
          credential_backend_id: nil,
          permission_digest: nil,
          expires_at: nil
        })
      else
        attrs
      end

    attrs
    |> Connection.create_changeset()
    |> Ecto.Changeset.change(
      connection_version: Map.get(attrs, :connection_version, 0),
      credential_version: Map.get(attrs, :credential_version, 0)
    )
    |> Repo.insert!()
  end

  def attempt(connection, overrides \\ %{}) do
    purpose =
      if connection.status == "pending_authorization", do: "initial_bind", else: "reauthorize"

    attrs =
      Map.merge(
        %{
          attempt_ref: Ecto.UUID.generate(),
          workspace_uri: connection.workspace_uri,
          backend_pair_id: "pair-task8-v1",
          authorization_ref: "authorization-#{System.unique_integer([:positive])}",
          connection_id: connection.connection_id,
          connection_version: connection.connection_version,
          purpose: purpose,
          reservation_digest: "reservation-#{System.unique_integer([:positive])}",
          requested_permission_digest: "permissions-v1",
          requested_execution_identity_class: "connected_user",
          redirect_uri_id: "task8-callback",
          callback_artifact_digest: "callback-artifact-digest",
          bound_subject_digest: "subject-digest",
          state_digest: "state-#{System.unique_integer([:positive])}",
          correlation_id: "callback-#{System.unique_integer([:positive])}",
          status: "consumed",
          expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
        },
        overrides
      )

    attrs
    |> AuthorizationAttempt.create_changeset()
    |> Ecto.Changeset.change(
      attempt_version: Map.get(attrs, :attempt_version, 0),
      claim_token: Map.get(attrs, :claim_token),
      claim_until: Map.get(attrs, :claim_until),
      consumed_at: Map.get(attrs, :consumed_at)
    )
    |> Repo.insert!()
  end
end
