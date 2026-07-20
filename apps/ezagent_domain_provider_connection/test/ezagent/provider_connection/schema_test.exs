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

  test "system-closure migrations are forward-only, fail-loud, and carry explicit backfills" do
    migration_dir = Application.app_dir(:ezagent_core, "priv/repo_pg/migrations")

    migrations = [
      "20260720001000_reserve_pending_provider_connections.exs",
      "20260720002000_close_provider_binding_cas.exs",
      "20260720003000_add_provider_recovery_schedule.exs",
      "20260720004000_add_refresh_compensation_obligations.exs"
    ]

    sources =
      Map.new(migrations, fn name ->
        source = File.read!(Path.join(migration_dir, name))
        refute source =~ "IF NOT EXISTS"
        refute source =~ "if_not_exists"
        {name, source}
      end)

    assert sources[Enum.at(migrations, 0)] =~ "UPDATE provider_authorization_attempts"
    assert sources[Enum.at(migrations, 0)] =~ "ALTER COLUMN purpose SET NOT NULL"
    assert sources[Enum.at(migrations, 1)] =~ "VALIDATE CONSTRAINT"
    assert sources[Enum.at(migrations, 2)] =~ "SET next_recovery_at = CURRENT_TIMESTAMP"
    assert sources[Enum.at(migrations, 3)] =~ "credential_cleanup_status = CASE"
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

  test "connection backend binding is all-or-none" do
    attrs = connection_attrs() |> Map.delete(:credential_backend_id)

    assert {:error, changeset} =
             %Connection{}
             |> Ecto.Changeset.change(attrs)
             |> Ecto.Changeset.check_constraint(:backend_pair_id,
               name: :provider_connections_backend_binding_check
             )
             |> Repo.insert()

    assert {"is invalid",
            [constraint: :check, constraint_name: "provider_connections_backend_binding_check"]} =
             changeset.errors[:backend_pair_id]
  end

  test "pending authorization is born without sentinel identity or backend references" do
    attrs =
      connection_attrs()
      |> Map.merge(%{
        status: "pending_authorization",
        requested_execution_identity_class: "connected_user"
      })
      |> Map.drop([
        :external_account_id,
        :display_login,
        :execution_identity,
        :authorization_backend_ref,
        :credential_backend_ref,
        :backend_pair_id,
        :authorization_backend_id,
        :credential_backend_id,
        :permission_digest,
        :expires_at
      ])

    assert {:ok, connection} = Repo.insert(Connection.create_changeset(attrs))
    assert connection.status == "pending_authorization"
    assert connection.requested_execution_identity_class == "connected_user"

    for field <- [
          :external_account_id,
          :display_login,
          :execution_identity,
          :authorization_backend_ref,
          :credential_backend_ref,
          :permission_digest,
          :expires_at
        ],
        do: assert(is_nil(Map.fetch!(connection, field)))
  end

  test "failed connections are closed account conflicts without active pointers" do
    pending =
      connection_attrs()
      |> Map.merge(%{
        status: "pending_authorization",
        requested_execution_identity_class: "connected_user"
      })
      |> Map.drop([
        :external_account_id,
        :display_login,
        :execution_identity,
        :authorization_backend_ref,
        :credential_backend_ref,
        :backend_pair_id,
        :authorization_backend_id,
        :credential_backend_id
      ])
      |> Connection.create_changeset()
      |> Ecto.Changeset.apply_changes()

    assert Connection.bind_changeset(pending, %{
             status: "failed",
             last_error_code: "account_conflict"
           }).valid?

    refute Connection.bind_changeset(pending, %{
             status: "failed",
             last_error_code: "account_conflict",
             external_account_id: "acct-loser",
             execution_identity: "human",
             authorization_backend_ref: "auth-loser",
             credential_backend_ref: "credential-loser"
           }).valid?

    for attrs <- [
          Map.merge(connection_attrs(), %{status: "failed", last_error_code: "account_conflict"}),
          connection_attrs()
          |> Map.merge(%{status: "failed"})
          |> Map.drop([
            :external_account_id,
            :execution_identity,
            :authorization_backend_ref,
            :credential_backend_ref
          ])
        ] do
      assert {:error, changeset} = Repo.insert(Connection.create_changeset(attrs))
      assert changeset.errors[:status]
    end
  end

  test "connection constructor rejects non-canonical or cross-workspace ownership" do
    for attrs <- [
          %{connection_attrs() | owner_uri: "entity://other/user/u1"},
          %{connection_attrs() | owner_uri: "entity://ACME/user/u1"},
          %{connection_attrs() | workspace_uri: "workspace://acme/workspace/main"},
          %{connection_attrs() | governed_host: "HTTPS://Example.Test/path"},
          %{connection_attrs() | governed_host: "api..example.test"},
          %{connection_attrs() | owner_uri: "entity://acme/agent/a1"},
          %{connection_attrs() | provider_id: "Fake Provider"},
          %{connection_attrs() | acquisition_method: "OAuth User"},
          %{connection_attrs() | external_account_id: " acct-1 "},
          %{connection_attrs() | execution_identity: "Connected User"}
        ] do
      refute Connection.create_changeset(attrs).valid?
    end
  end

  test "named connection transitions preserve bound identity" do
    connection = struct!(Connection, connection_attrs())

    assert Connection.transition_changeset(connection, %{
             status: "degraded",
             last_error_code: "backend_unavailable"
           }).valid?

    for immutable <- [
          :workspace_uri,
          :owner_uri,
          :provider_id,
          :governed_host,
          :external_account_id,
          :execution_identity,
          :acquisition_method
        ] do
      changeset =
        Connection.transition_changeset(connection, %{
          immutable => "changed",
          :status => "degraded"
        })

      refute changeset.valid?
      assert changeset.errors[immutable]
    end

    trusted = %{
      authorization_backend_ref: "auth-next",
      credential_backend_ref: "credential-next",
      authorization_version: 2,
      credential_version: 2,
      connection_version: 2,
      refresh_lease_token: "lease-next",
      refresh_lease_until: DateTime.add(DateTime.utc_now(), 60),
      refresh_lease_version: 2
    }

    trusted_changeset = Connection.transition_changeset(connection, trusted)

    for {field, value} <- trusted,
        do: assert(Ecto.Changeset.get_change(trusted_changeset, field) == value)

    untrusted_changeset =
      Connection.transition_changeset(
        connection,
        Map.new(trusted, fn {field, value} -> {Atom.to_string(field), value} end)
      )

    for field <- Map.keys(trusted),
        do: refute(Ecto.Changeset.get_change(untrusted_changeset, field))

    refute Connection.transition_changeset(connection, %{status: "invalid"}).valid?

    refute Connection.transition_changeset(connection, %{
             status: "degraded",
             last_error_code: "invalid"
           }).valid?
  end

  test "database rejects arbitrary drift after provider identity is bound" do
    connection = Repo.insert!(Connection.create_changeset(connection_attrs()))

    error =
      assert_raise Ecto.ConstraintError, fn ->
        connection
        |> Ecto.Changeset.change(external_account_id: "different-account")
        |> Repo.update!()
      end

    assert error.constraint == "provider_connections_immutable_binding_check"
  end

  test "operation command key and attempt correlation are unique" do
    connection = Repo.insert!(Connection.create_changeset(connection_attrs()))
    op = Operation.create_changeset(operation_attrs(connection.connection_id))
    assert {:ok, _} = Repo.insert(op)

    assert {:error, cs} =
             Repo.insert(Operation.create_changeset(operation_attrs(connection.connection_id)))

    assert cs.errors[:correlation_id]

    attempt = attempt_attrs(connection.connection_id)
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
    connection = Repo.insert!(Connection.create_changeset(connection_attrs()))
    attempt = attempt_attrs(connection.connection_id)
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
    connection = Repo.insert!(Connection.create_changeset(connection_attrs()))

    refute Connection.create_changeset(%{connection_attrs() | status: "invalid"}).valid?

    refute Connection.create_changeset(Map.put(connection_attrs(), :last_error_code, "invalid")).valid?

    violations = [
      {%Connection{}
       |> Ecto.Changeset.change(%{connection_attrs() | status: "invalid"})
       |> Ecto.Changeset.check_constraint(:status, name: :provider_connections_status_check),
       :status, "provider_connections_status_check"},
      {%Connection{}
       |> Ecto.Changeset.change(Map.put(connection_attrs(), :last_error_code, "invalid"))
       |> Ecto.Changeset.check_constraint(:last_error_code,
         name: :provider_connections_last_error_code_check
       ), :last_error_code, "provider_connections_last_error_code_check"},
      {AuthorizationAttempt.create_changeset(%{
         attempt_attrs(connection.connection_id)
         | status: "invalid"
       }), :status, "provider_authorization_attempts_status_check"},
      {Operation.create_changeset(%{
         operation_attrs(connection.connection_id)
         | operation_class: "invalid"
       }), :operation_class, "provider_connection_operations_operation_class_check"},
      {Operation.create_changeset(%{
         operation_attrs(connection.connection_id)
         | status: "invalid"
       }), :status, "provider_connection_operations_status_check"},
      {Operation.create_changeset(
         Map.put(operation_attrs(connection.connection_id), :safe_error_code, "invalid")
       ), :safe_error_code, "provider_connection_operations_safe_error_code_check"},
      {Operation.create_changeset(
         Map.put(
           operation_attrs(connection.connection_id),
           :provider_cleanup_error_code,
           "invalid"
         )
       ), :provider_cleanup_error_code,
       "provider_connection_operations_provider_cleanup_error_check"},
      {Operation.create_changeset(
         Map.put(
           operation_attrs(connection.connection_id),
           :credential_cleanup_error_code,
           "invalid"
         )
       ), :credential_cleanup_error_code,
       "provider_connection_operations_credential_cleanup_error_check"},
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
    connection = Repo.insert!(Connection.create_changeset(connection_attrs()))
    base = operation_attrs(connection.connection_id)

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
       |> Map.put(:result_credential_version, 2)
       |> Map.put(:handoff_ref, "handoff-ref")
       |> Map.delete(:expected_credential_version),
       "provider_connection_operations_callback_result_check"},
      {base
       |> Map.put(:status, "cleanup_pending")
       |> Map.put(:result_ref, "credential-ref")
       |> Map.put(:expected_credential_version, 1)
       |> Map.put(:handoff_ref, "handoff-ref"),
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
        result_credential_version: 2,
        result_external_account_id: "acct-1",
        result_execution_identity: "human",
        result_authorization_ref: "auth-result",
        result_authorization_version: 2,
        provider_result_ref: "provider-result",
        prior_credential_ref: "prior-credential-ref",
        prior_credential_version: 0,
        credential_cleanup_status: "pending",
        safe_error_code: "cleanup_pending"
      })

    assert %Operation{status: "cleanup_pending"} =
             %Operation{}
             |> Ecto.Changeset.change(valid)
             |> Repo.insert!()
  end

  test "prepared callback operation rejects a half prior credential pair" do
    connection = Repo.insert!(Connection.create_changeset(connection_attrs()))

    for missing <- [:prior_credential_ref, :prior_credential_version] do
      attrs =
        operation_attrs(connection.connection_id)
        |> Map.delete(missing)
        |> Map.put(:correlation_id, "half-prior-#{missing}")

      assert {:error, changeset} =
               %Operation{}
               |> Ecto.Changeset.change(attrs)
               |> Ecto.Changeset.check_constraint(:status,
                 name: :provider_connection_operations_callback_prepare_check
               )
               |> Repo.insert()

      assert {"is invalid",
              [
                constraint: :check,
                constraint_name: "provider_connection_operations_callback_prepare_check"
              ]} = changeset.errors[:status]
    end
  end

  test "initial callback operations allow no prior credential and reject half a prior pair" do
    connection = Repo.insert!(Connection.create_changeset(connection_attrs()))

    initial_attrs =
      operation_attrs(connection.connection_id, "initial_bind")

    assert {:ok, operation} = Repo.insert(Operation.create_changeset(initial_attrs))
    assert operation.prior_credential_ref == nil
    assert operation.prior_credential_version == nil

    for attrs <- [
          Map.put(initial_attrs, :prior_credential_ref, "orphan-ref"),
          Map.put(initial_attrs, :prior_credential_version, 1)
        ] do
      refute Operation.create_changeset(attrs).valid?
    end
  end

  test "callback result changesets accept absent prior coordinates but reject half a prior pair" do
    operation = %Operation{status: "prepared", handoff_ref: "handoff-ref"}

    result_attrs = %{result_ref: "credential-ref", result_credential_version: 1}

    assert Operation.backend_commit_changeset(operation, result_attrs).valid?
    assert Operation.cleanup_pending_changeset(operation, result_attrs).valid?

    for invalid_operation <- [
          %{operation | prior_credential_ref: "orphan-ref"},
          %{operation | prior_credential_version: 1}
        ] do
      refute Operation.backend_commit_changeset(invalid_operation, result_attrs).valid?
      refute Operation.cleanup_pending_changeset(invalid_operation, result_attrs).valid?
    end
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

  test "every durable provider struct redacts secret-bearing coordinates from Inspect" do
    sentinels = %{
      Connection => %{
        authorization_backend_ref: "AUTH_BACKEND_REF_SECRET",
        credential_backend_ref: "CREDENTIAL_BACKEND_REF_SECRET",
        refresh_lease_token: "REFRESH_LEASE_SECRET"
      },
      AuthorizationAttempt => %{
        backend_pair_id: "ATTEMPT_BACKEND_PAIR_SECRET",
        authorization_ref: "ATTEMPT_AUTHORIZATION_REF_SECRET",
        reservation_digest: "ATTEMPT_RESERVATION_SECRET",
        callback_artifact_digest: "ATTEMPT_ARTIFACT_DIGEST_SECRET",
        bound_subject_digest: "ATTEMPT_SUBJECT_SECRET",
        state_digest: "ATTEMPT_STATE_SECRET",
        pkce_digest: "ATTEMPT_PKCE_SECRET",
        callback_artifact: %{"token" => "CALLBACK_ARTIFACT_SECRET"},
        claim_token: "CLAIM_TOKEN_SECRET"
      },
      Operation => %{
        backend_pair_id: "OPERATION_BACKEND_PAIR_SECRET",
        attempt_claim_token: "ATTEMPT_CLAIM_SECRET",
        handoff_ref: "HANDOFF_REF_SECRET",
        result_ref: "RESULT_REF_SECRET",
        result_authorization_ref: "RESULT_AUTHORIZATION_REF_SECRET",
        prior_credential_ref: "PRIOR_CREDENTIAL_REF_SECRET",
        provider_result_ref: "PROVIDER_RESULT_REF_SECRET",
        lease_token: "OPERATION_LEASE_SECRET"
      },
      AuthorizationBackendRecord => %{
        authorization_ref: "AUTHORIZATION_REF_SECRET",
        backend_pair_id: "BACKEND_PAIR_SECRET",
        nonce: "NONCE_SECRET",
        ciphertext: "CIPHERTEXT_SECRET",
        handoff_ref: "BACKEND_HANDOFF_REF_SECRET"
      },
      ProviderAuthorizationCommand => %{
        backend_pair_id: "COMMAND_BACKEND_PAIR_SECRET",
        bound_input_digest: "COMMAND_INPUT_DIGEST_SECRET",
        authorization_ref: "COMMAND_AUTHORIZATION_REF_SECRET",
        safe_result: %{"coordinate" => "COMMAND_RESULT_SECRET"}
      },
      Ezagent.ProviderConnection.Event => %{
        correlation_id: "EVENT_CORRELATION_SECRET",
        provider_request_id: "EVENT_PROVIDER_REQUEST_SECRET"
      }
    }

    assert MapSet.new(Map.keys(sentinels)) == durable_provider_schemas()

    for {schema, attrs} <- sentinels do
      inspected = inspect(struct!(schema, attrs))
      for sentinel <- secret_sentinels(attrs), do: refute(inspected =~ sentinel)
    end
  end

  test "attempt, operation, and event reject absent or cross-workspace parents" do
    connection = Repo.insert!(Connection.create_changeset(connection_attrs()))

    valid_attempt =
      attempt_attrs(connection.connection_id)
      |> Map.merge(%{
        connection_id: connection.connection_id,
        workspace_uri: connection.workspace_uri,
        purpose: "initial_bind",
        reservation_digest: "reservation-digest",
        requested_permission_digest: "permission-digest",
        requested_execution_identity_class: "connected_user",
        redirect_uri_id: "callback-v1",
        callback_artifact_digest: "callback-artifact-digest"
      })

    assert {:ok, _attempt} = Repo.insert(AuthorizationAttempt.create_changeset(valid_attempt))

    for attrs <- [
          %{
            valid_attempt
            | attempt_ref: Ecto.UUID.generate(),
              authorization_ref: "auth-missing",
              state_digest: "state-missing",
              connection_id: Ecto.UUID.generate(),
              purpose: "legacy",
              status: "cancelled"
          },
          %{
            valid_attempt
            | attempt_ref: Ecto.UUID.generate(),
              authorization_ref: "auth-cross",
              state_digest: "state-cross",
              workspace_uri: "workspace://other",
              purpose: "legacy",
              status: "cancelled"
          }
        ] do
      assert {:error, changeset} = Repo.insert(AuthorizationAttempt.create_changeset(attrs))
      assert changeset.errors[:connection_id]
    end

    for schema <- [Operation, Ezagent.ProviderConnection.Event] do
      attrs = %{
        workspace_uri: "workspace://other",
        connection_id: connection.connection_id
      }

      changeset =
        case schema do
          Operation ->
            Operation.create_changeset(
              operation_attrs(connection.connection_id)
              |> Map.merge(attrs)
              |> Map.put(:operation_class, "replace")
            )

          _ ->
            Ezagent.ProviderConnection.Event.create_changeset(attrs)
        end

      assert {:error, changeset} = Repo.insert(changeset)
      assert changeset.errors[:connection_id]
    end
  end

  test "attempt purpose, open status, and backend coordinates form one closed reservation" do
    connection = Repo.insert!(Connection.create_changeset(connection_attrs()))
    base = attempt_attrs(connection.connection_id)

    violations = [
      %{base | purpose: "legacy", status: "pending"},
      Map.drop(base, [:backend_pair_id]),
      Map.drop(base, [:authorization_ref]),
      Map.drop(base, [:state_digest]),
      Map.drop(base, [:bound_subject_digest]),
      Map.drop(base, [:expires_at])
    ]

    for {attrs, index} <- Enum.with_index(violations) do
      attrs =
        Map.merge(attrs, %{
          attempt_ref: Ecto.UUID.generate(),
          correlation_id: "invalid-reservation-#{index}"
        })

      assert {:error, changeset} = Repo.insert(AuthorizationAttempt.create_changeset(attrs))
      assert changeset.errors[:purpose]
    end
  end

  test "operation states retain all external ownership and recovery coordinates" do
    connection = Repo.insert!(Connection.create_changeset(connection_attrs()))
    base = operation_attrs(connection.connection_id)

    violations = [
      base
      |> Map.merge(%{
        status: "backend_committed",
        handoff_ref: "handoff",
        result_ref: "credential-result",
        result_credential_version: 2
      }),
      base
      |> Map.merge(%{operation_class: "refresh", status: "backend_committed"}),
      Map.put(base, :next_recovery_at, nil),
      base
      |> Map.merge(%{status: "finalized", next_recovery_at: DateTime.utc_now()}),
      base
      |> Map.merge(%{
        status: "cleanup_pending",
        handoff_ref: "cleanup-handoff",
        result_ref: "cleanup-credential",
        result_credential_version: 2,
        result_external_account_id: "acct-1",
        result_execution_identity: "human",
        result_authorization_ref: "auth-result",
        result_authorization_version: 2,
        provider_result_ref: "provider-result",
        provider_cleanup_status: "not_required",
        credential_cleanup_status: "not_required"
      })
    ]

    for {attrs, index} <- Enum.with_index(violations) do
      changeset =
        %Operation{}
        |> Ecto.Changeset.change(
          Map.merge(attrs, %{id: Ecto.UUID.generate(), correlation_id: "ownership-#{index}"})
        )
        |> Ecto.Changeset.check_constraint(:status,
          name: :provider_connection_operations_durable_ownership_check
        )

      assert {:error, changeset} = Repo.insert(changeset)
      assert changeset.errors[:status]
    end
  end

  test "refresh effect states own provider and credential results together" do
    connection = Repo.insert!(Connection.create_changeset(connection_attrs()))
    base = operation_attrs(connection.connection_id)

    for {status, index} <-
          ["backend_committed", "connection_committed", "finalized"]
          |> Enum.with_index() do
      schedule = if status == "finalized", do: nil, else: DateTime.utc_now()

      for missing <- [:result_ref, :result_credential_version] do
        attrs =
          base
          |> Map.merge(%{
            id: Ecto.UUID.generate(),
            operation_class: "refresh",
            correlation_id: "refresh-ownership-#{index}-#{missing}",
            status: status,
            provider_result_ref: "provider-result",
            result_ref: "credential-result",
            result_credential_version: 2,
            next_recovery_at: schedule
          })
          |> Map.put(missing, nil)

        changeset =
          %Operation{}
          |> Ecto.Changeset.change(attrs)
          |> Ecto.Changeset.check_constraint(:status,
            name: :provider_connection_operations_durable_ownership_check
          )

        assert {:error, changeset} = Repo.insert(changeset)
        assert changeset.errors[:status]
      end
    end
  end

  test "event closed columns are enforced by named PostgreSQL CHECK constraints" do
    connection = Repo.insert!(Connection.create_changeset(connection_attrs()))

    for {field, constraint} <- [
          transition_from: "provider_connection_events_transition_from_check",
          transition_to: "provider_connection_events_transition_to_check"
        ] do
      event =
        Ezagent.ProviderConnection.Event
        |> struct!(%{
          workspace_uri: base().workspace_uri,
          connection_id: connection.connection_id
        })
        |> Map.put(field, "invalid")

      error =
        assert_raise Ecto.ConstraintError, fn ->
          Repo.insert!(event)
        end

      assert error.constraint == constraint
    end

    assert %Ezagent.ProviderConnection.Event{transition_to: "failed"} =
             Repo.insert!(
               Ezagent.ProviderConnection.Event.create_changeset(%{
                 workspace_uri: connection.workspace_uri,
                 connection_id: connection.connection_id,
                 transition_from: "pending_authorization",
                 transition_to: "failed"
               })
             )
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

  defp base, do: %{workspace_uri: "workspace://acme", backend_pair_id: "pair-a"}

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
        authorization_backend_id: "auth-backend-a",
        credential_backend_id: "credential-backend-a",
        status: "active"
      })

  defp operation_attrs(connection_id, purpose \\ "reauthorize") do
    connection = Repo.get!(Connection, connection_id)

    attempt =
      Repo.get_by(AuthorizationAttempt,
        connection_id: connection_id,
        correlation_id: "schema-operation-#{purpose}"
      ) || insert_operation_attempt!(connection, purpose)

    prior =
      case purpose do
        "initial_bind" ->
          %{prior_credential_ref: nil, prior_credential_version: nil}

        "reauthorize" ->
          %{
            prior_credential_ref: connection.credential_backend_ref,
            prior_credential_version: connection.credential_version
          }
      end

    base()
    |> Map.merge(%{
      connection_id: connection_id,
      attempt_ref: attempt.attempt_ref,
      operation_class: "store",
      correlation_id: "corr-1",
      bound_input_digest: "digest",
      expected_connection_version: connection.connection_version,
      expected_credential_version: connection.credential_version,
      attempt_version: attempt.attempt_version,
      attempt_claim_token: attempt.claim_token,
      next_recovery_at: DateTime.utc_now(),
      status: "prepared"
    })
    |> Map.merge(prior)
  end

  defp insert_operation_attempt!(connection, purpose) do
    unique = System.unique_integer([:positive])

    connection.connection_id
    |> attempt_attrs()
    |> Map.merge(%{
      attempt_ref: Ecto.UUID.generate(),
      authorization_ref: "schema-operation-auth-#{unique}",
      purpose: purpose,
      state_digest: "schema-operation-state-#{unique}",
      correlation_id: "schema-operation-#{purpose}",
      connection_version: connection.connection_version,
      status: "consumed"
    })
    |> AuthorizationAttempt.create_changeset()
    |> Ecto.Changeset.change(attempt_version: 1, claim_token: "claim-token")
    |> Repo.insert!()
  end

  defp attempt_attrs(connection_id),
    do:
      Map.merge(base(), %{
        attempt_ref: Ecto.UUID.generate(),
        authorization_ref: "auth-ref",
        connection_id: connection_id,
        purpose: "initial_bind",
        reservation_digest: "reservation",
        requested_permission_digest: "permission-digest",
        requested_execution_identity_class: "connected_user",
        redirect_uri_id: "callback-v1",
        callback_artifact_digest: "callback-artifact-digest",
        bound_subject_digest: "subject",
        state_digest: "state",
        correlation_id: "corr",
        status: "pending",
        expires_at: DateTime.utc_now()
      })

  defp secret_sentinels(attrs) do
    Enum.flat_map(attrs, fn
      {_key, value} when is_binary(value) -> [value]
      {_key, value} when is_map(value) -> Map.values(value)
      _other -> []
    end)
  end

  defp durable_provider_schemas do
    :ezagent_domain_provider_connection
    |> Application.spec(:modules)
    |> Enum.filter(fn module ->
      Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) and
        String.starts_with?(module.__schema__(:source), "provider_")
    end)
    |> MapSet.new()
  end

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
