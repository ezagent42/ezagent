defmodule Ezagent.ProviderConnection.CallbackTerminalProofTest do
  use ExUnit.Case, async: true

  alias Ezagent.ProviderConnection.{
    AuthorizationAttempt,
    AuthorizationBackendRecord,
    CallbackTerminalProof,
    Connection,
    Operation,
    ProviderAuthorizationCommand
  }

  test "accepts only a committed shredded handoff bound to the complete frozen callback scope" do
    {connection, operation, attempt, command, record} = exact_committed_handoff()

    assert {:handoff, :shredded} =
             CallbackTerminalProof.classify(connection, operation, attempt, command, record)
  end

  test "rejects callback digest drift even when all durable labels agree" do
    {connection, operation, attempt, command, record} = exact_committed_handoff()
    operation = %{operation | bound_input_digest: "forged-callback-digest"}

    assert {:error, :credential_conflict} =
             CallbackTerminalProof.classify(connection, operation, attempt, command, record)
  end

  test "rejects a committed command without the exact safe result" do
    {connection, operation, attempt, command, record} = exact_committed_handoff()

    for safe_result <- [nil, %{}, Map.put(command.safe_result, "handoff_ref", "other-handoff")] do
      assert {:error, :credential_conflict} =
               CallbackTerminalProof.classify(
                 connection,
                 operation,
                 attempt,
                 %{command | safe_result: safe_result},
                 record
               )
    end
  end

  test "rejects every independently drifted frozen coordinate" do
    {connection, operation, attempt, command, record} = exact_committed_handoff()

    mutants = [
      {connection, %{operation | workspace_uri: "workspace://other"}, attempt, command, record},
      {connection, %{operation | operation_class: "store"}, attempt, command, record},
      {connection, %{operation | correlation_id: "replace:other"}, attempt, command, record},
      {connection, %{operation | expected_authorization_version: 9}, attempt, command, record},
      {connection, %{operation | expected_credential_version: 9}, attempt, command, record},
      {connection, %{operation | provider_result_ref: "other-provider-result"}, attempt, command,
       record},
      {%{connection | owner_uri: "entity://acme/user/mallory"}, operation, attempt, command,
       record},
      {%{connection | provider_id: "other-provider"}, operation, attempt, command, record},
      {%{connection | governed_host: "other.example"}, operation, attempt, command, record},
      {%{connection | acquisition_method: "pat"}, operation, attempt, command, record},
      {%{connection | execution_identity: "service_account"}, operation, attempt, command,
       record},
      {connection, operation, attempt, %{command | workspace_uri: "workspace://other"}, record},
      {connection, operation, attempt, command,
       %{record | consume_input_digest: "other-consume-digest"}}
    ]

    for {{mutated_connection, mutated_operation, mutated_attempt, mutated_command,
          mutated_record}, index} <- Enum.with_index(mutants) do
      result =
        CallbackTerminalProof.classify(
          mutated_connection,
          mutated_operation,
          mutated_attempt,
          mutated_command,
          mutated_record
        )

      assert result == {:error, :credential_conflict},
             "historical proof mutant #{index} was accepted: #{inspect(result)}"
    end
  end

  defp exact_committed_handoff do
    connection = %Connection{
      connection_id: Ecto.UUID.generate(),
      workspace_uri: "workspace://acme",
      owner_uri: "entity://acme/user/alice",
      provider_id: "github",
      governed_host: "github.example",
      acquisition_method: "oauth_user",
      execution_identity: "connected_user",
      status: "revoking",
      connection_version: 8,
      authorization_version: 3,
      credential_version: 4
    }

    attempt = %AuthorizationAttempt{
      attempt_ref: Ecto.UUID.generate(),
      workspace_uri: connection.workspace_uri,
      backend_pair_id: "pair-v1",
      authorization_ref: "authorization-ref",
      connection_id: connection.connection_id,
      connection_version: 7,
      purpose: "reauthorize",
      bound_subject_digest: "subject-digest",
      correlation_id: "callback-correlation",
      attempt_version: 2,
      status: "cancelled"
    }

    record = %AuthorizationBackendRecord{
      workspace_uri: connection.workspace_uri,
      backend_pair_id: attempt.backend_pair_id,
      authorization_ref: attempt.authorization_ref,
      execution_identity: connection.execution_identity,
      bound_input_digest: attempt.bound_subject_digest,
      begin_correlation_id: "begin-correlation",
      owner_uri: connection.owner_uri,
      connection_id: connection.connection_id,
      connection_version: attempt.connection_version,
      provider_id: connection.provider_id,
      governed_host: connection.governed_host,
      acquisition_method: connection.acquisition_method,
      requested_permissions_digest: "permissions",
      redirect_uri_id: "callback-v1",
      consume_correlation_id: attempt.correlation_id,
      consume_input_digest: "consume-digest",
      handoff_ref: "handoff-ref",
      handoff_ciphertext: nil,
      lifecycle_status: "shredded",
      shredded_at: DateTime.utc_now()
    }

    frozen_connection = %{connection | connection_version: attempt.connection_version}

    operation = %Operation{
      id: Ecto.UUID.generate(),
      workspace_uri: connection.workspace_uri,
      connection_id: connection.connection_id,
      attempt_ref: attempt.attempt_ref,
      backend_pair_id: attempt.backend_pair_id,
      operation_class: "replace",
      correlation_id: "replace:#{attempt.correlation_id}",
      bound_input_digest: Operation.callback_digest(record, attempt, frozen_connection),
      expected_connection_version: attempt.connection_version,
      expected_authorization_ref: attempt.authorization_ref,
      expected_authorization_version: connection.authorization_version,
      expected_credential_version: connection.credential_version,
      prior_credential_ref: "credential-prior-ref",
      prior_credential_version: connection.credential_version,
      handoff_ref: record.handoff_ref,
      provider_result_ref: "provider-result-ref",
      result_external_account_id: "account-1",
      result_display_login: "alice",
      result_execution_identity: "connected_user",
      result_authorization_ref: attempt.authorization_ref,
      result_authorization_version: connection.authorization_version + 1,
      result_permission_digest: "permissions-v2",
      result_expires_at: nil,
      result_ref: "credential-result-ref",
      result_credential_version: connection.credential_version + 1,
      status: "finalized"
    }

    safe_result = %{
      "provider_result_ref" => "provider-result-ref",
      "external_account_id" => "account-1",
      "display_login" => "alice",
      "execution_identity" => %{
        "kind" => "connected_user",
        "external_account_id" => "account-1"
      },
      "authorization_ref" => operation.expected_authorization_ref,
      "authorization_version" => operation.expected_authorization_version + 1,
      "handoff_ref" => record.handoff_ref,
      "granted_permissions_digest" => "permissions-v2",
      "expires_at" => nil
    }

    command = %ProviderAuthorizationCommand{
      workspace_uri: connection.workspace_uri,
      backend_pair_id: attempt.backend_pair_id,
      operation_class: "consume",
      correlation_id: attempt.correlation_id,
      bound_input_digest: record.consume_input_digest,
      authorization_ref: attempt.authorization_ref,
      status: "committed",
      safe_result: safe_result,
      safe_error_code: nil
    }

    {connection, operation, attempt, command, record}
  end
end
