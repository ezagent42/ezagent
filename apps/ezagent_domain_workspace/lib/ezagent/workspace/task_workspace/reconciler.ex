defmodule Ezagent.Workspace.TaskWorkspace.Reconciler do
  @moduledoc "Bounded, durable-row-only task workspace cleanup and boot recovery."

  require Logger

  alias Ezagent.Workspace.TaskWorkspace.{CacheLock, GitRunner, Paths, Provision, Store}

  @cleanup_lease_seconds 180
  @cache_lock_timeout_ms 5_000

  @doc "Requests and completes cleanup of one durable provision row."
  @spec cleanup(pos_integer(), atom()) :: {:ok, Provision.t()} | {:error, term()}
  def cleanup(id, reason) when is_integer(id) and is_atom(reason) do
    with %Provision{status: status} = row when status != :cleaned <- Store.get(id),
         {:ok, paths} <- canonical_paths(row),
         {:ok, classification, pending} <- Store.request_cleanup(id, reason) do
      claim_and_clean(pending, classification, paths)
    else
      %Provision{status: :cleaned} = cleaned -> {:ok, cleaned}
      nil -> {:error, :workspace_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc "Processes one bounded recovery batch and continues after individual failures."
  @spec recover_once(keyword()) :: %{
          attempted: non_neg_integer(),
          cleaned: non_neg_integer(),
          failed: non_neg_integer()
        }
  def recover_once(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    effects = Store.list_effect_recovery_candidates(limit, now: now)
    ready_limit = max(limit - length(effects), 0)
    candidates = effects ++ Store.list_ready_recovery_candidates(ready_limit)
    after_candidate_list(opts, candidates)

    candidates
    |> Enum.reduce(%{attempted: 0, cleaned: 0, failed: 0}, fn row, report ->
      result = recover(row, now)
      report = %{report | attempted: report.attempted + 1}

      case result do
        {:ok, _row} ->
          %{report | cleaned: report.cleaned + 1}

        {:skip, _reason} ->
          report

        {:error, reason} ->
          Logger.warning(
            "task workspace recovery failed provision=#{row.provision_id} reason=#{inspect(reason)}"
          )

          %{report | failed: report.failed + 1}
      end
    end)
  end

  defp recover(%Provision{status: :ready} = row, _now) do
    with {:ok, paths} <- canonical_paths(row) do
      case runner().verify(paths) do
        :ok ->
          {:skip, :ready_workspace_valid}

        {:error, :worktree_verification_failed} ->
          with {:ok, :never_started, pending} <-
                 Store.request_invalid_ready_cleanup(
                   row.id,
                   row.state_version,
                   :workspace_not_ready
                 ) do
            claim_and_clean(pending, :never_started, paths)
          end

        {:error, reason} ->
          {:error, {:ready_verification_unavailable, reason}}
      end
    end
  end

  defp recover(%Provision{status: :provisioning} = row, _now),
    do: cleanup(row.id, :expired_provision_lease)

  defp recover(%Provision{status: :starting} = row, now) do
    with {:ok, paths} <- canonical_paths(row) do
      case Store.request_expired_start_cleanup(
             row.id,
             row.state_version,
             row.start_claim_token,
             now
           ) do
        {:ok, :ambiguous_or_live, pending} ->
          claim_and_clean(pending, :ambiguous_or_live, paths)

        {:error, reason}
        when reason in [
               :sidecar_start_claim_lost,
               :start_lease_active,
               :invalid_cleanup_transition
             ] ->
          {:skip, :stale_start_snapshot}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp recover(%Provision{status: :cleanup_pending} = row, _now),
    do: cleanup(row.id, :resume_cleanup)

  defp claim_and_clean(pending, classification, paths) do
    with {:ok, claimed} <-
           Store.claim_cleanup(pending.id,
             expected_version: pending.state_version,
             lease_seconds: @cleanup_lease_seconds
           ),
         :ok <- maybe_retire(claimed, classification),
         :ok <- remove_exact(claimed, paths),
         {:ok, current} <- Store.validate_cleanup_claim(claimed.id, claimed.claim_token),
         {:ok, cleaned} <- Store.mark_cleaned(current.id, current.claim_token) do
      {:ok, cleaned}
    end
  end

  defp maybe_retire(_claimed, :never_started), do: :ok

  defp maybe_retire(claimed, :ambiguous_or_live) do
    with {:ok, renewed} <- renew(claimed),
         :ok <- retirement().retire(renewed) do
      :ok
    end
  end

  defp remove_exact(claimed, paths) do
    CacheLock.with_lock(paths.cache_identity, @cache_lock_timeout_ms, fn ->
      with {:ok, current} <- renew(claimed) do
        case runner().verify_absent(paths) do
          :ok ->
            :ok

          {:error, :worktree_still_present} ->
            with {:ok, _current} <- renew(current),
                 :ok <- runner().remove(paths),
                 {:ok, _current} <- renew(current),
                 :ok <- runner().verify_absent(paths) do
              :ok
            end

          {:error, _reason} = error ->
            error
        end
      end
    end)
  end

  defp renew(%Provision{} = claimed) do
    Store.renew_cleanup_claim(claimed.id, claimed.claim_token,
      lease_seconds: @cleanup_lease_seconds
    )
  end

  defp canonical_paths(%Provision{} = row) do
    with {:ok, workspace_uri} <- parse_uri(row.workspace_uri),
         {:ok, repository_uri} <- parse_uri(row.repository_uri),
         {:ok, paths} <-
           Paths.derive(%{
             workspace_uri: workspace_uri,
             repository_uri: repository_uri,
             provision_id: row.provision_id,
             generation: row.generation,
             base_ref: row.base_ref,
             allowed_head_ref: row.allowed_head_ref
           }),
         :ok <- recorded_paths_match(row, paths) do
      {:ok, paths}
    else
      {:error, _reason} = error -> error
    end
  end

  defp parse_uri(value) do
    {:ok, Ezagent.URI.new!(value)}
  rescue
    _ -> {:error, :invalid_path_coordinates}
  end

  defp recorded_paths_match(%Provision{worktree_path: nil}, _paths), do: :ok

  defp recorded_paths_match(row, paths) do
    if row.cache_identity == paths.cache_identity and
         row.worktree_identity == paths.worktree_identity and
         row.worktree_path == paths.worktree_path,
       do: :ok,
       else: {:error, :workspace_path_mismatch}
  end

  defp runner do
    if Mix.env() == :test,
      do: Application.get_env(:ezagent_domain_workspace, :task_workspace_git_runner, GitRunner),
      else: GitRunner
  end

  defp retirement do
    if Mix.env() == :test,
      do:
        Application.get_env(
          :ezagent_domain_workspace,
          :task_workspace_retirement,
          Ezagent.Workspace.TaskWorkspace.Retirement
        ),
      else: Ezagent.Workspace.TaskWorkspace.Retirement
  end

  if Mix.env() == :test do
    defp after_candidate_list(opts, candidates) do
      case Keyword.get(opts, :after_candidate_list) do
        hook when is_function(hook, 1) -> hook.(candidates)
        nil -> :ok
      end
    end
  else
    defp after_candidate_list(_opts, _candidates), do: :ok
  end
end
