defmodule Ezagent.Workspace.TaskWorkspace.Provisioner do
  @moduledoc "Orchestrates one fenced anonymous task-workspace provision generation."

  @behaviour Ezagent.DomainGit.WorkspaceProvisionPort

  alias Ezagent.DomainGit.WorkspaceProvisionPort.Request
  alias Ezagent.Entity.GitTaskAccess
  alias Ezagent.Workspace.TaskWorkspace.{CacheLock, GitRunner, Paths, Provision, Store}

  @test_env Mix.env() == :test
  @wait_ms 2_000
  @poll_ms 10

  @impl true
  def prepare(%Request{operation: :prepare} = request) do
    with {:ok, policy} <- load_policy(request),
         :ok <- public_repository(policy),
         {:ok, row} <- create_plan(request, policy) do
      converge(row, request, policy)
    end
  end

  def prepare(%Request{}), do: {:error, :invalid_provision_operation}
  def prepare(_request), do: {:error, :invalid_provision_request}

  @impl true
  def cleanup(%Request{operation: :cleanup}), do: {:error, :cleanup_incomplete}
  def cleanup(%Request{}), do: {:error, :invalid_provision_operation}
  def cleanup(_request), do: {:error, :invalid_provision_request}

  defp load_policy(request) do
    case Ezagent.Kind.get_slice(request.task_access_uri, :git_task_access) do
      {:ok, %{policy: candidate}} ->
        with {:ok, policy} <- GitTaskAccess.revalidate(candidate),
             true <- GitTaskAccess.uri_from_args(policy) == request.task_access_uri,
             :ok <-
               GitTaskAccess.validate_invocation(policy, %{
                 action: :provision_workspace,
                 task_uri: request.task_uri,
                 generation: request.generation
               }) do
          {:ok, policy}
        else
          _ -> {:error, :task_policy_mismatch}
        end

      {:error, :not_found} ->
        {:error, :task_access_not_found}

      _ ->
        {:error, :task_access_not_found}
    end
  rescue
    _ -> {:error, :task_policy_mismatch}
  end

  defp public_repository(%GitTaskAccess{repository: %{visibility: :public}}), do: :ok

  defp public_repository(%GitTaskAccess{repository: %{visibility: :private}}),
    do: {:error, :private_checkout_not_supported}

  defp create_plan(request, policy) do
    attrs = %{
      provision_id: request.provision_id,
      workspace_uri: URI.to_string(policy.workspace_uri),
      task_uri: URI.to_string(request.task_uri),
      generation: request.generation,
      task_access_uri: URI.to_string(request.task_access_uri),
      repository_uri: URI.to_string(policy.repository.repository_uri),
      base_ref: policy.repository.base_ref,
      allowed_head_ref: policy.allowed_head_ref,
      visibility: policy.repository.visibility
    }

    case Store.create_planned(attrs) do
      {:ok, row} -> {:ok, row}
      {:error, :conflicting_provision_identity} -> {:error, :task_policy_mismatch}
      {:error, _reason} -> {:error, :checkout_unavailable}
    end
  end

  defp converge(%Provision{status: :ready} = row, _request, _policy), do: ready_result(row)

  defp converge(%Provision{status: status}, _request, _policy)
       when status in [:cleanup_pending, :cleaned],
       do: {:error, :provision_cancelled}

  defp converge(%Provision{status: :blocked}, _request, _policy),
    do: {:error, :workspace_not_ready}

  defp converge(%Provision{} = row, request, policy) do
    case Store.claim_provision(row.id, expected_version: row.state_version) do
      {:ok, claimed} -> run_claim(claimed, request, policy)
      {:error, :provision_already_claimed} -> await_terminal(row.id)
      {:error, :invalid_provision_transition} -> converge_current(row.id)
      {:error, _reason} -> {:error, :checkout_unavailable}
    end
  end

  defp run_claim(claimed, request, policy) do
    git_request = git_request(request, policy)

    with {:ok, paths} <- Paths.derive(git_request),
         true <- Store.worktree_path_available?(claimed.id, paths.worktree_path) do
      case serialized_prepare(paths.cache_identity, git_request) do
        {:ok, prepared} -> finish_prepared(claimed, request, prepared)
        {:error, reason} -> fail_claim(claimed, nil, normalize_failure(reason))
        _unexpected -> fail_claim(claimed, nil, :checkout_unavailable)
      end
    else
      false -> fail_claim(claimed, nil, :worktree_conflict)
      {:error, reason} -> fail_claim(claimed, nil, normalize_failure(reason))
    end
  end

  defp finish_prepared(claimed, request, prepared) do
    with :ok <- runner().verify(prepared),
         {:ok, current_policy} <- load_policy(request),
         true <- policy_matches_row?(current_policy, claimed),
         {:ok, ready} <-
           Store.mark_ready(claimed.id, claimed.claim_token, %{
             expected_version: claimed.state_version,
             cache_identity: prepared.cache_identity,
             worktree_identity: prepared.worktree_identity,
             worktree_path: prepared.worktree_path
           }) do
      ready_result(ready)
    else
      false -> fail_claim(claimed, prepared, :task_policy_mismatch)
      {:error, :provision_lease_lost} -> fail_claim(claimed, prepared, :provision_lease_lost)
      {:error, :provision_lease_expired} -> fail_claim(claimed, prepared, :provision_lease_lost)
      {:error, :invalid_provision_transition} ->
        fail_claim(claimed, prepared, :provision_lease_lost)

      {:error, :task_policy_mismatch} -> fail_claim(claimed, prepared, :task_policy_mismatch)
      {:error, :task_access_not_found} -> fail_claim(claimed, prepared, :task_policy_mismatch)
      {:error, _reason} -> fail_claim(claimed, prepared, :workspace_not_ready)
    end
  end

  defp serialized_prepare(cache_identity, request) do
    CacheLock.with_lock(cache_identity, fn -> runner().prepare(request) end)
  end

  defp fail_claim(claimed, prepared, blocker) do
    if is_map(prepared), do: runner().remove(prepared)
    _ = Store.request_cleanup(claimed.id, blocker)
    {:error, blocker}
  end

  defp normalize_failure(:worktree_verification_failed), do: :workspace_not_ready
  defp normalize_failure(:git_command_timeout), do: :checkout_unavailable
  defp normalize_failure(:git_output_limit_exceeded), do: :checkout_unavailable
  defp normalize_failure(:cache_remote_mismatch), do: :anonymous_checkout_denied
  defp normalize_failure({:cache_clone_failed, _}), do: :checkout_unavailable
  defp normalize_failure({:worktree_add_failed, _}), do: :checkout_unavailable
  defp normalize_failure(_reason), do: :checkout_unavailable

  defp await_terminal(id) do
    deadline = System.monotonic_time(:millisecond) + @wait_ms
    poll(id, deadline)
  end

  defp poll(id, deadline) do
    case Store.get(id) do
      %Provision{status: :ready} = ready ->
        ready_result(ready)

      %Provision{status: status} when status in [:cleanup_pending, :cleaned] ->
        {:error, :provision_cancelled}

      %Provision{status: :blocked} ->
        {:error, :workspace_not_ready}

      %Provision{} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@poll_ms)
          poll(id, deadline)
        else
          {:error, :provision_already_claimed}
        end

      nil ->
        {:error, :checkout_unavailable}
    end
  end

  defp converge_current(id) do
    case Store.get(id) do
      %Provision{status: :ready} = ready ->
        ready_result(ready)

      %Provision{status: status} when status in [:cleanup_pending, :cleaned] ->
        {:error, :provision_cancelled}

      _ ->
        {:error, :workspace_not_ready}
    end
  end

  defp ready_result(row) do
    {:ok,
     %{
       status: :ready,
       provision_id: row.provision_id,
       task_access_uri: row.task_access_uri,
       task_uri: row.task_uri,
       generation: row.generation,
       cwd: row.worktree_path,
       start_token: row.start_token
     }}
  end

  defp git_request(request, policy) do
    repository = policy.repository

    %{
      workspace_uri: policy.workspace_uri,
      repository_uri: repository.repository_uri,
      remote_url: anonymous_remote(repository.provider_host, repository.owner_path),
      base_ref: repository.base_ref,
      provision_id: request.provision_id,
      generation: request.generation,
      allowed_head_ref: policy.allowed_head_ref,
      visibility: repository.visibility
    }
  end

  defp anonymous_remote(host, owner_path), do: "https://#{host}/#{owner_path}.git"

  defp policy_matches_row?(policy, row) do
    URI.to_string(policy.workspace_uri) == row.workspace_uri and
      URI.to_string(policy.repository.repository_uri) == row.repository_uri and
      policy.repository.base_ref == row.base_ref and
      policy.allowed_head_ref == row.allowed_head_ref and policy.generation == row.generation
  end

  defp runner do
    if @test_env,
      do: Application.get_env(:ezagent_domain_workspace, :task_workspace_git_runner, GitRunner),
      else: GitRunner
  end
end
