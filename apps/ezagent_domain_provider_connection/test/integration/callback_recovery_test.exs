Code.require_file(Path.expand("../support/fake_driver_alpha.ex", __DIR__))

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
    Store,
    CallbackIngress
  }

  alias Ezagent.ProviderConnection.Test.FakeDriverAlpha
  alias EzagentCore.Repo

  defmodule CredentialSink do
    @behaviour Ezagent.ProviderConnection.CredentialBackend

    @impl true
    def store(%{credential_material: material, correlation_id: correlation_id} = command) do
      owner = Application.fetch_env!(:ezagent_domain_provider_connection, :task7_test_owner)
      state = Application.fetch_env!(:ezagent_domain_provider_connection, :task7_credential_state)

      {result, block_response?, hook} =
        Agent.get_and_update(state, fn state ->
          canonical_digest =
            :crypto.hash(
              :sha256,
              :erlang.term_to_binary(Map.delete(command, :credential_material))
            )

          {result, results, logical_effects} =
            case Map.fetch(state.results, correlation_id) do
              {:ok, result} ->
                if Map.get(state.canonical_digests, correlation_id) == canonical_digest,
                  do: {result, state.results, state.logical_effects},
                  else: {:correlation_conflict, state.results, state.logical_effects}

              :error ->
                result = %{
                  credential_ref: "credential-ref-#{map_size(state.results) + 1}",
                  credential_version: map_size(state.results) + 1
                }

                {result, Map.put(state.results, correlation_id, result),
                 state.logical_effects + 1}
            end

          next = %{
            state
            | results: results,
              canonical_digests:
                Map.put_new(state.canonical_digests, correlation_id, canonical_digest),
              logical_effects: logical_effects,
              invocations: state.invocations + 1,
              block_once?: false,
              hook: nil
          }

          {{result, state.block_once?, state.hook}, next}
        end)

      if result == :correlation_conflict do
        {:error, :correlation_conflict}
      else
        send(owner, {:credential_store, material, correlation_id})
        if is_function(hook, 1), do: hook.(command)

        if block_response? do
          send(owner, {:credential_committed_without_response, self(), correlation_id, result})

          receive do
            :return_credential_response -> {:ok, result}
          end
        else
          {:ok, result}
        end
      end
    end

    @impl true
    def replace(command), do: {:ok, command}
    @impl true
    def status(command), do: {:ok, command}
    @impl true
    def lease_for_operation(command), do: {:ok, command}
    @impl true
    def consume_lease(_command), do: :ok
    @impl true
    def revoke(_command), do: :ok
  end

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
             invocations: 0,
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
      %{"credential-alpha-v1" => CredentialSink}
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

    assert {:ok, first} = CredentialSink.store(command)
    assert {:ok, ^first} = CredentialSink.store(command)

    assert {:error, :correlation_conflict} =
             CredentialSink.store(%{command | connection_id: Ecto.UUID.generate()})
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
    refute_receive {:credential_store, _, _}
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

    assert {:ok, %{credential_material: {:write_only_handoff, handoff_ref}}} =
             LocalAuthorizationBackend.consume_callback(callback)

    assert {:ok, %{credential_material: {:write_only_handoff, ^handoff_ref}}} =
             LocalAuthorizationBackend.consume_callback(callback)

    assert FakeDriverAlpha.provider_effect_count() == 2

    attempt = insert_finalize_attempt!(started.authorization_ref, "consume-handoff-1")
    operation = insert_finalize_operation!(attempt, handoff_ref)

    assert {:ok, result} =
             LocalAuthorizationBackend.handoff_to_registered_credential(
               operation.id,
               attempt.attempt_ref
             )

    assert result == %{credential_ref: "credential-ref-1", credential_version: 1}
    credential_correlation = operation.correlation_id

    assert_receive {:credential_store, "TASK6_DRIVER_OWNED_CREDENTIAL", ^credential_correlation}
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

  test "credential handoff rejects execution-identity drift before the credential effect" do
    {:ok, started} = LocalAuthorizationBackend.begin_authorization(begin_request())
    _connection = ensure_finalize_connection!(started.authorization_ref)

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

    assert {:ok, %{credential_material: {:write_only_handoff, handoff_ref}}} =
             LocalAuthorizationBackend.consume_callback(callback)

    attempt = insert_finalize_attempt!(started.authorization_ref, callback.correlation_id)
    operation = insert_finalize_operation!(attempt, handoff_ref)
    connection = Repo.get!(Connection, attempt.connection_id)

    connection
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

    refute_receive {:credential_store, _, _}
  end

  test "backend-committed same-correlation retry reconstructs one durable logical result" do
    Code.ensure_loaded!(Operation)
    refute function_exported?(Operation, :advance_changeset, 2)
    refute function_exported?(Operation, :advance_changeset, 3)
    assert function_exported?(Operation, :backend_commit_changeset, 2)

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
        external_account_id: "pending:#{connection_id}",
        execution_identity: "connected_user",
        acquisition_method: "oauth_user",
        authorization_backend_ref: "auth-recovery",
        credential_backend_ref: "pending",
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
      %{
        workspace_uri: attempt.workspace_uri,
        connection_id: attempt.connection_id,
        backend_pair_id: "pair-alpha-v1",
        operation_class: "store",
        correlation_id: "store:#{attempt.correlation_id}",
        bound_input_digest: "durable-result-digest",
        expected_connection_version: attempt.connection_version,
        attempt_claim_token: attempt.claim_token,
        attempt_version: attempt.attempt_version,
        status: "prepared"
      }
      |> Operation.create_changeset()
      |> Ecto.Changeset.change(handoff_ref: "handoff")
      |> Repo.insert!()

    operation
    |> Operation.backend_commit_changeset(%{
      result_ref: "credential-ref-durable",
      expected_credential_version: 7
    })
    |> Repo.update!()

    ctx = %{self_uri: owner, now: DateTime.utc_now()}
    args = %{attempt_ref: attempt.attempt_ref, correlation_id: correlation_id}

    assert {:ok, first} = Store.execute(:consume_callback, args, ctx)
    assert {:ok, ^first} = Store.execute(:consume_callback, args, ctx)
    assert first.connection_id == connection.connection_id
    refute Map.has_key?(first, :credential_ref)
    refute Map.has_key?(first, :credential_version)
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
        external_account_id: "pending:#{connection_id}",
        execution_identity: "connected_user",
        acquisition_method: "oauth_user",
        authorization_backend_ref: "pending",
        credential_backend_ref: "pending",
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
      execution_identity: connection.execution_identity
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

    attempt =
      %{
        attempt_ref: Ecto.UUID.generate(),
        workspace_uri: connection.workspace_uri,
        backend_pair_id: "pair-z-local-v1",
        authorization_ref: started.authorization_ref,
        connection_id: connection.connection_id,
        connection_version: connection.connection_version,
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
    assert recovered.status == "backend_committed"

    committed = Repo.get!(Operation, prepared.id)
    recovered_attempt = Repo.get!(AuthorizationAttempt, attempt.attempt_ref)
    assert committed.id == prepared.id
    assert committed.bound_input_digest == prepared.bound_input_digest
    assert committed.handoff_ref == prepared.handoff_ref
    assert committed.result_ref == result.credential_ref
    assert committed.expected_credential_version == result.credential_version
    assert recovered_attempt.claim_token != expired_claim.claim_token
    assert recovered_attempt.attempt_version == expired_claim.attempt_version + 1
    assert committed.attempt_claim_token == recovered_attempt.claim_token
    assert committed.attempt_version == recovered_attempt.attempt_version

    assert FakeDriverAlpha.provider_effect_count() == 2
    assert Agent.get(credential_state, & &1.logical_effects) == 1
    assert Agent.get(credential_state, & &1.invocations) == 2
    assert Repo.get!(AuthorizationAttempt, attempt.attempt_ref).status == "consuming"

    connection
    |> Ecto.Changeset.change(execution_identity: "drifted-after-commit")
    |> Repo.update!()

    assert {:error, :stale_attempt_claim} =
             Store.execute(
               :consume_callback,
               %{attempt_ref: attempt.attempt_ref, correlation_id: attempt.correlation_id},
               %{self_uri: owner, now: DateTime.utc_now()}
             )

    send(tracer, {:stop, self()})
    assert_receive {:trace_count, 2}
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

    assert {:error, :credential_conflict} =
             Store.execute(
               :consume_callback,
               %{attempt_ref: attempt.attempt_ref, correlation_id: attempt.correlation_id},
               %{self_uri: owner, now: now}
             )

    operation = Repo.get_by!(Operation, correlation_id: "store:#{attempt.correlation_id}")
    result = Agent.get(credential_state, &Map.fetch!(&1.results, operation.correlation_id))
    assert operation.status == "cleanup_pending"
    assert operation.safe_error_code == "cleanup_pending"
    assert operation.result_ref == result.credential_ref
    assert operation.expected_credential_version == result.credential_version
    assert operation.correlation_id == "store:#{attempt.correlation_id}"
  end

  defp insert_attempt!(now, overrides \\ []) do
    attrs = %{
      attempt_ref: Ecto.UUID.generate(),
      workspace_uri: URI.to_string(Ezagent.URI.workspace("acme")),
      backend_pair_id: Keyword.get(overrides, :backend_pair_id, "pair-alpha-v1"),
      authorization_ref:
        Keyword.get(overrides, :authorization_ref, "auth-#{System.unique_integer([:positive])}"),
      connection_id: Keyword.get(overrides, :connection_id, Ecto.UUID.generate()),
      connection_version: Keyword.get(overrides, :connection_version, 1),
      bound_subject_digest: Keyword.get(overrides, :bound_subject_digest, "subject-digest"),
      state_digest: "state-#{System.unique_integer([:positive])}",
      correlation_id:
        Keyword.get(
          overrides,
          :correlation_id,
          "stable-correlation-#{System.unique_integer([:positive])}"
        ),
      status: Keyword.get(overrides, :status, "pending"),
      expires_at: Keyword.get(overrides, :expires_at, DateTime.add(now, 60, :second))
    }

    Repo.insert!(AuthorizationAttempt.create_changeset(attrs))
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
        execution_identity: connection.execution_identity
      },
      acquisition_method: connection.acquisition_method,
      requested_permissions_digest: "requested-digest-lost-fence",
      redirect_uri_id: "callback-v1",
      correlation_id: "begin-lost-fence"
    }
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
        execution_identity: connection.execution_identity
      },
      correlation_id: correlation_id
    }
  end

  defp insert_connection!(owner, status, version) do
    connection_id = Ecto.UUID.generate()

    %{
      connection_id: connection_id,
      workspace_uri: URI.to_string(Ezagent.Capability.workspace_of(owner)),
      owner_uri: URI.to_string(owner),
      provider_id: "task6-provider",
      governed_host: "example.test",
      external_account_id: "pending:#{connection_id}",
      execution_identity: "connected_user",
      acquisition_method: "oauth_user",
      authorization_backend_ref: "pending",
      credential_backend_ref: "pending",
      status: status
    }
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
      bound_subject_digest: backend_record.bound_input_digest,
      state_digest: "state-finalize-#{System.unique_integer([:positive])}",
      correlation_id: correlation_id,
      status: "consuming",
      claim_token: "claim-finalize",
      claim_until: DateTime.add(DateTime.utc_now(), 30, :second),
      attempt_version: 1,
      expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
    }

    %AuthorizationAttempt{}
    |> Ecto.Changeset.change(attrs)
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
      external_account_id: "pending:#{backend_record.connection_id}",
      execution_identity: "connected_user",
      acquisition_method: "oauth_user",
      authorization_backend_ref: authorization_ref,
      credential_backend_ref: "pending",
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

    %{
      workspace_uri: attempt.workspace_uri,
      connection_id: attempt.connection_id,
      backend_pair_id: attempt.backend_pair_id,
      operation_class: "store",
      correlation_id: "store:#{attempt.correlation_id}",
      bound_input_digest: Operation.callback_digest(backend_record, attempt, connection),
      expected_connection_version: attempt.connection_version,
      attempt_claim_token: attempt.claim_token,
      attempt_version: attempt.attempt_version,
      status: "prepared"
    }
    |> Operation.create_changeset()
    |> Ecto.Changeset.change(
      handoff_ref: handoff_ref,
      result_ref: "credential-ref-1",
      expected_credential_version: 1
    )
    |> Repo.insert!()
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
end
