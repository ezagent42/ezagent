defmodule Ezagent.ProviderConnection.CallbackTerminalProof do
  @moduledoc false

  alias Ezagent.ProviderConnection.{
    AuthorizationAttempt,
    AuthorizationBackendRecord,
    Connection,
    Operation,
    ProviderAuthorizationCommand
  }

  @consume_result_keys MapSet.new(~w(
    provider_result_ref external_account_id display_login execution_identity
    authorization_ref authorization_version handoff_ref granted_permissions_digest expires_at
  ))

  @doc false
  def classify(
        %Connection{} = current_connection,
        %Operation{} = operation,
        %AuthorizationAttempt{} = attempt,
        %ProviderAuthorizationCommand{} = command,
        %AuthorizationBackendRecord{} = record
      ) do
    frozen_connection = frozen_connection(current_connection, operation, attempt)

    if matching_scope?(
         current_connection,
         frozen_connection,
         operation,
         attempt,
         command,
         record
       ) do
      classify_terminal_result(operation, command, record)
    else
      {:error, :credential_conflict}
    end
  end

  def classify(_connection, _operation, _attempt, _command, _record),
    do: {:error, :credential_conflict}

  defp frozen_connection(connection, operation, %AuthorizationAttempt{purpose: "initial_bind"}) do
    %{
      connection
      | connection_version: operation.expected_connection_version,
        status: "pending_authorization",
        execution_identity: nil
    }
  end

  defp frozen_connection(connection, operation, _attempt) do
    %{connection | connection_version: operation.expected_connection_version}
  end

  defp classify_terminal_result(operation, command, record) do
    cond do
      confirmed_absence?(operation, command, record) ->
        :confirmed_absence

      exact_committed_result?(operation, command, record) and coherent_consumed_handoff?(record) ->
        {:handoff, :consumed}

      exact_committed_result?(operation, command, record) and coherent_pending_handoff?(record) ->
        {:handoff, :pending}

      exact_committed_result?(operation, command, record) and coherent_shredded_handoff?(record) ->
        {:handoff, :shredded}

      true ->
        {:error, :credential_conflict}
    end
  end

  defp matching_scope?(current, frozen, operation, attempt, command, record) do
    operation.operation_class == callback_operation_class(attempt.purpose) and
      operation.correlation_id == "#{operation.operation_class}:#{attempt.correlation_id}" and
      operation.workspace_uri == current.workspace_uri and
      operation.workspace_uri == attempt.workspace_uri and
      operation.workspace_uri == record.workspace_uri and
      operation.attempt_ref == attempt.attempt_ref and
      operation.connection_id == current.connection_id and
      operation.connection_id == attempt.connection_id and
      operation.connection_id == record.connection_id and
      operation.backend_pair_id == attempt.backend_pair_id and
      operation.backend_pair_id == record.backend_pair_id and
      operation.backend_pair_id == command.backend_pair_id and
      operation.expected_connection_version == attempt.connection_version and
      operation.expected_connection_version == record.connection_version and
      operation.expected_authorization_ref == attempt.authorization_ref and
      operation.expected_authorization_ref == record.authorization_ref and
      operation.expected_authorization_ref == command.authorization_ref and
      historical_credential_coordinates?(operation, attempt) and
      record.bound_input_digest == attempt.bound_subject_digest and
      record.owner_uri == current.owner_uri and
      record.provider_id == current.provider_id and
      record.governed_host == current.governed_host and
      record.acquisition_method == current.acquisition_method and
      record.execution_identity == current.execution_identity and
      record.consume_correlation_id == attempt.correlation_id and
      present?(record.consume_input_digest) and
      command.workspace_uri == current.workspace_uri and
      command.operation_class == "consume" and
      command.correlation_id == attempt.correlation_id and
      command.bound_input_digest == record.consume_input_digest and
      operation.bound_input_digest == Operation.callback_digest(record, attempt, frozen)
  end

  defp historical_credential_coordinates?(operation, %AuthorizationAttempt{
         purpose: "initial_bind"
       }) do
    operation.expected_credential_version == 0 and is_nil(operation.prior_credential_ref) and
      is_nil(operation.prior_credential_version)
  end

  defp historical_credential_coordinates?(operation, %AuthorizationAttempt{
         purpose: "reauthorize"
       }) do
    present?(operation.prior_credential_ref) and
      operation.prior_credential_version == operation.expected_credential_version
  end

  defp historical_credential_coordinates?(_operation, _attempt), do: false

  defp confirmed_absence?(operation, command, record),
    do:
      provider_unowned?(operation) and command.status == "terminal_failed" and
        command.safe_error_code == "not_completed" and is_nil(command.safe_result) and
        record.lifecycle_status == "cancelled" and is_nil(record.handoff_ref) and
        is_nil(record.handoff_ciphertext) and is_nil(record.shredded_at)

  defp exact_committed_result?(operation, command, record) do
    with "committed" <- command.status,
         nil <- command.safe_error_code,
         %{} = result <- command.safe_result,
         true <- MapSet.new(Map.keys(result)) == @consume_result_keys,
         provider_result_ref when is_binary(provider_result_ref) <- result["provider_result_ref"],
         true <- byte_size(provider_result_ref) > 0,
         external_account_id when is_binary(external_account_id) <- result["external_account_id"],
         true <- byte_size(external_account_id) > 0,
         display_login when is_binary(display_login) <- result["display_login"],
         true <- byte_size(display_login) > 0,
         %{"kind" => kind, "external_account_id" => ^external_account_id} <-
           result["execution_identity"],
         true <- kind in ["connected_user", "service_account"],
         true <- result["authorization_ref"] == operation.expected_authorization_ref,
         true <-
           result["authorization_version"] == operation.expected_authorization_version + 1,
         true <- result["handoff_ref"] == record.handoff_ref,
         true <- present?(result["granted_permissions_digest"]),
         {:ok, expires_at} <- decode_optional_datetime(result["expires_at"]),
         true <- operation_result_coherent?(operation, result, expires_at) do
      true
    else
      _mismatch -> false
    end
  end

  defp operation_result_coherent?(operation, result, expires_at) do
    provider_unowned?(operation) or
      (operation.handoff_ref == result["handoff_ref"] and
         operation.provider_result_ref == result["provider_result_ref"] and
         operation.result_external_account_id == result["external_account_id"] and
         operation.result_display_login == result["display_login"] and
         operation.result_execution_identity == result["execution_identity"]["kind"] and
         operation.result_authorization_ref == result["authorization_ref"] and
         operation.result_authorization_version == result["authorization_version"] and
         operation.result_permission_digest == result["granted_permissions_digest"] and
         optional_datetime_equal?(operation.result_expires_at, expires_at) and
         present?(operation.result_ref) and is_integer(operation.result_credential_version))
  end

  defp provider_unowned?(operation) do
    Enum.all?(
      [
        operation.provider_result_ref,
        operation.handoff_ref,
        operation.result_permission_digest,
        operation.result_expires_at,
        operation.result_external_account_id,
        operation.result_display_login,
        operation.result_execution_identity,
        operation.result_authorization_ref,
        operation.result_authorization_version,
        operation.result_ref,
        operation.result_credential_version
      ],
      &is_nil/1
    )
  end

  defp callback_operation_class("initial_bind"), do: "store"
  defp callback_operation_class("reauthorize"), do: "replace"
  defp callback_operation_class(_purpose), do: :invalid

  defp coherent_consumed_handoff?(record),
    do:
      record.lifecycle_status == "consumed" and present?(record.handoff_ref) and
        present?(record.handoff_ciphertext) and is_nil(record.shredded_at)

  defp coherent_pending_handoff?(record),
    do:
      record.lifecycle_status == "handoff_finalization_pending" and
        present?(record.handoff_ref) and present?(record.handoff_ciphertext) and
        is_nil(record.shredded_at)

  defp coherent_shredded_handoff?(record),
    do:
      record.lifecycle_status == "shredded" and present?(record.handoff_ref) and
        is_nil(record.handoff_ciphertext) and is_struct(record.shredded_at, DateTime)

  defp decode_optional_datetime(nil), do: {:ok, nil}

  defp decode_optional_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{} = datetime, 0} -> {:ok, datetime}
      _invalid -> :error
    end
  end

  defp decode_optional_datetime(_value), do: :error

  defp optional_datetime_equal?(nil, nil), do: true

  defp optional_datetime_equal?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp optional_datetime_equal?(_left, _right), do: false

  defp present?(value), do: is_binary(value) and byte_size(value) > 0
end
