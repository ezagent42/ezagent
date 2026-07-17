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

  @doc "Loads a provision by its database id."
  @spec get(pos_integer()) :: Provision.t() | nil
  def get(id) when is_integer(id) and id > 0, do: Repo.get(Provision, id)
  def get(_id), do: nil

  @doc "Loads a provision by its opaque public identity."
  @spec get_by_provision_id(String.t()) :: Provision.t() | nil
  def get_by_provision_id(provision_id) when is_binary(provision_id) and provision_id != "",
    do: Repo.get_by(Provision, provision_id: provision_id)

  def get_by_provision_id(_provision_id), do: nil

  @doc "Binds deterministic Agent retirement intent before sidecar instantiation."
  @spec bind_start_intent(String.t(), map()) :: {:ok, Provision.t()} | {:error, term()}
  def bind_start_intent(provision_id, %{
        agent_uri: agent_uri,
        provenance_root_uri: root_uri,
        workspace_uri: workspace_uri,
        task_access_uri: task_access_uri,
        task_uri: task_uri,
        generation: generation
      })
      when is_binary(provision_id) and is_binary(agent_uri) and agent_uri != "" and
             is_binary(root_uri) and root_uri != "" and is_binary(workspace_uri) and
             is_binary(task_access_uri) and is_binary(task_uri) and is_integer(generation) do
    case get_by_provision_id(provision_id) do
      %Provision{id: id} ->
        locked(id, fn
          %Provision{
            status: :ready,
            workspace_uri: ^workspace_uri,
            task_access_uri: ^task_access_uri,
            task_uri: ^task_uri,
            generation: ^generation,
            agent_uri: nil,
            provenance_root_uri: nil
          } = row ->
            with :ok <- intent_authority(agent_uri, root_uri, workspace_uri) do
              update_row(row, %{
                agent_uri: agent_uri,
                provenance_root_uri: root_uri,
                state_version: row.state_version + 1
              })
            end

          %Provision{
            status: :ready,
            workspace_uri: ^workspace_uri,
            task_access_uri: ^task_access_uri,
            task_uri: ^task_uri,
            generation: ^generation,
            agent_uri: ^agent_uri,
            provenance_root_uri: ^root_uri
          } = row ->
            {:ok, row}

          %Provision{status: :ready} ->
            {:error, :conflicting_sidecar_start_intent}

          %Provision{} ->
            {:error, :workspace_not_ready}
        end)

      nil ->
        {:error, :workspace_not_ready}
    end
  end

  def bind_start_intent(_provision_id, _intent), do: {:error, :invalid_sidecar_start_intent}

  defp intent_authority(agent_uri, root_uri, workspace_uri) do
    with {:ok, agent} <- URI.new(agent_uri),
         {:ok, root} <- URI.new(root_uri),
         {:ok, workspace} <- URI.new(workspace_uri),
         true <- Ezagent.URI.scheme?(agent, :entity) and Ezagent.URI.type?(agent, :agent),
         true <- Ezagent.URI.workspace_of(agent) == workspace,
         true <- Ezagent.URI.workspace_of(root) == workspace do
      :ok
    else
      _ -> {:error, :sidecar_start_authority_mismatch}
    end
  end

  @doc "Returns whether no other non-cleaned provision owns the exact worktree path."
  @spec worktree_path_available?(pos_integer(), String.t()) :: boolean()
  def worktree_path_available?(provision_id, path)
      when is_integer(provision_id) and is_binary(path) do
    not Repo.exists?(
      from(p in Provision,
        where: p.id != ^provision_id and p.worktree_path == ^path and p.status != :cleaned
      )
    )
  end

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

  @doc "Moves only the current, unexpired provision claim into cleanup pending."
  @spec fail_provision(pos_integer(), String.t(), atom(), keyword()) ::
          {:ok, Provision.t()} | {:error, term()}
  def fail_provision(id, claim_token, reason, opts \\ [])

  def fail_provision(id, claim_token, reason, opts)
      when is_binary(claim_token) and is_atom(reason) and not is_nil(reason) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    locked(id, fn
      %Provision{status: :provisioning, claim_token: ^claim_token} = row ->
        with :ok <- current_lease(row.lease_until, now, :provision_lease_expired) do
          update_row(row, %{
            status: :cleanup_pending,
            state_version: row.state_version + 1,
            cleanup_reason: Atom.to_string(reason),
            claim_token: nil,
            lease_until: nil
          })
        end

      %Provision{status: :provisioning} ->
        {:error, :provision_lease_lost}

      %Provision{} ->
        {:error, :invalid_provision_transition}
    end)
  end

  def fail_provision(_id, _claim_token, _reason, _opts),
    do: {:error, :invalid_cleanup_reason}

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
  @spec mark_started(pos_integer(), String.t(), map()) ::
          {:ok, Provision.t()} | {:error, term()}
  def mark_started(id, start_token, retirement_handle)
      when is_binary(start_token) and is_map(retirement_handle) do
    locked(id, fn
      %Provision{
        status: :ready,
        start_token: ^start_token,
        start_token_consumed_at: consumed_at
      } = row
      when not is_nil(consumed_at) ->
        with {:ok, handle} <- retirement_handle(retirement_handle) do
          update_row(
            row,
            Map.merge(handle, %{status: :sidecar_started, state_version: row.state_version + 1})
          )
        end

      %Provision{status: :ready, start_token: ^start_token} ->
        {:error, :start_token_not_claimed}

      %Provision{status: :ready} ->
        {:error, :start_token_mismatch}

      %Provision{} ->
        {:error, :invalid_start_transition}
    end)
  end

  def mark_started(_id, _start_token, _retirement_handle),
    do: {:error, :invalid_retirement_handle}

  defp retirement_handle(%{
         agent_uri: agent_uri,
         creation_attempt_id: creation_attempt_id,
         provenance_root_uri: provenance_root_uri
       })
       when is_binary(agent_uri) and agent_uri != "" and is_binary(creation_attempt_id) and
              creation_attempt_id != "" and is_binary(provenance_root_uri) and
              provenance_root_uri != "" do
    {:ok,
     %{
       agent_uri: agent_uri,
       creation_attempt_id: creation_attempt_id,
       provenance_root_uri: provenance_root_uri
     }}
  end

  defp retirement_handle(_handle), do: {:error, :invalid_retirement_handle}

  @doc "Moves a non-terminal provision into cleanup pending with a safe reason code."
  @spec request_cleanup(pos_integer(), atom()) ::
          {:ok, :never_started | :ambiguous_or_live, Provision.t()} | {:error, term()}
  def request_cleanup(id, reason) when is_atom(reason) and not is_nil(reason) do
    locked(id, fn
      %Provision{status: :cleanup_pending} = row ->
        {:ok, start_classification(row), row}

      %Provision{status: :cleaned} ->
        {:error, :already_cleaned}

      %Provision{} = row ->
        classification = start_classification(row)

        case update_row(row, %{
               status: :cleanup_pending,
               state_version: row.state_version + 1,
               cleanup_reason: Atom.to_string(reason),
               claim_token: nil,
               lease_until: nil,
               start_token: invalidate_unused_start_token(row)
             }) do
          {:ok, pending} -> {:ok, classification, pending}
          {:error, _reason} = error -> error
        end
    end)
  end

  def request_cleanup(_id, _reason), do: {:error, :invalid_cleanup_reason}

  @doc "CAS transition for a ready row proven invalid before start was claimed."
  @spec request_invalid_ready_cleanup(pos_integer(), non_neg_integer(), atom()) ::
          {:ok, :never_started, Provision.t()} | {:error, term()}
  def request_invalid_ready_cleanup(id, expected_version, reason)
      when is_integer(expected_version) and is_atom(reason) and not is_nil(reason) do
    locked(id, fn
      %Provision{status: :ready, state_version: ^expected_version, start_token_consumed_at: nil} =
          row ->
        case update_row(row, %{
               status: :cleanup_pending,
               state_version: row.state_version + 1,
               cleanup_reason: Atom.to_string(reason),
               start_token: nil,
               claim_token: nil,
               lease_until: nil
             }) do
          {:ok, pending} -> {:ok, :never_started, pending}
          {:error, _reason} = error -> error
        end

      %Provision{status: :ready, start_token_consumed_at: consumed_at}
      when not is_nil(consumed_at) ->
        {:error, :start_ambiguous_or_live}

      %Provision{status: :ready} ->
        {:error, :stale_ready_version}

      %Provision{} ->
        {:error, :invalid_cleanup_transition}
    end)
  end

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

  @doc "Checks that a cleanup lease still owns the next external effect."
  @spec validate_cleanup_claim(pos_integer(), String.t(), keyword()) ::
          {:ok, Provision.t()} | {:error, term()}
  def validate_cleanup_claim(id, claim_token, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    locked(id, fn
      %Provision{status: :cleanup_pending, claim_token: ^claim_token} = row ->
        case current_lease(row.lease_until, now, :cleanup_lease_expired) do
          :ok -> {:ok, row}
          {:error, _reason} = error -> error
        end

      %Provision{status: :cleanup_pending} ->
        {:error, :cleanup_lease_lost}

      %Provision{} ->
        {:error, :invalid_cleanup_transition}
    end)
  end

  @doc "Renews only the current unexpired cleanup lease."
  @spec renew_cleanup_claim(pos_integer(), String.t(), keyword()) ::
          {:ok, Provision.t()} | {:error, term()}
  def renew_cleanup_claim(id, claim_token, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    lease_seconds = Keyword.get(opts, :lease_seconds, 60)

    locked(id, fn
      %Provision{status: :cleanup_pending, claim_token: ^claim_token} = row ->
        with :ok <- current_lease(row.lease_until, now, :cleanup_lease_expired) do
          update_row(row, %{lease_until: DateTime.add(now, lease_seconds, :second)})
        end

      %Provision{status: :cleanup_pending} ->
        {:error, :cleanup_lease_lost}

      %Provision{} ->
        {:error, :invalid_cleanup_transition}
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

  @doc "Compatibility name for the durable-only bounded recovery query."
  @spec list_recoverable(pos_integer()) :: [Provision.t()]
  def list_recoverable(limit), do: list_recovery_candidates(limit)

  @doc "Lists only durable cleanup/recovery candidates in a bounded batch."
  @spec list_recovery_candidates(pos_integer(), keyword()) :: [Provision.t()]
  def list_recovery_candidates(limit, opts \\ []) when is_integer(limit) and limit > 0 do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    Repo.all(
      from(p in Provision,
        where:
          (p.status == :provisioning and (is_nil(p.lease_until) or p.lease_until <= ^now)) or
            (p.status == :cleanup_pending and
               (is_nil(p.lease_until) or p.lease_until <= ^now)) or
            (p.status == :ready and is_nil(p.start_token_consumed_at)),
        order_by: [asc: p.inserted_at, asc: p.id],
        limit: ^limit
      )
    )
  end

  defp start_classification(%Provision{start_token_consumed_at: nil}), do: :never_started
  defp start_classification(%Provision{}), do: :ambiguous_or_live

  defp invalidate_unused_start_token(%Provision{start_token_consumed_at: nil}), do: nil
  defp invalidate_unused_start_token(%Provision{start_token: token}), do: token

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
