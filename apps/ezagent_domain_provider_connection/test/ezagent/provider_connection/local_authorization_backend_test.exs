Code.require_file(Path.expand("../../support/fake_driver_alpha.ex", __DIR__))

defmodule Ezagent.ProviderConnection.LocalAuthorizationBackendTest do
  use EzagentCore.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ezagent.ProviderConnection.AuthorizationBackendRecord
  alias Ezagent.ProviderConnection.AuthorizationKeyRing
  alias Ezagent.ProviderConnection.BackendPair
  alias Ezagent.ProviderConnection.BackendPairRegistry
  alias Ezagent.ProviderConnection.Connection
  alias Ezagent.ProviderConnection.Driver
  alias Ezagent.ProviderConnection.DriverRegistry
  alias Ezagent.ProviderConnection.LocalAuthorizationBackend
  alias Ezagent.ProviderConnection.ProviderAuthorizationCommand
  alias Ezagent.ProviderConnection.Test.FakeDriverAlpha
  alias EzagentCore.Repo

  @sentinel "TASK6_CALLBACK_SECRET_37E26D"

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    owner = {__MODULE__, self()}

    previous_pairs =
      Application.get_env(:ezagent_domain_provider_connection, :local_authorization_backend_pairs)

    Application.put_env(
      :ezagent_domain_provider_connection,
      :local_authorization_backend_pairs,
      %{{"task6-provider", "oauth_user"} => "pair-z-local-v1"}
    )

    FakeDriverAlpha.reset()

    subject = subject()

    %{
      connection_id: subject.connection_id,
      workspace_uri: URI.to_string(subject.workspace_uri),
      owner_uri: URI.to_string(subject.owner_uri),
      provider_id: subject.provider_id,
      governed_host: subject.governed_host,
      external_account_id: "acct-1",
      execution_identity: "connected_user",
      acquisition_method: "oauth_user",
      authorization_backend_ref: "pending",
      credential_backend_ref: "pending",
      status: "pending_authorization"
    }
    |> Connection.create_changeset()
    |> Ecto.Changeset.change(connection_version: subject.connection_version)
    |> Repo.insert!()

    for pair_id <- ["pair-a-local-v1", "pair-z-local-v1"] do
      pair =
        BackendPair.new!(%{
          pair_id: pair_id,
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
    end

    driver =
      Driver.new!(%{
        provider_id: "task6-provider",
        acquisition_method: "oauth_user",
        provider_fingerprint: "task6-driver-v1",
        implementation: FakeDriverAlpha,
        backend_pair_ids: ["pair-a-local-v1", "pair-z-local-v1"],
        metadata: FakeDriverAlpha.declaration_metadata()
      })

    result = DriverRegistry.register(owner, driver)
    assert result in [:acquired, :existing_identical]

    on_exit(fn ->
      DriverRegistry.unregister_owner(owner)
      BackendPairRegistry.unregister_owner(owner)

      if previous_pairs do
        Application.put_env(
          :ezagent_domain_provider_connection,
          :local_authorization_backend_pairs,
          previous_pairs
        )
      else
        Application.delete_env(
          :ezagent_domain_provider_connection,
          :local_authorization_backend_pairs
        )
      end
    end)

    :ok
  end

  test "begin is D0-shaped, durable across restart, and caller digest fields are ignored" do
    request = begin_request()
    assert {:ok, first} = LocalAuthorizationBackend.begin_authorization(request)
    assert %{authorization_ref: ref, redirect: %{}, expires_at: %DateTime{}} = first
    assert first.redirect["authorization_uri"] == "https://alpha.example/authorize"
    assert first.redirect["driver_marker"] == "alpha-owned"
    assert String.starts_with?(first.redirect["state"], "test-v1.")
    assert {:ok, ^first} = LocalAuthorizationBackend.begin_authorization(request)

    forged = Map.put(request, :bound_input_digest, "caller-forgery")
    assert {:ok, ^first} = LocalAuthorizationBackend.begin_authorization(forged)

    assert %AuthorizationBackendRecord{} =
             Repo.get_by!(AuthorizationBackendRecord, authorization_ref: ref)

    assert Repo.get_by!(AuthorizationBackendRecord, authorization_ref: ref).backend_pair_id ==
             "pair-z-local-v1"

    assert {:error, :correlation_conflict} =
             request
             |> put_in([:subject, :governed_host], "attacker.example")
             |> LocalAuthorizationBackend.begin_authorization()
  end

  test "concurrent begin creates one row and invokes the driver once" do
    request = begin_request(%{correlation_id: "begin-concurrent"})
    trace_calls(FakeDriverAlpha, :begin_authorization)

    results = concurrently(fn -> LocalAuthorizationBackend.begin_authorization(request) end)
    assert [{:ok, first}, {:ok, first}] = Enum.sort(results)

    assert Repo.aggregate(AuthorizationBackendRecord, :count, :id) == 1
    assert traced_call_count(FakeDriverAlpha, :begin_authorization) == 1
  after
    stop_trace(FakeDriverAlpha, :begin_authorization)
  end

  test "prepared begin survives a transient driver failure and reuses the sealed coordinates" do
    request = begin_request(%{correlation_id: "begin-prepared-recovery"})
    FakeDriverAlpha.fail_next(:begin, :authorization_backend_unavailable)

    assert {:error, :authorization_backend_unavailable} =
             LocalAuthorizationBackend.begin_authorization(request)

    command =
      Repo.get_by!(ProviderAuthorizationCommand,
        operation_class: "begin",
        correlation_id: request.correlation_id
      )

    row = Repo.get_by!(AuthorizationBackendRecord, authorization_ref: command.authorization_ref)
    assert command.status == "prepared"
    sealed = {row.key_id, row.nonce, row.ciphertext}

    assert {:ok, resumed} = LocalAuthorizationBackend.begin_authorization(request)
    assert resumed.authorization_ref == row.authorization_ref

    resumed_row =
      Repo.get_by!(AuthorizationBackendRecord, authorization_ref: row.authorization_ref)

    assert resumed_row.key_id == elem(sealed, 0)
    assert resumed_row.nonce != nil
    assert resumed_row.ciphertext != nil
  end

  test "running key generation is immutable and config rotation requires restart" do
    key_config = AuthorizationKeyRing
    previous = Application.fetch_env!(:ezagent_domain_provider_connection, key_config)

    Application.put_env(:ezagent_domain_provider_connection, key_config,
      source: :explicit_test,
      active_key_id: "test-v2",
      keys: %{"test-v2" => :binary.copy(<<42>>, 32)}
    )

    try do
      assert :ok = AuthorizationKeyRing.validate_rotation_config()

      assert {:error, :authorization_backend_unavailable} =
               LocalAuthorizationBackend.begin_authorization(
                 begin_request(%{correlation_id: "begin-generation-mismatch"})
               )
    after
      Application.put_env(:ezagent_domain_provider_connection, key_config, previous)
    end
  end

  test "concurrent exact consume holds the row lock through one driver effect" do
    {:ok, started} = LocalAuthorizationBackend.begin_authorization(begin_request())
    request = callback_request(started)
    trace_calls(FakeDriverAlpha, :consume_callback)

    results = concurrently(fn -> LocalAuthorizationBackend.consume_callback(request) end)
    assert [{:ok, first}, {:ok, first}] = Enum.sort(results)
    assert %{credential_material: {:write_only_handoff, handoff_ref}} = first
    assert is_binary(handoff_ref)
    assert traced_call_count(FakeDriverAlpha, :consume_callback) == 1
  after
    stop_trace(FakeDriverAlpha, :consume_callback)
  end

  test "consume commits prepared command before its independently retried driver effect" do
    {:ok, started} = LocalAuthorizationBackend.begin_authorization(begin_request())
    request = callback_request(started, %{}, "consume-prepared-recovery")
    FakeDriverAlpha.fail_next(:consume, :authorization_backend_unavailable)

    assert {:error, :authorization_backend_unavailable} =
             LocalAuthorizationBackend.consume_callback(request)

    assert %ProviderAuthorizationCommand{status: "prepared"} =
             Repo.get_by!(ProviderAuthorizationCommand,
               operation_class: "consume",
               correlation_id: request.correlation_id
             )

    prepared_row =
      Repo.get_by!(AuthorizationBackendRecord, authorization_ref: started.authorization_ref)

    assert is_binary(prepared_row.callback_ciphertext)
    assert is_binary(prepared_row.callback_key_fingerprint)
    assert prepared_row.consume_correlation_id == request.correlation_id
    assert is_binary(prepared_row.consume_input_digest)

    assert {:ok, result} = LocalAuthorizationBackend.consume_callback(request)
    assert result.external_account_id == "acct-1"
    assert result.display_login == "alice-alpha"
    assert result.granted_permissions_digest == "driver-granted-digest"
    assert result.provider_metadata == %{"tier" => "alpha"}

    committed_row =
      Repo.get_by!(AuthorizationBackendRecord, authorization_ref: started.authorization_ref)

    assert committed_row.callback_ciphertext == nil
    assert committed_row.callback_nonce == nil
    assert committed_row.ciphertext == nil
    assert is_binary(committed_row.key_fingerprint)
  end

  test "committed consume response loss reconciles without another provider effect" do
    {:ok, started} = LocalAuthorizationBackend.begin_authorization(begin_request())
    request = callback_request(started, %{}, "consume-committed-response-loss")
    assert {:ok, first} = LocalAuthorizationBackend.consume_callback(request)

    assert first.provider_metadata ==
             first.provider_metadata |> Jason.encode!() |> Jason.decode!()

    retry = Task.async(fn -> LocalAuthorizationBackend.consume_callback(request) end)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), retry.pid)
    assert {:ok, ^first} = Task.await(retry, 5_000)
    assert FakeDriverAlpha.provider_effect_count() == 2
  end

  test "consume verifies durable subject/AAD, internal digest, tamper, and retry semantics" do
    {:ok, started} = LocalAuthorizationBackend.begin_authorization(begin_request())
    request = callback_request(started)
    assert {:ok, first} = LocalAuthorizationBackend.consume_callback(request)
    assert first.external_account_id == "acct-1"
    assert first.display_login == "alice-alpha"
    assert first.execution_identity == %{kind: :connected_user, external_account_id: "acct-1"}
    assert first.granted_permissions_digest == "driver-granted-digest"
    assert {:ok, ^first} = LocalAuthorizationBackend.consume_callback(request)

    assert {:ok, ^first} =
             request
             |> Map.put(:bound_input_digest, "ignored-forgery")
             |> LocalAuthorizationBackend.consume_callback()

    assert {:error, :correlation_conflict} =
             request
             |> put_in([:expected_subject, :governed_host], "attacker.example")
             |> LocalAuthorizationBackend.consume_callback()

    assert {:error, :callback_already_consumed} =
             request
             |> Map.put(:correlation_id, "consume-other")
             |> LocalAuthorizationBackend.consume_callback()

    {:ok, tampered} =
      LocalAuthorizationBackend.begin_authorization(begin_request(%{correlation_id: "tamper"}))

    row = Repo.get_by!(AuthorizationBackendRecord, authorization_ref: tampered.authorization_ref)
    <<head, rest::binary>> = row.ciphertext

    row
    |> Ecto.Changeset.change(ciphertext: <<Bitwise.bxor(head, 1), rest::binary>>)
    |> Repo.update!()

    tampered_callback = callback_request(tampered, %{}, "consume-tamper")

    assert {:error, :state_mismatch} =
             LocalAuthorizationBackend.consume_callback(tampered_callback)

    assert {:error, :state_mismatch} =
             LocalAuthorizationBackend.consume_callback(tampered_callback)
  end

  test "cancel and reauthenticate reconcile exact retries and reject conflicts" do
    {:ok, started} = LocalAuthorizationBackend.begin_authorization(begin_request())

    cancel = %{
      authorization_ref: started.authorization_ref,
      expected_subject: subject(),
      correlation_id: "cancel-1"
    }

    assert :ok = LocalAuthorizationBackend.cancel_authorization(cancel)
    assert :ok = LocalAuthorizationBackend.cancel_authorization(cancel)

    assert {:error, :correlation_conflict} =
             cancel
             |> put_in([:expected_subject, :connection_version], 2)
             |> LocalAuthorizationBackend.cancel_authorization()

    {:ok, invalid_cancel_started} =
      LocalAuthorizationBackend.begin_authorization(
        begin_request(%{correlation_id: "begin-invalid-cancel"})
      )

    invalid_cancel = %{
      authorization_ref: invalid_cancel_started.authorization_ref,
      expected_subject: %{subject() | connection_version: 2},
      correlation_id: "cancel-invalid-subject"
    }

    assert {:error, :invalid_authorization_subject} =
             LocalAuthorizationBackend.cancel_authorization(invalid_cancel)

    assert {:error, :invalid_authorization_subject} =
             LocalAuthorizationBackend.cancel_authorization(invalid_cancel)

    reauth = %{
      subject: subject(),
      session_assurance_evidence: %{aal: :aal2},
      correlation_id: "reauth-1"
    }

    assert {:ok, first} = LocalAuthorizationBackend.reauthenticate(reauth)
    assert {:ok, ^first} = LocalAuthorizationBackend.reauthenticate(reauth)

    assert {:error, :correlation_conflict} =
             reauth
             |> put_in([:subject, :connection_version], 2)
             |> LocalAuthorizationBackend.reauthenticate()
  end

  test "cancel after consume is monotonic and makes zero durable mutation" do
    {:ok, started} = LocalAuthorizationBackend.begin_authorization(begin_request())
    assert {:ok, _result} = LocalAuthorizationBackend.consume_callback(callback_request(started))

    before_count = Repo.aggregate(ProviderAuthorizationCommand, :count, :id)

    before_row =
      Repo.get_by!(AuthorizationBackendRecord, authorization_ref: started.authorization_ref)

    assert {:error, :callback_already_consumed} =
             LocalAuthorizationBackend.cancel_authorization(%{
               authorization_ref: started.authorization_ref,
               expected_subject: subject(),
               correlation_id: "cancel-after-consume"
             })

    after_row =
      Repo.get_by!(AuthorizationBackendRecord, authorization_ref: started.authorization_ref)

    assert after_row.lifecycle_status == "consumed"
    assert after_row.updated_at == before_row.updated_at
    assert Repo.aggregate(ProviderAuthorizationCommand, :count, :id) == before_count
  end

  test "closed request keys, exact D0 errors, and durable reauthentication binding fail closed" do
    assert {:error, :invalid_acquisition_method} =
             begin_request(%{acquisition_method: "unknown"})
             |> LocalAuthorizationBackend.begin_authorization()

    assert {:error, :callback_invalid} =
             begin_request(%{unexpected_authority: "smuggled"})
             |> LocalAuthorizationBackend.begin_authorization()

    assert {:error, :authorization_backend_unavailable} =
             begin_request(%{
               subject: %{subject() | provider_id: "unregistered-provider"}
             })
             |> LocalAuthorizationBackend.begin_authorization()

    assert {:error, :invalid_authorization_subject} =
             LocalAuthorizationBackend.reauthenticate(%{
               subject: %{subject() | connection_id: "missing-connection"},
               session_assurance_evidence: %{aal: :aal2},
               correlation_id: "reauth-without-record"
             })

    {:ok, started} = LocalAuthorizationBackend.begin_authorization(begin_request())

    assert {:error, :callback_invalid} =
             started
             |> callback_request()
             |> Map.put(:driver, Ezagent.ProviderConnection.Test.MaliciousDriver)
             |> LocalAuthorizationBackend.consume_callback()
  end

  test "required begin coordinates and canonical subject fail before durable writes" do
    for request <- [
          begin_request(%{requested_permissions_digest: ""}),
          begin_request(%{redirect_uri_id: ""}),
          begin_request(%{
            subject: %{subject() | workspace_uri: Ezagent.URI.user("acme", "alice")}
          })
        ] do
      assert {:error, _closed_error} = LocalAuthorizationBackend.begin_authorization(request)
    end

    assert Repo.aggregate(AuthorizationBackendRecord, :count, :id) == 0
    assert Repo.aggregate(ProviderAuthorizationCommand, :count, :id) == 0
  end

  test "provider metadata is validated recursively against the declared positive schema" do
    {:ok, started} = LocalAuthorizationBackend.begin_authorization(begin_request())
    FakeDriverAlpha.set_provider_metadata(%{"tier" => "alpha", "unexpected" => %{"x" => 1}})

    assert {:error, :provider_protocol_error} =
             LocalAuthorizationBackend.consume_callback(
               callback_request(started, %{}, "consume-schema-reject")
             )
  end

  test "consume and cancel expire pending rows under lock without command or driver effects" do
    for {operation, correlation_id} <- [consume: "consume-expired", cancel: "cancel-expired"] do
      {:ok, started} =
        LocalAuthorizationBackend.begin_authorization(
          begin_request(%{correlation_id: "begin-#{operation}-expired"})
        )

      row = Repo.get_by!(AuthorizationBackendRecord, authorization_ref: started.authorization_ref)

      row
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()

      before_commands = Repo.aggregate(ProviderAuthorizationCommand, :count, :id)

      result =
        case operation do
          :consume ->
            LocalAuthorizationBackend.consume_callback(
              callback_request(started, %{}, correlation_id)
            )

          :cancel ->
            LocalAuthorizationBackend.cancel_authorization(%{
              authorization_ref: started.authorization_ref,
              expected_subject: subject(),
              correlation_id: correlation_id
            })
        end

      assert result == {:error, :callback_expired}

      assert Repo.get_by!(AuthorizationBackendRecord,
               authorization_ref: started.authorization_ref
             ).lifecycle_status == "expired"

      assert Repo.aggregate(ProviderAuthorizationCommand, :count, :id) == before_commands
    end
  end

  test "handoff stays sealed for Task 7 and all public/error/log/Inspect paths remain secret-safe" do
    log =
      capture_log(fn ->
        {:ok, started} = LocalAuthorizationBackend.begin_authorization(begin_request())
        request = callback_request(started, %{code: @sentinel})
        assert {:ok, result} = LocalAuthorizationBackend.consume_callback(request)
        refute inspect(result) =~ @sentinel

        row =
          Repo.get_by!(AuthorizationBackendRecord, authorization_ref: started.authorization_ref)

        assert is_binary(row.handoff_ciphertext)
        assert row.shredded_at == nil
        refute inspect(row) =~ @sentinel
      end)

    refute log =~ @sentinel
    assert function_exported?(LocalAuthorizationBackend, :prepare_handoff_finalization, 1)
    assert function_exported?(LocalAuthorizationBackend, :finalize_handoff, 1)
  end

  defp begin_request(overrides \\ %{}) do
    Map.merge(
      %{
        subject: subject(),
        acquisition_method: "oauth_user",
        requested_permissions_digest: "requested-digest-1",
        redirect_uri_id: "callback-v1",
        correlation_id: "begin-1"
      },
      overrides
    )
  end

  defp callback_request(started, extra \\ %{}, correlation_id \\ "consume-1") do
    %{
      authorization_ref: started.authorization_ref,
      callback_envelope:
        Map.merge(
          %{
            state: started.redirect["state"],
            pkce_digest: started.redirect["pkce_digest"],
            governed_host: "example.test",
            external_account_id: "acct-1",
            acquisition_origin: :repository_consent
          },
          extra
        ),
      expected_subject: subject(),
      correlation_id: correlation_id
    }
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

  defp concurrently(fun) do
    parent = self()

    tasks =
      for _ <- 1..2 do
        task =
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> fun.()
            end
          end)

        Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), task.pid)
        task
      end

    for _ <- tasks, do: assert_receive({:ready, _pid})
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 5_000))
  end

  defp trace_calls(module, function) do
    :erlang.trace_pattern({module, function, 1}, true, [:local])
    :erlang.trace(:all, true, [:call, {:tracer, self()}])
  end

  defp traced_call_count(module, function), do: drain_calls(module, function, 0)

  defp drain_calls(module, function, count) do
    receive do
      {:trace, _pid, :call, {^module, ^function, [_arg]}} ->
        drain_calls(module, function, count + 1)

      _other ->
        drain_calls(module, function, count)
    after
      50 -> count
    end
  end

  defp stop_trace(module, function) do
    :erlang.trace(:all, false, [:call])
    :erlang.trace_pattern({module, function, 1}, false, [:local])
  end
end
