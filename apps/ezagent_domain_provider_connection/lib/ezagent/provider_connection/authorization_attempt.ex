defmodule Ezagent.ProviderConnection.AuthorizationAttempt do
  @moduledoc "Public, secret-safe authorization correlation row."
  @derive {Inspect,
           only: [
             :attempt_ref,
             :workspace_uri,
             :connection_id,
             :connection_version,
             :purpose,
             :correlation_id,
             :attempt_version,
             :status,
             :consumed_at,
             :expires_at
           ]}
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
    field(:purpose, :string)
    field(:reservation_digest, :string)
    field(:requested_permission_digest, :string)
    field(:requested_execution_identity_class, :string)
    field(:redirect_uri_id, :string)
    field(:callback_artifact_digest, :string)
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

  @trusted ~w(attempt_ref workspace_uri backend_pair_id authorization_ref connection_id connection_version purpose reservation_digest requested_permission_digest requested_execution_identity_class redirect_uri_id callback_artifact_digest bound_subject_digest state_digest pkce_digest correlation_id callback_artifact expires_at)a
  @doc "Builds the initial, secret-safe authorization-attempt changeset from trusted attributes."
  def create_changeset(attrs),
    do:
      %__MODULE__{}
      |> cast(attrs, [:status])
      |> change(Map.take(attrs, @trusted))
      |> validate_required(
        ~w(attempt_ref workspace_uri connection_id purpose correlation_id status)a
      )
      |> validate_reservation()
      |> validate_lifecycle_coordinates()
      |> unique_constraint(:authorization_ref,
        name: :provider_authorization_attempts_authorization_ref_index
      )
      |> unique_constraint(:state_digest,
        name: :provider_authorization_attempts_backend_state_index
      )
      |> unique_constraint(:connection_id,
        name: :provider_authorization_attempts_one_open_index
      )
      |> check_constraint(:status, name: :provider_authorization_attempts_status_check)
      |> check_constraint(:purpose, name: :provider_authorization_attempts_purpose_check)
      |> check_constraint(:purpose, name: :provider_authorization_attempts_reservation_check)
      |> check_constraint(:purpose, name: :provider_authorization_attempts_lifecycle_check)
      |> foreign_key_constraint(:connection_id,
        name: :provider_authorization_attempts_connection_workspace_fkey
      )

  defp validate_reservation(changeset) do
    if get_field(changeset, :purpose) == "legacy" do
      changeset
    else
      validate_required(changeset, [
        :reservation_digest,
        :requested_permission_digest,
        :requested_execution_identity_class,
        :redirect_uri_id,
        :callback_artifact_digest
      ])
    end
  end

  defp validate_lifecycle_coordinates(changeset) do
    purpose = get_field(changeset, :purpose)
    status = get_field(changeset, :status)

    coordinates = [
      :backend_pair_id,
      :authorization_ref,
      :bound_subject_digest,
      :state_digest,
      :expires_at
    ]

    valid? =
      cond do
        purpose == "legacy" ->
          status in ["consumed", "cancelled", "expired"]

        purpose in ["initial_bind", "reauthorize"] and status in ["pending", "consuming"] ->
          Enum.all?(coordinates, &(not is_nil(get_field(changeset, &1))))

        purpose in ["initial_bind", "reauthorize"] ->
          true

        true ->
          false
      end

    if valid?,
      do: changeset,
      else: add_error(changeset, :purpose, "does not match status and backend coordinates")
  end

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
           :ok <- callback_source_status(attempt.purpose, connection.status) do
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

  # Spec §4 callback source matrix (purpose-aware, aligned with the ingress
  # layer): refresh_required is not a legal source; reauthorization from an
  # expired connection is. This is the single owner of the matrix — Store
  # delegates here rather than carrying a copy.
  @doc false
  def callback_source_status("initial_bind", status)
      when status in ["pending_authorization", "active", "degraded", "expired"],
      do: :ok

  def callback_source_status("reauthorize", status)
      when status in ["active", "degraded", "expired"],
      do: :ok

  def callback_source_status(_purpose, _status), do: {:error, :connection_terminal}
end
