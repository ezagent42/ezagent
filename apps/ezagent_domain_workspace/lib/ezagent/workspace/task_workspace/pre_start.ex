defmodule Ezagent.Workspace.TaskWorkspace.PreStart do
  @moduledoc "Claims and verifies one ready task workspace before Agent instantiation."

  @behaviour Ezagent.Kind.Template.PreStart

  alias Ezagent.Workspace.TaskWorkspace.AgentStart.Ref
  alias Ezagent.Workspace.TaskWorkspace.{GitRunner, PreStartVerifier, Provision, Store}

  @start_lease_safety_ms 10_000

  @impl true
  def prepare(%Ref{} = ref) do
    with %Provision{} = row <- Store.get_by_provision_id(ref.provision_id),
         :ok <- exact_identity(row, ref),
         {:ok, claimed} <- claim(row),
         :ok <- verify(claimed) do
      {:ok, %{cwd: claimed.worktree_path, claim: {claimed.id, claimed.start_claim_token}}}
    else
      nil -> {:error, :workspace_not_ready}
      {:error, reason} = error -> maybe_cleanup(ref.provision_id, reason, error)
    end
  end

  def prepare(_ref), do: {:error, :workspace_not_ready}

  @impl true
  def complete({id, start_token}, {:ok, %{workers: [%URI{} = agent_uri]}}) do
    with %Provision{} = row <- Store.get(id),
         true <- row.agent_uri == URI.to_string(agent_uri),
         {:ok, workspace_uri} <- parse_uri(row.workspace_uri),
         {:ok, attempt_id} <-
           Ezagent.Agent.CreationInventory.find_attempt(agent_uri, workspace_uri),
         {:ok, provenance_root} <- Ezagent.AgentLineage.lookup(agent_uri),
         true <- row.provenance_root_uri == URI.to_string(provenance_root),
         {:ok, _started} <-
           Store.mark_started(id, start_token, %{
             agent_uri: URI.to_string(agent_uri),
             creation_attempt_id: attempt_id,
             provenance_root_uri: URI.to_string(provenance_root)
           }) do
      :ok
    else
      _reason -> request_cleanup(id, :sidecar_start_ambiguous)
    end
  end

  def complete({id, _start_token}, {:error, _reason}) do
    request_cleanup(id, :sidecar_start_failed)
  end

  def complete(_claim, _outcome), do: {:error, :invalid_task_workspace_start_claim}

  defp exact_identity(row, ref) do
    if row.task_access_uri == URI.to_string(ref.task_access_uri) and
         row.task_uri == URI.to_string(ref.task_uri) and row.generation == ref.generation and
         is_binary(row.agent_uri) and row.agent_uri != "" and
         is_binary(row.provenance_root_uri) and row.provenance_root_uri != "",
       do: :ok,
       else: {:error, :workspace_not_ready}
  end

  defp claim(row) do
    case Store.claim_start(row.id, row.start_token, lease_seconds: start_lease_seconds()) do
      {:ok, claimed} ->
        {:ok, claimed}

      {:error, reason}
      when reason in [:start_token_consumed, :start_already_claimed, :invalid_start_transition] ->
        {:error, :sidecar_start_already_consumed}

      {:error, _reason} ->
        {:error, :workspace_not_ready}
    end
  end

  defp verify(row) do
    proof = %{
      cache_path: Path.join(Path.dirname(row.worktree_path), row.cache_identity),
      worktree_path: row.worktree_path,
      remote_url: row.remote_url,
      resolved_base_commit: row.resolved_base_commit,
      local_branch_ref: row.local_branch_ref
    }

    with true <- Path.expand(row.worktree_path) == row.worktree_path,
         :ok <- PreStartVerifier.verify(proof) do
      :ok
    else
      false -> fail_proof(row, :workspace_checkout_mismatch)
      {:error, reason} -> fail_proof(row, reason)
    end
  end

  defp maybe_cleanup(_provision_id, _reason, error), do: error

  defp fail_proof(row, reason) do
    case Store.fail_start(row.id, row.start_claim_token, reason) do
      {:ok, _pending} ->
        {:error, reason}

      {:error, lost} when lost in [:sidecar_start_claim_lost, :invalid_start_transition] ->
        {:error, :sidecar_start_claim_lost}

      {:error, _reason} ->
        {:error, reason}
    end
  end

  defp start_lease_seconds do
    div(GitRunner.maximum_provision_duration_ms() + @start_lease_safety_ms + 999, 1_000)
  end

  defp request_cleanup(id, reason) do
    case Store.request_cleanup(id, reason) do
      {:ok, _classification, _row} -> :ok
      {:error, cleanup_reason} -> {:error, cleanup_reason}
    end
  end

  defp parse_uri(value) when is_binary(value) do
    case Ezagent.URI.parse(value) do
      {:ok, %URI{} = uri} -> {:ok, uri}
      {:error, _reason} -> {:error, :invalid_retirement_handle}
    end
  end
end
