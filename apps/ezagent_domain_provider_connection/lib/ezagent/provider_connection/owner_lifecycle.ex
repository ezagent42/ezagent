defmodule Ezagent.ProviderConnection.OwnerLifecycle do
  @moduledoc """
  Owns owner-initiated authorization reservation and settlement.

  Each command reserves durable connection and attempt state in one transaction,
  calls the authorization backend outside that transaction, then settles under a
  second transaction. Settlement always locks the connection before the attempt.
  """

  import Ecto.Query

  alias Ezagent.ProviderConnection.{
    AuthorizationAttempt,
    AuthorizationBackendRecord,
    Connection,
    LocalAuthorizationBackend,
    ProviderAuthorizationCommand
  }

  alias EzagentCore.Repo

  @doc "Begins an initial provider authorization for the owning subject."
  @spec begin_authorization(map(), map()) :: {:ok, map()} | {:error, atom()}
  def begin_authorization(args, %{self_uri: %URI{} = owner} = ctx) do
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
         {:ok, state_digest} <- LocalAuthorizationBackend.state_digest(state),
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

  @doc "Begins a replacement authorization for an existing owned connection."
  @spec reauthorize(map(), map()) :: {:ok, map()} | {:error, atom()}
  def reauthorize(args, %{self_uri: %URI{} = owner}) do
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
