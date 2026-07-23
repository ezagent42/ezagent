Code.require_file(Path.expand("../support/fake_driver_alpha.ex", __DIR__))
Code.require_file(Path.expand("../support/refresh_exchange_backend_support.ex", __DIR__))
Code.require_file(Path.expand("../support/callback_recovery_credential_sink.ex", __DIR__))

defmodule Ezagent.ProviderConnection.CallbackRecoveryTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ProviderConnection.{
    AuthorizationAttempt,
    AuthorizationBackendRecord,
    BackendPair,
    BackendPairRegistry,
    Connection,
    Driver,
    DriverRegistry,
    LocalAuthorizationBackend,
    Operation,
    ProviderAuthorizationCommand,
    Store,
    CallbackIngress
  }

  alias Ezagent.ProviderConnection.Test.{CallbackRecoveryCredentialSink, FakeDriverAlpha}
  alias EzagentCore.Repo

  setup do
    owner = {__MODULE__, self()}
    FakeDriverAlpha.reset()

    credential_state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             results: %{},
             canonical_digests: %{},
             logical_effects: 0,
             effects: [],
             invocations: 0,
             revocations: [],
             block_once?: false,
             hook: nil
           }
         end}
      )

    previous_implementations =
      Application.get_env(
        :ezagent_domain_provider_connection,
        :credential_backend_implementations
      )

    Application.put_env(
      :ezagent_domain_provider_connection,
      :credential_backend_implementations,
      %{"credential-alpha-v1" => CallbackRecoveryCredentialSink}
    )

    Application.put_env(:ezagent_domain_provider_connection, :task7_test_owner, self())

    Application.put_env(
      :ezagent_domain_provider_connection,
      :task7_credential_state,
      credential_state
    )

    Application.put_env(:ezagent_domain_provider_connection, :callback_redirect_pairs, %{
      "callback-v1" => "pair-z-local-v1"
    })

    pair =
      BackendPair.new!(%{
        pair_id: "pair-z-local-v1",
        authorization_backend: %{
          id: "local-authorization-v1",
          fingerprint: "local-authorization-contract-v1"
        },
        credential_backend: %{
          id: "credential-alpha-v1",
          fingerprint: "credential-alpha-contract-v1"
        }
      })

    assert BackendPairRegistry.register(owner, pair) in [:acquired, :existing_identical]

    driver =
      Driver.new!(%{
        provider_id: "task6-provider",
        acquisition_method: "oauth_user",
        provider_fingerprint: "task7-driver-v1",
        implementation: FakeDriverAlpha,
        backend_pair_ids: ["pair-z-local-v1"],
        metadata: FakeDriverAlpha.declaration_metadata()
      })

    assert DriverRegistry.register(owner, driver) in [:acquired, :existing_identical]

    on_exit(fn ->
      DriverRegistry.unregister_owner(owner)
      BackendPairRegistry.unregister_owner(owner)
      Application.delete_env(:ezagent_domain_provider_connection, :task7_test_owner)
      Application.delete_env(:ezagent_domain_provider_connection, :task7_credential_state)
      Application.delete_env(:ezagent_domain_provider_connection, :callback_redirect_pairs)

      if previous_implementations,
        do:
          Application.put_env(
            :ezagent_domain_provider_connection,
            :credential_backend_implementations,
            previous_implementations
          ),
        else:
          Application.delete_env(
            :ezagent_domain_provider_connection,
            :credential_backend_implementations
          )
    end)

    :ok
  end

  test "credential sink reuses a canonical result and rejects changed input" do
    command = %{
      correlation_id: "canonical-correlation",
      backend_pair_id: "pair-z-local-v1",
      operation_class: "store",
      connection_id: Ecto.UUID.generate(),
      credential_material: :secret
    }

    assert {:ok, first} = CallbackRecoveryCredentialSink.store(command)
    assert {:ok, ^first} = CallbackRecoveryCredentialSink.store(command)

    assert {:error, :correlation_conflict} =
             CallbackRecoveryCredentialSink.store(%{
               command
               | connection_id: Ecto.UUID.generate()
             })
  end

  test "claim is single-winner and expired lease recovery reuses the stored correlation" do
    now = ~U[2026-07-19 00:00:00.000000Z]
    attempt = insert_attempt!(now)

    parent = self()

    tasks =
      for _ <- 1..2 do
        task =
          Task.async(fn ->
            send(parent, {:claim_ready, self()})

            receive do
              :claim_go -> AuthorizationAttempt.claim(attempt.attempt_ref, now, 30)
            end
          end)

        Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), task.pid)
        task
      end

    for _ <- tasks, do: assert_receive({:claim_ready, _pid})
    Enum.each(tasks, &send(&1.pid, :claim_go))

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert [{:error, :callback_in_progress}, {:ok, first}] = Enum.sort(results)

    assert {:error, :callback_in_progress} =
             AuthorizationAttempt.claim(
               attempt.attempt_ref,
               DateTime.add(now, 29, :second),
               30
             )

    assert {:ok, recovered} =
             AuthorizationAttempt.claim(
               attempt.attempt_ref,
               DateTime.add(now, 30, :second),
               30
             )

    assert recovered.claim_token != first.claim_token
    assert recovered.attempt_version > first.attempt_version
    assert recovered.correlation_id == first.correlation_id
  end

  test "expired cancelled consumed and stale connection attempts make zero mutation" do
    now = ~U[2026-07-19 00:00:00.000000Z]

    for {status, expires_at, expected} <- [
          {"pending", DateTime.add(now, -1, :second), :callback_expired},
          {"cancelled", DateTime.add(now, 60, :second), :authorization_cancelled},
          {"consumed", DateTime.add(now, 60, :second), :callback_already_consumed}
        ] do
      attempt = insert_attempt!(now, status: status, expires_at: expires_at)
      before = Repo.get!(AuthorizationAttempt, attempt.attempt_ref)

      assert {:error, ^expected} = AuthorizationAttempt.claim(attempt.attempt_ref, now, 30)

      after_claim = Repo.get!(AuthorizationAttempt, attempt.attempt_ref)

      if status == "pending" do
        assert after_claim.status == "expired"
        assert after_claim.attempt_version == before.attempt_version + 1
      else
        assert after_claim == before
      end
    end

    stale = insert_attempt!(now, connection_version: 2)
    before = Repo.get!(AuthorizationAttempt, stale.attempt_ref)

    assert {:error, :stale_connection_version} =
             AuthorizationAttempt.claim(stale.attempt_ref, now, 30, current_connection_version: 3)

    assert Repo.get!(AuthorizationAttempt, stale.attempt_ref) == before
    assert FakeDriverAlpha.provider_effect_count() == 0

    owner = Ezagent.URI.user("acme", "downstream-fence-owner")
    ctx = %{self_uri: owner, now: now}

    for {attempt_status, expires_at, attempt_version, connection_status, expected} <- [
          {"cancelled", DateTime.add(now, 60, :second), 1, "pending_authorization",
           :authorization_cancelled},
          {"pending", DateTime.add(now, -1, :second), 1, "pending_authorization",
           :callback_expired},
          {"pending", DateTime.add(now, 60, :second), 0, "pending_authorization",
           :stale_connection_version},
          {"pending", DateTime.add(now, 60, :second), 1, "revoked", :connection_terminal}
        ] do
      connection = insert_connection!(owner, connection_status, 1)

      attempt =
        insert_attempt!(now,
          connection_id: connection.connection_id,
          connection_version: attempt_version,
          status: attempt_status,
          expires_at: expires_at
        )

      assert {:error, ^expected} =
               Store.execute(
                 :consume_callback,
                 %{attempt_ref: attempt.attempt_ref, correlation_id: attempt.correlation_id},
                 ctx
               )
    end

    assert FakeDriverAlpha.provider_effect_count() == 0
    refute_receive {:credential_effect, _, _, _}
  end

  test "registered pair handoff accepts no caller command and Task 7 exposes no finalizer" do
    Code.ensure_loaded!(LocalAuthorizationBackend)
    refute function_exported?(LocalAuthorizationBackend, :handoff_to_credential_backend, 6)
    refute function_exported?(LocalAuthorizationBackend, :handoff_to_credential_backend, 5)
    assert function_exported?(LocalAuthorizationBackend, :handoff_to_registered_credential, 2)
    refute function_exported?(LocalAuthorizationBackend, :finalize_handoff, 4)
    refute function_exported?(Store, :consume_handoff, 5)
    refute function_exported?(Store, :finalize_callback, 1)
    refute function_exported?(Store, :finalize_callback, 2)
    Process.put(:task7_test_owner, self())
    assert {:ok, started} = LocalAuthorizationBackend.begin_authorization(begin_request())
    _connection = ensure_finalize_connection!(started.authorization_ref)
    attempt = insert_finalize_attempt!(started.authorization_ref, "consume-handoff-1")
    operation = insert_finalize_operation!(attempt, nil)

    callback = %{
      authorization_ref: started.authorization_ref,
      callback_envelope: %{
        state: started.redirect["state"],
        pkce_digest: started.redirect["pkce_digest"],
        governed_host: "example.test",
        external_account_id: "acct-1",
        acquisition_origin: :repository_consent
      },
      expected_subject: subject(),
      correlation_id: "consume-handoff-1"
    }

    assert {:ok, %{credential_material: {:write_only_handoff, handoff_ref}} = callback_result} =
             LocalAuthorizationBackend.consume_callback(callback)

    assert {:ok, %{credential_material: {:write_only_handoff, ^handoff_ref}}} =
             LocalAuthorizationBackend.consume_callback(callback)

    assert FakeDriverAlpha.provider_effect_count() == 2

    operation = journal_provider_fixture!(operation, callback_result)

    assert {:ok, result} =
             LocalAuthorizationBackend.handoff_to_registered_credential(
               operation.id,
               attempt.attempt_ref
             )

    assert result == %{credential_ref: "credential-ref-1", credential_version: 1}
    credential_correlation = operation.correlation_id

    assert_receive {:credential_effect, :store, "TASK6_DRIVER_OWNED_CREDENTIAL",
                    ^credential_correlation}

    refute inspect(result) =~ "TASK6_DRIVER_OWNED_CREDENTIAL"

    row =
      Repo.get_by!(AuthorizationBackendRecord, authorization_ref: started.authorization_ref)

    assert is_binary(row.handoff_ciphertext)
    assert row.shredded_at == nil

    assert is_binary(Repo.get!(AuthorizationBackendRecord, row.id).handoff_ciphertext)
    assert Repo.get!(AuthorizationAttempt, attempt.attempt_ref).status == "consuming"
    assert Repo.get!(Operation, operation.id).status == "prepared"
  after
    Process.delete(:task7_test_owner)
  end

  test "reauthorization uses one exact replace effect and completed retry is stable" do
    now = DateTime.utc_now()
    owner = Ezagent.URI.user("acme", "replace-orchestration-owner")

    connection =
      insert_connection!(owner, "active", 7)
      |> Ecto.Changeset.change(
        authorization_backend_ref: "authorization-ref-current",
        authorization_version: 4,
        credential_backend_ref: "credential-ref-current",
        credential_version: 3,
        backend_pair_id: "pair-z-local-v1",
        authorization_backend_id: "local-authorization-v1",
        credential_backend_id: "credential-alpha-v1"
      )
      |> Repo.update!()

    {:ok, started} =
      LocalAuthorizationBackend.begin_authorization(
        reconciliation_begin_request(connection, owner, "replace-orchestration")
      )

    callback = callback_request(started, connection, owner, "replace-orchestration-callback")

    :ok =
      LocalAuthorizationBackend.stage_callback(
        "pair-z-local-v1",
        started.authorization_ref,
        callback.correlation_id,
        callback.callback_envelope.state,
        Map.delete(callback.callback_envelope, :state)
      )

    backend_record =
      Repo.get_by!(AuthorizationBackendRecord, authorization_ref: started.authorization_ref)

    attempt =
      insert_attempt!(now,
        connection_id: connection.connection_id,
        connection_version: connection.connection_version,
        correlation_id: callback.correlation_id,
        authorization_ref: started.authorization_ref,
        backend_pair_id: "pair-z-local-v1",
        bound_subject_digest: backend_record.bound_input_digest
      )

    args = %{attempt_ref: attempt.attempt_ref, correlation_id: attempt.correlation_id}
    ctx = %{self_uri: owner, now: now}

    assert {:ok, receipt} = Store.execute(:consume_callback, args, ctx)
    assert {:ok, ^receipt} = Store.execute(:consume_callback, args, ctx)

    operation = Repo.get_by!(Operation, correlation_id: "replace:#{attempt.correlation_id}")

    credential_state =
      Application.fetch_env!(:ezagent_domain_provider_connection, :task7_credential_state)

    assert operation.operation_class == "replace"
    assert operation.expected_connection_version == 7
    assert operation.expected_authorization_ref == attempt.authorization_ref
    assert operation.expected_authorization_version == 4
    assert operation.expected_credential_version == 3
    assert operation.prior_credential_ref == "credential-ref-current"
    assert operation.prior_credential_version == 3
    assert operation.provider_result_ref == Repo.reload!(operation).provider_result_ref
    assert operation.result_ref == Repo.reload!(operation).result_ref

    assert [effect] = Agent.get(credential_state, &Map.get(&1, :effects, []))
    assert effect.kind == :replace
    assert effect.command.operation_class == "replace"
    assert effect.command.operation_id == operation.id
    assert effect.command.correlation_id == operation.correlation_id
    assert effect.command.command_digest == operation.bound_input_digest
    assert effect.command.expected_authorization_ref == operation.expected_authorization_ref

    assert effect.command.expected_authorization_version ==
             operation.expected_authorization_version

    assert effect.command.expected_credential_version == operation.expected_credential_version
    assert effect.command.prior_credential_ref == operation.prior_credential_ref
    assert effect.command.prior_credential_version == operation.prior_credential_version
    assert Agent.get(credential_state, & &1.logical_effects) == 1

    discard_context = %{
      owner_uri: connection.owner_uri,
      workspace_uri: connection.workspace_uri,
      provider_id: connection.provider_id,
      acquisition_method: connection.acquisition_method,
      governed_host: connection.governed_host,
      backend_pair_id: operation.backend_pair_id,
      operation_id: operation.id,
      connection_id: operation.connection_id,
      expected_connection_version: operation.expected_connection_version,
      attempt_ref: attempt.attempt_ref,
      authorization_ref: operation.expected_authorization_ref,
      expected_authorization_version: operation.expected_authorization_version,
      correlation_id: operation.correlation_id,
      command_digest: operation.bound_input_digest,
      expected_credential_version: operation.expected_credential_version,
      provider_result_ref: operation.provider_result_ref,
      discard_idempotency_key: operation.correlation_id <> ":provider-discard"
    }

    assert :ok = FakeDriverAlpha.discard_callback_result(discard_context)
    assert :ok = FakeDriverAlpha.discard_callback_result(discard_context)

    assert {:error, :correlation_conflict} =
             FakeDriverAlpha.discard_callback_result(%{
               discard_context
               | provider_result_ref: "cross-result"
             })

    assert {:error, :correlation_conflict} =
             FakeDriverAlpha.discard_callback_result(%{
               discard_context
               | connection_id: Ecto.UUID.generate()
             })

    assert FakeDriverAlpha.provider_discard_effect_count() == 1
    assert FakeDriverAlpha.whole_connection_revoke_count() == 0
  end

  test "historical successful initial bind remains a terminal proof for revoke and disconnect" do
    for action <- [:revoke, :disconnect] do
      %{connection: connection, attempt: attempt, operation: operation, record: record} =
        establish_successful_callback!(action)

      assert attempt.status == "consumed"
      assert %DateTime{} = attempt.consumed_at
      assert operation.status == "finalized"
      assert record.lifecycle_status == "shredded"

      current = Repo.get!(Connection, connection.connection_id)

      result =
        Store.execute(
          action,
          %{connection_id: current.connection_id, expected_version: current.connection_version},
          %{self_uri: Ezagent.URI.new!(current.owner_uri)}
        )

      assert {:ok, %{status: terminal}} = result

      assert terminal == if(action == :revoke, do: "revoked", else: "disconnected")
    end
  end

  test "historical callback proof accepts a monotonic descendant and rejects immutable drift" do
    %{connection: connection, operation: operation} =
      establish_successful_callback!(:descendant)

    descendant =
      Connection
      |> Repo.get!(connection.connection_id)
      |> Ecto.Changeset.change(
        connection_version: operation.expected_connection_version + 5,
        authorization_version: operation.result_authorization_version + 2,
        credential_version: operation.result_credential_version + 2,
        authorization_backend_ref: "authorization-ref-descendant",
        credential_backend_ref: "credential-ref-descendant"
      )
      |> Repo.update!()

    assert {:ok, %{status: "disconnected"}} =
             Store.execute(
               :disconnect,
               %{
                 connection_id: descendant.connection_id,
                 expected_version: descendant.connection_version
               },
               %{self_uri: Ezagent.URI.new!(descendant.owner_uri)}
             )

    %{connection: drift_connection, operation: drift_operation} =
      establish_successful_callback!(:drift)

    drift_operation
    |> Ecto.Changeset.change(bound_input_digest: "historical-digest-drift")
    |> Repo.update!()

    current = Repo.get!(Connection, drift_connection.connection_id)

    assert {:error, :authorization_backend_unavailable} =
             Store.execute(
               :revoke,
               %{
                 connection_id: current.connection_id,
                 expected_version: current.connection_version
               },
               %{self_uri: Ezagent.URI.new!(current.owner_uri)}
             )

    assert Repo.get!(Connection, current.connection_id).status == "revoking"
  end

  test "credential handoff rejects execution-identity drift before the credential effect" do
    {:ok, started} = LocalAuthorizationBackend.begin_authorization(begin_request())
    _connection = ensure_finalize_connection!(started.authorization_ref)
    attempt = insert_finalize_attempt!(started.authorization_ref, "consume-scope-drift")
    operation = insert_finalize_operation!(attempt, nil)

    callback = %{
      authorization_ref: started.authorization_ref,
      callback_envelope: %{
        state: started.redirect["state"],
        pkce_digest: started.redirect["pkce_digest"],
        governed_host: "example.test",
        external_account_id: "acct-1",
        acquisition_origin: :repository_consent
      },
      expected_subject: subject(),
      correlation_id: "consume-scope-drift"
    }

    assert {:ok, callback_result} = LocalAuthorizationBackend.consume_callback(callback)
    operation = journal_provider_fixture!(operation, callback_result)

    backend_record =
      Repo.get_by!(AuthorizationBackendRecord, authorization_ref: started.authorization_ref)

    backend_record
    |> Ecto.Changeset.change(execution_identity: "installation_service")
    |> Repo.update!()

    assert {:error, :credential_conflict} =
             LocalAuthorizationBackend.handoff_to_registered_credential(
               operation.id,
               attempt.attempt_ref
             )

    assert {:error, :credential_conflict} =
             Store.execute(
               :consume_callback,
               %{attempt_ref: attempt.attempt_ref, correlation_id: callback.correlation_id},
               %{self_uri: subject().owner_uri}
             )

    refute_receive {:credential_effect, _, _, _}
  end

  test "backend-committed retry without its authority record fails closed" do
    Code.ensure_loaded!(Operation)
    refute function_exported?(Operation, :advance_changeset, 2)
    refute function_exported?(Operation, :advance_changeset, 3)
    refute function_exported?(Operation, :advance_changeset, 2)

    owner = Ezagent.URI.user("acme", "recovery-owner")
    workspace = Ezagent.URI.workspace("acme")
    connection_id = Ecto.UUID.generate()
    correlation_id = "recovery-correlation"

    connection =
      %{
        connection_id: connection_id,
        workspace_uri: URI.to_string(workspace),
        owner_uri: URI.to_string(owner),
        provider_id: "task6-provider",
        governed_host: "example.test",
        requested_execution_identity_class: "connected_user",
        acquisition_method: "oauth_user",
        status: "pending_authorization"
      }
      |> Connection.create_changeset()
      |> Ecto.Changeset.change(connection_version: 1)
      |> Repo.insert!()

    attempt =
      insert_attempt!(DateTime.utc_now(),
        connection_id: connection_id,
        correlation_id: correlation_id
      )
      |> Ecto.Changeset.change(
        status: "consuming",
        claim_token: "recovery-claim",
        claim_until: DateTime.add(DateTime.utc_now(), 30, :second),
        attempt_version: 1
      )
      |> Repo.update!()

    operation =
      Operation.store_create_changeset(attempt, connection, %{
        operation_class: "store",
        correlation_id: "store:#{attempt.correlation_id}",
        bound_input_digest: "durable-result-digest",
        next_recovery_at: DateTime.utc_now(),
        status: "prepared"
      })
      |> Repo.insert!()

    operation =
      operation
      |> Operation.provider_ownership_changeset(%{
        handoff_ref: "handoff",
        result_external_account_id: "acct-1",
        result_display_login: "alice-alpha",
        result_execution_identity: "connected_user",
        result_authorization_ref: attempt.authorization_ref,
        result_authorization_version: 1,
        provider_result_ref: "provider-result-recovery",
        result_permission_digest: "permissions-recovery",
        result_expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
      })
      |> Repo.update!()

    operation
    |> Operation.credential_ownership_changeset("backend_committed", %{
      result_ref: "credential-ref-durable",
      result_credential_version: 7
    })
    |> Repo.update!()

    ctx = %{self_uri: owner, now: DateTime.utc_now()}
    args = %{attempt_ref: attempt.attempt_ref, correlation_id: correlation_id}

    assert {:error, :credential_conflict} = Store.execute(:consume_callback, args, ctx)
    assert {:error, :credential_conflict} = Store.execute(:consume_callback, args, ctx)
    assert FakeDriverAlpha.provider_effect_count() == 0

    assert {:error, :correlation_conflict} =
             Store.execute(
               :consume_callback,
               %{args | correlation_id: "different-correlation"},
               ctx
             )
  end

  test "worker death after credential commit recovers the same prepared operation after lease expiry" do
    owner = Ezagent.URI.user("acme", "orchestration-owner")
    workspace = Ezagent.URI.workspace("acme")
    connection_id = Ecto.UUID.generate()

    assert {:ok, _user} = Ezagent.Users.create(owner, nil, [])
    assert {:ok, pid} = Ezagent.SpawnRegistry.spawn(owner)
    _state = :sys.get_state(pid)

    connection =
      %{
        connection_id: connection_id,
        workspace_uri: URI.to_string(workspace),
        owner_uri: URI.to_string(owner),
        provider_id: "task6-provider",
        governed_host: "example.test",
        requested_execution_identity_class: "connected_user",
        acquisition_method: "oauth_user",
        status: "pending_authorization"
      }
      |> Connection.create_changeset()
      |> Repo.insert!()

    subject = %{
      owner_uri: owner,
      workspace_uri: workspace,
      provider_id: connection.provider_id,
      governed_host: connection.governed_host,
      connection_id: connection.connection_id,
      connection_version: connection.connection_version,
      execution_identity:
        connection.execution_identity || connection.requested_execution_identity_class
    }

    assert {:ok, started} =
             LocalAuthorizationBackend.begin_authorization(%{
               subject: subject,
               acquisition_method: connection.acquisition_method,
               requested_permissions_digest: "requested-digest",
               redirect_uri_id: "callback-v1",
               correlation_id: "begin-orchestration"
             })

    raw_state = started.redirect["state"]
    {:ok, state_digest} = LocalAuthorizationBackend.state_digest(raw_state)
    artifact = callback_artifact(owner)

    backend_record =
      Repo.get_by!(AuthorizationBackendRecord, authorization_ref: started.authorization_ref)

    artifact_digest = Ezagent.ProviderConnection.CallbackBinding.artifact_digest(artifact)

    reservation_coordinates = %{
      requested_execution_identity_class: "connected_user",
      requested_permission_digest: "requested-digest",
      redirect_uri_id: "callback-v1"
    }

    attempt =
      %{
        attempt_ref: Ecto.UUID.generate(),
        workspace_uri: connection.workspace_uri,
        backend_pair_id: "pair-z-local-v1",
        authorization_ref: started.authorization_ref,
        connection_id: connection.connection_id,
        connection_version: connection.connection_version,
        purpose: "initial_bind",
        reservation_digest:
          Ezagent.ProviderConnection.CallbackBinding.reservation_digest(
            "initial_bind",
            connection,
            reservation_coordinates,
            backend_record.begin_correlation_id,
            artifact_digest
          ),
        requested_permission_digest: "requested-digest",
        requested_execution_identity_class: "connected_user",
        redirect_uri_id: "callback-v1",
        callback_artifact_digest: artifact_digest,
        bound_subject_digest: backend_record.bound_input_digest,
        state_digest: state_digest,
        correlation_id: "callback-orchestration",
        callback_artifact: Ezagent.Capability.to_map(artifact),
        status: "pending",
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
      }
      |> AuthorizationAttempt.create_changeset()
      |> Repo.insert!()

    envelope = %{
      code: "provider-code",
      pkce_digest: started.redirect["pkce_digest"],
      governed_host: connection.governed_host,
      external_account_id: "acct-1",
      acquisition_origin: :repository_consent
    }

    credential_state =
      Application.fetch_env!(:ezagent_domain_provider_connection, :task7_credential_state)

    Agent.update(credential_state, &%{&1 | block_once?: true})

    Code.ensure_loaded!(Ezagent.Router)
    :erlang.trace_pattern({Ezagent.Router, :dispatch, 1}, true, [:local])
    parent = self()
    tracer = spawn(fn -> collect_traces(parent, 0) end)

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        receive do
          :go ->
            send(
              parent,
              {:first_ingress_result, CallbackIngress.consume("callback-v1", raw_state, envelope)}
            )
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), caller)
    :erlang.trace(caller, true, [:call, {:tracer, tracer}])
    send(caller, :go)

    assert_receive {:credential_committed_without_response, ^pid, credential_correlation, result}

    prepared = Repo.get_by!(Operation, correlation_id: credential_correlation)
    claimed = Repo.get!(AuthorizationAttempt, attempt.attempt_ref)
    assert prepared.status == "prepared"
    assert is_binary(prepared.handoff_ref)

    assert {:error, :callback_in_progress} =
             Store.execute(
               :consume_callback,
               %{attempt_ref: attempt.attempt_ref, correlation_id: attempt.correlation_id},
               %{self_uri: owner, now: DateTime.utc_now()}
             )

    assert Agent.get(credential_state, & &1.invocations) == 1

    worker_monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^worker_monitor, :process, ^pid, _reason}
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, _reason}

    expired_claim =
      claimed
      |> Ecto.Changeset.change(claim_until: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()

    restarted_pid =
      case Ezagent.SpawnRegistry.spawn(owner) do
        {:ok, restarted_pid} ->
          restarted_pid

        {:error, {:already_registered, _uri}} ->
          assert {:ok, restarted_pid} = Ezagent.KindRegistry.lookup(owner)
          restarted_pid
      end

    _state = :sys.get_state(restarted_pid)
    assert Ezagent.ReadyGate.status(owner) == :ready

    :erlang.trace(self(), true, [:call, {:tracer, tracer}])
    assert {:ok, recovered} = CallbackIngress.consume("callback-v1", raw_state, envelope)
    assert recovered.status == "active"

    committed = Repo.get!(Operation, prepared.id)
    recovered_attempt = Repo.get!(AuthorizationAttempt, attempt.attempt_ref)
    assert committed.id == prepared.id
    assert committed.bound_input_digest == prepared.bound_input_digest
    assert committed.handoff_ref == prepared.handoff_ref
    assert is_binary(committed.provider_result_ref)
    assert committed.result_ref == result.credential_ref
    assert committed.status == "finalized"
    assert committed.expected_credential_version == connection.credential_version
    assert committed.result_credential_version == result.credential_version
    assert is_nil(recovered_attempt.claim_token)
    assert recovered_attempt.attempt_version == expired_claim.attempt_version + 1
    assert committed.attempt_version == recovered_attempt.attempt_version

    assert FakeDriverAlpha.provider_effect_count() == 2
    assert Agent.get(credential_state, & &1.logical_effects) == 1
    assert Agent.get(credential_state, & &1.invocations) == 2
    assert Repo.get!(AuthorizationAttempt, attempt.attempt_ref).status == "consumed"

    assert {:ok, ^recovered} = CallbackIngress.consume("callback-v1", raw_state, envelope)

    replayed_operation = Repo.get!(Operation, prepared.id)
    assert replayed_operation.provider_result_ref == committed.provider_result_ref
    assert replayed_operation.result_authorization_ref == committed.result_authorization_ref

    assert replayed_operation.result_authorization_version ==
             committed.result_authorization_version

    assert Agent.get(credential_state, & &1.logical_effects) == 1

    send(tracer, {:stop, self()})
    assert_receive {:trace_count, 3}
  after
    :erlang.trace(self(), false, [:call])
    :erlang.trace_pattern({Ezagent.Router, :dispatch, 1}, false, [:local])
  end

  test "credential result is journaled as cleanup pending when the claim fence is lost" do
    now = DateTime.utc_now()
    owner = Ezagent.URI.user("acme", "lost-fence-owner")
    connection = insert_connection!(owner, "pending_authorization", 1)

    {:ok, started} =
      LocalAuthorizationBackend.begin_authorization(begin_request(connection, owner))

    callback = callback_request(started, connection, owner, "lost-fence-correlation")

    :ok =
      LocalAuthorizationBackend.stage_callback(
        "pair-z-local-v1",
        started.authorization_ref,
        callback.correlation_id,
        callback.callback_envelope.state,
        Map.delete(callback.callback_envelope, :state)
      )

    attempt =
      insert_attempt!(now,
        connection_id: connection.connection_id,
        connection_version: connection.connection_version,
        correlation_id: callback.correlation_id,
        authorization_ref: started.authorization_ref,
        backend_pair_id: "pair-z-local-v1",
        bound_subject_digest:
          Repo.get_by!(AuthorizationBackendRecord,
            authorization_ref: started.authorization_ref
          ).bound_input_digest
      )

    credential_state =
      Application.fetch_env!(:ezagent_domain_provider_connection, :task7_credential_state)

    Agent.update(credential_state, fn state ->
      hook = fn command ->
        attempt = Repo.get!(AuthorizationAttempt, command.attempt_ref)

        attempt
        |> Ecto.Changeset.change(
          claim_token: "stolen-after-effect",
          attempt_version: attempt.attempt_version + 1
        )
        |> Repo.update!()
      end

      %{state | hook: hook}
    end)

    assert {:error, :connection_terminal} =
             Store.execute(
               :consume_callback,
               %{attempt_ref: attempt.attempt_ref, correlation_id: attempt.correlation_id},
               %{self_uri: owner, now: now}
             )

    operation = Repo.get_by!(Operation, correlation_id: "store:#{attempt.correlation_id}")
    result = Agent.get(credential_state, &Map.fetch!(&1.results, operation.correlation_id))
    assert operation.status == "finalized"
    assert operation.safe_error_code == "connection_terminal"
    assert operation.provider_cleanup_status == "confirmed"
    assert operation.credential_cleanup_status == "confirmed"
    assert operation.result_ref == result.credential_ref
    assert operation.expected_credential_version == connection.credential_version
    assert operation.result_credential_version == result.credential_version
    assert operation.correlation_id == "store:#{attempt.correlation_id}"
  end

  test "terminal close wins after a real callback claim and waits for callback result cleanup" do
    now = DateTime.utc_now()
    owner = Ezagent.URI.user("acme", "terminal-race-owner")

    connection =
      insert_connection!(owner, "active", 4)
      |> Ecto.Changeset.change(
        credential_backend_ref: "credential-ref-current",
        credential_version: 2,
        backend_pair_id: "pair-z-local-v1",
        authorization_backend_id: "local-authorization-v1",
        credential_backend_id: "credential-alpha-v1"
      )
      |> Repo.update!()

    {:ok, started} =
      LocalAuthorizationBackend.begin_authorization(begin_request(connection, owner))

    callback = callback_request(started, connection, owner, "terminal-race-callback")

    :ok =
      LocalAuthorizationBackend.stage_callback(
        "pair-z-local-v1",
        started.authorization_ref,
        callback.correlation_id,
        callback.callback_envelope.state,
        Map.delete(callback.callback_envelope, :state)
      )

    backend_record =
      Repo.get_by!(AuthorizationBackendRecord, authorization_ref: started.authorization_ref)

    attempt =
      insert_attempt!(now,
        connection_id: connection.connection_id,
        connection_version: connection.connection_version,
        correlation_id: callback.correlation_id,
        authorization_ref: started.authorization_ref,
        backend_pair_id: "pair-z-local-v1",
        bound_subject_digest: backend_record.bound_input_digest
      )

    parent = self()

    credential_state =
      Application.fetch_env!(:ezagent_domain_provider_connection, :task7_credential_state)

    Agent.update(credential_state, fn state ->
      hook = fn command ->
        send(parent, {:callback_effect_committed, self(), command})

        receive do
          :release_callback_effect -> :ok
        end
      end

      %{state | hook: hook}
    end)

    callback_task =
      Task.async(fn ->
        receive do
          :go ->
            Store.execute(
              :consume_callback,
              %{attempt_ref: attempt.attempt_ref, correlation_id: attempt.correlation_id},
              %{self_uri: owner, now: now}
            )
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), callback_task.pid)
    send(callback_task.pid, :go)

    assert_receive {:callback_effect_committed, callback_worker, command}

    assert {:error, :authorization_backend_unavailable} =
             Store.execute(
               :revoke,
               %{connection_id: connection.connection_id, expected_version: 4},
               %{self_uri: owner}
             )

    closing = Repo.get!(Connection, connection.connection_id)
    assert closing.status == "revoking"
    assert closing.connection_version == 5
    assert closing.credential_backend_ref == "credential-ref-current"

    terminal_operations =
      Repo.all(
        from(o in Operation,
          where: o.connection_id == ^connection.connection_id and o.operation_class == "revoke"
        )
      )

    assert Enum.all?(terminal_operations, &(&1.status == "backend_committed"))

    send(callback_worker, :release_callback_effect)
    assert {:error, :connection_terminal} = Task.await(callback_task)

    callback_operation =
      Repo.get_by!(Operation,
        backend_pair_id: "pair-z-local-v1",
        operation_class: callback_operation_class(attempt),
        correlation_id: "#{callback_operation_class(attempt)}:#{attempt.correlation_id}"
      )

    callback_result = Agent.get(credential_state, &Map.fetch!(&1.results, command.correlation_id))
    assert callback_operation.status == "finalized"
    assert callback_operation.result_ref == callback_result.credential_ref

    assert {:ok, %{status: "revoked", version: 6}} =
             Store.execute(
               :revoke,
               %{connection_id: connection.connection_id, expected_version: 4},
               %{self_uri: owner}
             )

    revoked_refs =
      Agent.get(credential_state, &Enum.map(&1.revocations, fn call -> call.credential_ref end))

    assert "credential-ref-current" in revoked_refs
    assert callback_operation.result_ref in revoked_refs
  end

  test "terminal reconciles a provider effect after worker death and cleans its exact result" do
    %{connection: connection, attempt: attempt, operation: operation} =
      crash_after_provider_effect!("reconcile-confirmed", 10)

    terminal_result =
      run_unboxed(fn ->
        expire_claim!(attempt)

        Store.execute(
          :revoke,
          %{connection_id: connection.connection_id, expected_version: 10},
          %{self_uri: Ezagent.URI.new!(connection.owner_uri)}
        )
      end)

    assert {:ok, %{status: "revoked", version: 12}} = terminal_result

    recovered = Repo.get!(Operation, operation.id)
    assert recovered.status == "finalized"
    assert is_binary(recovered.result_ref)

    assert Repo.get!(Connection, connection.connection_id).credential_backend_ref ==
             "credential-ref-current"

    credential_state =
      Application.fetch_env!(:ezagent_domain_provider_connection, :task7_credential_state)

    revocations = Agent.get(credential_state, & &1.revocations)
    revoked_refs = Enum.map(revocations, & &1.credential_ref)

    assert "credential-ref-current" in revoked_refs
    assert recovered.result_ref in revoked_refs

    assert Enum.any?(revocations, fn call ->
             call.credential_ref == recovered.result_ref and
               call.expected_credential_version == recovered.result_credential_version and
               call.correlation_id == operation.correlation_id <> ":terminal-cleanup"
           end)

    assert FakeDriverAlpha.provider_effect_count(:consume) == 1
  end

  test "reconciliation seals the same handoff before the provider ownership journal" do
    %{connection: connection, attempt: attempt, operation: operation} =
      crash_after_provider_effect!("reconcile-atomic-bind", 40)

    run_unboxed(fn ->
      connection
      |> Repo.reload!()
      |> Ecto.Changeset.change(status: "revoking", connection_version: 41)
      |> Repo.update!()

      expire_claim!(attempt)
    end)

    parent = self()

    worker =
      spawn(fn ->
        result =
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            LocalAuthorizationBackend.reconcile_callback(operation.id, attempt.attempt_ref)
          end)

        send(parent, {:reconciliation_committed, self(), result})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:reconciliation_committed, ^worker,
                    {:ok, %{credential_material: {:write_only_handoff, handoff_ref}}}},
                   5_000

    Process.exit(worker, :kill)
    assert Repo.get!(Operation, operation.id).handoff_ref == nil

    assert {:ok, %{credential_material: {:write_only_handoff, ^handoff_ref}}} =
             run_unboxed(fn ->
               LocalAuthorizationBackend.reconcile_callback(operation.id, attempt.attempt_ref)
             end)

    sealed =
      Repo.get_by!(AuthorizationBackendRecord, authorization_ref: attempt.authorization_ref)

    assert sealed.lifecycle_status == "consumed"
    assert is_binary(sealed.handoff_ciphertext)

    assert {:error, :credential_conflict} =
             run_unboxed(fn ->
               Ezagent.ProviderConnection.CredentialReplacement.fence(operation.id)
             end)

    still_sealed = Repo.get!(AuthorizationBackendRecord, sealed.id)
    assert still_sealed.lifecycle_status == "consumed"
    assert still_sealed.handoff_ciphertext == sealed.handoff_ciphertext

    assert :ok =
             run_unboxed(fn ->
               Ezagent.ProviderConnection.CredentialReplacement.reconcile(operation.id)
             end)

    journaled = Repo.get!(Operation, operation.id)
    assert journaled.handoff_ref == handoff_ref
    assert is_binary(journaled.provider_result_ref)
    assert journaled.status == "finalized"

    command =
      Repo.get_by!(ProviderAuthorizationCommand,
        backend_pair_id: operation.backend_pair_id,
        operation_class: "consume",
        correlation_id: attempt.correlation_id
      )

    assert command.status == "committed"
  end

  test "terminal fences a reconciled confirmed absence" do
    %{connection: connection, attempt: attempt, operation: operation} =
      crash_before_provider_effect!("reconcile-absent", 20)

    assert FakeDriverAlpha.provider_effect_count(:consume) == 0

    assert {:ok, %{status: "revoked", version: 22}} =
             run_unboxed(fn ->
               expire_claim!(attempt)

               Store.execute(
                 :revoke,
                 %{connection_id: connection.connection_id, expected_version: 20},
                 %{self_uri: Ezagent.URI.new!(connection.owner_uri)}
               )
             end)

    assert Repo.get!(Operation, operation.id).status == "fenced"

    command =
      Repo.get_by!(ProviderAuthorizationCommand,
        backend_pair_id: operation.backend_pair_id,
        operation_class: "consume",
        correlation_id: attempt.correlation_id
      )

    assert command.status == "terminal_failed"
    assert command.safe_error_code == "not_completed"

    backend_record =
      Repo.get_by!(AuthorizationBackendRecord, authorization_ref: attempt.authorization_ref)

    assert backend_record.lifecycle_status == "cancelled"
    assert backend_record.handoff_ref == nil
    assert backend_record.handoff_ciphertext == nil
    assert backend_record.shredded_at == nil
  end

  test "ambiguous callback reconciliation leaves the connection closing and recoverable" do
    %{connection: connection, attempt: attempt, operation: operation} =
      crash_after_provider_effect!("reconcile-ambiguous", 30)

    :ok = FakeDriverAlpha.set_reconciliation(attempt.correlation_id, :ambiguous)

    args = %{connection_id: connection.connection_id, expected_version: 30}
    ctx = %{self_uri: Ezagent.URI.new!(connection.owner_uri)}

    assert [
             {:error, :authorization_backend_unavailable},
             {:error, :authorization_backend_unavailable}
           ] =
             run_unboxed(fn ->
               expire_claim!(attempt)
               [Store.execute(:revoke, args, ctx), Store.execute(:revoke, args, ctx)]
             end)

    assert Repo.get!(Connection, connection.connection_id).status == "revoking"
    assert Repo.get!(Operation, operation.id).status == "prepared"
  end

  test "terminal retry rechecks callback set after acquiring the connection lock" do
    now = DateTime.utc_now()
    owner = Ezagent.URI.user("acme", "terminal-insert-race-owner")

    %{connection: connection, attempt: attempt} =
      run_unboxed(fn ->
        fixture = persist_reconciliation_fixture(now, owner, "terminal-insert-race", 70)

        closing =
          fixture.connection
          |> Ecto.Changeset.change(status: "revoking", connection_version: 71)
          |> Repo.update!()

        Enum.each(["provider", "credential"], fn obligation ->
          attrs = %{
            workspace_uri: closing.workspace_uri,
            connection_id: closing.connection_id,
            backend_pair_id: closing.backend_pair_id,
            operation_class: "revoke",
            correlation_id: "termination:revoke:#{closing.connection_id}:70:#{obligation}",
            bound_input_digest: termination_digest(closing, closing.backend_pair_id, :revoke, 70),
            expected_connection_version: 70,
            expected_credential_version: closing.credential_version,
            next_recovery_at: now,
            status: "backend_committed"
          }

          changeset = Operation.create_changeset(attrs)

          changeset =
            if obligation == "credential",
              do: Ecto.Changeset.change(changeset, handoff_ref: closing.credential_backend_ref),
              else: changeset

          Repo.insert!(changeset)
        end)

        fixture
      end)

    on_exit(fn ->
      cleanup_reconciliation_fixture(connection.connection_id, attempt.authorization_ref)
    end)

    parent = self()

    holder =
      spawn(fn ->
        result =
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              locked =
                Connection
                |> where([row], row.connection_id == ^connection.connection_id)
                |> lock("FOR UPDATE")
                |> Repo.one!()

              send(parent, {:terminal_race_lock_held, self()})

              receive do
                :insert_callback_obligation ->
                  locked_attempt = Repo.get!(AuthorizationAttempt, attempt.attempt_ref)

                  record =
                    Repo.get_by!(AuthorizationBackendRecord,
                      authorization_ref: locked_attempt.authorization_ref
                    )

                  base = %{locked | connection_version: 70, status: "active"}

                  Repo.insert!(
                    Operation.store_create_changeset(locked_attempt, base, %{
                      operation_class: "replace",
                      correlation_id: "replace:#{locked_attempt.correlation_id}",
                      bound_input_digest: Operation.callback_digest(record, locked_attempt, base),
                      next_recovery_at: now,
                      status: "prepared"
                    })
                  )
              end
            end)
          end)

        send(parent, {:terminal_race_holder_done, self(), result})
      end)

    assert_receive {:terminal_race_lock_held, ^holder}, 5_000

    worker =
      spawn(fn ->
        result =
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            %{rows: [[backend_pid]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()")
            send(parent, {:terminal_race_worker_backend, self(), backend_pid})

            Store.execute(
              :revoke,
              %{connection_id: connection.connection_id, expected_version: 70},
              %{self_uri: owner}
            )
          end)

        send(parent, {:terminal_race_worker_done, self(), result})
      end)

    assert_receive {:terminal_race_worker_backend, ^worker, backend_pid}, 5_000
    assert_backend_waiting_on_lock!(backend_pid, 1_000)

    send(holder, :insert_callback_obligation)
    assert_receive {:terminal_race_holder_done, ^holder, {:ok, %Operation{}}}, 5_000

    assert_receive {:terminal_race_worker_done, ^worker,
                    {:error, :authorization_backend_unavailable}},
                   5_000

    assert Repo.get!(Connection, connection.connection_id).status == "revoking"

    assert Repo.get_by!(Operation, correlation_id: "replace:#{attempt.correlation_id}").status ==
             "prepared"
  end

  defp insert_attempt!(now, overrides \\ []) do
    connection_id = Keyword.get(overrides, :connection_id, Ecto.UUID.generate())
    connection_version = Keyword.get(overrides, :connection_version, 1)
    connection = ensure_attempt_connection!(connection_id, connection_version)

    callback_artifact =
      Keyword.get(overrides, :callback_artifact, %{"fixture" => "callback-recovery"})

    callback_artifact_digest = digest(callback_artifact)
    requested_permission_digest = "requested-permissions"
    requested_execution_identity_class = "connected_user"
    redirect_uri_id = "callback-v1"

    purpose =
      if connection.status == "pending_authorization", do: "initial_bind", else: "reauthorize"

    correlation_id =
      Keyword.get(
        overrides,
        :correlation_id,
        "stable-correlation-#{System.unique_integer([:positive])}"
      )

    attrs = %{
      attempt_ref: Ecto.UUID.generate(),
      workspace_uri: connection.workspace_uri,
      backend_pair_id: Keyword.get(overrides, :backend_pair_id, "pair-alpha-v1"),
      authorization_ref:
        Keyword.get(overrides, :authorization_ref, "auth-#{System.unique_integer([:positive])}"),
      connection_id: connection.connection_id,
      connection_version: connection_version,
      purpose: purpose,
      reservation_digest:
        reservation_digest(
          purpose,
          connection,
          requested_execution_identity_class,
          requested_permission_digest,
          redirect_uri_id,
          correlation_id,
          callback_artifact_digest
        ),
      requested_permission_digest: requested_permission_digest,
      requested_execution_identity_class: requested_execution_identity_class,
      redirect_uri_id: redirect_uri_id,
      callback_artifact_digest: callback_artifact_digest,
      bound_subject_digest: Keyword.get(overrides, :bound_subject_digest, "subject-digest"),
      state_digest: "state-#{System.unique_integer([:positive])}",
      correlation_id: correlation_id,
      callback_artifact: callback_artifact,
      status: Keyword.get(overrides, :status, "pending"),
      expires_at: Keyword.get(overrides, :expires_at, DateTime.add(now, 60, :second))
    }

    Repo.insert!(AuthorizationAttempt.create_changeset(attrs))
  end

  defp crash_after_provider_effect!(correlation_id, version) do
    crash_at_provider_barrier!(correlation_id, version, :consume)
  end

  defp crash_before_provider_effect!(correlation_id, version) do
    crash_at_provider_barrier!(correlation_id, version, :consume_before_effect)
  end

  defp crash_at_provider_barrier!(correlation_id, version, barrier) do
    now = DateTime.utc_now()
    correlation_id = "#{correlation_id}-#{System.unique_integer([:positive])}"
    owner = Ezagent.URI.user("acme", "#{correlation_id}-owner")

    parent = self()

    spawn(fn ->
      fixture =
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          persist_reconciliation_fixture(now, owner, correlation_id, version)
        end)

      send(parent, {:persisted_reconciliation_fixture, self(), fixture})
    end)

    assert_receive {:persisted_reconciliation_fixture, _setup_worker,
                    %{connection: connection, attempt: attempt}},
                   2_000

    on_exit(fn ->
      cleanup_reconciliation_fixture(connection.connection_id, attempt.authorization_ref)
    end)

    :ok = FakeDriverAlpha.set_barrier(barrier, self())

    worker =
      spawn(fn ->
        result =
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            Store.execute(
              :consume_callback,
              %{attempt_ref: attempt.attempt_ref, correlation_id: attempt.correlation_id},
              %{self_uri: owner, now: now}
            )
          end)

        send(parent, {:callback_worker_result, self(), result})
      end)

    monitor = Process.monitor(worker)

    receive do
      {:fake_driver_barrier, ^barrier, _worker, _context} ->
        :ok

      {:callback_worker_result, ^worker, result} ->
        current_attempt = Repo.get!(AuthorizationAttempt, attempt.attempt_ref)
        current_connection = Repo.get!(Connection, connection.connection_id)

        operation_class = callback_operation_class(attempt)

        current_operation =
          Repo.get_by(Operation, correlation_id: "#{operation_class}:#{attempt.correlation_id}")

        flunk(
          "callback exited before provider barrier: #{inspect(result)} attempt=#{inspect({current_attempt.status, current_attempt.connection_version, current_attempt.expires_at})} connection=#{inspect({current_connection.status, current_connection.connection_version, current_connection.owner_uri})} operation=#{inspect(current_operation && current_operation.status)} now=#{inspect(now)}"
        )
    after
      2_000 -> flunk("callback did not reach provider barrier")
    end

    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}

    operation_class = callback_operation_class(attempt)

    operation =
      Repo.get_by!(Operation,
        backend_pair_id: "pair-z-local-v1",
        operation_class: operation_class,
        correlation_id: "#{operation_class}:#{attempt.correlation_id}"
      )

    assert operation.status == "prepared"
    %{connection: connection, attempt: Repo.reload!(attempt), operation: operation}
  end

  defp cleanup_reconciliation_fixture(connection_id, authorization_ref) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      Repo.delete_all(from(o in Operation, where: o.connection_id == ^connection_id))

      Repo.delete_all(from(a in AuthorizationAttempt, where: a.connection_id == ^connection_id))

      Repo.delete_all(
        from(c in ProviderAuthorizationCommand,
          where: c.authorization_ref == ^authorization_ref
        )
      )

      Repo.delete_all(
        from(r in AuthorizationBackendRecord,
          where: r.authorization_ref == ^authorization_ref
        )
      )

      Repo.delete_all(from(c in Connection, where: c.connection_id == ^connection_id))
      :ok
    end)
  end

  defp run_unboxed(fun) do
    parent = self()
    ref = make_ref()

    spawn(fn ->
      result = Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
      send(parent, {ref, result})
    end)

    assert_receive {^ref, result}, 5_000
    result
  end

  defp assert_backend_waiting_on_lock!(backend_pid, attempts) when attempts > 0 do
    waiting? =
      run_unboxed(fn ->
        case Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1",
               [backend_pid]
             ).rows do
          [["Lock"]] -> true
          _other -> false
        end
      end)

    if waiting? do
      :ok
    else
      Process.sleep(5)
      assert_backend_waiting_on_lock!(backend_pid, attempts - 1)
    end
  end

  defp assert_backend_waiting_on_lock!(_backend_pid, 0),
    do: flunk("terminal worker did not block on the connection linearization lock")

  defp persist_reconciliation_fixture(now, owner, correlation_id, version) do
    connection =
      insert_connection!(owner, "active", version)
      |> Ecto.Changeset.change(
        credential_backend_ref: "credential-ref-current",
        credential_version: 4,
        backend_pair_id: "pair-z-local-v1",
        authorization_backend_id: "local-authorization-v1",
        credential_backend_id: "credential-alpha-v1"
      )
      |> Repo.update!()

    {:ok, started} =
      LocalAuthorizationBackend.begin_authorization(
        reconciliation_begin_request(connection, owner, correlation_id)
      )

    callback = callback_request(started, connection, owner, correlation_id)

    :ok =
      LocalAuthorizationBackend.stage_callback(
        "pair-z-local-v1",
        started.authorization_ref,
        callback.correlation_id,
        callback.callback_envelope.state,
        Map.delete(callback.callback_envelope, :state)
      )

    backend_record =
      Repo.get_by!(AuthorizationBackendRecord, authorization_ref: started.authorization_ref)

    attempt =
      insert_attempt!(now,
        connection_id: connection.connection_id,
        connection_version: connection.connection_version,
        correlation_id: callback.correlation_id,
        authorization_ref: started.authorization_ref,
        backend_pair_id: "pair-z-local-v1",
        bound_subject_digest: backend_record.bound_input_digest
      )

    %{connection: connection, attempt: attempt}
  end

  defp establish_successful_callback!(tag) do
    now = DateTime.utc_now()
    suffix = "#{tag}-#{System.unique_integer([:positive])}"
    owner = Ezagent.URI.user("acme", "historical-winner-#{suffix}")
    connection = insert_connection!(owner, "pending_authorization", 0)

    {:ok, started} =
      LocalAuthorizationBackend.begin_authorization(
        reconciliation_begin_request(connection, owner, "historical-winner-#{suffix}")
      )

    callback = callback_request(started, connection, owner, "historical-callback-#{suffix}")

    :ok =
      LocalAuthorizationBackend.stage_callback(
        "pair-z-local-v1",
        started.authorization_ref,
        callback.correlation_id,
        callback.callback_envelope.state,
        Map.delete(callback.callback_envelope, :state)
      )

    backend_record =
      Repo.get_by!(AuthorizationBackendRecord, authorization_ref: started.authorization_ref)

    attempt =
      insert_attempt!(now,
        connection_id: connection.connection_id,
        connection_version: connection.connection_version,
        correlation_id: callback.correlation_id,
        authorization_ref: started.authorization_ref,
        backend_pair_id: "pair-z-local-v1",
        bound_subject_digest: backend_record.bound_input_digest
      )

    assert {:ok, %{status: "active"}} =
             Store.execute(
               :consume_callback,
               %{attempt_ref: attempt.attempt_ref, correlation_id: attempt.correlation_id},
               %{self_uri: owner, now: now}
             )

    operation = Repo.get_by!(Operation, correlation_id: "store:#{attempt.correlation_id}")

    %{
      connection: Repo.get!(Connection, connection.connection_id),
      attempt: Repo.get!(AuthorizationAttempt, attempt.attempt_ref),
      operation: operation,
      record: Repo.get!(AuthorizationBackendRecord, backend_record.id)
    }
  end

  defp expire_claim!(attempt) do
    attempt
    |> Repo.reload!()
    |> Ecto.Changeset.change(claim_until: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()
  end

  defp begin_request do
    %{
      subject: subject(),
      acquisition_method: "oauth_user",
      requested_permissions_digest: "requested-digest-1",
      redirect_uri_id: "callback-v1",
      correlation_id: "begin-handoff-1"
    }
  end

  defp begin_request(connection, owner) do
    %{
      subject: %{
        owner_uri: owner,
        workspace_uri: Ezagent.Capability.workspace_of(owner),
        provider_id: connection.provider_id,
        governed_host: connection.governed_host,
        connection_id: connection.connection_id,
        connection_version: connection.connection_version,
        execution_identity:
          connection.execution_identity || connection.requested_execution_identity_class
      },
      acquisition_method: connection.acquisition_method,
      requested_permissions_digest: "requested-digest-lost-fence",
      redirect_uri_id: "callback-v1",
      correlation_id: "begin-lost-fence"
    }
  end

  defp reconciliation_begin_request(connection, owner, correlation_id) do
    connection
    |> begin_request(owner)
    |> Map.put(
      :correlation_id,
      "begin-#{correlation_id}-#{System.unique_integer([:positive])}"
    )
  end

  defp callback_request(started, connection, owner, correlation_id) do
    %{
      authorization_ref: started.authorization_ref,
      callback_envelope: %{
        state: started.redirect["state"],
        pkce_digest: started.redirect["pkce_digest"],
        governed_host: connection.governed_host,
        external_account_id: "acct-1",
        acquisition_origin: :repository_consent
      },
      expected_subject: %{
        owner_uri: owner,
        workspace_uri: Ezagent.Capability.workspace_of(owner),
        provider_id: connection.provider_id,
        governed_host: connection.governed_host,
        connection_id: connection.connection_id,
        connection_version: connection.connection_version,
        execution_identity:
          connection.execution_identity || connection.requested_execution_identity_class
      },
      correlation_id: correlation_id
    }
  end

  defp insert_connection!(owner, status, version) do
    connection_id = Ecto.UUID.generate()

    connection_attrs(connection_id, owner, status)
    |> Connection.create_changeset()
    |> Ecto.Changeset.change(connection_version: version)
    |> Repo.insert!()
  end

  defp insert_finalize_attempt!(authorization_ref, correlation_id) do
    backend_record =
      Repo.get_by!(AuthorizationBackendRecord, authorization_ref: authorization_ref)

    connection_id = backend_record.connection_id

    _connection = ensure_finalize_connection!(authorization_ref)

    attrs = %{
      attempt_ref: Ecto.UUID.generate(),
      workspace_uri: URI.to_string(Ezagent.URI.workspace("acme")),
      backend_pair_id: "pair-z-local-v1",
      authorization_ref: authorization_ref,
      connection_id: connection_id,
      connection_version: 1,
      purpose: "initial_bind",
      reservation_digest: digest({:finalize_reservation, authorization_ref}),
      requested_permission_digest: backend_record.requested_permissions_digest,
      requested_execution_identity_class: backend_record.execution_identity,
      redirect_uri_id: backend_record.redirect_uri_id,
      callback_artifact_digest: digest(:finalize_callback_artifact),
      bound_subject_digest: backend_record.bound_input_digest,
      state_digest: "state-finalize-#{System.unique_integer([:positive])}",
      correlation_id: correlation_id,
      status: "consuming",
      claim_token: "claim-finalize",
      claim_until: DateTime.add(DateTime.utc_now(), 30, :second),
      attempt_version: 1,
      expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
    }

    attrs
    |> AuthorizationAttempt.create_changeset()
    |> Ecto.Changeset.change(
      claim_token: attrs.claim_token,
      claim_until: attrs.claim_until,
      attempt_version: attrs.attempt_version
    )
    |> Repo.insert!()
  end

  defp ensure_finalize_connection!(authorization_ref) do
    backend_record =
      Repo.get_by!(AuthorizationBackendRecord, authorization_ref: authorization_ref)

    attrs = %{
      connection_id: backend_record.connection_id,
      workspace_uri: URI.to_string(Ezagent.URI.workspace("acme")),
      owner_uri: URI.to_string(Ezagent.URI.user("acme", "alice")),
      provider_id: "task6-provider",
      governed_host: "example.test",
      requested_execution_identity_class: backend_record.execution_identity,
      acquisition_method: "oauth_user",
      status: "pending_authorization"
    }

    case Repo.get(Connection, backend_record.connection_id) do
      %Connection{} = connection ->
        connection

      nil ->
        attrs
        |> Connection.create_changeset()
        |> Ecto.Changeset.change(connection_version: 1)
        |> Repo.insert!()
    end
  end

  defp insert_finalize_operation!(attempt, handoff_ref) do
    backend_record =
      Repo.get_by!(AuthorizationBackendRecord, authorization_ref: attempt.authorization_ref)

    connection = Repo.get!(Connection, attempt.connection_id)

    operation =
      %{
        operation_class: callback_operation_class(attempt),
        correlation_id: "#{callback_operation_class(attempt)}:#{attempt.correlation_id}",
        bound_input_digest: Operation.callback_digest(backend_record, attempt, connection),
        next_recovery_at: DateTime.utc_now(),
        status: "prepared"
      }
      |> then(&Operation.store_create_changeset(attempt, connection, &1))
      |> Repo.insert!()

    if is_nil(handoff_ref), do: operation, else: %{operation | handoff_ref: handoff_ref}
  end

  defp journal_provider_fixture!(operation, result) do
    operation
    |> Operation.provider_ownership_changeset(%{
      handoff_ref: elem(result.credential_material, 1),
      provider_result_ref: result.provider_result_ref,
      result_external_account_id: result.external_account_id,
      result_display_login: result.display_login,
      result_execution_identity: Atom.to_string(result.execution_identity.kind),
      result_authorization_ref: result.authorization_ref,
      result_authorization_version: result.authorization_version,
      result_permission_digest: result.granted_permissions_digest,
      result_expires_at: result.expires_at
    })
    |> Repo.update!()
  end

  defp ensure_attempt_connection!(connection_id, connection_version) do
    case Repo.get(Connection, connection_id) do
      %Connection{} = connection ->
        connection

      nil ->
        owner = Ezagent.URI.user("acme", "attempt-fixture-#{connection_id}")

        connection_id
        |> connection_attrs(owner, "pending_authorization")
        |> Connection.create_changeset()
        |> Ecto.Changeset.change(connection_version: connection_version)
        |> Repo.insert!()
    end
  end

  defp connection_attrs(connection_id, owner, status) do
    common = %{
      connection_id: connection_id,
      workspace_uri: URI.to_string(Ezagent.Capability.workspace_of(owner)),
      owner_uri: URI.to_string(owner),
      provider_id: "task6-provider",
      governed_host: "example.test",
      requested_execution_identity_class: "connected_user",
      acquisition_method: "oauth_user",
      status: status
    }

    if status == "pending_authorization" do
      common
    else
      Map.merge(common, %{
        external_account_id: "acct-1",
        display_login: "alice-alpha",
        execution_identity: "connected_user",
        authorization_backend_ref: "authorization-ref-current",
        credential_backend_ref: "credential-ref-current"
      })
    end
  end

  defp reservation_digest(
         purpose,
         connection,
         identity_class,
         permissions_digest,
         redirect_uri_id,
         correlation_id,
         artifact_digest
       ) do
    digest({
      purpose,
      connection.connection_id,
      connection.connection_version,
      connection.owner_uri,
      connection.workspace_uri,
      connection.provider_id,
      connection.governed_host,
      connection.acquisition_method,
      identity_class,
      permissions_digest,
      redirect_uri_id,
      correlation_id,
      artifact_digest
    })
  end

  defp digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp termination_digest(connection, pair_id, action, expected_version) do
    digest({
      :termination_v1,
      action,
      connection.connection_id,
      connection.workspace_uri,
      connection.owner_uri,
      connection.provider_id,
      connection.governed_host,
      connection.execution_identity,
      expected_version,
      connection.credential_version,
      pair_id
    })
  end

  defp subject do
    %{
      owner_uri: Ezagent.URI.user("acme", "alice"),
      workspace_uri: Ezagent.URI.workspace("acme"),
      provider_id: "task6-provider",
      governed_host: "example.test",
      connection_id: "00000000-0000-4000-8000-000000000001",
      connection_version: 1,
      execution_identity: "connected_user"
    }
  end

  defp callback_artifact(owner) do
    requested =
      Ezagent.Capability.cap(
        :user,
        Ezagent.ActionSet.ProviderConnection,
        :consume_callback,
        Ezagent.URI.instance(owner),
        Ezagent.Capability.workspace_of(owner)
      )

    {:ok, artifact} =
      Ezagent.Cap.issue({:admin, Ezagent.Entity.User.admin_uri()}, owner, requested)

    artifact
  end

  defp collect_traces(parent, count) do
    receive do
      {:trace, _pid, :call, {Ezagent.Router, :dispatch, [_cmd]}} = message ->
        send(parent, message)
        collect_traces(parent, count + 1)

      {:stop, from} ->
        send(from, {:trace_count, count})

      _message ->
        collect_traces(parent, count)
    end
  end

  defp callback_operation_class(%AuthorizationAttempt{purpose: "initial_bind"}), do: "store"
  defp callback_operation_class(%AuthorizationAttempt{purpose: "reauthorize"}), do: "replace"
end
