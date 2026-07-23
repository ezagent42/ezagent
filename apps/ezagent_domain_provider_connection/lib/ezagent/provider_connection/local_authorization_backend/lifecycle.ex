defmodule Ezagent.ProviderConnection.LocalAuthorizationBackend.Lifecycle do
  @moduledoc false

  import Ecto.Query
  alias Ezagent.ProviderConnection.LocalAuthorizationBackend.Support

  alias Ezagent.ProviderConnection.AuthorizationBackendRecord
  alias Ezagent.ProviderConnection.DriverRegistry
  alias Ezagent.ProviderConnection.ProviderAuthorizationCommand
  alias EzagentCore.Repo

  @cancel_keys MapSet.new(
                 ~w(authorization_ref expected_subject correlation_id bound_input_digest)a ++
                   ["bound_input_digest"]
               )
  @reauth_keys MapSet.new(
                 ~w(subject session_assurance_evidence correlation_id bound_input_digest)a ++
                   ["bound_input_digest"]
               )

  @doc false
  def cancel_authorization(request) when is_map(request) do
    with :ok <- Support.closed_keys(request, @cancel_keys),
         {:ok, authorization_ref} <-
           Support.required_binary(request, :authorization_ref, :callback_invalid),
         {:ok, correlation_id} <-
           Support.required_binary(request, :correlation_id, :callback_invalid),
         {:ok, digest} <- Support.command_digest(:cancel, request) do
      Repo.transaction(fn ->
        lifecycle_cancel_locked(authorization_ref, correlation_id, digest, request)
      end)
      |> Support.unwrap_transaction()
    end
  end

  @doc false
  def cancel_authorization(_request), do: {:error, :callback_invalid}

  @doc false
  def reauthenticate(request) when is_map(request) do
    with :ok <- Support.closed_keys(request, @reauth_keys),
         {:ok, subject} <- Support.subject(request[:subject]),
         {:ok, correlation_id} <-
           Support.required_binary(request, :correlation_id, :callback_invalid),
         {:ok, digest} <- Support.command_digest(:reauthenticate, request),
         {:ok, pair_id} <-
           lifecycle_durable_pair_for_reauthentication(subject, correlation_id, digest),
         :ok <- Support.local_pair?(pair_id),
         true <- is_binary(pair_id) do
      attrs =
        Support.command_attrs(
          URI.to_string(subject.workspace_uri),
          pair_id,
          "reauthenticate",
          correlation_id,
          digest,
          nil
        )

      Repo.transaction(fn ->
        case lifecycle_insert_command(attrs) do
          :inserted -> lifecycle_commit_reauthentication(attrs, request)
          :existing -> lifecycle_reconcile_reauthentication(pair_id, correlation_id, digest)
        end
      end)
      |> Support.unwrap_transaction()
    end
  end

  @doc false
  def reauthenticate(_request), do: {:error, :callback_invalid}

  # LOCK-ORDER NOTE (final-review Minor, deferred with intent): this cancel
  # path locks the backend record BEFORE its command row, while
  # `LocalAuthorizationBackend.Exchange.finish_consume/4` locks the consume
  # command row first and the backend record second — an ABBA inversion.
  # Cancel/reauthenticate are not owner-reachable in D1 (both currently
  # return a closed error before touching this path), so the inversion is
  # dormant; when the follow-up phase enables these flows it MUST reorder
  # this path to the consume order (command row, then backend record) or
  # prove the inversion unreachable under its concurrency model.
  defp lifecycle_cancel_locked(authorization_ref, correlation_id, digest, request) do
    with %AuthorizationBackendRecord{} = row <- lifecycle_locked_record(authorization_ref),
         :ok <-
           lifecycle_existing_digest_matches(
             row.backend_pair_id,
             "cancel",
             correlation_id,
             digest
           ),
         :ok <- Support.expected_subject(row, request.expected_subject) do
      case lifecycle_cancel_lifecycle(row) do
        :pending -> lifecycle_cancel_pending(row, correlation_id, digest)
        {:error, :authorization_cancelled} -> lifecycle_replay_cancel(row, correlation_id, digest)
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :callback_invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lifecycle_cancel_pending(row, correlation_id, digest) do
    attrs = Support.command_attrs(row, "cancel", correlation_id, digest, row.authorization_ref)

    case lifecycle_insert_command(attrs) do
      :inserted ->
        row |> Ecto.Changeset.change(lifecycle_status: "cancelled") |> Repo.update!()
        lifecycle_commit_command(attrs, nil)
        :ok

      :existing ->
        lifecycle_replay_cancel(row, correlation_id, digest)
    end
  end

  defp lifecycle_replay_cancel(row, correlation_id, digest) do
    case lifecycle_maybe_command(row.backend_pair_id, "cancel", correlation_id) do
      %{bound_input_digest: ^digest, status: "committed"} -> :ok
      nil -> {:error, :authorization_cancelled}
      _other -> {:error, :correlation_conflict}
    end
  end

  defp lifecycle_cancel_lifecycle(%{lifecycle_status: "pending", expires_at: expires_at} = row) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
      :pending
    else
      row |> Ecto.Changeset.change(lifecycle_status: "expired") |> Repo.update!()
      {:error, :callback_expired}
    end
  end

  defp lifecycle_cancel_lifecycle(%{lifecycle_status: "cancelled"}),
    do: {:error, :authorization_cancelled}

  defp lifecycle_cancel_lifecycle(%{lifecycle_status: "consumed"}),
    do: {:error, :callback_already_consumed}

  defp lifecycle_cancel_lifecycle(%{lifecycle_status: "expired"}), do: {:error, :callback_expired}

  defp lifecycle_commit_reauthentication(attrs, %{session_assurance_evidence: %{aal: aal}})
       when aal in [:aal2, :aal3] do
    result = %{
      "reauth_ref" => Support.stable_ref("reauth", attrs.backend_pair_id, attrs.correlation_id),
      "expires_at" => DateTime.utc_now() |> DateTime.add(120, :second) |> DateTime.to_iso8601()
    }

    lifecycle_commit_command(attrs, result)
    {:ok, Support.decode_reauth_result(result)}
  end

  defp lifecycle_commit_reauthentication(attrs, _request) do
    lifecycle_fail_command(attrs, :reauthentication_failed)
    {:error, :reauthentication_failed}
  end

  defp lifecycle_reconcile_reauthentication(pair_id, correlation_id, digest) do
    command = lifecycle_locked_command(pair_id, "reauthenticate", correlation_id)

    cond do
      command.bound_input_digest != digest -> {:error, :correlation_conflict}
      command.status == "committed" -> {:ok, Support.decode_reauth_result(command.safe_result)}
      command.status == "terminal_failed" -> {:error, Support.safe_error(command.safe_error_code)}
      true -> {:error, :authorization_backend_unavailable}
    end
  end

  defp lifecycle_durable_pair_for_reauthentication(subject, correlation_id, digest) do
    case lifecycle_durable_pairs(subject, true) do
      [pair_id] ->
        {:ok, pair_id}

      _other ->
        case lifecycle_durable_pairs(subject, false) do
          [pair_id] ->
            case lifecycle_maybe_command(pair_id, "reauthenticate", correlation_id) do
              %{bound_input_digest: stored} when stored != digest ->
                {:error, :correlation_conflict}

              _command ->
                {:error, :invalid_authorization_subject}
            end

          _other ->
            {:error, :invalid_authorization_subject}
        end
    end
  end

  defp lifecycle_durable_pairs(subject, exact_version?) do
    query =
      AuthorizationBackendRecord
      |> where(
        [row],
        row.owner_uri == ^URI.to_string(subject.owner_uri) and
          row.workspace_uri == ^URI.to_string(subject.workspace_uri) and
          row.connection_id == ^subject.connection_id and
          row.provider_id == ^subject.provider_id and
          row.governed_host == ^subject.governed_host
      )

    query =
      if exact_version?,
        do: where(query, [row], row.connection_version == ^subject.connection_version),
        else: query

    query
    |> select([row], row.backend_pair_id)
    |> distinct(true)
    |> Repo.all()
  end

  defp lifecycle_existing_digest_matches(pair_id, operation, correlation_id, digest) do
    case lifecycle_maybe_command(pair_id, operation, correlation_id) do
      %{bound_input_digest: ^digest} -> :ok
      %ProviderAuthorizationCommand{} -> {:error, :correlation_conflict}
      nil -> :ok
    end
  end

  @doc false
  def configured_pair(provider_id, method) do
    mappings =
      Application.get_env(
        :ezagent_domain_provider_connection,
        :local_authorization_backend_pairs,
        %{}
      )

    with {:ok, pair_id} <- Map.fetch(mappings, {provider_id, method}),
         {:ok, driver} <- lifecycle_normalize_lookup(DriverRegistry.lookup(provider_id, method)),
         true <- pair_id in driver.backend_pair_ids,
         :ok <- Support.local_pair?(pair_id) do
      {:ok, pair_id}
    else
      :error -> lifecycle_missing_mapping_error(mappings, provider_id)
      false -> {:error, :authorization_backend_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lifecycle_missing_mapping_error(mappings, provider_id) do
    if Enum.any?(Map.keys(mappings), fn
         {^provider_id, _method} -> true
         _other -> false
       end) do
      {:error, :invalid_acquisition_method}
    else
      {:error, :authorization_backend_unavailable}
    end
  end

  defp lifecycle_normalize_lookup({:ok, value}), do: {:ok, value}
  defp lifecycle_normalize_lookup(:error), do: {:error, :authorization_backend_unavailable}

  defp lifecycle_insert_command(attrs) do
    true = attrs.operation_class in ["cancel", "reauthenticate"]
    now = DateTime.utc_now()
    row = Map.merge(attrs, %{id: Ecto.UUID.generate(), inserted_at: now, updated_at: now})

    case Repo.insert_all(ProviderAuthorizationCommand, [row],
           on_conflict: :nothing,
           conflict_target: [:backend_pair_id, :operation_class, :correlation_id]
         ) do
      {1, _rows} -> :inserted
      {0, _rows} -> :existing
    end
  end

  defp lifecycle_commit_command(command_or_attrs, safe_result) do
    command =
      lifecycle_locked_command(
        command_or_attrs.backend_pair_id,
        command_or_attrs.operation_class,
        command_or_attrs.correlation_id
      )

    command
    |> Ecto.Changeset.change(
      status: "committed",
      safe_result: safe_result,
      safe_error_code: nil
    )
    |> Repo.update!()
  end

  defp lifecycle_fail_command(command_or_attrs, reason) do
    command =
      lifecycle_locked_command(
        command_or_attrs.backend_pair_id,
        command_or_attrs.operation_class,
        command_or_attrs.correlation_id
      )

    command
    |> Ecto.Changeset.change(
      status: "terminal_failed",
      safe_error_code: Atom.to_string(reason)
    )
    |> Repo.update!()
  end

  defp lifecycle_locked_record(ref),
    do:
      Repo.one(
        from(row in AuthorizationBackendRecord,
          where: row.authorization_ref == ^ref,
          lock: "FOR UPDATE"
        )
      )

  defp lifecycle_maybe_command(pair, operation, correlation),
    do:
      (
        true = operation in ["cancel", "reauthenticate"]

        Repo.one(
          from(command in ProviderAuthorizationCommand,
            where:
              command.backend_pair_id == ^pair and command.operation_class == ^operation and
                command.correlation_id == ^correlation
          )
        )
      )

  defp lifecycle_locked_command(pair, operation, correlation),
    do:
      (
        true = operation in ["cancel", "reauthenticate"]

        Repo.one!(
          from(command in ProviderAuthorizationCommand,
            where:
              command.backend_pair_id == ^pair and command.operation_class == ^operation and
                command.correlation_id == ^correlation,
            lock: "FOR UPDATE"
          )
        )
      )
end
