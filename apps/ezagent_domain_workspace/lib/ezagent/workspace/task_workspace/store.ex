defmodule Ezagent.Workspace.TaskWorkspace.Store do
  @moduledoc """
  Locked persistence boundary for task workspace lifecycle transitions.

  Every transition takes a PostgreSQL row lock and advances `state_version`.
  Claim tokens bind effect completion to the lease holder that performed it.
  """

  import Ecto.Query

  alias Ezagent.Workspace.TaskWorkspace.Provision
  alias EzagentCore.Repo

  @create_keys Provision.immutable_fields() ++ [:visibility]
  @doc "Creates an idempotent public-repository provision plan."
  @spec create_planned(map()) :: {:ok, Provision.t()} | {:error, term()}
  def create_planned(%{visibility: :private}), do: {:error, :private_checkout_not_supported}

  def create_planned(%{visibility: :public} = attrs) do
    with :ok <- validate_create_keys(attrs) do
      identity = Map.take(attrs, [:workspace_uri, :task_uri, :generation])
      immutable = Map.take(attrs, Provision.immutable_fields())

      case Repo.get_by(Provision, identity) do
        %Provision{} = existing ->
          compare_immutable(existing, immutable)

        nil ->
          %Provision{}
          |> Provision.create_changeset(immutable)
          |> Repo.insert()
          |> recover_concurrent_insert(identity, immutable)
      end
    end
  end

  def create_planned(%{visibility: _other}), do: {:error, :invalid_visibility}
  def create_planned(_attrs), do: {:error, :invalid_attributes}

  @doc "Claims an unclaimed or expired provision operation."
  @spec claim_provision(pos_integer(), keyword()) :: {:ok, Provision.t()} | {:error, term()}
  def claim_provision(id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    lease_seconds = Keyword.get(opts, :lease_seconds, 60)
    expected_version = Keyword.get(opts, :expected_version)

    locked(id, fn provision ->
      claim_provision_locked(provision, now, lease_seconds, expected_version)
    end)
  end

  @doc "Commits a verified ready workspace for the current provision lease."
  @spec mark_ready(pos_integer(), String.t(), map(), keyword()) ::
          {:ok, Provision.t()} | {:error, term()}
  def mark_ready(id, claim_token, attrs, opts \\ [])
      when is_binary(claim_token) and is_map(attrs) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    locked(id, fn
      %Provision{status: :provisioning, claim_token: ^claim_token} = provision ->
        with :ok <- current_lease(provision.lease_until, now, :provision_lease_expired),
             :ok <- expected_version(provision, attrs, :stale_provision_version),
             {:ok, ready} <- ready_values(attrs) do
          update_row(provision, %{
            status: :ready,
            state_version: provision.state_version + 1,
            cache_identity: ready.cache_identity,
            worktree_identity: ready.worktree_identity,
            worktree_path: ready.worktree_path,
            claim_token: nil,
            lease_until: nil,
            start_token: Ecto.UUID.generate(),
            start_token_consumed_at: nil,
            blocker_code: nil
          })
        end

      %Provision{status: :provisioning} ->
        {:error, :provision_lease_lost}

      %Provision{} ->
        {:error, :invalid_provision_transition}
    end)
  end

  @doc "Consumes the ready record's start token exactly once."
  @spec claim_start(pos_integer(), String.t()) :: {:ok, Provision.t()} | {:error, term()}
  def claim_start(id, start_token) when is_binary(start_token) do
    locked(id, fn
      %Provision{status: :ready, start_token: ^start_token, start_token_consumed_at: nil} = row ->
        update_row(row, %{
          state_version: row.state_version + 1,
          start_token_consumed_at: DateTime.utc_now()
        })

      %Provision{status: :ready, start_token: ^start_token} ->
        {:error, :start_token_consumed}

      %Provision{status: :ready} ->
        {:error, :start_token_mismatch}

      %Provision{} ->
        {:error, :invalid_start_transition}
    end)
  end

  @doc "Records that sidecar instantiation succeeded for a consumed start token."
  @spec mark_started(pos_integer(), String.t()) :: {:ok, Provision.t()} | {:error, term()}
  def mark_started(id, start_token) when is_binary(start_token) do
    locked(id, fn
      %Provision{
        status: :ready,
        start_token: ^start_token,
        start_token_consumed_at: consumed_at
      } = row
      when not is_nil(consumed_at) ->
        update_row(row, %{status: :sidecar_started, state_version: row.state_version + 1})

      %Provision{status: :ready, start_token: ^start_token} ->
        {:error, :start_token_not_claimed}

      %Provision{status: :ready} ->
        {:error, :start_token_mismatch}

      %Provision{} ->
        {:error, :invalid_start_transition}
    end)
  end

  @doc "Moves a non-terminal provision into cleanup pending with a safe reason code."
  @spec request_cleanup(pos_integer(), atom()) :: {:ok, Provision.t()} | {:error, term()}
  def request_cleanup(id, reason) when is_atom(reason) and not is_nil(reason) do
    locked(id, fn
      %Provision{status: :cleanup_pending} = row ->
        {:ok, row}

      %Provision{status: :cleaned} ->
        {:error, :already_cleaned}

      %Provision{} = row ->
        update_row(row, %{
          status: :cleanup_pending,
          state_version: row.state_version + 1,
          cleanup_reason: Atom.to_string(reason),
          claim_token: nil,
          lease_until: nil
        })
    end)
  end

  def request_cleanup(_id, _reason), do: {:error, :invalid_cleanup_reason}

  @doc "Claims an unclaimed or expired cleanup operation."
  @spec claim_cleanup(pos_integer(), keyword()) :: {:ok, Provision.t()} | {:error, term()}
  def claim_cleanup(id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    lease_seconds = Keyword.get(opts, :lease_seconds, 60)
    expected_version = Keyword.get(opts, :expected_version)

    locked(id, fn provision ->
      claim_cleanup_locked(provision, now, lease_seconds, expected_version)
    end)
  end

  @doc "Marks cleanup complete only for the current cleanup lease holder."
  @spec mark_cleaned(pos_integer(), String.t(), keyword()) ::
          {:ok, Provision.t()} | {:error, term()}
  def mark_cleaned(id, claim_token, opts \\ [])
      when is_binary(claim_token) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    locked(id, fn
      %Provision{status: :cleanup_pending, claim_token: ^claim_token} = row ->
        with :ok <- current_lease(row.lease_until, now, :cleanup_lease_expired) do
          update_row(row, %{
            status: :cleaned,
            state_version: row.state_version + 1,
            claim_token: nil,
            lease_until: nil,
            cleaned_at: now
          })
        end

      %Provision{status: :cleanup_pending} ->
        {:error, :cleanup_lease_lost}

      %Provision{} ->
        {:error, :invalid_cleanup_transition}
    end)
  end

  @doc "Lists a bounded oldest-first recovery batch, excluding terminal records."
  @spec list_recoverable(pos_integer()) :: [Provision.t()]
  def list_recoverable(limit) when is_integer(limit) and limit > 0 do
    now = DateTime.utc_now()

    Repo.all(
      from(p in Provision,
        where:
          p.status in [:planned, :ready, :blocked] or
            (p.status in [:provisioning, :cleanup_pending] and
               (is_nil(p.lease_until) or p.lease_until <= ^now)),
        order_by: [asc: p.inserted_at, asc: p.id],
        limit: ^limit
      )
    )
  end

  defp claim_provision_locked(
         %Provision{status: :provisioning, lease_until: lease} = row,
         now,
         lease_seconds,
         expected_version
       )
       when not is_nil(lease) do
    if DateTime.compare(lease, now) == :gt,
      do: {:error, :provision_already_claimed},
      else: claim_provision_lease(row, now, lease_seconds, expected_version)
  end

  defp claim_provision_locked(%Provision{status: status} = row, now, seconds, expected)
       when status in [:planned, :provisioning] do
    claim_provision_lease(row, now, seconds, expected)
  end

  defp claim_provision_locked(%Provision{}, _now, _seconds, _expected),
    do: {:error, :invalid_provision_transition}

  defp claim_provision_lease(row, now, seconds, expected) do
    with :ok <- valid_lease(now, seconds),
         :ok <- expected_version(row, expected, :stale_provision_version) do
      update_row(row, %{
        status: :provisioning,
        state_version: row.state_version + 1,
        claim_token: Ecto.UUID.generate(),
        lease_until: DateTime.add(now, seconds, :second),
        attempts: row.attempts + 1,
        blocker_code: nil
      })
    end
  end

  defp claim_cleanup_locked(
         %Provision{status: :cleanup_pending, claim_token: token, lease_until: lease} = row,
         now,
         seconds,
         expected
       )
       when is_binary(token) and not is_nil(lease) do
    if DateTime.compare(lease, now) == :gt,
      do: {:error, :cleanup_already_claimed},
      else: claim_cleanup_lease(row, now, seconds, expected)
  end

  defp claim_cleanup_locked(%Provision{status: :cleanup_pending} = row, now, seconds, expected) do
    claim_cleanup_lease(row, now, seconds, expected)
  end

  defp claim_cleanup_locked(%Provision{}, _now, _seconds, _expected),
    do: {:error, :invalid_cleanup_transition}

  defp claim_cleanup_lease(row, now, seconds, expected) do
    with :ok <- valid_lease(now, seconds),
         :ok <- expected_version(row, expected, :stale_cleanup_version) do
      update_row(row, %{
        state_version: row.state_version + 1,
        claim_token: Ecto.UUID.generate(),
        lease_until: DateTime.add(now, seconds, :second),
        attempts: row.attempts + 1
      })
    end
  end

  defp locked(id, transition) when is_integer(id) and id > 0 do
    Repo.transaction(fn ->
      row = Repo.one(from(p in Provision, where: p.id == ^id, lock: "FOR UPDATE"))

      case row do
        nil -> {:error, :not_found}
        %Provision{} -> transition.(row)
      end
    end)
    |> unwrap_transaction()
  end

  defp locked(_id, _transition), do: {:error, :not_found}

  defp update_row(%Provision{} = provision, attrs) do
    provision
    |> Provision.transition_changeset(attrs)
    |> Repo.update()
  end

  defp valid_lease(%DateTime{}, seconds) when is_integer(seconds) and seconds > 0, do: :ok
  defp valid_lease(_now, _seconds), do: {:error, :invalid_lease}

  defp current_lease(%DateTime{} = lease_until, %DateTime{} = now, error) do
    if DateTime.compare(lease_until, now) == :gt, do: :ok, else: {:error, error}
  end

  defp current_lease(_lease_until, _now, error), do: {:error, error}

  defp expected_version(provision, attrs, error) when is_map(attrs),
    do: expected_version(provision, Map.get(attrs, :expected_version), error)

  defp expected_version(_provision, nil, _error), do: :ok
  defp expected_version(%Provision{state_version: version}, version, _error), do: :ok
  defp expected_version(%Provision{}, _version, error), do: {:error, error}

  defp ready_values(attrs) do
    keys = [:cache_identity, :worktree_identity, :worktree_path]

    if Enum.all?(keys, &(is_binary(Map.get(attrs, &1)) and Map.get(attrs, &1) != "")) do
      {:ok, Map.take(attrs, keys)}
    else
      {:error, :invalid_ready_attributes}
    end
  end

  defp validate_create_keys(attrs) do
    keys = Map.keys(attrs)

    cond do
      Enum.any?(keys, &(not is_atom(&1))) -> {:error, :invalid_attributes}
      Enum.any?(keys, &(&1 not in @create_keys)) -> {:error, :unknown_fields}
      true -> :ok
    end
  end

  defp compare_immutable(%Provision{} = provision, attrs) do
    if Enum.all?(Provision.immutable_fields(), &(Map.get(provision, &1) == Map.get(attrs, &1))),
      do: {:ok, provision},
      else: {:error, :conflicting_provision_identity}
  end

  defp recover_concurrent_insert({:ok, provision}, _identity, _attrs), do: {:ok, provision}

  defp recover_concurrent_insert({:error, %Ecto.Changeset{} = changeset} = error, identity, attrs) do
    if changeset.errors[:workspace_uri] do
      case Repo.get_by(Provision, identity) do
        %Provision{} = existing -> compare_immutable(existing, attrs)
        nil -> error
      end
    else
      error
    end
  end

  defp unwrap_transaction({:ok, result}), do: result
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
