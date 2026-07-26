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
  alias EzagentPluginGitWorkflow.DeterministicRef
  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowFacts
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
      {1, _} ->
        {:ok, binding}

      {0, _} ->
        %TaskBinding{id: id} = binding
        {:error, {:binding_exists, id}}
    end
  end

  @doc "Disables a binding by id."
  @spec disable_binding(String.t()) :: {:ok, TaskBinding.t()} | {:error, term()}
  def disable_binding(binding_id) when is_binary(binding_id) do
    case read_binding_row(binding_id) do
      nil ->
        {:error, :not_found}

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
  def accept(%AcceptIntent{
        binding_id: binding_id,
        binding_generation: binding_generation,
        external_task_id: external_task_id,
        source_task_uri: source_task_uri,
        source_revision: source_revision,
        requested_head_ref: requested_head_ref
      }) do
    run_id = WorkflowRun.generate_id(binding_id, binding_generation, external_task_id)

    with {:ok, binding} <- check_binding_active(binding_id),
         :ok <- validate_binding_generation(binding_generation, binding),
         :ok <- validate_source_workspace(source_task_uri, binding, requested_head_ref, run_id),
         digest =
           compute_accept_digest(
             binding_id,
             binding_generation,
             external_task_id,
             source_task_uri,
             source_revision,
             requested_head_ref
           ) do
      %TaskBinding{workspace_uri: workspace_uri} = binding

      run_attrs = %{
        id: run_id,
        binding_id: binding_id,
        binding_generation: binding_generation,
        external_task_id: external_task_id,
        workspace_uri: workspace_uri,
        status: WorkflowRun.initial_status(),
        state_version: 1,
        input_digest: digest,
        source_task_uri: source_task_uri,
        source_revision: source_revision,
        requested_head_ref: requested_head_ref,
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
  Rejects unknown statuses and illegal edges (WorkflowRun.legal_transition?/2)
  at call time. Terminal runs are rejected.

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
    # Reject invalid statuses and illegal edges at the gate.
    # Terminal states are blocked INSIDE the CAS WHERE clause (no pre-read
    # TOCTOU): `AND status NOT IN ('failed','cancelled')` makes the UPDATE
    # a no-op when the row is terminal — even if expected_status
    # accidentally names a terminal state.
    with :ok <- check_valid_status(expected_status),
         :ok <- check_valid_status(next_status),
         :ok <- check_legal_edge(expected_status, next_status) do
      next_version = expected_version + 1
      now = DateTime.utc_now()

      result =
        Repo.query!(
          "UPDATE git_workflow_runs SET status = $1, state_version = $2, updated_at = $3
           WHERE id = $4 AND state_version = $5 AND status = $6
             AND status NOT IN ('failed', 'cancelled')",
          [next_status, next_version, now, run_id, expected_version, expected_status]
        )

      %Postgrex.Result{num_rows: num_rows} = result

      case num_rows do
        1 ->
          {:ok, fetch_run!(run_id)}

        0 ->
          classify_cas_miss(run_id, next_status, next_version, expected_version, expected_status)
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
  # Facts operations
  # ---------------------------------------------------------------------------

  @doc """
  Inserts or fully replaces the facts row for `facts.run_id`.

  Single-statement `INSERT ... ON CONFLICT (run_id) DO UPDATE` — never
  read-then-write. This is what makes concurrent upserts for the same
  run_id race-free: Postgres resolves the conflict against its own unique
  index inside one statement, so two concurrent callers can never both
  observe "no row yet" and both INSERT (which would violate the unique
  index and surface as a DB error, not a silent duplicate) — one of them
  always takes the ON CONFLICT DO UPDATE branch instead. Whichever caller's
  statement commits last simply overwrites every non-key column with its
  own values (last-write-wins), leaving exactly one row.

  The update clause deliberately excludes `id`, so on conflict the row
  keeps its ORIGINAL `id` — never the caller's. The statement therefore
  carries `RETURNING *` and the returned struct is built from that
  returned row (via `row_to_facts/1`), not from the caller's input struct:
  two concurrent callers upserting the same `run_id` with different `id`
  values must never both get back an `{:ok, facts}` whose `id` disagrees
  with what is actually persisted.
  """
  @spec upsert_facts(WorkflowFacts.t()) :: {:ok, WorkflowFacts.t()}
  def upsert_facts(%WorkflowFacts{} = facts) do
    now = DateTime.utc_now()
    row = facts_to_row(facts, now)

    columns = Map.keys(row)
    values = Map.values(row)
    placeholders = 1..length(columns) |> Enum.map(&"$#{&1}") |> Enum.join(", ")

    update_clause =
      columns
      |> Enum.reject(&(&1 in ["id", "run_id", "inserted_at"]))
      |> Enum.map(&"#{&1} = EXCLUDED.#{&1}")
      |> Enum.join(", ")

    %Postgrex.Result{columns: result_columns, rows: [result_row | _]} =
      Repo.query!(
        "INSERT INTO git_workflow_facts (" <>
          Enum.join(columns, ", ") <>
          ") VALUES (" <>
          placeholders <>
          ") ON CONFLICT (run_id) DO UPDATE SET " <> update_clause <> " RETURNING *",
        values
      )

    {:ok, Enum.zip(result_columns, result_row) |> Map.new() |> row_to_facts()}
  end

  @doc "Reads the facts row for a run id."
  @spec read_facts(String.t()) :: {:ok, WorkflowFacts.t()} | {:error, :not_found}
  def read_facts(run_id) when is_binary(run_id) do
    %Postgrex.Result{rows: rows, columns: columns} =
      Repo.query!("SELECT * FROM git_workflow_facts WHERE run_id = $1", [run_id])

    case rows do
      [] -> {:error, :not_found}
      [row | _] -> {:ok, Enum.zip(columns, row) |> Map.new() |> row_to_facts()}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: accept helpers
  # ---------------------------------------------------------------------------

  defp check_binding_active(binding_id) do
    case read_binding_row(binding_id) do
      nil ->
        {:error, :binding_not_found}

      row ->
        if row["enabled"],
          do: {:ok, row_to_binding(row)},
          else: {:error, :binding_disabled}
    end
  end

  defp validate_binding_generation(gen, %TaskBinding{generation: gen}), do: :ok
  defp validate_binding_generation(_gen, _binding), do: {:error, :binding_generation_mismatch}

  defp compute_accept_digest(
         binding_id,
         binding_generation,
         external_task_id,
         source_task_uri,
         source_revision,
         requested_head_ref
       ) do
    WorkflowRun.compute_digest(%{
      binding_id: binding_id,
      binding_generation: binding_generation,
      external_task_id: external_task_id,
      source_task_uri: source_task_uri,
      source_revision: source_revision,
      requested_head_ref: requested_head_ref
    })
  end

  defp validate_source_workspace(
         source_task_uri,
         %TaskBinding{workspace_uri: workspace_uri} = binding,
         requested_head_ref,
         run_id
       ) do
    source_ws = Ezagent.URI.workspace_name(source_task_uri)
    binding_ws = Ezagent.URI.workspace_name(workspace_uri)

    case {source_ws, binding_ws} do
      {{:ok, ws}, {:ok, ws}} ->
        validate_requested_head_ref(requested_head_ref, binding, run_id)

      {{:ok, _}, {:ok, _}} ->
        {:error, :source_workspace_mismatch}

      _ ->
        {:error, :invalid_source_task_uri}
    end
  end

  defp validate_requested_head_ref(nil, _binding, _run_id), do: :ok

  defp validate_requested_head_ref(
         ref,
         %TaskBinding{allowed_head_namespace: ns},
         run_id
       ) do
    if ref == DeterministicRef.derive(ns, run_id),
      do: :ok,
      else: {:error, :head_ref_not_allowed}
  end

  # insert-or-load with digest comparison.
  defp insert_or_load(run_attrs, digest) do
    id = Map.fetch!(run_attrs, :id)
    binding_id = Map.fetch!(run_attrs, :binding_id)
    binding_generation = Map.fetch!(run_attrs, :binding_generation)
    external_task_id = Map.fetch!(run_attrs, :external_task_id)
    status = Map.fetch!(run_attrs, :status)
    workspace_uri_raw = Map.fetch!(run_attrs, :workspace_uri)
    state_version = Map.fetch!(run_attrs, :state_version)
    input_digest = Map.fetch!(run_attrs, :input_digest)
    source_task_uri_raw = Map.fetch!(run_attrs, :source_task_uri)
    source_revision = Map.fetch!(run_attrs, :source_revision)
    requested_head_ref = Map.fetch!(run_attrs, :requested_head_ref)
    last_error_code = Map.fetch!(run_attrs, :last_error_code)
    workspace_uri_str = to_string(workspace_uri_raw)
    source_task_uri_str = to_string(source_task_uri_raw)

    now = DateTime.utc_now()

    # Use raw SQL INSERT ... ON CONFLICT DO NOTHING without conflict_target
    # so ALL unique violations (primary key + unique index) are caught.
    # Ecto's insert_all requires a conflict_target which can only name ONE
    # constraint — but concurrent inserts can violate EITHER the pk or the
    # unique index depending on timing. Raw SQL catches both.
    columns = ~w(
      id binding_id binding_generation external_task_id
      workspace_uri status state_version input_digest
      source_task_uri source_revision requested_head_ref
      last_error_code inserted_at updated_at
    )

    result =
      Repo.query!(
        "INSERT INTO git_workflow_runs (" <> Enum.join(columns, ", ") <> ")
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
         ON CONFLICT DO NOTHING",
        [
          id,
          binding_id,
          binding_generation,
          external_task_id,
          workspace_uri_str,
          status,
          state_version,
          input_digest,
          source_task_uri_str,
          source_revision,
          requested_head_ref,
          last_error_code,
          now,
          now
        ]
      )

    %Postgrex.Result{num_rows: num_rows} = result

    if num_rows == 1 do
      {:ok, run} =
        WorkflowRun.new(%{
          id: id,
          binding_id: binding_id,
          binding_generation: binding_generation,
          external_task_id: external_task_id,
          workspace_uri: workspace_uri_raw,
          status: status,
          state_version: state_version,
          input_digest: input_digest,
          source_task_uri: source_task_uri_raw,
          source_revision: source_revision,
          requested_head_ref: requested_head_ref,
          last_error_code: last_error_code
        })

      {:ok, run}
    else
      existing =
        fetch_run_by_key!(
          binding_id,
          binding_generation,
          external_task_id
        )

      %WorkflowRun{input_digest: existing_digest} = existing

      if existing_digest == digest,
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

  defp check_legal_edge(expected_status, next_status) do
    if WorkflowRun.legal_transition?(expected_status, next_status),
      do: :ok,
      else: {:error, {:illegal_transition, expected_status, next_status}}
  end

  defp classify_cas_miss(run_id, next_status, next_version, expected_version, expected_status) do
    case read_run_row(run_id) do
      nil ->
        {:error, :not_found}

      row ->
        run = row_to_run(row)
        %WorkflowRun{status: current_status, state_version: current_version} = run

        cond do
          # Exact retry: already at target state+version (first, before terminal check)
          current_status == next_status and current_version == next_version ->
            {:ok, run}

          # Terminal — reject any new transition. Exact retry of a terminal
          # state was already handled above; this is a DIFFERENT transition
          # attempt on a terminal run.
          WorkflowRun.terminal?(current_status) ->
            {:error, :workflow_terminal}

          # Status is right but version differs — stale
          current_status == next_status ->
            {:error, :stale_state_version}

          # Version advanced, status differs
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
    %Postgrex.Result{rows: rows, columns: columns} =
      Repo.query!("SELECT * FROM git_workflow_bindings WHERE id = $1", [binding_id])

    case rows do
      [] -> nil
      [row | _] -> Enum.zip(columns, row) |> Map.new()
    end
  end

  defp read_run_row(run_id) do
    %Postgrex.Result{rows: rows, columns: columns} =
      Repo.query!("SELECT * FROM git_workflow_runs WHERE id = $1", [run_id])

    case rows do
      [] -> nil
      [row | _] -> Enum.zip(columns, row) |> Map.new()
    end
  end

  defp zip_row(%{columns: cols, rows: [row | _]}), do: Enum.zip(cols, row) |> Map.new()

  # ---------------------------------------------------------------------------
  # Row ↔ Struct (atom-safe — no String.to_atom/1)
  # ---------------------------------------------------------------------------

  defp binding_to_row(%TaskBinding{
         id: id,
         generation: generation,
         workspace_uri: workspace_uri,
         task_receiver_uri: task_receiver_uri,
         credential_owner_uri: credential_owner_uri,
         repository_uri: repository_uri,
         provider_adapter: provider_adapter,
         provider_host: provider_host,
         external_id: external_id,
         owner_path: owner_path,
         base_ref: base_ref,
         visibility: visibility,
         allowed_head_namespace: allowed_head_namespace,
         enabled: enabled
       }) do
    now = DateTime.utc_now()

    %{
      id: id,
      generation: generation,
      workspace_uri: Ezagent.URI.stable_key(workspace_uri),
      task_receiver_uri: Ezagent.URI.stable_key(task_receiver_uri),
      credential_owner_uri: Ezagent.URI.stable_key(credential_owner_uri),
      repository_uri: Ezagent.URI.stable_key(repository_uri),
      provider_adapter: Atom.to_string(provider_adapter),
      provider_host: provider_host,
      external_id: external_id,
      owner_path: owner_path,
      base_ref: base_ref,
      visibility: Atom.to_string(visibility),
      allowed_head_namespace: allowed_head_namespace,
      enabled: enabled,
      inserted_at: now,
      updated_at: now
    }
  end

  defp row_to_binding(row) when is_map(row) do
    adapter = String.to_existing_atom(row["provider_adapter"])

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
      workspace_uri: parse_uri!(row["workspace_uri"]),
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

  defp facts_to_row(%WorkflowFacts{workspace_uri: workspace_uri} = facts, now) do
    facts
    |> Map.from_struct()
    |> Map.drop([:inserted_at, :updated_at])
    |> Map.put(:workspace_uri, to_string(workspace_uri))
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
    |> Map.put("inserted_at", now)
    |> Map.put("updated_at", now)
  end

  defp row_to_facts(row) when is_map(row) do
    struct!(WorkflowFacts, %{
      id: row["id"],
      run_id: row["run_id"],
      workspace_uri: parse_uri!(row["workspace_uri"]),
      workspace_provision_id: row["workspace_provision_id"],
      deterministic_head_ref: row["deterministic_head_ref"],
      change_digest: row["change_digest"],
      expected_base_sha: row["expected_base_sha"],
      head_sha: row["head_sha"],
      change_request_id: row["change_request_id"],
      change_request_url: row["change_request_url"],
      change_request_state: row["change_request_state"],
      change_request_head_ref: row["change_request_head_ref"],
      change_request_base_ref: row["change_request_base_ref"],
      checks_revision: row["checks_revision"],
      checks_summary: row["checks_summary"],
      checks_observed_at: row["checks_observed_at"],
      reviews_revision: row["reviews_revision"],
      reviews_summary: row["reviews_summary"],
      reviews_observed_at: row["reviews_observed_at"],
      inserted_at: row["inserted_at"],
      updated_at: row["updated_at"]
    })
  end

  defp parse_uri!(str) when is_binary(str), do: Ezagent.URI.new!(str)
  defp parse_uri!(nil), do: nil

  defp parse_visibility("public"), do: :public
  defp parse_visibility("private"), do: :private

  defp parse_visibility(other) when is_binary(other) do
    String.to_existing_atom(other)
  end
end
