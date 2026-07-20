Code.require_file(Path.expand("../support/fake_driver_alpha.ex", __DIR__))

defmodule Ezagent.ProviderConnection.OwnerCommandLifecycleTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.ProviderConnection

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
    Store
  }

  alias Ezagent.ProviderConnection.LocalAuthorizationBackend.Support
  alias Ezagent.ProviderConnection.Test.FakeDriverAlpha
  alias EzagentCore.Repo

  @provider_id "task2-provider"
  @method "oauth_user"
  @pair_id "pair-task2-local-v1"

  setup do
    declaration_owner = {__MODULE__, self()}

    previous_pairs =
      Application.get_env(:ezagent_domain_provider_connection, :local_authorization_backend_pairs)

    previous_credential_implementations =
      Application.get_env(
        :ezagent_domain_provider_connection,
        :credential_backend_implementations
      )

    pair =
      BackendPair.new!(%{
        pair_id: @pair_id,
        authorization_backend: %{
          id: "local-authorization-v1",
          fingerprint: "local-authorization-contract-v1"
        },
        credential_backend: %{
          id: "credential-alpha-v1",
          fingerprint: "credential-alpha-contract-v1"
        }
      })

    driver =
      Driver.new!(%{
        provider_id: @provider_id,
        acquisition_method: @method,
        provider_fingerprint: "task2-provider-contract-v1",
        implementation: FakeDriverAlpha,
        backend_pair_ids: [@pair_id],
        metadata: FakeDriverAlpha.declaration_metadata()
      })

    assert BackendPairRegistry.register(declaration_owner, pair) in [
             :acquired,
             :existing_identical
           ]

    assert DriverRegistry.register(declaration_owner, driver) in [
             :acquired,
             :existing_identical
           ]

    Application.put_env(
      :ezagent_domain_provider_connection,
      :local_authorization_backend_pairs,
      %{{@provider_id, @method} => @pair_id}
    )

    Application.put_env(
      :ezagent_domain_provider_connection,
      :credential_backend_implementations,
      %{}
    )

    FakeDriverAlpha.reset()

    on_exit(fn ->
      DriverRegistry.unregister_owner(declaration_owner)
      BackendPairRegistry.unregister_owner(declaration_owner)

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

      if previous_credential_implementations do
        Application.put_env(
          :ezagent_domain_provider_connection,
          :credential_backend_implementations,
          previous_credential_implementations
        )
      else
        Application.delete_env(
          :ezagent_domain_provider_connection,
          :credential_backend_implementations
        )
      end
    end)

    owner = Ezagent.URI.user(:task2, "owner-#{System.unique_integer([:positive])}")
    {:ok, owner: owner}
  end

  test "initial begin creates the pending aggregate and settles one reservation", %{owner: owner} do
    args = begin_args()

    assert {:ok, receipt} = Store.execute(:begin_authorization, args, %{self_uri: owner})
    assert %{attempt_ref: attempt_ref, authorization_url: url, expires_at: expires_at} = receipt
    assert url == "https://alpha.example/authorize"
    assert {:ok, _expires_at, 0} = DateTime.from_iso8601(expires_at)

    connection = Repo.get!(Connection, args.connection_id)
    assert connection.owner_uri == URI.to_string(owner)
    assert connection.workspace_uri == URI.to_string(Ezagent.Capability.workspace_of(owner))
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

    attempt = Repo.get!(AuthorizationAttempt, attempt_ref)
    assert attempt.connection_id == connection.connection_id
    assert attempt.connection_version == connection.connection_version
    assert attempt.purpose == "initial_bind"
    assert attempt.status == "pending"
    assert attempt.requested_permission_digest == args.requested_permissions_digest
    assert attempt.requested_execution_identity_class == "connected_user"
    assert attempt.redirect_uri_id == args.redirect_uri_id
    assert is_binary(attempt.reservation_digest)
    assert is_binary(attempt.callback_artifact_digest)
  end

  test "initial begin exact retry reuses one reservation and conflicting retry is closed", %{
    owner: owner
  } do
    args = begin_args()

    assert {:ok, first_receipt} =
             Store.execute(:begin_authorization, args, %{self_uri: owner})

    assert {:ok, ^first_receipt} =
             Store.execute(:begin_authorization, args, %{self_uri: owner})

    assert {:error, :correlation_conflict} =
             Store.execute(
               :begin_authorization,
               %{args | requested_permissions_digest: "conflicting-digest"},
               %{self_uri: owner}
             )

    first_receipt.attempt_ref
    |> then(&Repo.get!(AuthorizationAttempt, &1))
    |> Ecto.Changeset.change(
      status: "consuming",
      claim_token: "claimed-callback",
      claim_until: DateTime.add(DateTime.utc_now(), 30, :second)
    )
    |> Repo.update!()

    assert {:ok, ^first_receipt} =
             Store.execute(:begin_authorization, args, %{self_uri: owner})

    assert Repo.aggregate(
             from(attempt in AuthorizationAttempt,
               where: attempt.connection_id == ^args.connection_id
             ),
             :count
           ) == 1

    assert FakeDriverAlpha.provider_effect_count(:begin) == 1
  end

  test "terminal transition wins the begin settle race and closes its reservation", %{
    owner: owner
  } do
    args = begin_args()
    parent = self()

    barrier = fn connection, reservation ->
      send(parent, {:before_begin_settle, self(), connection, reservation})

      receive do
        :release_begin_settle -> :ok
      end
    end

    begin_task =
      Task.async(fn ->
        receive do
          :go ->
            Store.execute(:begin_authorization, args, %{
              self_uri: owner,
              before_begin_settle: barrier
            })
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), begin_task.pid)
    send(begin_task.pid, :go)

    begin_pid = begin_task.pid
    assert_receive {:before_begin_settle, ^begin_pid, %Connection{}, %AuthorizationAttempt{}}

    assert {:ok, %Connection{status: "failed"}} =
             Repo.transaction(fn ->
               connection =
                 Connection
                 |> where([row], row.connection_id == ^args.connection_id)
                 |> lock("FOR UPDATE")
                 |> Repo.one!()

               connection
               |> Connection.bind_changeset(%{
                 status: "failed",
                 last_error_code: "account_conflict"
               })
               |> Repo.update!()
             end)

    send(begin_pid, :release_begin_settle)
    assert {:error, :connection_terminal} = Task.await(begin_task)

    attempt = Repo.get_by!(AuthorizationAttempt, connection_id: args.connection_id)
    assert attempt.status == "cancelled"

    assert {:error, :connection_terminal} =
             Store.execute(:begin_authorization, args, %{self_uri: owner})

    assert FakeDriverAlpha.provider_effect_count(:begin) == 1
  end

  test "terminal initial begin failure closes the reservation and replays without a new effect",
       %{
         owner: owner
       } do
    args = begin_args()
    FakeDriverAlpha.fail_next(:begin, :provider_denied)

    assert {:error, :provider_authorization_denied} =
             Store.execute(:begin_authorization, args, %{self_uri: owner})

    first_attempt = Repo.get_by!(AuthorizationAttempt, connection_id: args.connection_id)
    assert first_attempt.status == "cancelled"

    assert %ProviderAuthorizationCommand{
             status: "terminal_failed",
             safe_error_code: "provider_authorization_denied"
           } = begin_command(args.correlation_id)

    assert {:error, :provider_authorization_denied} =
             Store.execute(:begin_authorization, args, %{self_uri: owner})

    replayed_attempt = Repo.get!(AuthorizationAttempt, first_attempt.attempt_ref)
    assert replayed_attempt.attempt_ref == first_attempt.attempt_ref
    assert replayed_attempt.correlation_id == args.correlation_id
    assert replayed_attempt.status == "cancelled"

    assert Repo.aggregate(
             from(attempt in AuthorizationAttempt,
               where: attempt.connection_id == ^args.connection_id
             ),
             :count
           ) == 1

    assert FakeDriverAlpha.provider_effect_count(:begin) == 0

    replacement = %{args | correlation_id: "replacement-#{System.unique_integer([:positive])}"}

    assert {:ok, replacement_receipt} =
             Store.execute(:begin_authorization, replacement, %{self_uri: owner})

    refute replacement_receipt.attempt_ref == first_attempt.attempt_ref

    assert Repo.get!(AuthorizationAttempt, replacement_receipt.attempt_ref).correlation_id !=
             args.correlation_id

    assert Repo.aggregate(
             from(attempt in AuthorizationAttempt,
               where: attempt.connection_id == ^args.connection_id
             ),
             :count
           ) == 2

    assert FakeDriverAlpha.provider_effect_count(:begin) == 1
  end

  test "retryable initial begin failure keeps one open reservation for exact retry", %{
    owner: owner
  } do
    args = begin_args()
    FakeDriverAlpha.fail_next(:begin, :backend_unavailable)

    assert {:error, :authorization_backend_unavailable} =
             Store.execute(:begin_authorization, args, %{self_uri: owner})

    attempt = Repo.get_by!(AuthorizationAttempt, connection_id: args.connection_id)
    assert attempt.status == "beginning"
    assert %ProviderAuthorizationCommand{status: "prepared"} = begin_command(args.correlation_id)

    assert {:ok, receipt} = Store.execute(:begin_authorization, args, %{self_uri: owner})
    assert receipt.attempt_ref == attempt.attempt_ref
    assert FakeDriverAlpha.provider_effect_count(:begin) == 1

    assert Repo.aggregate(
             from(row in AuthorizationAttempt,
               where: row.connection_id == ^args.connection_id
             ),
             :count
           ) == 1
  end

  test "pending aggregate scope is fenced by its requested execution identity" do
    connection = %Connection{
      owner_uri: "entity://task2/user/owner",
      workspace_uri: "workspace://task2",
      connection_id: Ecto.UUID.generate(),
      connection_version: 0,
      provider_id: @provider_id,
      governed_host: "example.test",
      acquisition_method: @method,
      requested_execution_identity_class: "connected_user",
      execution_identity: nil,
      status: "pending_authorization"
    }

    backend_record = %AuthorizationBackendRecord{
      owner_uri: connection.owner_uri,
      workspace_uri: connection.workspace_uri,
      connection_id: connection.connection_id,
      connection_version: connection.connection_version,
      provider_id: connection.provider_id,
      governed_host: connection.governed_host,
      acquisition_method: connection.acquisition_method,
      execution_identity: "connected_user"
    }

    assert :ok = Support.validate_backend_connection_scope(backend_record, connection)

    refute :ok ==
             Support.validate_backend_connection_scope(
               %{backend_record | execution_identity: "workspace_service"},
               connection
             )

    bound_connection = %{
      connection
      | status: "active",
        execution_identity: "connected_user",
        requested_execution_identity_class: "workspace_service"
    }

    assert :ok = Support.validate_backend_connection_scope(backend_record, bound_connection)

    refute :ok ==
             Support.validate_backend_connection_scope(
               %{backend_record | execution_identity: "workspace_service"},
               bound_connection
             )
  end

  test "initial callback creates an immediately recoverable prepared operation", %{owner: owner} do
    args = begin_args()
    assert {:ok, receipt} = Store.execute(:begin_authorization, args, %{self_uri: owner})

    attempt = Repo.get!(AuthorizationAttempt, receipt.attempt_ref)
    stage_callback!(args, owner, attempt)
    before_callback = DateTime.utc_now()

    assert {:error, :credential_conflict} =
             Store.execute(
               :consume_callback,
               %{attempt_ref: attempt.attempt_ref, correlation_id: attempt.correlation_id},
               %{self_uri: owner}
             )

    after_callback = DateTime.utc_now()

    operation =
      Repo.get_by!(Operation,
        backend_pair_id: @pair_id,
        operation_class: "store",
        correlation_id: "store:#{attempt.correlation_id}"
      )

    assert operation.status == "prepared"
    assert is_nil(operation.prior_credential_ref)
    assert is_nil(operation.prior_credential_version)
    assert DateTime.compare(operation.next_recovery_at, before_callback) in [:eq, :gt]
    assert DateTime.compare(operation.next_recovery_at, after_callback) in [:eq, :lt]
    assert FakeDriverAlpha.provider_effect_count(:consume) == 1
  end

  test "reauthorize reserves its own purpose against an exact active generation", %{
    owner: owner
  } do
    connection = insert_bound_connection!(owner, "active", 7)
    args = reauthorize_args(connection)

    assert {:ok, receipt} = Store.execute(:reauthorize, args, %{self_uri: owner})
    assert %{attempt_ref: attempt_ref, authorization_url: url, expires_at: expires_at} = receipt
    assert url == "https://alpha.example/authorize"
    assert {:ok, _expires_at, 0} = DateTime.from_iso8601(expires_at)

    attempt = Repo.get!(AuthorizationAttempt, attempt_ref)
    assert attempt.connection_id == connection.connection_id
    assert attempt.connection_version == 7
    assert attempt.purpose == "reauthorize"
    assert attempt.status == "pending"
    assert attempt.requested_permission_digest == args.requested_permissions_digest
    assert attempt.requested_execution_identity_class == "connected_user"
    assert attempt.redirect_uri_id == args.redirect_uri_id

    persisted = Repo.get!(Connection, connection.connection_id)
    assert persisted.status == "active"
    assert persisted.connection_version == 7
    assert persisted.external_account_id == connection.external_account_id
  end

  test "reauthorize sends the current requested execution identity to the backend", %{
    owner: owner
  } do
    connection = insert_bound_connection!(owner, "active", 4)

    args = %{
      reauthorize_args(connection)
      | requested_execution_identity_class: "workspace_service"
    }

    assert {:ok, _receipt} = Store.execute(:reauthorize, args, %{self_uri: owner})

    assert %AuthorizationBackendRecord{execution_identity: "workspace_service"} =
             Repo.get_by!(AuthorizationBackendRecord, begin_correlation_id: args.correlation_id)

    assert Repo.get!(Connection, connection.connection_id).execution_identity == "connected_user"
  end

  test "terminal reauthorization failure closes and replays the same reservation", %{owner: owner} do
    connection = insert_bound_connection!(owner, "active", 6)
    args = reauthorize_args(connection)
    FakeDriverAlpha.fail_next(:begin, :provider_denied)

    assert {:error, :provider_authorization_denied} =
             Store.execute(:reauthorize, args, %{self_uri: owner})

    attempt = Repo.get_by!(AuthorizationAttempt, connection_id: connection.connection_id)
    assert attempt.purpose == "reauthorize"
    assert attempt.status == "cancelled"

    assert {:error, :provider_authorization_denied} =
             Store.execute(:reauthorize, args, %{self_uri: owner})

    replayed_attempt = Repo.get!(AuthorizationAttempt, attempt.attempt_ref)
    assert replayed_attempt.attempt_ref == attempt.attempt_ref
    assert replayed_attempt.correlation_id == args.correlation_id
    assert replayed_attempt.status == "cancelled"

    assert Repo.aggregate(
             from(row in AuthorizationAttempt,
               where: row.connection_id == ^connection.connection_id
             ),
             :count
           ) == 1

    assert FakeDriverAlpha.provider_effect_count(:begin) == 0

    replacement = %{
      args
      | correlation_id: "reauthorize-replacement-#{System.unique_integer([:positive])}"
    }

    assert {:ok, replacement_receipt} =
             Store.execute(:reauthorize, replacement, %{self_uri: owner})

    refute replacement_receipt.attempt_ref == attempt.attempt_ref

    assert Repo.aggregate(
             from(row in AuthorizationAttempt,
               where: row.connection_id == ^connection.connection_id
             ),
             :count
           ) == 2

    assert FakeDriverAlpha.provider_effect_count(:begin) == 1
  end

  test "reauthorize has a closed source/version matrix and idempotent reservation", %{
    owner: owner
  } do
    for status <- ["active", "degraded", "expired"] do
      connection = insert_bound_connection!(owner, status, 3)
      args = reauthorize_args(connection)

      assert {:ok, first_receipt} = Store.execute(:reauthorize, args, %{self_uri: owner})
      assert {:ok, ^first_receipt} = Store.execute(:reauthorize, args, %{self_uri: owner})

      assert {:error, :correlation_conflict} =
               Store.execute(
                 :reauthorize,
                 %{args | requested_permissions_digest: "conflicting-#{status}"},
                 %{self_uri: owner}
               )
    end

    stale = insert_bound_connection!(owner, "active", 5)

    assert {:error, :stale_version} =
             Store.execute(
               :reauthorize,
               %{reauthorize_args(stale) | expected_version: 4},
               %{self_uri: owner}
             )

    terminal = insert_bound_connection!(owner, "revoked", 2)

    assert {:error, :connection_terminal} =
             Store.execute(:reauthorize, reauthorize_args(terminal), %{self_uri: owner})

    assert FakeDriverAlpha.provider_effect_count(:begin) == 3
  end

  test "read returns only the safe owner-scoped connection view", %{owner: owner} do
    connection = insert_bound_connection!(owner, "degraded", 9)

    assert {:ok, %{connection: view}} =
             Store.execute(
               :read_connection,
               %{connection_id: connection.connection_id},
               %{self_uri: owner}
             )

    assert Map.keys(view) |> Enum.sort() ==
             Enum.sort([
               :acquisition_method,
               :connection_id,
               :display_login,
               :execution_identity,
               :expires_at,
               :external_account_id,
               :governed_host,
               :last_error_code,
               :owner_uri,
               :permission_digest,
               :provider_id,
               :requested_execution_identity_class,
               :status,
               :version,
               :workspace_uri
             ])

    assert view.connection_id == connection.connection_id
    assert view.status == "degraded"
    assert view.version == 9
    assert view.expires_at == DateTime.to_iso8601(connection.expires_at)

    for forbidden <- [
          :authorization_backend_ref,
          :credential_backend_ref,
          :backend_pair_id,
          :authorization_backend_id,
          :credential_backend_id,
          :authorization_version,
          :credential_version,
          :refresh_lease_token,
          :refresh_lease_until,
          :refresh_lease_version,
          :inserted_at,
          :updated_at
        ],
        do: refute(Map.has_key?(view, forbidden))

    other_owner = Ezagent.URI.user(:task2, "other-owner")

    assert {:error, :invalid_authorization_subject} =
             Store.execute(
               :read_connection,
               %{connection_id: connection.connection_id},
               %{self_uri: other_owner}
             )
  end

  test "all seven registered Store handlers return real closed protocol results", %{owner: owner} do
    begin = %{begin_args() | connection_id: "not-a-uuid"}

    reauthorize =
      reauthorize_args(%Connection{connection_id: "not-a-uuid", connection_version: 1})

    commands = [
      {:begin_authorization, begin},
      {:consume_callback, %{attempt_ref: "not-a-uuid", correlation_id: "callback"}},
      {:reauthorize, reauthorize},
      {:refresh, %{connection_id: "not-a-uuid", expected_version: 1, correlation_id: "refresh"}},
      {:revoke, %{connection_id: "not-a-uuid", expected_version: 1}},
      {:disconnect, %{connection_id: "not-a-uuid", expected_version: 1}},
      {:read_connection, %{connection_id: "not-a-uuid"}}
    ]

    for {action, args} <- commands do
      assert {:error, reason} = Store.execute(action, args, %{self_uri: owner})
      refute reason == :provider_connection_orchestration_not_implemented
    end
  end

  defp begin_args do
    %{
      connection_id: Ecto.UUID.generate(),
      provider_id: @provider_id,
      governed_host: "example.test",
      acquisition_method: @method,
      requested_execution_identity_class: "connected_user",
      requested_permissions_digest: "requested-digest-1",
      redirect_uri_id: "callback-v1",
      correlation_id: "begin-#{System.unique_integer([:positive])}",
      callback_artifact:
        Ezagent.Capability.cap(
          :user,
          ProviderConnection,
          :consume_callback,
          :any,
          Ezagent.URI.workspace(:task2)
        )
        |> Map.replace!(:granted_at, DateTime.utc_now())
    }
  end

  defp reauthorize_args(connection) do
    begin = begin_args()

    %{
      connection_id: connection.connection_id,
      expected_version: connection.connection_version,
      requested_execution_identity_class: begin.requested_execution_identity_class,
      requested_permissions_digest: "reauthorize-requested-digest",
      redirect_uri_id: begin.redirect_uri_id,
      correlation_id: "reauthorize-#{System.unique_integer([:positive])}",
      callback_artifact: begin.callback_artifact,
      assurance: :already_validated_by_action_set
    }
  end

  defp begin_command(correlation_id) do
    Repo.get_by!(ProviderAuthorizationCommand,
      backend_pair_id: @pair_id,
      operation_class: "begin",
      correlation_id: correlation_id
    )
  end

  defp stage_callback!(args, owner, attempt) do
    connection = Repo.get!(Connection, args.connection_id)

    assert {:ok, started} =
             LocalAuthorizationBackend.begin_authorization(%{
               subject: %{
                 owner_uri: owner,
                 workspace_uri: Ezagent.Capability.workspace_of(owner),
                 provider_id: connection.provider_id,
                 governed_host: connection.governed_host,
                 connection_id: connection.connection_id,
                 connection_version: connection.connection_version,
                 execution_identity: connection.requested_execution_identity_class
               },
               acquisition_method: connection.acquisition_method,
               requested_permissions_digest: args.requested_permissions_digest,
               redirect_uri_id: args.redirect_uri_id,
               correlation_id: args.correlation_id
             })

    :ok =
      LocalAuthorizationBackend.stage_callback(
        @pair_id,
        started.authorization_ref,
        attempt.correlation_id,
        started.redirect["state"],
        %{
          pkce_digest: started.redirect["pkce_digest"],
          governed_host: connection.governed_host,
          external_account_id: "acct-1",
          acquisition_origin: :repository_consent
        }
      )
  end

  defp insert_bound_connection!(owner, status, version) do
    id = Ecto.UUID.generate()

    %{
      connection_id: id,
      workspace_uri: URI.to_string(Ezagent.Capability.workspace_of(owner)),
      owner_uri: URI.to_string(owner),
      provider_id: @provider_id,
      governed_host: "example.test",
      external_account_id: "acct-#{id}",
      display_login: "task2-owner",
      execution_identity: "connected_user",
      requested_execution_identity_class: "connected_user",
      acquisition_method: @method,
      authorization_backend_ref: "authorization-existing-#{id}",
      credential_backend_ref: "credential-existing-#{id}",
      backend_pair_id: @pair_id,
      authorization_backend_id: "local-authorization-v1",
      credential_backend_id: "credential-alpha-v1",
      status: status,
      permission_digest: "existing-permission-digest",
      expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
    }
    |> Connection.create_changeset()
    |> Ecto.Changeset.change(
      connection_version: version,
      authorization_version: version,
      credential_version: version
    )
    |> Repo.insert!()
  end
end
