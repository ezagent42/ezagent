defmodule Ezagent.ProviderConnection.CallbackBinding do
  @moduledoc false

  alias Ezagent.ProviderConnection.AuthorizationAttempt

  @spec artifact_digest(Ezagent.Capability.t()) :: String.t()
  def artifact_digest(%Ezagent.Capability{} = artifact) do
    artifact
    |> Ezagent.Capability.to_map()
    |> digest()
  end

  @spec reservation_digest(String.t(), struct(), map(), String.t(), String.t()) ::
          String.t()
  def reservation_digest(purpose, connection, coordinates, begin_correlation_id, artifact_digest) do
    digest({
      purpose,
      connection.connection_id,
      connection.connection_version,
      connection.owner_uri,
      connection.workspace_uri,
      connection.provider_id,
      connection.governed_host,
      connection.acquisition_method,
      coordinates.requested_execution_identity_class,
      requested_permissions_digest(coordinates),
      coordinates.redirect_uri_id,
      begin_correlation_id,
      artifact_digest
    })
  end

  @spec valid?(struct(), AuthorizationAttempt.t(), struct(), Ezagent.Capability.t()) :: boolean()
  def valid?(connection, attempt, backend_record, artifact) do
    artifact_digest = artifact_digest(artifact)

    attempt.callback_artifact_digest == artifact_digest and
      attempt.reservation_digest ==
        reservation_digest(
          attempt.purpose,
          connection,
          attempt,
          backend_record.begin_correlation_id,
          artifact_digest
        ) and
      attempt.workspace_uri == connection.workspace_uri and
      attempt.connection_id == connection.connection_id and
      attempt.connection_version == connection.connection_version and
      attempt.backend_pair_id == backend_record.backend_pair_id and
      attempt.authorization_ref == backend_record.authorization_ref and
      attempt.bound_subject_digest == backend_record.bound_input_digest and
      backend_record.workspace_uri == connection.workspace_uri and
      backend_record.owner_uri == connection.owner_uri and
      backend_record.connection_id == connection.connection_id and
      backend_record.connection_version == connection.connection_version and
      backend_record.provider_id == connection.provider_id and
      backend_record.governed_host == connection.governed_host and
      backend_record.acquisition_method == connection.acquisition_method and
      backend_record.requested_permissions_digest == attempt.requested_permission_digest and
      backend_record.redirect_uri_id == attempt.redirect_uri_id and
      backend_record.execution_identity == attempt.requested_execution_identity_class
  end

  @spec reservation_valid?(struct(), AuthorizationAttempt.t(), String.t(), Ezagent.Capability.t()) ::
          boolean()
  def reservation_valid?(connection, attempt, begin_correlation_id, artifact) do
    artifact_digest = artifact_digest(artifact)

    attempt.callback_artifact_digest == artifact_digest and
      attempt.reservation_digest ==
        reservation_digest(
          attempt.purpose,
          connection,
          attempt,
          begin_correlation_id,
          artifact_digest
        )
  end

  defp requested_permissions_digest(%{requested_permissions_digest: digest}), do: digest
  defp requested_permissions_digest(%{requested_permission_digest: digest}), do: digest

  defp digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
