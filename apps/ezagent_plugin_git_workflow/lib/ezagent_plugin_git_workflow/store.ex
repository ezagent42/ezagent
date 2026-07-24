defmodule EzagentPluginGitWorkflow.Store do
  @moduledoc """
  PostgreSQL-backed store for workflow bindings and runs — E2-A only.

  No authorization. No authenticated_principal. No CapBAC. All caller
  authorization is deferred to E2-B. This module receives an
  already-validated AcceptIntent and handles only persistence,
  idempotency, and CAS concurrency.

  All concurrency decisions are driven by database results: unique
  constraints, single-statement conditional UPDATE, and fresh-read
  reconciliation. No GenServer, Agent, ETS, or application lock.
  """

  alias EzagentCore.Repo
  alias EzagentPluginGitWorkflow.AcceptIntent
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
      Repo.insert_all("git_workflow_bindings", [row],
        on_conflict: :nothing,
        conflict_target: [:id]
      )

    case result do
      {1, _} -> {:ok, binding}
      {0, _} -> {:error, {:binding_exists, binding.id}}
    end
  end

  @doc "Disables a binding by id."
  @spec disable_binding(String.t()) :: {:ok, TaskBinding.t()} | {:error, term()}
  def disable_binding(binding_id) when is_binary(binding_id) do
    case read_binding_row(binding_id) do
      nil -> {:error, :not_found}
      _row ->
        now = DateTime.utc_now()
        Repo.query!("UPDATE git_workflow_bindings SET enabled = $1, updated_at = $2 WHERE id = $3",
          [false, now, binding_id])

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
  # Accept (server-generated intent creation)
  # ---------------------------------------------------------------------------

  @doc """
  Accept a typed AcceptIntent and persist an accepted run.

  Server-generated: run id (full sha256), input_digest, status="accepted",
  state_version=1.

  Validates:
    - binding exists and is enabled
    - binding.generation == intent.binding_generation

  Returns {:ok, WorkflowRun.t()} on success.

  Idempotency: duplicate unique-key returns the existing run if digest matches.
  Different digest on same unique-key returns {:error, :digest_conflict}.
  """
  @spec accept(AcceptIntent.t()) :: {:ok, WorkflowRun.t()} | {:error, term()}
  def accept(%AcceptIntent{} = intent) do
    with {:ok, binding} <- check_binding_active(intent.binding_id),
         :ok <- validate_binding_generation(intent, binding),
         :ok <- validate_source_workspace(intent, binding),
         run_id = WorkflowRun.generate_id(intent.binding_id, intent.binding_generation, intent.external_task_id),
         digest = compute_accept_digest(intent) do
      run_attrs = %{
        id: run_id,
        binding_id: intent.binding_id,
        binding_generation: intent.binding_generation,
        external_task_id: intent.external_task_id,
        status: WorkflowRun.initial_status(),
        state_version: 1,
        input_digest: digest,
        source_task_uri: intent.source_task_uri,
        source_revision: intent.source_revision,
        requested_head_ref: intent.requested_head_ref,
        last_error_code: nil
      }

      insert_or_load(run_attrs, digest)
    end
  end

  # ---------------------------------------------------------------------------
  # CAS transition
  # ---------------------------------------------------------------------------

  @doc """
  Atomically transition a run's status using single-statement PostgreSQL CAS.

  UPDATE succeeds only when id, state_version, and status all match.
  Rejects unknown statuses at call time. Terminal runs are rejected.

  On zero rows updated, fresh-reads and distinguishes:
    - exact retry (already at target state+version)
    - stale_state_version
    - workflow_state_conflict
    - workflow_terminal (run is in terminal state)
    - not_found
  """
  @spec transition(String.t(), pos_integer(), String.t(), String.t()) ::
          {:ok, WorkflowRun.t()} | {:error, term()}
  def transition(run_id, expected_version, expected_status, next_status)
      when is_binary(run_id) and is_integer(expected_version) and
           is_binary(expected_status) and is_binary(next_status) do
    # Reject invalid statuses at the gate
    with :ok <- check_valid_status(expected_status),
         :ok <- check_valid_status(next_status),
         :ok <- check_not_terminal(run_id) do
      next_version = expected_version + 1
      now = DateTime.utc_now()

      result =
        Repo.query!(
          "UPDATE git_workflow_runs SET status = $1, state_version = $2, updated_at = $3
           WHERE id = $4 AND state_version = $5 AND status = $6",
          [next_status, next_version, now, run_id, expected_version, expected_status]
        )

      case result.num_rows do
        1 -> {:ok, fetch_run!(run_id)}
        0 -> classify_cas_miss(run_id, next_status, next_version, expected_version, expected_status)
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
  # Private: accept helpers
  # ---------------------------------------------------------------------------

  defp check_binding_active(binding_id) do
    case read_binding_row(binding_id) do
      nil -> {:error, :binding_not_found}
      row ->
        if row["enabled"],
          do: {:ok, row_to_binding(row)},
          else: {:error, :binding_disabled}
    end
  end

  defp validate_binding_generation(%AcceptIntent{binding_generation: gen}, %TaskBinding{generation: gen}), do: :ok
  defp validate_binding_generation(_intent, _binding), do: {:error, :binding_generation_mismatch}

  defp compute_accept_digest(%AcceptIntent{} = intent) do
    WorkflowRun.compute_digest(Map.from_struct(intent))
  end

  defp validate_source_workspace(%AcceptIntent{} = intent, %TaskBinding{} = binding) do
    source_ws = Ezagent.URI.workspace_name(intent.source_task_uri)
    binding_ws = Ezagent.URI.workspace_name(binding.workspace_uri)

    case {source_ws, binding_ws} do
      {{:ok, ws}, {:ok, ws}} ->
        validate_requested_head_ref(intent, binding)

      {{:ok, _}, {:ok, _}} ->
        {:error, :source_workspace_mismatch}

      _ ->
        {:error, :invalid_source_task_uri}
    end
  end

  defp validate_requested_head_ref(%AcceptIntent{requested_head_ref: nil}, _binding), do: :ok

  defp validate_requested_head_ref(%AcceptIntent{requested_head_ref: ref}, %TaskBinding{allowed_head_namespace: ns}) do
    if String.starts_with?(ref, ns),
      do: :ok,
      else: {:error, :head_ref_not_allowed}
  end

  # insert-or-load with digest comparison.
  defp insert_or_load(run_attrs, digest) do
    now = DateTime.utc_now()

    insert_row = %{
      id: run_attrs.id,
      binding_id: run_attrs.binding_id,
      binding_generation: run_attrs.binding_generation,
      external_task_id: run_attrs.external_task_id,
      status: run_attrs.status,
      state_version: run_attrs.state_version,
      input_digest: run_attrs.input_digest,
      source_task_uri: to_string(run_attrs.source_task_uri),
      source_revision: run_attrs.source_revision,
      requested_head_ref: run_attrs.requested_head_ref,
      last_error_code: run_attrs.last_error_code,
      inserted_at: now,
      updated_at: now
    }

    # Use raw SQL INSERT ... ON CONFLICT DO NOTHING without conflict_target
    # so ALL unique violations (primary key + unique index) are caught.
    # Ecto's insert_all requires a conflict_target which can only name ONE
    # constraint — but concurrent inserts can violate EITHER the pk or the
    # unique index depending on timing. Raw SQL catches both.
    columns = ~w(
      id binding_id binding_generation external_task_id
      status state_version input_digest source_task_uri
      source_revision requested_head_ref last_error_code
      inserted_at updated_at
    )

    result =
      Repo.query!(
        "INSERT INTO git_workflow_runs (" <> Enum.join(columns, ", ") <> ")
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
         ON CONFLICT DO NOTHING",
        [
          insert_row.id,
          insert_row.binding_id,
          insert_row.binding_generation,
          insert_row.external_task_id,
          insert_row.status,
          insert_row.state_version,
          insert_row.input_digest,
          insert_row.source_task_uri,
          insert_row.source_revision,
          insert_row.requested_head_ref,
          insert_row.last_error_code,
          insert_row.inserted_at,
          insert_row.updated_at
        ]
      )

    if result.num_rows == 1 do
      {:ok, run} =
        WorkflowRun.new(%{
          id: insert_row.id,
          binding_id: insert_row.binding_id,
          binding_generation: insert_row.binding_generation,
          external_task_id: insert_row.external_task_id,
          status: insert_row.status,
          state_version: insert_row.state_version,
          input_digest: insert_row.input_digest,
          source_task_uri: run_attrs.source_task_uri,
          source_revision: insert_row.source_revision,
          requested_head_ref: insert_row.requested_head_ref,
          last_error_code: insert_row.last_error_code
        })

      {:ok, run}
    else
      existing = fetch_run_by_key!(run_attrs.binding_id, run_attrs.binding_generation, run_attrs.external_task_id)

      if existing.input_digest == digest,
        do: {:ok, existing},
        else: {:error, :digest_conflict}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: CAS helpers
  # ---------------------------------------------------------------------------

  defp check_valid_status(status) do
    if WorkflowRun.valid_status?(status),
      do: :ok,
      else: {:error, {:invalid_status, status}}
  end

  defp check_not_terminal(run_id) do
    case read_run_row(run_id) do
      nil -> {:error, :not_found}
      row ->
        if WorkflowRun.terminal?(row["status"]),
          do: {:error, :workflow_terminal},
          else: :ok
    end
  end

  defp classify_cas_miss(run_id, next_status, next_version, expected_version, expected_status) do
    case read_run_row(run_id) do
      nil ->
        {:error, :not_found}

      row ->
        run = row_to_run(row)

        cond do
          # Terminal — reject any further transitions
          WorkflowRun.terminal?(run.status) ->
            {:error, :workflow_terminal}

          # Exact retry: already at target
          run.status == next_status and run.state_version == next_version ->
            {:ok, run}

          # Status is right but version differs — stale
          run.status == next_status ->
            {:error, :stale_state_version}

          # Version advanced, status differs
          run.state_version != expected_version and run.status != expected_status ->
            {:error, :stale_state_version}

          # Status mismatch
          run.status != expected_status ->
            {:error, :workflow_state_conflict}

          true ->
            {:error, :workflow_state_conflict}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private: DB row accessors
  # ---------------------------------------------------------------------------

  defp fetch_run!(run_id) do
    result = Repo.query!("SELECT * FROM git_workflow_runs WHERE id = $1", [run_id])
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

  defp read_binding_row(binding_id) do
    result = Repo.query!("SELECT * FROM git_workflow_bindings WHERE id = $1", [binding_id])

    case result.rows do
      [] -> nil
      [row | _] -> Enum.zip(result.columns, row) |> Map.new()
    end
  end

  defp read_run_row(run_id) do
    result = Repo.query!("SELECT * FROM git_workflow_runs WHERE id = $1", [run_id])

    case result.rows do
      [] -> nil
      [row | _] -> Enum.zip(result.columns, row) |> Map.new()
    end
  end

  defp zip_row(%{columns: cols, rows: [row | _]}), do: Enum.zip(cols, row) |> Map.new()

  # ---------------------------------------------------------------------------
  # Row ↔ Struct (atom-safe — no String.to_atom/1)
  # ---------------------------------------------------------------------------

  @known_adapters %{
    "Elixir.GitHubTestAdapter" => GitHubTestAdapter,
    # Production adapters registered here; unknown → fail closed
  }

  defp binding_to_row(%TaskBinding{} = b) do
    now = DateTime.utc_now()
    %{
      id: b.id,
      generation: b.generation,
      workspace_uri: URI.to_string(b.workspace_uri),
      task_receiver_uri: URI.to_string(b.task_receiver_uri),
      credential_owner_uri: URI.to_string(b.credential_owner_uri),
      repository_uri: URI.to_string(b.repository_uri),
      provider_adapter: Atom.to_string(b.provider_adapter),
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

  defp row_to_binding(row) when is_map(row) do
    adapter = parse_adapter!(row["provider_adapter"])

    struct!(TaskBinding, %{
      id: row["id"],
      generation: row["generation"],
      workspace_uri: parse_uri!(row["workspace_uri"]),
      task_receiver_uri: parse_uri!(row["task_receiver_uri"]),
      credential_owner_uri: parse_uri!(row["credential_owner_uri"]),
      repository_uri: parse_uri!(row["repository_uri"]),
      provider_adapter: adapter,
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

  defp row_to_run(row) when is_map(row) do
    struct!(WorkflowRun, %{
      id: row["id"],
      binding_id: row["binding_id"],
      binding_generation: row["binding_generation"],
      external_task_id: row["external_task_id"],
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
  defp parse_visibility(other) when is_binary(other) do
    # Use String.to_existing_atom for visibility — :public and :private are
    # already defined at compile time; corrupt values fail closed.
    String.to_existing_atom(other)
  end

  defp parse_adapter!(name) when is_binary(name) do
    case Map.fetch(@known_adapters, name) do
      {:ok, mod} ->
        mod

      :error ->
        try do
          module = String.to_existing_atom(name)
          if Code.ensure_loaded?(module), do: module, else: raise("not loaded")
        rescue
          _ -> reraise ArgumentError, "unknown/corrupt provider_adapter: #{name}", __STACKTRACE__
        end
    end
  end
end
