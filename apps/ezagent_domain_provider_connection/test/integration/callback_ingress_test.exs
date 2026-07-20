defmodule Ezagent.ProviderConnection.CallbackIngressTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ProviderConnection.{
    AuthorizationAttempt,
    AuthorizationBackendRecord,
    AuthorizationKeyRing,
    CallbackIngress,
    Connection,
    LocalAuthorizationBackend
  }

  alias EzagentCore.Repo

  setup do
    previous_redirects =
      Application.get_env(:ezagent_domain_provider_connection, :callback_redirect_pairs)

    Application.put_env(:ezagent_domain_provider_connection, :callback_redirect_pairs, %{
      "callback-v1" => "pair-alpha-v1"
    })

    on_exit(fn ->
      if previous_redirects,
        do:
          Application.put_env(
            :ezagent_domain_provider_connection,
            :callback_redirect_pairs,
            previous_redirects
          ),
        else:
          Application.delete_env(
            :ezagent_domain_provider_connection,
            :callback_redirect_pairs
          )
    end)

    :ok
  end

  test "ingress resolves only server-owned coordinates from keyed state" do
    owner = Ezagent.URI.user("acme", "alice")
    workspace = Ezagent.URI.workspace("acme")
    connection_id = Ecto.UUID.generate()
    attempt_ref = Ecto.UUID.generate()
    raw_state = "test-v1.opaque-state-secret"

    assert {:ok, _user} = Ezagent.Users.create(owner, nil, [])
    assert {:ok, pid} = Ezagent.SpawnRegistry.spawn(owner)
    _state = :sys.get_state(pid)
    artifact = callback_artifact(owner)

    insert_connection!(connection_id, owner, workspace)

    {:ok, digest} = LocalAuthorizationBackend.state_digest(raw_state)

    insert_attempt!(%{
      attempt_ref: attempt_ref,
      connection_id: connection_id,
      workspace_uri: URI.to_string(workspace),
      backend_pair_id: "pair-alpha-v1",
      authorization_ref: "authorization-ref-#{attempt_ref}",
      state_digest: digest,
      callback_artifact: Ezagent.Capability.to_map(artifact)
    })

    insert_backend_record!(attempt_ref, connection_id)

    assert {:ok, %{state: slice_state}} = GenServer.call(pid, :ezagent_runtime_view)

    assert {:ok, _snapshot} =
             Ezagent.SnapshotStore.write(owner, slice_state,
               kind_type: :user,
               workspace_uri: URI.to_string(workspace),
               version: 0
             )

    owner_monitor = Process.monitor(pid)

    :ok =
      DynamicSupervisor.terminate_child(
        EzagentDomainIdentity.Application.UserSupervisor,
        pid
      )

    assert_receive {:DOWN, ^owner_monitor, :process, ^pid, _reason}
    registry_barrier()
    :ok = Ezagent.ReadyGate.put(owner, :unknown)
    assert :error = Ezagent.KindRegistry.lookup(owner)
    assert {:ok, _durable_snapshot} = Ezagent.SnapshotStore.latest(owner)
    assert Ezagent.ReadyGate.status(owner) == :unknown

    Code.ensure_loaded!(Ezagent.Router)
    :erlang.trace_pattern({Ezagent.Router, :dispatch, 1}, true, [:local])

    envelope = %{
      code: "provider-code-secret",
      owner_uri: "entity://attacker/user/mallory",
      workspace_uri: "workspace://attacker",
      connection_id: Ecto.UUID.generate(),
      provider_id: "attacker-provider",
      governed_host: "attacker.example"
    }

    parent = self()
    tracer = spawn(fn -> collect_trace(parent, 0) end)
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])
    handler_id = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:ezagent, :provider_connection, :callback_ingress, :rejected],
        fn _event, _measurements, metadata, pid -> send(pid, {:callback_rejected, metadata}) end,
        self()
      )

    ingress_result = CallbackIngress.consume("callback-v1", raw_state, envelope)

    refute_receive {:callback_rejected, _metadata}
    assert_receive {:trace, _pid, :call, {Ezagent.Router, :dispatch, [cmd]}}
    send(tracer, {:stop, self()})
    assert_receive {:trace_count, 1}

    assert ingress_result == {:error, :state_mismatch}
    assert {:ok, _cold_started_pid} = Ezagent.KindRegistry.lookup(owner)

    assert cmd.target == owner
    assert cmd.ctx.caller == owner
    assert cmd.ctx.caps == MapSet.new([artifact])
    assert cmd.args.attempt_ref == attempt_ref
    refute inspect(cmd) =~ raw_state
    refute inspect(cmd) =~ "provider-code-secret"
    refute Map.has_key?(cmd.args, :owner_uri)
    refute Map.has_key?(cmd.args, :workspace_uri)
    refute Map.has_key?(cmd.args, :connection_id)
  after
    :telemetry.detach({__MODULE__, self()})
    :erlang.trace(self(), false, [:call])
    :erlang.trace_pattern({Ezagent.Router, :dispatch, 1}, false, [:local])
  end

  test "unknown redirect, key id, and digest make zero mutation" do
    before_count = Repo.aggregate(AuthorizationAttempt, :count, :attempt_ref)

    for {redirect, state} <- [
          {"unknown", "test-v1.opaque"},
          {"callback-v1", "unknown.opaque"},
          {"callback-v1", "test-v1.not-in-store"},
          {"callback-v1", "malformed"}
        ] do
      assert {:error, :callback_invalid} = CallbackIngress.consume(redirect, state, %{})
    end

    assert Repo.aggregate(AuthorizationAttempt, :count, :attempt_ref) == before_count
  end

  test "unknown redirect telemetry exposes only a fixed marker" do
    handler_id = {__MODULE__, self(), :unknown_redirect}

    :ok =
      :telemetry.attach(
        handler_id,
        [:ezagent, :provider_connection, :callback_ingress, :rejected],
        fn _event, _measurements, metadata, pid -> send(pid, {:callback_rejected, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    raw_redirect = "attacker-controlled-#{System.unique_integer([:positive])}"

    assert {:error, :callback_invalid} =
             CallbackIngress.consume(raw_redirect, "test-v1.opaque", %{})

    assert_receive {:callback_rejected, %{redirect_id: :unknown}}
    refute_receive {:callback_rejected, %{redirect_id: ^raw_redirect}}
  end

  test "production ingress has no key or dispatch injection and raw callback cannot enter Cmd" do
    Code.ensure_loaded!(CallbackIngress)
    assert function_exported?(CallbackIngress, :consume, 3)
    refute function_exported?(CallbackIngress, :consume, 4)
    refute function_exported?(CallbackIngress, :state_digest, 3)

    refute function_exported?(AuthorizationKeyRing, :digest_state, 1)
    refute function_exported?(AuthorizationKeyRing, :seal, 3)
    refute function_exported?(AuthorizationKeyRing, :seal_with, 4)
    refute function_exported?(AuthorizationKeyRing, :unseal, 3)

    assert {:ok, digest} = LocalAuthorizationBackend.state_digest("test-v1.public-struct-secret")

    assert is_binary(digest)
  end

  test "central verifier rejects a tampered stored artifact before callback staging" do
    owner = Ezagent.URI.user("acme", "tampered-owner")
    workspace = Ezagent.URI.workspace("acme")
    connection_id = Ecto.UUID.generate()
    attempt_ref = Ecto.UUID.generate()
    raw_state = "test-v1.tampered-artifact-state"

    assert {:ok, _user} = Ezagent.Users.create(owner, nil, [])
    assert {:ok, pid} = Ezagent.SpawnRegistry.spawn(owner)
    _state = :sys.get_state(pid)
    insert_connection!(connection_id, owner, workspace)
    {:ok, digest} = LocalAuthorizationBackend.state_digest(raw_state)

    tampered = %{callback_artifact(owner) | signature: "tampered-signature"}

    insert_attempt!(%{
      attempt_ref: attempt_ref,
      connection_id: connection_id,
      workspace_uri: URI.to_string(workspace),
      backend_pair_id: "pair-alpha-v1",
      authorization_ref: "authorization-ref-#{attempt_ref}",
      state_digest: digest,
      callback_artifact: Ezagent.Capability.to_map(tampered)
    })

    insert_backend_record!(attempt_ref, connection_id, owner)
    before = Repo.get!(AuthorizationAttempt, attempt_ref)

    assert {:error, :callback_invalid} =
             CallbackIngress.consume("callback-v1", raw_state, %{code: "secret-code"})

    assert Repo.get!(AuthorizationAttempt, attempt_ref) == before

    refute is_binary(
             Repo.get_by!(AuthorizationBackendRecord,
               authorization_ref: "authorization-ref-#{attempt_ref}"
             ).callback_ciphertext
           )
  end

  test "terminal connection rejects before staging, claim, or effects" do
    owner = Ezagent.URI.user("acme", "terminal-owner")
    workspace = Ezagent.URI.workspace("acme")
    connection_id = Ecto.UUID.generate()
    attempt_ref = Ecto.UUID.generate()
    raw_state = "test-v1.terminal-state"

    assert {:ok, _user} = Ezagent.Users.create(owner, nil, [])
    assert {:ok, pid} = Ezagent.SpawnRegistry.spawn(owner)
    _state = :sys.get_state(pid)
    insert_connection!(connection_id, owner, workspace, "revoked")
    {:ok, digest} = LocalAuthorizationBackend.state_digest(raw_state)

    insert_attempt!(%{
      attempt_ref: attempt_ref,
      connection_id: connection_id,
      workspace_uri: URI.to_string(workspace),
      backend_pair_id: "pair-alpha-v1",
      authorization_ref: "authorization-ref-#{attempt_ref}",
      state_digest: digest,
      callback_artifact: Ezagent.Capability.to_map(callback_artifact(owner))
    })

    insert_backend_record!(attempt_ref, connection_id, owner)
    before = Repo.get!(AuthorizationAttempt, attempt_ref)

    assert {:error, :callback_invalid} =
             CallbackIngress.consume("callback-v1", raw_state, %{code: "secret-code"})

    assert Repo.get!(AuthorizationAttempt, attempt_ref) == before

    refute is_binary(
             Repo.get_by!(AuthorizationBackendRecord,
               authorization_ref: "authorization-ref-#{attempt_ref}"
             ).callback_ciphertext
           )
  end

  test "ingress rejects non-canonical attempt bindings before callback staging" do
    owner = Ezagent.URI.user("acme", "canonical-owner")
    workspace = Ezagent.URI.workspace("acme")
    connection_id = Ecto.UUID.generate()
    attempt_ref = Ecto.UUID.generate()
    raw_state = "test-v1.canonical-binding-state"

    assert {:ok, _user} = Ezagent.Users.create(owner, nil, [])
    assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(owner)
    insert_connection!(connection_id, owner, workspace)
    {:ok, state_digest} = LocalAuthorizationBackend.state_digest(raw_state)
    artifact = callback_artifact(owner)

    attempt =
      insert_attempt!(%{
        attempt_ref: attempt_ref,
        connection_id: connection_id,
        workspace_uri: URI.to_string(workspace),
        backend_pair_id: "pair-alpha-v1",
        authorization_ref: "authorization-ref-#{attempt_ref}",
        state_digest: state_digest,
        callback_artifact: Ezagent.Capability.to_map(artifact),
        reservation_digest: "swapped-reservation"
      })

    backend = insert_backend_record!(attempt_ref, connection_id, owner)

    assert attempt.reservation_digest == "swapped-reservation"

    assert {:error, :callback_invalid} =
             CallbackIngress.consume("callback-v1", raw_state, %{code: "secret-code"})

    refute is_binary(Repo.get!(AuthorizationBackendRecord, backend.id).callback_ciphertext)
  end

  test "refresh_required is not a legal callback source" do
    owner = Ezagent.URI.user("acme", "refresh-required-owner")
    workspace = Ezagent.URI.workspace("acme")
    connection_id = Ecto.UUID.generate()
    attempt_ref = Ecto.UUID.generate()
    raw_state = "test-v1.refresh-required-state"

    assert {:ok, _user} = Ezagent.Users.create(owner, nil, [])
    assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(owner)
    insert_connection!(connection_id, owner, workspace, "refresh_required")
    {:ok, state_digest} = LocalAuthorizationBackend.state_digest(raw_state)

    insert_attempt!(%{
      attempt_ref: attempt_ref,
      connection_id: connection_id,
      workspace_uri: URI.to_string(workspace),
      backend_pair_id: "pair-alpha-v1",
      authorization_ref: "authorization-ref-#{attempt_ref}",
      state_digest: state_digest,
      purpose: "reauthorize",
      callback_artifact: Ezagent.Capability.to_map(callback_artifact(owner))
    })

    backend = insert_backend_record!(attempt_ref, connection_id, owner)

    assert {:error, :callback_invalid} =
             CallbackIngress.consume("callback-v1", raw_state, %{code: "secret-code"})

    refute is_binary(Repo.get!(AuthorizationBackendRecord, backend.id).callback_ciphertext)
  end

  defp insert_connection!(connection_id, owner, workspace, status \\ "pending_authorization") do
    attrs =
      %{
        connection_id: connection_id,
        workspace_uri: URI.to_string(workspace),
        owner_uri: URI.to_string(owner),
        provider_id: "task7-provider",
        governed_host: "example.test",
        requested_execution_identity_class: "connected_user",
        acquisition_method: "oauth_user",
        status: status
      }
      |> then(fn attrs ->
        if status == "pending_authorization" do
          attrs
        else
          Map.merge(attrs, %{
            external_account_id: "account-#{connection_id}",
            display_login: "alice",
            execution_identity: "connected_user",
            authorization_backend_ref: "auth-ref",
            credential_backend_ref: "credential-ref"
          })
        end
      end)

    Repo.insert!(Connection.create_changeset(attrs))
  end

  defp insert_attempt!(overrides) do
    attrs =
      Map.merge(
        %{
          authorization_ref: "authorization-ref-#{System.unique_integer([:positive])}",
          connection_version: 0,
          purpose: "initial_bind",
          requested_permission_digest: "permissions",
          requested_execution_identity_class: "connected_user",
          redirect_uri_id: "callback-v1",
          bound_subject_digest: "subject-digest",
          correlation_id: "callback-correlation",
          status: "pending",
          expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
        },
        overrides
      )

    connection = Repo.get!(Connection, attrs.connection_id)
    artifact_digest = digest(attrs.callback_artifact)

    attrs =
      attrs
      |> Map.put_new(:callback_artifact_digest, artifact_digest)
      |> Map.put_new(
        :reservation_digest,
        digest({
          "initial_bind",
          connection.connection_id,
          connection.connection_version,
          connection.owner_uri,
          connection.workspace_uri,
          connection.provider_id,
          connection.governed_host,
          connection.acquisition_method,
          attrs.requested_execution_identity_class,
          attrs.requested_permission_digest,
          attrs.redirect_uri_id,
          "begin-correlation",
          artifact_digest
        })
      )

    Repo.insert!(AuthorizationAttempt.create_changeset(attrs))
  end

  defp digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp insert_backend_record!(
         attempt_ref,
         connection_id,
         owner \\ Ezagent.URI.user("acme", "alice")
       ) do
    attrs = %{
      id: Ecto.UUID.generate(),
      workspace_uri: URI.to_string(Ezagent.URI.workspace("acme")),
      backend_pair_id: "pair-alpha-v1",
      authorization_ref: "authorization-ref-#{attempt_ref}",
      key_id: "test-v1",
      key_fingerprint: :crypto.hash(:sha256, :binary.copy(<<90>>, 32)),
      nonce: :binary.copy(<<1>>, 12),
      ciphertext: :binary.copy(<<2>>, 32),
      bound_input_digest: "subject-digest",
      begin_correlation_id: "begin-correlation",
      owner_uri: URI.to_string(owner),
      execution_identity: "connected_user",
      connection_id: connection_id,
      connection_version: 0,
      provider_id: "task7-provider",
      governed_host: "example.test",
      acquisition_method: "oauth_user",
      requested_permissions_digest: "permissions",
      redirect_uri_id: "callback-v1",
      lifecycle_status: "pending",
      expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
    }

    Repo.insert!(AuthorizationBackendRecord.create_changeset(attrs))
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

  defp collect_trace(parent, count) do
    receive do
      {:stop, caller} ->
        send(caller, {:trace_count, count})

      {:trace, _pid, :call, {Ezagent.Router, :dispatch, [_cmd]}} = message ->
        send(parent, message)
        collect_trace(parent, count + 1)

      _message ->
        collect_trace(parent, count)
    end
  end

  defp registry_barrier do
    for {_id, partition, :worker, [Registry.Partition]} <-
          Supervisor.which_children(Ezagent.KindRegistry) do
      _state = :sys.get_state(partition)
    end

    :ok
  end
end
