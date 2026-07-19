defmodule Ezagent.ProviderConnection.SchemaTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ProviderConnection.{
    AuthorizationAttempt,
    AuthorizationBackendRecord,
    Connection,
    Operation,
    ProviderAuthorizationCommand
  }

  alias EzagentCore.Repo

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "all provider connection schemas are persisted through the shared core Repo boundary" do
    for schema <- [
          Connection,
          AuthorizationAttempt,
          Operation,
          Ezagent.ProviderConnection.Event,
          AuthorizationBackendRecord,
          ProviderAuthorizationCommand
        ] do
      assert schema.__schema__(:fields) |> Enum.member?(:workspace_uri)

      assert schema.__schema__(:source) in ~w(provider_connections provider_authorization_attempts provider_connection_operations provider_connection_events provider_authorization_backend_records provider_authorization_commands)
    end

    assert Repo.__adapter__() == Ecto.Adapters.Postgres

    assert Enum.all?(
             [Connection, AuthorizationAttempt, Operation],
             &function_exported?(&1, :create_changeset, 1)
           )
  end

  test "active binding uniqueness is a named PostgreSQL constraint" do
    attrs = connection_attrs()
    assert {:ok, _} = Repo.insert(Connection.create_changeset(attrs))

    assert {:error, changeset} =
             Repo.insert(
               Connection.create_changeset(%{attrs | connection_id: Ecto.UUID.generate()})
             )

    assert {"has already been taken",
            [constraint: :unique, constraint_name: "provider_connections_active_binding_index"]} =
             changeset.errors[:external_account_id]
  end

  test "operation command key and attempt correlation are unique" do
    op = Operation.create_changeset(operation_attrs())
    assert {:ok, _} = Repo.insert(op)
    assert {:error, cs} = Repo.insert(Operation.create_changeset(operation_attrs()))
    assert cs.errors[:correlation_id]

    attempt = attempt_attrs()
    assert {:ok, _} = Repo.insert(AuthorizationAttempt.create_changeset(attempt))

    duplicate_state = %{
      attempt
      | attempt_ref: Ecto.UUID.generate(),
        authorization_ref: "auth-ref-2"
    }

    assert {:error, cs} = Repo.insert(AuthorizationAttempt.create_changeset(duplicate_state))
    assert cs.errors[:state_digest]
  end

  test "authorization ref uniqueness is enforced independently of state uniqueness" do
    attempt = attempt_attrs()
    assert {:ok, _} = Repo.insert(AuthorizationAttempt.create_changeset(attempt))

    duplicate_authorization_ref = %{
      attempt
      | attempt_ref: Ecto.UUID.generate(),
        state_digest: "independent-state"
    }

    assert {:error, changeset} =
             Repo.insert(AuthorizationAttempt.create_changeset(duplicate_authorization_ref))

    assert {"has already been taken",
            [
              constraint: :unique,
              constraint_name: "provider_authorization_attempts_authorization_ref_index"
            ]} = changeset.errors[:authorization_ref]
  end

  test "every durable closed value is rejected by its named PostgreSQL CHECK" do
    violations = [
      {Connection.create_changeset(%{connection_attrs() | status: "invalid"}), :status,
       "provider_connections_status_check"},
      {Connection.create_changeset(Map.put(connection_attrs(), :last_error_code, "invalid")),
       :last_error_code, "provider_connections_last_error_code_check"},
      {AuthorizationAttempt.create_changeset(%{attempt_attrs() | status: "invalid"}), :status,
       "provider_authorization_attempts_status_check"},
      {Operation.create_changeset(%{operation_attrs() | operation_class: "invalid"}),
       :operation_class, "provider_connection_operations_operation_class_check"},
      {Operation.create_changeset(%{operation_attrs() | status: "invalid"}), :status,
       "provider_connection_operations_status_check"},
      {Operation.create_changeset(Map.put(operation_attrs(), :safe_error_code, "invalid")),
       :safe_error_code, "provider_connection_operations_safe_error_code_check"},
      {AuthorizationBackendRecord.create_changeset(%{
         backend_record_attrs()
         | lifecycle_status: "invalid"
       }), :lifecycle_status, "provider_authorization_backend_records_lifecycle_status_check"}
    ]

    for {changeset, field, constraint_name} <- violations do
      assert {:error, changeset} = Repo.insert(changeset)

      assert {"is invalid", [constraint: :check, constraint_name: ^constraint_name]} =
               changeset.errors[field]
    end
  end

  test "callback operation phases are closed over their required fence and result coordinates" do
    base = operation_attrs()

    violations = [
      {Map.drop(base, [:attempt_claim_token]),
       "provider_connection_operations_callback_fence_check"},
      {base
       |> Map.put(:status, "backend_committed")
       |> Map.put(:handoff_ref, "handoff-ref"),
       "provider_connection_operations_callback_result_check"},
      {base
       |> Map.put(:status, "cleanup_pending")
       |> Map.put(:result_ref, "credential-ref")
       |> Map.put(:expected_credential_version, 1),
       "provider_connection_operations_callback_result_check"}
    ]

    for {attrs, constraint_name} <- violations do
      assert {:error, changeset} =
               %Operation{}
               |> Ecto.Changeset.change(attrs)
               |> Ecto.Changeset.check_constraint(:status, name: constraint_name)
               |> Repo.insert()

      assert {"is invalid", [constraint: :check, constraint_name: ^constraint_name]} =
               changeset.errors[:status]
    end

    valid =
      base
      |> Map.merge(%{
        correlation_id: "cleanup-valid",
        status: "cleanup_pending",
        handoff_ref: "handoff-ref",
        result_ref: "credential-ref",
        expected_credential_version: 1,
        safe_error_code: "cleanup_pending"
      })

    assert %Operation{status: "cleanup_pending"} =
             %Operation{}
             |> Ecto.Changeset.change(valid)
             |> Repo.insert!()
  end

  test "private authorization backend Inspect excludes every secret-bearing field" do
    sentinels = %{
      nonce: "UNIQUE_NONCE_SECRET",
      ciphertext: "UNIQUE_CIPHERTEXT_SECRET",
      handoff_ciphertext: "UNIQUE_HANDOFF_SECRET"
    }

    inspected = inspect(struct!(AuthorizationBackendRecord, sentinels))

    for sentinel <- Map.values(sentinels), do: refute(inspected =~ sentinel)
  end

  test "event closed columns are enforced by named PostgreSQL CHECK constraints" do
    for {field, constraint} <- [
          transition_from: "provider_connection_events_transition_from_check",
          transition_to: "provider_connection_events_transition_to_check"
        ] do
      event =
        Ezagent.ProviderConnection.Event
        |> struct!(%{
          workspace_uri: base().workspace_uri,
          connection_id: Ecto.UUID.generate()
        })
        |> Map.put(field, "invalid")

      error =
        assert_raise Ecto.ConstraintError, fn ->
          Repo.insert!(event)
        end

      assert error.constraint == constraint
    end
  end

  test "backend records allow exactly one lifecycle row per authorization ref" do
    attrs = backend_record_attrs()
    assert {:ok, _} = Repo.insert(AuthorizationBackendRecord.create_changeset(attrs))

    assert {:error, cs} =
             Repo.insert(
               AuthorizationBackendRecord.create_changeset(%{attrs | id: Ecto.UUID.generate()})
             )

    assert cs.errors[:authorization_ref]
  end

  defp base, do: %{workspace_uri: "workspace://acme/workspace/main", backend_pair_id: "pair-a"}

  defp connection_attrs,
    do:
      Map.merge(base(), %{
        connection_id: Ecto.UUID.generate(),
        owner_uri: "entity://acme/user/u1",
        provider_id: "fake",
        governed_host: "example.test",
        external_account_id: "acct-1",
        display_login: "alice",
        execution_identity: "human",
        acquisition_method: "oauth",
        authorization_backend_ref: "auth:a",
        credential_backend_ref: "cred:a",
        status: "active"
      })

  defp operation_attrs,
    do:
      Map.merge(base(), %{
        connection_id: Ecto.UUID.generate(),
        operation_class: "store",
        correlation_id: "corr-1",
        bound_input_digest: "digest",
        expected_connection_version: 1,
        attempt_version: 1,
        attempt_claim_token: "claim-token",
        status: "prepared"
      })

  defp attempt_attrs,
    do:
      Map.merge(base(), %{
        attempt_ref: Ecto.UUID.generate(),
        authorization_ref: "auth-ref",
        connection_id: Ecto.UUID.generate(),
        bound_subject_digest: "subject",
        state_digest: "state",
        correlation_id: "corr",
        status: "pending",
        expires_at: DateTime.utc_now()
      })

  defp backend_record_attrs,
    do:
      Map.merge(base(), %{
        id: Ecto.UUID.generate(),
        authorization_ref: "auth-ref-committed",
        key_id: "k1",
        key_fingerprint: :crypto.hash(:sha256, "test-key"),
        nonce: <<1>>,
        ciphertext: <<2>>,
        bound_input_digest: "digest",
        begin_correlation_id: "begin-1",
        owner_uri: "entity://acme/user/u1",
        execution_identity: "connected_user",
        connection_id: "conn-1",
        connection_version: 1,
        provider_id: "fake",
        governed_host: "example.test",
        acquisition_method: "oauth_user",
        requested_permissions_digest: "permissions",
        redirect_uri_id: "callback-v1",
        lifecycle_status: "consumed",
        expires_at: DateTime.utc_now()
      })
end
