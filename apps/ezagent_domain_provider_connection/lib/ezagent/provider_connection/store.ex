defmodule Ezagent.ProviderConnection.Store do
  @moduledoc "Durable provider-connection callback and credential handoff boundary."

  import Ecto.Query

  alias Ezagent.ProviderConnection.{
    AuthorizationAttempt,
    AuthorizationBackendRecord,
    Connection,
    CredentialReplacement,
    LocalAuthorizationBackend,
    Operation,
    ProviderAuthorizationCommand,
    Refresh,
    Termination
  }

  alias Ezagent.ProviderConnection.LocalAuthorizationBackend.Support, as: BackendSupport
  alias EzagentCore.Repo

  @claim_seconds 30

  @doc "Executes the implemented owner command boundary."
  def execute(:begin_authorization, args, %{self_uri: %URI{} = owner} = ctx) do
    with {:ok, {connection, reservation}} <- reserve_initial_begin(args, owner),
         subject <- subject(connection, owner, args.requested_execution_identity_class),
         {:ok, started} <-
           begin_authorization(
             "initial_bind",
             connection,
             reservation,
             args,
             subject
           ),
         :ok <- before_begin_settle(ctx, connection, reservation),
         {:ok, state} <- fetch_string(started.redirect, "state"),
         {:ok, state_digest} <-
           LocalAuthorizationBackend.state_digest(state),
         %AuthorizationBackendRecord{} = backend_record <-
           Repo.get_by(AuthorizationBackendRecord,
             authorization_ref: started.authorization_ref
           ),
         {:ok, attempt} <-
           settle_initial_begin(
             connection,
             reservation,
             backend_record,
             state_digest,
             args.callback_artifact
           ) do
      {:ok,
       %{
         attempt_ref: attempt.attempt_ref,
         authorization_url: started.redirect["authorization_uri"],
         expires_at: DateTime.to_iso8601(started.expires_at)
       }}
    else
      {:error, _reason} = error -> error
      _reason -> {:error, :callback_invalid}
    end
  end

  def execute(:reauthorize, args, %{self_uri: %URI{} = owner}) do
    with {:ok, {connection, reservation}} <- reserve_reauthorization(args, owner),
         subject <- subject(connection, owner, args.requested_execution_identity_class),
         {:ok, started} <-
           begin_authorization(
             "reauthorize",
             connection,
             reservation,
             args,
             subject
           ),
         {:ok, state} <- fetch_string(started.redirect, "state"),
         {:ok, state_digest} <- LocalAuthorizationBackend.state_digest(state),
         %AuthorizationBackendRecord{} = backend_record <-
           Repo.get_by(AuthorizationBackendRecord,
             authorization_ref: started.authorization_ref
           ),
         {:ok, attempt} <-
           settle_reauthorization(
             connection,
             reservation,
             backend_record,
             state_digest,
             args.callback_artifact
           ) do
      {:ok,
       %{
         attempt_ref: attempt.attempt_ref,
         authorization_url: started.redirect["authorization_uri"],
         expires_at: DateTime.to_iso8601(started.expires_at)
       }}
    else
      {:error, _reason} = error -> error
      _reason -> {:error, :callback_invalid}
    end
  end

  def execute(:consume_callback, args, %{self_uri: %URI{} = owner} = ctx) do
    case Ecto.UUID.cast(args.attempt_ref) do
      {:ok, _attempt_ref} -> execute_callback(args, owner, ctx)
      :error -> {:error, :callback_invalid}
    end
  end

  def execute(:refresh, args, %{self_uri: %URI{} = owner} = ctx) do
    with {:ok, _connection_id} <- Ecto.UUID.cast(args.connection_id),
         %Connection{} = connection <- owned_connection(args.connection_id, owner),
         true <- is_integer(args.expected_version),
         true <- is_binary(args.correlation_id) and args.correlation_id != "" do
      Refresh.execute(connection, args, Map.get(ctx, :now, DateTime.utc_now()))
    else
      :error -> {:error, :invalid_authorization_subject}
      nil -> {:error, :invalid_authorization_subject}
      false -> {:error, :credential_conflict}
      {:error, _reason} = error -> error
    end
  end

  def execute(action, args, %{self_uri: %URI{} = owner}) when action in [:revoke, :disconnect] do
    with {:ok, _connection_id} <- Ecto.UUID.cast(args.connection_id),
         %Connection{} = connection <- owned_connection(args.connection_id, owner),
         true <- is_integer(args.expected_version) do
      Termination.execute(connection, action, args.expected_version)
    else
      :error -> {:error, :invalid_authorization_subject}
      nil -> {:error, :invalid_authorization_subject}
      false -> {:error, :credential_conflict}
      {:error, _reason} = error -> error
    end
  end

  def execute(:read_connection, args, %{self_uri: %URI{} = owner}) do
    with {:ok, _connection_id} <- Ecto.UUID.cast(args.connection_id),
         %Connection{} = connection <- owned_connection(args.connection_id, owner) do
      {:ok, %{connection: safe_connection_view(connection)}}
    else
      _reason -> {:error, :invalid_authorization_subject}
    end
  end

  def execute(_action, _args, _ctx),
    do: {:error, :unsupported_provider_connection_action}

  defp execute_callback(args, owner, ctx) do
    now = Map.get(ctx, :now, DateTime.utc_now())

    with %AuthorizationAttempt{} = attempt <- Repo.get(AuthorizationAttempt, args.attempt_ref),
         true <- attempt.correlation_id == args.correlation_id,
         %Connection{} = connection <- owned_connection(attempt.connection_id, owner),
         :ok <- callback_source_status(connection.status),
         result <- dispatch_callback_phase(attempt, connection, owner, now) do
      result
    else
      false -> {:error, :correlation_conflict}
      nil -> {:error, :callback_invalid}
      {:error, _reason} = error -> error
      _reason -> {:error, :credential_conflict}
    end
  end

  defp dispatch_callback_phase(attempt, connection, owner, now) do
    case operation_for(attempt) do
      %Operation{status: "backend_committed"} = operation ->
        if Repo.get_by(AuthorizationBackendRecord, authorization_ref: attempt.authorization_ref) do
          if final_operation_scope?(operation, attempt, connection),
            do: finish_callback(operation),
            else: {:error, :stale_attempt_claim}
        else
          {:error, :credential_conflict}
        end

      %Operation{status: status} = operation
      when status in ["connection_committed", "finalized"] ->
        if final_operation_scope?(operation, attempt, connection),
          do: finish_callback(operation),
          else: {:error, :stale_attempt_claim}

      %Operation{status: "prepared"} = operation ->
        resume_prepared(operation, attempt, connection, owner, now)

      nil ->
        consume_to_backend_commit(attempt, connection, owner, now)

      %Operation{} ->
        {:error, :credential_conflict}
    end
  end

  defp consume_to_backend_commit(attempt, connection, owner, now) do
    with {:ok, claim} <-
           AuthorizationAttempt.claim_for_connection(
             attempt.attempt_ref,
             connection.connection_id,
             URI.to_string(owner),
             now,
             @claim_seconds
           ),
         {:ok, operation} <- prepare_operation(claim, connection),
         :ok <- validate_fence_locked(operation, claim, connection),
         {:ok, callback_result} <- consume_authorization(claim, connection, owner),
         {:write_only_handoff, handoff_ref} <- callback_result.credential_material,
         {:ok, operation} <- bind_handoff(operation, claim, connection, handoff_ref),
         :ok <- validate_fence_locked(operation, claim, connection),
         {:ok, credential_result} <-
           LocalAuthorizationBackend.handoff_to_registered_credential(
             operation.id,
             claim.attempt_ref
           ),
         {:ok, operation} <-
           journal_credential_result(operation, claim, connection, credential_result),
         {:ok, operation} <- CredentialReplacement.commit(operation.id) do
      {:ok, logical_result(Repo.get!(Connection, connection.connection_id), operation)}
    else
      {:error, _reason} = error -> error
      _reason -> {:error, :credential_conflict}
    end
  end

  defp owned_connection(connection_id, owner) do
    Repo.one(
      from(connection in Connection,
        where:
          connection.connection_id == ^connection_id and
            connection.owner_uri == ^URI.to_string(owner) and
            connection.workspace_uri == ^URI.to_string(Ezagent.Capability.workspace_of(owner))
      )
    )
  end

  defp safe_connection_view(connection) do
    %{
      connection_id: connection.connection_id,
      workspace_uri: connection.workspace_uri,
      owner_uri: connection.owner_uri,
      provider_id: connection.provider_id,
      governed_host: connection.governed_host,
      external_account_id: connection.external_account_id,
      display_login: connection.display_login,
      execution_identity: connection.execution_identity,
      requested_execution_identity_class: connection.requested_execution_identity_class,
      acquisition_method: connection.acquisition_method,
      status: connection.status,
      permission_digest: connection.permission_digest,
      expires_at: encode_datetime(connection.expires_at),
      last_error_code: connection.last_error_code,
      version: connection.connection_version
    }
  end

  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(nil), do: nil

  defp reserve_initial_begin(args, owner) do
    with {:ok, connection_id} <- Ecto.UUID.cast(args.connection_id) do
      Repo.transaction(fn ->
        lock_connection_key(connection_id)

        case lock_connection(connection_id) do
          nil -> insert_initial_reservation(args, owner, connection_id)
          %Connection{} = connection -> reconcile_initial_reservation(connection, args, owner)
        end
      end)
      |> unwrap_transaction()
    else
      :error -> {:error, :invalid_authorization_subject}
    end
  end

  defp reconcile_initial_reservation(connection, args, owner) do
    owner_uri = URI.to_string(owner)
    workspace_uri = URI.to_string(Ezagent.Capability.workspace_of(owner))
    artifact_digest = callback_artifact_digest(args.callback_artifact)
    reservation_digest = reservation_digest("initial_bind", connection, args, artifact_digest)

    cond do
      connection.owner_uri != owner_uri or connection.workspace_uri != workspace_uri ->
        Repo.rollback(:invalid_authorization_subject)

      connection.status != "pending_authorization" ->
        Repo.rollback(:connection_terminal)

      true ->
        case lock_open_attempt(connection.connection_id) do
          %AuthorizationAttempt{purpose: "initial_bind"} = attempt ->
            if attempt.connection_version == connection.connection_version and
                 attempt.reservation_digest == reservation_digest do
              {connection, attempt}
            else
              Repo.rollback(:correlation_conflict)
            end

          nil ->
            reconcile_cancelled_or_insert_initial(
              connection,
              args,
              artifact_digest,
              reservation_digest
            )

          _other ->
            Repo.rollback(:correlation_conflict)
        end
    end
  end

  defp reconcile_cancelled_or_insert_initial(
         connection,
         args,
         artifact_digest,
         reservation_digest
       ) do
    case lock_cancelled_attempt(connection.connection_id, "initial_bind", args.correlation_id) do
      %AuthorizationAttempt{
        connection_version: version,
        reservation_digest: ^reservation_digest
      } = attempt
      when version == connection.connection_version ->
        {connection, attempt}

      %AuthorizationAttempt{} ->
        Repo.rollback(:correlation_conflict)

      nil ->
        if initial_scope_matches?(connection, args) do
          connection
          |> insert_begin_attempt("initial_bind", args, artifact_digest, reservation_digest)
          |> then(&{connection, &1})
        else
          Repo.rollback(:correlation_conflict)
        end
    end
  end

  defp insert_initial_reservation(args, owner, connection_id) do
    workspace = Ezagent.Capability.workspace_of(owner)
    artifact_digest = callback_artifact_digest(args.callback_artifact)

    connection_attrs = %{
      connection_id: connection_id,
      workspace_uri: URI.to_string(workspace),
      owner_uri: URI.to_string(owner),
      provider_id: args.provider_id,
      governed_host: args.governed_host,
      requested_execution_identity_class: args.requested_execution_identity_class,
      acquisition_method: args.acquisition_method,
      status: "pending_authorization"
    }

    with {:ok, connection} <- Repo.insert(Connection.create_changeset(connection_attrs)),
         {:ok, attempt} <-
           Repo.insert(
             begin_attempt_changeset(
               connection,
               "initial_bind",
               args,
               artifact_digest,
               reservation_digest("initial_bind", connection, args, artifact_digest)
             )
           ) do
      {connection, attempt}
    else
      {:error, _changeset} -> Repo.rollback(:invalid_authorization_subject)
    end
  end

  defp reserve_reauthorization(args, owner) do
    with {:ok, connection_id} <- Ecto.UUID.cast(args.connection_id),
         true <- is_integer(args.expected_version) do
      Repo.transaction(fn ->
        connection = lock_connection(connection_id)

        with %Connection{} <- connection,
             true <- connection.owner_uri == URI.to_string(owner),
             true <-
               connection.workspace_uri ==
                 URI.to_string(Ezagent.Capability.workspace_of(owner)) do
          cond do
            connection.connection_version != args.expected_version ->
              Repo.rollback(:stale_version)

            connection.status not in ["active", "degraded", "expired"] ->
              Repo.rollback(:connection_terminal)

            true ->
              reconcile_or_insert_reauthorization(connection, args)
          end
        else
          _reason -> Repo.rollback(:invalid_authorization_subject)
        end
      end)
      |> unwrap_transaction()
    else
      :error -> {:error, :invalid_authorization_subject}
      false -> {:error, :stale_version}
    end
  end

  defp reconcile_or_insert_reauthorization(connection, args) do
    artifact_digest = callback_artifact_digest(args.callback_artifact)

    reservation_digest =
      reservation_digest("reauthorize", connection, args, artifact_digest)

    case lock_open_attempt(connection.connection_id) do
      nil ->
        reconcile_cancelled_or_insert_reauthorization(
          connection,
          args,
          artifact_digest,
          reservation_digest
        )

      %AuthorizationAttempt{
        purpose: "reauthorize",
        connection_version: version,
        reservation_digest: ^reservation_digest
      } = attempt
      when version == connection.connection_version ->
        {connection, attempt}

      _other ->
        Repo.rollback(:correlation_conflict)
    end
  end

  defp reconcile_cancelled_or_insert_reauthorization(
         connection,
         args,
         artifact_digest,
         reservation_digest
       ) do
    case lock_cancelled_attempt(connection.connection_id, "reauthorize", args.correlation_id) do
      %AuthorizationAttempt{
        connection_version: version,
        reservation_digest: ^reservation_digest
      } = attempt
      when version == connection.connection_version ->
        {connection, attempt}

      %AuthorizationAttempt{} ->
        Repo.rollback(:correlation_conflict)

      nil ->
        connection
        |> insert_begin_attempt("reauthorize", args, artifact_digest, reservation_digest)
        |> then(&{connection, &1})
    end
  end

  defp insert_begin_attempt(connection, purpose, args, artifact_digest, reservation_digest) do
    connection
    |> begin_attempt_changeset(purpose, args, artifact_digest, reservation_digest)
    |> Repo.insert!()
  end

  defp begin_attempt_changeset(
         connection,
         purpose,
         args,
         artifact_digest,
         reservation_digest
       ) do
    AuthorizationAttempt.create_changeset(%{
      attempt_ref: Ecto.UUID.generate(),
      workspace_uri: connection.workspace_uri,
      connection_id: connection.connection_id,
      connection_version: connection.connection_version,
      purpose: purpose,
      reservation_digest: reservation_digest,
      requested_permission_digest: args.requested_permissions_digest,
      requested_execution_identity_class: args.requested_execution_identity_class,
      redirect_uri_id: args.redirect_uri_id,
      callback_artifact_digest: artifact_digest,
      correlation_id: args.correlation_id,
      callback_artifact: Ezagent.Capability.to_map(args.callback_artifact),
      status: "beginning"
    })
  end

  defp initial_scope_matches?(connection, args) do
    connection.provider_id == args.provider_id and
      connection.governed_host == args.governed_host and
      connection.acquisition_method == args.acquisition_method and
      connection.requested_execution_identity_class == args.requested_execution_identity_class
  end

  defp settle_initial_begin(
         connection,
         reservation,
         backend_record,
         state_digest,
         artifact
       ) do
    Repo.transaction(fn ->
      locked_connection = lock_connection(connection.connection_id)
      locked_attempt = lock_attempt(reservation.attempt_ref)

      cond do
        not match?(%Connection{status: "pending_authorization"}, locked_connection) ->
          cancel_begin_reservation(locked_attempt)
          {:closed, :connection_terminal}

        not match?(%AuthorizationAttempt{}, locked_attempt) or
            locked_attempt.status not in ["beginning", "pending", "consuming"] ->
          Repo.rollback(:correlation_conflict)

        locked_attempt.connection_id != locked_connection.connection_id or
          locked_attempt.connection_version != locked_connection.connection_version or
            locked_attempt.callback_artifact_digest != callback_artifact_digest(artifact) ->
          Repo.rollback(:correlation_conflict)

        locked_attempt.status in ["pending", "consuming"] and
          locked_attempt.backend_pair_id == backend_record.backend_pair_id and
          locked_attempt.authorization_ref == backend_record.authorization_ref and
          locked_attempt.bound_subject_digest == backend_record.bound_input_digest and
          locked_attempt.state_digest == state_digest and
            locked_attempt.correlation_id ==
              callback_correlation(backend_record.authorization_ref) ->
          locked_attempt

        locked_attempt.status in ["pending", "consuming"] ->
          Repo.rollback(:correlation_conflict)

        true ->
          locked_attempt
          |> Ecto.Changeset.change(
            backend_pair_id: backend_record.backend_pair_id,
            authorization_ref: backend_record.authorization_ref,
            bound_subject_digest: backend_record.bound_input_digest,
            state_digest: state_digest,
            correlation_id: callback_correlation(backend_record.authorization_ref),
            status: "pending",
            expires_at: backend_record.expires_at
          )
          |> Repo.update!()
      end
    end)
    |> unwrap_begin_settle()
  end

  defp cancel_begin_reservation(%AuthorizationAttempt{} = attempt) do
    attempt
    |> Ecto.Changeset.change(
      status: "cancelled",
      claim_token: nil,
      claim_until: nil
    )
    |> Repo.update!()
  end

  defp cancel_begin_reservation(_missing), do: :ok

  defp unwrap_begin_settle({:ok, {:closed, reason}}), do: {:error, reason}
  defp unwrap_begin_settle(result), do: unwrap_transaction(result)

  defp settle_reauthorization(connection, reservation, backend_record, state_digest, artifact) do
    Repo.transaction(fn ->
      locked_connection = lock_connection(connection.connection_id)
      locked_attempt = lock_attempt(reservation.attempt_ref)

      cond do
        not match?(%Connection{}, locked_connection) or
            locked_connection.status not in ["active", "degraded", "expired"] ->
          cancel_begin_reservation(locked_attempt)
          {:closed, :connection_terminal}

        locked_connection.connection_version != reservation.connection_version ->
          cancel_begin_reservation(locked_attempt)
          {:closed, :stale_version}

        not match?(%AuthorizationAttempt{}, locked_attempt) or
            locked_attempt.status not in ["beginning", "pending", "consuming"] ->
          Repo.rollback(:correlation_conflict)

        locked_attempt.connection_id != locked_connection.connection_id or
          locked_attempt.connection_version != locked_connection.connection_version or
            locked_attempt.callback_artifact_digest != callback_artifact_digest(artifact) ->
          Repo.rollback(:correlation_conflict)

        locked_attempt.status in ["pending", "consuming"] and
          locked_attempt.backend_pair_id == backend_record.backend_pair_id and
          locked_attempt.authorization_ref == backend_record.authorization_ref and
          locked_attempt.bound_subject_digest == backend_record.bound_input_digest and
          locked_attempt.state_digest == state_digest and
            locked_attempt.correlation_id ==
              callback_correlation(backend_record.authorization_ref) ->
          locked_attempt

        locked_attempt.status in ["pending", "consuming"] ->
          Repo.rollback(:correlation_conflict)

        true ->
          locked_attempt
          |> Ecto.Changeset.change(
            backend_pair_id: backend_record.backend_pair_id,
            authorization_ref: backend_record.authorization_ref,
            bound_subject_digest: backend_record.bound_input_digest,
            state_digest: state_digest,
            correlation_id: callback_correlation(backend_record.authorization_ref),
            status: "pending",
            expires_at: backend_record.expires_at
          )
          |> Repo.update!()
      end
    end)
    |> unwrap_begin_settle()
  end

  defp callback_artifact_digest(%Ezagent.Capability{} = artifact) do
    artifact
    |> Ezagent.Capability.to_map()
    |> digest()
  end

  defp callback_artifact_digest(_artifact), do: digest(:invalid_callback_artifact)

  defp begin_authorization(purpose, connection, reservation, args, subject) do
    request = %{
      subject: subject,
      acquisition_method: connection.acquisition_method,
      requested_permissions_digest: args.requested_permissions_digest,
      redirect_uri_id: args.redirect_uri_id,
      correlation_id: args.correlation_id
    }

    case LocalAuthorizationBackend.begin_authorization(request) do
      {:ok, _started} = ok ->
        ok

      {:error, reason} = error ->
        settle_terminal_begin_failure(purpose, connection, reservation, reason)
        error
    end
  end

  defp settle_terminal_begin_failure(purpose, connection, reservation, reason) do
    with %AuthorizationBackendRecord{} = backend_record <-
           Repo.get_by(AuthorizationBackendRecord,
             connection_id: connection.connection_id,
             connection_version: connection.connection_version,
             begin_correlation_id: reservation.correlation_id
           ),
         %ProviderAuthorizationCommand{
           status: "terminal_failed",
           safe_error_code: safe_error_code,
           authorization_ref: authorization_ref
         } <-
           Repo.get_by(ProviderAuthorizationCommand,
             backend_pair_id: backend_record.backend_pair_id,
             operation_class: "begin",
             correlation_id: reservation.correlation_id
           ),
         true <- authorization_ref == backend_record.authorization_ref,
         true <- safe_error_code == Atom.to_string(reason) do
      cancel_terminal_begin_reservation(purpose, connection, reservation, backend_record)
    else
      _uncertain_or_retryable -> :ok
    end
  end

  defp cancel_terminal_begin_reservation(purpose, connection, reservation, backend_record) do
    _ =
      Repo.transaction(fn ->
        locked_connection = lock_connection(connection.connection_id)
        locked_attempt = lock_attempt(reservation.attempt_ref)

        if match?(%Connection{}, locked_connection) and
             match?(%AuthorizationAttempt{}, locked_attempt) and
             locked_attempt.connection_id == locked_connection.connection_id and
             locked_attempt.connection_version == connection.connection_version and
             locked_attempt.purpose == purpose and
             locked_attempt.reservation_digest == reservation.reservation_digest and
             locked_attempt.status == "beginning" do
          locked_attempt
          |> Ecto.Changeset.change(
            backend_pair_id: backend_record.backend_pair_id,
            authorization_ref: backend_record.authorization_ref,
            bound_subject_digest: backend_record.bound_input_digest,
            status: "cancelled",
            claim_token: nil,
            claim_until: nil
          )
          |> Repo.update!()
        end

        :ok
      end)

    :ok
  end

  defp reservation_digest(purpose, connection, args, artifact_digest) do
    digest({
      purpose,
      connection.connection_id,
      connection.connection_version,
      connection.owner_uri,
      connection.workspace_uri,
      connection.provider_id,
      connection.governed_host,
      connection.acquisition_method,
      args.requested_execution_identity_class,
      args.requested_permissions_digest,
      args.redirect_uri_id,
      args.correlation_id,
      artifact_digest
    })
  end

  defp digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  if Mix.env() == :test do
    defp before_begin_settle(%{before_begin_settle: barrier}, connection, reservation)
         when is_function(barrier, 2) do
      _ = barrier.(connection, reservation)
      :ok
    end

    defp before_begin_settle(_ctx, _connection, _reservation), do: :ok
  else
    defp before_begin_settle(_ctx, _connection, _reservation), do: :ok
  end

  defp callback_correlation(authorization_ref) do
    "callback:" <>
      (:crypto.hash(:sha256, authorization_ref) |> Base.url_encode64(padding: false))
  end

  defp lock_open_attempt(connection_id) do
    AuthorizationAttempt
    |> where(
      [attempt],
      attempt.connection_id == ^connection_id and
        attempt.status in ["beginning", "pending", "consuming"]
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_cancelled_attempt(connection_id, purpose, correlation_id) do
    AuthorizationAttempt
    |> where(
      [attempt],
      attempt.connection_id == ^connection_id and attempt.purpose == ^purpose and
        attempt.correlation_id == ^correlation_id and attempt.status == "cancelled"
    )
    |> order_by([attempt], desc: attempt.inserted_at)
    |> limit(1)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp consume_authorization(attempt, connection, owner) do
    LocalAuthorizationBackend.consume_callback(%{
      authorization_ref: attempt.authorization_ref,
      expected_subject: subject(connection, owner),
      correlation_id: attempt.correlation_id
    })
  end

  defp prepare_operation(attempt, connection) do
    correlation_id = "store:#{attempt.correlation_id}"
    now = DateTime.utc_now()
    {prior_credential_ref, prior_credential_version} = prior_credential(connection)

    backend_record =
      Repo.get_by(AuthorizationBackendRecord, authorization_ref: attempt.authorization_ref)

    with %AuthorizationBackendRecord{} <- backend_record,
         :ok <- stable_scope(backend_record, attempt, connection) do
      digest = Operation.callback_digest(backend_record, attempt, connection)

      attrs = %{
        workspace_uri: connection.workspace_uri,
        connection_id: connection.connection_id,
        attempt_ref: attempt.attempt_ref,
        backend_pair_id: attempt.backend_pair_id,
        operation_class: "store",
        correlation_id: correlation_id,
        bound_input_digest: digest,
        expected_connection_version: connection.connection_version,
        expected_credential_version: connection.credential_version,
        prior_credential_ref: prior_credential_ref,
        prior_credential_version: prior_credential_version,
        attempt_version: attempt.attempt_version,
        attempt_claim_token: attempt.claim_token,
        next_recovery_at: now,
        status: "prepared"
      }

      case Repo.insert(Operation.create_changeset(attrs)) do
        {:ok, operation} ->
          {:ok, operation}

        {:error, _changeset} ->
          reconcile_operation(attempt.backend_pair_id, correlation_id, digest)
      end
    else
      _reason -> {:error, :credential_conflict}
    end
  end

  defp prior_credential(%Connection{
         status: "pending_authorization",
         credential_backend_ref: nil
       }),
       do: {nil, nil}

  defp prior_credential(connection),
    do: {connection.credential_backend_ref, connection.credential_version}

  defp reconcile_operation(pair_id, correlation_id, digest) do
    case Repo.get_by(Operation,
           backend_pair_id: pair_id,
           operation_class: "store",
           correlation_id: correlation_id
         ) do
      %Operation{bound_input_digest: ^digest} = operation -> {:ok, operation}
      %Operation{} -> {:error, :correlation_conflict}
      nil -> {:error, :credential_conflict}
    end
  end

  defp bind_handoff(
         %Operation{status: "prepared", handoff_ref: nil} = operation,
         attempt,
         connection,
         handoff_ref
       ) do
    if operation_fence_matches?(operation, attempt, connection) do
      operation
      |> Ecto.Changeset.change(handoff_ref: handoff_ref)
      |> Repo.update()
    else
      fence_if_terminal(operation)
    end
  end

  defp bind_handoff(
         %Operation{status: "prepared", handoff_ref: handoff_ref} = operation,
         attempt,
         connection,
         handoff_ref
       ) do
    if operation_fence_matches?(operation, attempt, connection),
      do: {:ok, operation},
      else: fence_if_terminal(operation)
  end

  defp bind_handoff(_operation, _attempt, _connection, _handoff_ref),
    do: {:error, :credential_conflict}

  defp journal_credential_result(
         %Operation{status: "backend_committed"} = operation,
         _attempt,
         _connection,
         _result
       ),
       do: {:ok, operation}

  defp journal_credential_result(operation, attempt, connection, result) do
    Repo.transaction(fn ->
      locked_connection = lock_connection(connection.connection_id)
      locked_attempt = lock_attempt(attempt.attempt_ref)
      locked_operation = lock_operation(operation.id)

      attrs = %{
        result_ref: result.credential_ref,
        result_credential_version: result.credential_version
      }

      case locked_operation do
        %Operation{status: "prepared"} ->
          if current_operation_fence?(locked_operation, locked_attempt, locked_connection) do
            locked_operation
            |> Operation.backend_commit_changeset(attrs)
            |> Repo.update!()
            |> then(&{:backend_committed, &1})
          else
            locked_operation
            |> Operation.cleanup_pending_changeset(
              Map.put(attrs, :safe_error_code, "cleanup_pending")
            )
            |> Repo.update!()
            |> then(&{:cleanup_pending, &1})
          end

        %Operation{status: status} = journaled
        when status in ["backend_committed", "cleanup_pending"] ->
          if journaled.result_ref == result.credential_ref and
               journaled.result_credential_version == result.credential_version do
            {String.to_existing_atom(status), journaled}
          else
            Repo.rollback(:credential_conflict)
          end

        %Operation{} ->
          Repo.rollback(:credential_conflict)

        nil ->
          Repo.rollback(:credential_conflict)
      end
    end)
    |> case do
      {:ok, {:backend_committed, committed}} ->
        {:ok, committed}

      {:ok, {:cleanup_pending, operation}} ->
        case CredentialReplacement.cleanup(operation.id) do
          :ok -> {:error, :connection_terminal}
          {:error, :stale_version} -> {:error, :credential_conflict}
          {:error, _reason} -> {:error, :authorization_backend_unavailable}
        end

      {:error, _reason} ->
        {:error, :credential_conflict}
    end
  end

  defp operation_for(attempt),
    do:
      Repo.get_by(Operation,
        backend_pair_id: attempt.backend_pair_id,
        operation_class: "store",
        correlation_id: "store:#{attempt.correlation_id}"
      )

  defp logical_result(connection, operation),
    do: %{
      connection_id: connection.connection_id,
      status: operation.status,
      version: connection.connection_version
    }

  defp callback_source_status(status)
       when status in ["pending_authorization", "active", "refresh_required", "degraded"],
       do: :ok

  defp callback_source_status(_status), do: {:error, :connection_terminal}

  defp resume_prepared(operation, attempt, connection, owner, now) do
    with {:ok, {operation, attempt, connection}} <-
           claim_prepared(operation, attempt, connection, owner, now),
         :ok <- validate_fence_locked(operation, attempt, connection),
         {:ok, callback_result} <- consume_authorization(attempt, connection, owner),
         {:write_only_handoff, handoff_ref} <- callback_result.credential_material,
         {:ok, operation} <- bind_handoff(operation, attempt, connection, handoff_ref),
         :ok <- validate_fence_locked(operation, attempt, connection),
         {:ok, credential_result} <-
           LocalAuthorizationBackend.handoff_to_registered_credential(
             operation.id,
             attempt.attempt_ref
           ),
         {:ok, committed} <-
           journal_credential_result(operation, attempt, connection, credential_result),
         {:ok, committed} <- CredentialReplacement.commit(committed.id) do
      {:ok, logical_result(Repo.get!(Connection, connection.connection_id), committed)}
    else
      false -> {:error, :stale_attempt_claim}
      {:error, _reason} = error -> error
      _reason -> {:error, :credential_conflict}
    end
  end

  defp finish_callback(operation) do
    with {:ok, finalized} <- CredentialReplacement.commit(operation.id) do
      connection = Repo.get!(Connection, operation.connection_id)
      {:ok, logical_result(connection, finalized)}
    end
  end

  defp claim_prepared(operation, attempt, connection, owner, now) do
    Repo.transaction(fn ->
      locked_connection = lock_connection(connection.connection_id)
      locked_attempt = lock_attempt(attempt.attempt_ref)
      locked_operation = lock_operation(operation.id)

      backend_record =
        Repo.get_by(AuthorizationBackendRecord, authorization_ref: attempt.authorization_ref)

      with %Connection{} <- locked_connection,
           %AuthorizationAttempt{} <- locked_attempt,
           %Operation{status: "prepared"} <- locked_operation,
           %AuthorizationBackendRecord{} <- backend_record,
           true <- locked_connection.owner_uri == URI.to_string(owner),
           :ok <- stable_scope(backend_record, locked_attempt, locked_connection),
           true <-
             locked_operation.bound_input_digest ==
               Operation.callback_digest(backend_record, locked_attempt, locked_connection),
           :ok <- callback_source_status(locked_connection.status),
           :ok <- recoverable_attempt(locked_attempt, now) do
        renew_prepared_claim(locked_operation, locked_attempt, locked_connection, now)
      else
        {:error, _reason} = error -> Repo.rollback(error)
        _reason -> Repo.rollback({:error, :credential_conflict})
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, _reason} -> {:error, :credential_conflict}
    end
  end

  defp recoverable_attempt(%AuthorizationAttempt{status: "consuming"} = attempt, now) do
    cond do
      DateTime.compare(now, attempt.expires_at) != :lt -> {:error, :callback_expired}
      is_nil(attempt.claim_until) -> {:error, :stale_attempt_claim}
      DateTime.compare(now, attempt.claim_until) == :lt -> {:error, :callback_in_progress}
      true -> :ok
    end
  end

  defp recoverable_attempt(_attempt, _now), do: {:error, :stale_attempt_claim}

  defp renew_prepared_claim(operation, attempt, connection, now) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    version = attempt.attempt_version + 1

    renewed_attempt =
      attempt
      |> Ecto.Changeset.change(
        claim_token: token,
        claim_until: DateTime.add(now, @claim_seconds, :second),
        attempt_version: version
      )
      |> Repo.update!()

    renewed_operation =
      operation
      |> Ecto.Changeset.change(attempt_claim_token: token, attempt_version: version)
      |> Repo.update!()

    {renewed_operation, renewed_attempt, connection}
  end

  defp validate_fence_locked(operation, attempt, connection) do
    Repo.transaction(fn ->
      locked_connection = lock_connection(connection.connection_id)
      locked_attempt = lock_attempt(attempt.attempt_ref)
      locked_operation = lock_operation(operation.id)

      cond do
        operation_fence_matches?(locked_operation, locked_attempt, locked_connection) ->
          :ok

        locked_connection.status in ["revoking", "disconnecting"] ->
          Repo.rollback(:connection_terminal)

        true ->
          Repo.rollback(:stale_attempt_claim)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, :connection_terminal} -> fence_if_terminal(operation)
      {:error, _reason} -> {:error, :stale_attempt_claim}
    end
  end

  defp fence_if_terminal(operation) do
    case CredentialReplacement.fence(operation.id) do
      :ok -> {:error, :connection_terminal}
      {:error, :stale_version} -> {:error, :stale_attempt_claim}
      {:error, _reason} -> {:error, :authorization_backend_unavailable}
    end
  end

  defp operation_fence_matches?(
         %Operation{} = operation,
         %AuthorizationAttempt{} = attempt,
         %Connection{} = connection
       ) do
    operation.workspace_uri == attempt.workspace_uri and
      operation.workspace_uri == connection.workspace_uri and
      operation.connection_id == attempt.connection_id and
      operation.connection_id == connection.connection_id and
      operation.backend_pair_id == attempt.backend_pair_id and
      operation.correlation_id == "store:#{attempt.correlation_id}" and
      operation.expected_connection_version == attempt.connection_version and
      operation.expected_connection_version == connection.connection_version and
      operation.attempt_claim_token == attempt.claim_token and
      operation.attempt_version == attempt.attempt_version and attempt.status == "consuming"
  end

  defp operation_fence_matches?(_operation, _attempt, _connection), do: false

  defp current_operation_fence?(operation, attempt, connection) do
    backend_record =
      if match?(%AuthorizationAttempt{}, attempt) do
        Repo.get_by(AuthorizationBackendRecord, authorization_ref: attempt.authorization_ref)
      end

    match?(%AuthorizationBackendRecord{}, backend_record) and
      operation_fence_matches?(operation, attempt, connection) and
      stable_scope(backend_record, attempt, connection) == :ok and
      operation.bound_input_digest ==
        Operation.callback_digest(backend_record, attempt, connection)
  end

  defp final_operation_scope?(operation, attempt, connection) do
    base_connection = %{connection | connection_version: operation.expected_connection_version}

    case Repo.get_by(AuthorizationBackendRecord, authorization_ref: attempt.authorization_ref) do
      %AuthorizationBackendRecord{} = backend_record ->
        operation.attempt_version == attempt.attempt_version and
          stable_scope(backend_record, attempt, base_connection) == :ok and
          operation.bound_input_digest ==
            Operation.callback_digest(backend_record, attempt, base_connection)

      nil ->
        false
    end
  end

  defp stable_scope(backend_record, attempt, connection) do
    with :ok <- BackendSupport.validate_backend_connection_scope(backend_record, connection),
         true <- backend_record.authorization_ref == attempt.authorization_ref,
         true <- backend_record.backend_pair_id == attempt.backend_pair_id,
         true <- backend_record.bound_input_digest == attempt.bound_subject_digest,
         true <- backend_record.workspace_uri == attempt.workspace_uri,
         true <- attempt.connection_id == connection.connection_id,
         true <- backend_record.connection_version == attempt.connection_version do
      :ok
    else
      _mismatch -> {:error, :credential_conflict}
    end
  end

  defp lock_connection(connection_id),
    do:
      Connection
      |> where([row], row.connection_id == ^connection_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

  defp lock_connection_key(connection_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [connection_id])
    :ok
  end

  defp lock_attempt(attempt_ref),
    do:
      AuthorizationAttempt
      |> where([row], row.attempt_ref == ^attempt_ref)
      |> lock("FOR UPDATE")
      |> Repo.one()

  defp lock_operation(operation_id),
    do:
      Operation
      |> where([row], row.id == ^operation_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

  defp subject(connection, owner),
    do: subject(connection, owner, connection_execution_identity(connection))

  defp subject(connection, owner, execution_identity) do
    %{
      owner_uri: owner,
      workspace_uri: Ezagent.Capability.workspace_of(owner),
      provider_id: connection.provider_id,
      governed_host: connection.governed_host,
      connection_id: connection.connection_id,
      connection_version: connection.connection_version,
      execution_identity: execution_identity
    }
  end

  defp connection_execution_identity(%Connection{status: "pending_authorization"} = connection),
    do: connection.requested_execution_identity_class

  defp connection_execution_identity(connection), do: connection.execution_identity

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp unwrap_transaction({:error, _reason}), do: {:error, :invalid_authorization_subject}

  defp fetch_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _reason -> {:error, :provider_protocol_error}
    end
  end
end
