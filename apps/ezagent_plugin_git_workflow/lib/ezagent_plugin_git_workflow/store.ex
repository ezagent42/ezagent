defmodule EzagentPluginGitWorkflow.Store do
  @moduledoc """
  PostgreSQL-backed store for workflow bindings and runs.

  All idempotency and concurrency decisions are driven by database results:
  unique constraints, single-statement CAS, and fresh-read reconciliation.
  No GenServer, Agent, ETS, or application lock.
  """

  alias EzagentCore.Repo
  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowRun

  # ---------------------------------------------------------------------------
  # Binding operations
  # ---------------------------------------------------------------------------

  @doc "Inserts a governed binding row. Rejects duplicates."
  @spec register_binding(TaskBinding.t()) :: {:ok, TaskBinding.t()} | {:error, term()}
  def register_binding(%TaskBinding{} = binding) do
    row = binding_to_row(binding)

    result =
      Repo.insert_all(
        "git_workflow_bindings",
        [row],
        on_conflict: :nothing,
        conflict_target: [:id]
      )

    case result do
      {1, _} -> {:ok, binding}
      {0, _} -> {:error, {:binding_exists, binding.id}}
    end
  end

  @doc "Disables a binding by id. Returns not_found if unknown."
  @spec disable_binding(String.t()) :: {:ok, TaskBinding.t()} | {:error, term()}
  def disable_binding(binding_id) when is_binary(binding_id) do
    case read_binding_row(binding_id) do
      nil -> {:error, :not_found}
      _row ->
        now = DateTime.utc_now()
        Repo.query!(
          "UPDATE git_workflow_bindings SET enabled = $1, updated_at = $2 WHERE id = $3",
          [false, now, binding_id]
        )

        case read_binding_row(binding_id) do
          nil -> {:error, :not_found}
          row -> {:ok, row_to_binding(row)}
        end
    end
  end

  @doc "Reads a binding by id."
  @spec read_binding(String.t()) :: {:ok, TaskBinding.t()} | {:error, term()}
  def read_binding(binding_id) when is_binary(binding_id) do
    case read_binding_row(binding_id) do
      nil -> {:error, :not_found}
      row -> {:ok, row_to_binding(row)}
    end
  end

  # ---------------------------------------------------------------------------
  # Run operations
  # ---------------------------------------------------------------------------

  @doc """
  Claim a workflow run with insert-or-load semantics.

  Returns {:ok, run} with a persisted accepted run, or an error.

  Idempotency: same (binding_id, binding_generation, external_task_id) returns
  the existing run. Different input_digest on the same unique key returns
  {:error, :digest_conflict}.
  """
  @spec claim(WorkflowRun.t()) :: {:ok, WorkflowRun.t()} | {:error, term()}
  def claim(%WorkflowRun{} = run) do
    if is_nil(run.authenticated_principal_uri) do
      {:error, :authenticated_principal_required}
    else
      with {:ok, _binding} <- check_binding_active(run.binding_id) do
        case check_unique_claim(run) do
          :ok -> insert_run(run)
          {:ok, existing} -> {:ok, existing}
          {:error, _} = error -> error
        end
      end
    end
  end

  @doc """
  Atomically transition a run's status using single-statement CAS.

  The update only succeeds when `run_id` matches AND `state_version` equals
  `expected_version` AND `status` equals `expected_status`. On zero rows
  updated, fresh-reads the run and distinguishes:
    - exact retry (already at next state/version) → returns current run
    - stale version                         → :stale_state_version
    - status conflict                       → :workflow_state_conflict
    - terminal conflict                     → :workflow_terminal
  """
  @spec transition(String.t(), pos_integer(), String.t(), String.t()) ::
          {:ok, WorkflowRun.t()} | {:error, term()}
  def transition(run_id, expected_version, expected_status, next_status)
      when is_binary(run_id) and is_integer(expected_version) and
           is_binary(expected_status) and is_binary(next_status) do
    next_version = expected_version + 1
    now = DateTime.utc_now()

    result =
      Repo.query!(
        "UPDATE git_workflow_runs SET status = $1, state_version = $2, updated_at = $3
         WHERE id = $4 AND state_version = $5 AND status = $6",
        [next_status, next_version, now, run_id, expected_version, expected_status]
      )

    case result.num_rows do
      1 ->
        {:ok, fetch_run!(run_id)}

      0 ->
        case read_run_row(run_id) do
          nil ->
            {:error, :not_found}

          row ->
            run = row_to_run(row)
            current_status = run.status
            current_version = run.state_version

            cond do
              # Exact retry: already at the target state+version
              current_status == next_status and current_version == next_version ->
                {:ok, run}

              # Already at next status but different version
              current_status == next_status ->
                {:error, :stale_state_version}

              # Version advanced and status differs
              current_version != expected_version and current_status != expected_status ->
                {:error, :stale_state_version}

              # Status mismatch
              current_status != expected_status ->
                {:error, :workflow_state_conflict}

              true ->
                {:error, :workflow_state_conflict}
            end
        end
    end
  end

  @doc "Reads a run by id."
  @spec read_run(String.t()) :: {:ok, WorkflowRun.t()} | {:error, term()}
  def read_run(run_id) when is_binary(run_id) do
    case read_run_row(run_id) do
      nil -> {:error, :not_found}
      row -> {:ok, row_to_run(row)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp check_binding_active(binding_id) do
    case read_binding_row(binding_id) do
      nil -> {:error, :binding_not_found}
      row ->
        if row["enabled"] do
          {:ok, row_to_binding(row)}
        else
          {:error, :binding_disabled}
        end
    end
  end

  defp check_unique_claim(%WorkflowRun{} = run) do
    result =
      Repo.query!(
        "SELECT * FROM git_workflow_runs
         WHERE binding_id = $1 AND binding_generation = $2 AND external_task_id = $3",
        [run.binding_id, run.binding_generation, run.external_task_id]
      )

    case result.rows do
      [] ->
        :ok

      [row | _] ->
        cols = result.columns
        existing_run = row_to_run(Enum.zip(cols, row) |> Map.new())
        if existing_run.input_digest == run.input_digest,
          do: {:ok, existing_run},
          else: {:error, :digest_conflict}
    end
  end

  defp insert_run(%WorkflowRun{} = run) do
    row = run_to_row(run)

    result =
      Repo.insert_all(
        "git_workflow_runs",
        [row],
        on_conflict: :nothing,
        conflict_target: [:binding_id, :binding_generation, :external_task_id]
      )

    case result do
      {1, _} ->
        {:ok, run}

      {0, _} ->
        run = fetch_run_by_key!(run.binding_id, run.binding_generation, run.external_task_id)
        {:ok, run}
    end
  end

  defp fetch_run!(run_id) do
    result =
      Repo.query!(
        "SELECT * FROM git_workflow_runs WHERE id = $1",
        [run_id]
      )

    row_to_run(zip_row(result))
  end

  defp fetch_run_by_key!(binding_id, binding_generation, external_task_id) do
    result =
      Repo.query!(
        "SELECT * FROM git_workflow_runs
         WHERE binding_id = $1 AND binding_generation = $2 AND external_task_id = $3",
        [binding_id, binding_generation, external_task_id]
      )

    row_to_run(zip_row(result))
  end

  # ---------------------------------------------------------------------------
  # Row ↔ Struct conversions
  # ---------------------------------------------------------------------------

  defp binding_to_row(%TaskBinding{} = b) do
    now = DateTime.utc_now()
    %{
      id: b.id,
      generation: b.generation,
      workspace_uri: URI.to_string(b.workspace_uri),
      task_receiver_uri: URI.to_string(b.task_receiver_uri),
      credential_owner_uri: URI.to_string(b.credential_owner_uri),
      repository_uri: URI.to_string(b.repository_uri),
      provider_adapter: b.provider_adapter,
      provider_host: b.provider_host,
      external_id: b.external_id,
      owner_path: b.owner_path,
      base_ref: b.base_ref,
      visibility: Atom.to_string(b.visibility),
      allowed_head_namespace: b.allowed_head_namespace,
      enabled: b.enabled,
      inserted_at: now,
      updated_at: now
    }
  end

  defp read_binding_row(binding_id) do
    result =
      Repo.query!(
        "SELECT * FROM git_workflow_bindings WHERE id = $1",
        [binding_id]
      )

    case result.rows do
      [] -> nil
      [row | _] -> Enum.zip(result.columns, row) |> Map.new()
    end
  end

  defp row_to_binding(row) when is_map(row) do
    struct!(TaskBinding, %{
      id: row["id"],
      generation: row["generation"],
      workspace_uri: parse_uri!(row["workspace_uri"]),
      task_receiver_uri: parse_uri!(row["task_receiver_uri"]),
      credential_owner_uri: parse_uri!(row["credential_owner_uri"]),
      repository_uri: parse_uri!(row["repository_uri"]),
      provider_adapter: row["provider_adapter"],
      provider_host: row["provider_host"],
      external_id: row["external_id"],
      owner_path: row["owner_path"],
      base_ref: row["base_ref"],
      visibility: parse_visibility(row["visibility"]),
      allowed_head_namespace: row["allowed_head_namespace"],
      enabled: row["enabled"],
      inserted_at: row["inserted_at"],
      updated_at: row["updated_at"]
    })
  end

  defp run_to_row(%WorkflowRun{} = r) do
    now = DateTime.utc_now()
    %{
      id: r.id,
      binding_id: r.binding_id,
      binding_generation: r.binding_generation,
      external_task_id: r.external_task_id,
      authenticated_principal_uri: URI.to_string(r.authenticated_principal_uri),
      status: r.status,
      state_version: r.state_version,
      input_digest: r.input_digest,
      source_task_uri: URI.to_string(r.source_task_uri),
      source_revision: r.source_revision,
      requested_head_ref: r.requested_head_ref,
      last_error_code: r.last_error_code,
      inserted_at: now,
      updated_at: now
    }
  end

  defp read_run_row(run_id) do
    result =
      Repo.query!(
        "SELECT * FROM git_workflow_runs WHERE id = $1",
        [run_id]
      )

    case result.rows do
      [] -> nil
      [row | _] -> Enum.zip(result.columns, row) |> Map.new()
    end
  end

  defp zip_row(%{columns: cols, rows: [row | _]}), do: Enum.zip(cols, row) |> Map.new()

  defp row_to_run(row) when is_map(row) do
    struct!(WorkflowRun, %{
      id: row["id"],
      binding_id: row["binding_id"],
      binding_generation: row["binding_generation"],
      external_task_id: row["external_task_id"],
      authenticated_principal_uri: parse_uri!(row["authenticated_principal_uri"]),
      status: row["status"],
      state_version: row["state_version"],
      input_digest: row["input_digest"],
      source_task_uri: parse_uri!(row["source_task_uri"]),
      source_revision: row["source_revision"],
      requested_head_ref: row["requested_head_ref"],
      last_error_code: row["last_error_code"],
      inserted_at: row["inserted_at"],
      updated_at: row["updated_at"]
    })
  end

  defp parse_uri!(str) when is_binary(str), do: URI.parse(str)
  defp parse_uri!(nil), do: nil

  defp parse_visibility("public"), do: :public
  defp parse_visibility("private"), do: :private
  defp parse_visibility(other) when is_binary(other), do: String.to_existing_atom(other)
end
