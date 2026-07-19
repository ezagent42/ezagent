defmodule Ezagent.ProviderConnection.AuthorizationAttempt do
  @moduledoc "Public, secret-safe authorization correlation row."
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias EzagentCore.Repo
  alias Ezagent.ProviderConnection.Connection
  @primary_key {:attempt_ref, Ecto.UUID, autogenerate: false}
  schema "provider_authorization_attempts" do
    field(:workspace_uri, :string)
    field(:backend_pair_id, :string)
    field(:authorization_ref, :string)
    field(:connection_id, Ecto.UUID)
    field(:connection_version, :integer, default: 0)
    field(:bound_subject_digest, :string)
    field(:state_digest, :string)
    field(:pkce_digest, :string)
    field(:correlation_id, :string)
    field(:attempt_version, :integer, default: 0)
    field(:status, :string)
    field(:callback_artifact, :map)
    field(:claim_token, :string)
    field(:claim_until, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @trusted ~w(attempt_ref workspace_uri backend_pair_id authorization_ref connection_id connection_version bound_subject_digest state_digest pkce_digest correlation_id callback_artifact expires_at)a
  @doc "Builds the initial, secret-safe authorization-attempt changeset from trusted attributes."
  def create_changeset(attrs),
    do:
      %__MODULE__{}
      |> cast(attrs, [:status])
      |> change(Map.take(attrs, @trusted))
      |> validate_required(
        ~w(attempt_ref workspace_uri backend_pair_id authorization_ref connection_id bound_subject_digest state_digest correlation_id status expires_at)a
      )
      |> unique_constraint(:authorization_ref,
        name: :provider_authorization_attempts_authorization_ref_index
      )
      |> unique_constraint(:state_digest,
        name: :provider_authorization_attempts_backend_state_index
      )
      |> check_constraint(:status, name: :provider_authorization_attempts_status_check)

  @doc "Claims a pending callback attempt or steals an expired claim with a new fence."
  @spec claim(Ecto.UUID.t(), DateTime.t(), pos_integer(), keyword()) ::
          {:ok, t()} | {:error, atom()}
  def claim(attempt_ref, now, ttl_seconds, opts \\ [])
      when is_binary(attempt_ref) and is_struct(now, DateTime) and is_integer(ttl_seconds) and
             ttl_seconds > 0 do
    Repo.transaction(fn ->
      row =
        __MODULE__
        |> where([attempt], attempt.attempt_ref == ^attempt_ref)
        |> lock("FOR UPDATE")
        |> Repo.one()

      claim_locked(row, now, ttl_seconds, opts)
    end)
    |> case do
      {:ok, result} -> result
      {:error, _reason} -> {:error, :callback_invalid}
    end
  end

  @doc "Claims while holding the exact connection and attempt locks and checking their fence."
  @spec claim_for_connection(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          DateTime.t(),
          pos_integer()
        ) ::
          {:ok, t()} | {:error, atom()}
  def claim_for_connection(attempt_ref, connection_id, owner_uri, now, ttl_seconds)
      when is_binary(attempt_ref) and is_binary(connection_id) and is_binary(owner_uri) and
             is_struct(now, DateTime) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    Repo.transaction(fn ->
      connection =
        Connection
        |> where(
          [row],
          row.connection_id == ^connection_id and row.owner_uri == ^owner_uri
        )
        |> lock("FOR UPDATE")
        |> Repo.one()

      attempt =
        __MODULE__
        |> where([row], row.attempt_ref == ^attempt_ref and row.connection_id == ^connection_id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      with %Connection{} <- connection,
           %__MODULE__{} <- attempt,
           true <- connection.workspace_uri == attempt.workspace_uri,
           :ok <- callback_source_status(connection.status) do
        claim_locked(attempt, now, ttl_seconds,
          current_connection_version: connection.connection_version
        )
      else
        false -> {:error, :callback_invalid}
        nil -> {:error, :callback_invalid}
        {:error, _reason} = error -> error
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, _reason} -> {:error, :callback_invalid}
    end
  end

  @doc "Finalizes only the current claim token and version fence."
  @spec consume_claim(Ecto.UUID.t(), String.t(), non_neg_integer(), DateTime.t()) ::
          {:ok, t()} | {:error, atom()}
  def consume_claim(attempt_ref, token, version, now) do
    Repo.transaction(fn ->
      row =
        __MODULE__
        |> where([attempt], attempt.attempt_ref == ^attempt_ref)
        |> lock("FOR UPDATE")
        |> Repo.one()

      case row do
        %__MODULE__{
          status: "consuming",
          claim_token: ^token,
          attempt_version: ^version
        } = claimed ->
          claimed
          |> change(
            status: "consumed",
            claim_token: nil,
            claim_until: nil,
            consumed_at: now
          )
          |> Repo.update()

        %__MODULE__{status: "consumed"} ->
          {:error, :callback_already_consumed}

        %__MODULE__{} ->
          {:error, :stale_attempt_claim}

        nil ->
          {:error, :callback_invalid}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, _reason} -> {:error, :callback_invalid}
    end
  end

  defp claim_locked(nil, _now, _ttl_seconds, _opts), do: {:error, :callback_invalid}

  defp claim_locked(%__MODULE__{status: "cancelled"}, _now, _ttl_seconds, _opts),
    do: {:error, :authorization_cancelled}

  defp claim_locked(%__MODULE__{status: "consumed"}, _now, _ttl_seconds, _opts),
    do: {:error, :callback_already_consumed}

  defp claim_locked(%__MODULE__{status: "expired"}, _now, _ttl_seconds, _opts),
    do: {:error, :callback_expired}

  defp claim_locked(row, now, ttl_seconds, opts) do
    case preclaim_check(row, now, opts) do
      :ok -> claim_available(row, now, ttl_seconds)
      {:error, _reason} = error -> error
    end
  end

  defp preclaim_check(row, now, opts) do
    expected_version = Keyword.get(opts, :current_connection_version, row.connection_version)

    cond do
      row.connection_version != expected_version -> {:error, :stale_connection_version}
      DateTime.compare(now, row.expires_at) != :lt -> expire_claim(row)
      true -> :ok
    end
  end

  defp expire_claim(row) do
    row
    |> change(status: "expired", attempt_version: row.attempt_version + 1)
    |> Repo.update!()

    {:error, :callback_expired}
  end

  defp claim_available(%__MODULE__{status: "pending"} = row, now, ttl_seconds),
    do: persist_claim(row, now, ttl_seconds)

  defp claim_available(
         %__MODULE__{status: "consuming", claim_until: claim_until} = row,
         now,
         ttl_seconds
       ) do
    if DateTime.compare(now, claim_until) in [:eq, :gt],
      do: persist_claim(row, now, ttl_seconds),
      else: {:error, :callback_in_progress}
  end

  defp claim_available(%__MODULE__{}, _now, _ttl_seconds), do: {:error, :callback_invalid}

  defp persist_claim(row, now, ttl_seconds) do
    row
    |> change(
      status: "consuming",
      claim_token: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
      claim_until: DateTime.add(now, ttl_seconds, :second),
      attempt_version: row.attempt_version + 1
    )
    |> Repo.update()
  end

  defp callback_source_status(status)
       when status in ["pending_authorization", "active", "refresh_required", "degraded"],
       do: :ok

  defp callback_source_status(_status), do: {:error, :connection_terminal}
end
