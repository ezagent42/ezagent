defmodule Ezagent.ProviderConnection.LocalAuthorizationBackend.CallbackOperation do
  @moduledoc false

  alias Ezagent.ProviderConnection.AuthorizationAttempt
  alias Ezagent.ProviderConnection.AuthorizationBackendRecord
  alias Ezagent.ProviderConnection.Operation
  alias Ezagent.ProviderConnection.ProviderAuthorizationCommand
  alias EzagentCore.Repo

  @doc false
  @spec resolve(AuthorizationBackendRecord.t(), ProviderAuthorizationCommand.t()) ::
          {:ok, {AuthorizationAttempt.t(), Operation.t()}}
          | {:error, :correlation_conflict}
  def resolve(%AuthorizationBackendRecord{} = row, %ProviderAuthorizationCommand{} = command) do
    attempt =
      Repo.get_by(AuthorizationAttempt,
        authorization_ref: row.authorization_ref,
        correlation_id: command.correlation_id
      )

    case lookup(command, attempt) do
      %Operation{
        expected_authorization_ref: expected_ref,
        expected_authorization_version: expected_version
      } = operation
      when expected_ref == row.authorization_ref and is_integer(expected_version) ->
        {:ok, {attempt, operation}}

      _other ->
        {:error, :correlation_conflict}
    end
  end

  @doc false
  @spec driver_identity(
          AuthorizationBackendRecord.t(),
          ProviderAuthorizationCommand.t(),
          AuthorizationAttempt.t(),
          Operation.t()
        ) :: map()
  def driver_identity(row, command, attempt, operation) do
    %{
      owner_uri: row.owner_uri,
      workspace_uri: row.workspace_uri,
      provider_id: row.provider_id,
      acquisition_method: row.acquisition_method,
      governed_host: row.governed_host,
      backend_pair_id: command.backend_pair_id,
      operation_id: operation.id,
      connection_id: operation.connection_id,
      correlation_id: operation.correlation_id,
      attempt_ref: attempt.attempt_ref,
      authorization_ref: operation.expected_authorization_ref,
      expected_connection_version: operation.expected_connection_version,
      expected_authorization_version: operation.expected_authorization_version,
      expected_credential_version: operation.expected_credential_version,
      command_digest: operation.bound_input_digest
    }
  end

  defp lookup(command, %AuthorizationAttempt{} = attempt) do
    operation_class = operation_class(attempt.purpose)

    Repo.get_by(Operation,
      backend_pair_id: command.backend_pair_id,
      operation_class: operation_class,
      correlation_id: "#{operation_class}:#{command.correlation_id}"
    )
  end

  defp lookup(_command, _attempt), do: nil

  defp operation_class("initial_bind"), do: "store"
  defp operation_class("reauthorize"), do: "replace"
  defp operation_class(_purpose), do: nil
end
