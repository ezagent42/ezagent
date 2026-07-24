defmodule EzagentPluginGitWorkflow.ConcurrencyTest do
  use EzagentPluginGitWorkflow.ConnCase, async: false

  alias EzagentCore.Repo
  alias EzagentPluginGitWorkflow.Store

  @moduletag :concurrency
  @n 20
  @binding_id "bnd_conc"

  setup do
    now = DateTime.utc_now()
    Repo.insert_all("git_workflow_bindings", [%{
      id: @binding_id, generation: 1,
      workspace_uri: "workspace://test-ws",
      task_receiver_uri: "resource://test-ws/kanban-task/task-recv",
      credential_owner_uri: "entity://test-ws/user/admin",
      repository_uri: "resource://test-ws/git-repository/my-repo",
      provider_adapter: "Elixir.GitHubTestAdapter",
      provider_host: "github.com", external_id: "owner/repo",
      owner_path: "owner", base_ref: "main", visibility: "public",
      allowed_head_namespace: "feature/", enabled: true,
      inserted_at: now, updated_at: now
    }], on_conflict: :nothing, conflict_target: [:id])
    :ok
  end

  describe "unique constraint enforcement — #{@n} sequential accepts" do
    test "all accept calls return the same run id, exactly 1 DB row" do
      task_key = "conc-seq-#{System.unique_integer([:positive])}"

      results =
        for _ <- 1..@n do
          Store.accept(%{
            binding_id: @binding_id, binding_generation: 1,
            external_task_id: task_key,
            source_task_uri: URI.parse("resource://test-ws/kanban-task/task-src"),
            source_revision: "abc", requested_head_ref: "feature/seq"
          })
        end

      oks = Enum.filter(results, &match?({:ok, _}, &1))
      assert length(oks) == @n

      run_ids = oks |> Enum.map(fn {:ok, r} -> r.id end) |> Enum.uniq()
      assert length(run_ids) == 1

      [[count]] = Repo.query!(
        "SELECT COUNT(*) FROM git_workflow_runs WHERE binding_id=$1 AND external_task_id=$2",
        [@binding_id, task_key]).rows
      assert count == 1
    end
  end

  describe "digest conflict — #{@n} different-digest sequential" do
    test "first accept wins, all subsequent different-digest returns conflict" do
      task_key = "conc-dig-seq-#{System.unique_integer([:positive])}"

      results =
        for i <- 1..@n do
          Store.accept(%{
            binding_id: @binding_id, binding_generation: 1,
            external_task_id: task_key,
            source_task_uri: URI.parse("resource://test-ws/kanban-task/task-src"),
            source_revision: "rev-#{i}", requested_head_ref: "feature/dig"
          })
        end

      oks = Enum.filter(results, &match?({:ok, _}, &1))
      conflicts = Enum.filter(results, &(&1 == {:error, :digest_conflict}))

      assert length(oks) == 1
      assert length(conflicts) == @n - 1

      [[count]] = Repo.query!(
        "SELECT COUNT(*) FROM git_workflow_runs WHERE binding_id=$1 AND external_task_id=$2",
        [@binding_id, task_key]).rows
      assert count == 1
    end
  end

  describe "CAS atomicity — #{@n} sequential transitions" do
    test "exactly 1 state change across #{@n} transitions; rest are exact retries" do
      task_key = "conc-cas-seq-#{System.unique_integer([:positive])}"

      {:ok, run} = Store.accept(%{
        binding_id: @binding_id, binding_generation: 1,
        external_task_id: task_key,
        source_task_uri: URI.parse("resource://test-ws/kanban-task/task-src"),
        source_revision: "abc", requested_head_ref: "feature/cas"
      })

      results =
        for i <- 1..@n do
          result = Store.transition(run.id, 1, "accepted", "workspace_ready")
          {i, result}
        end

      # First transition changes state; subsequent are exact retries (also {:ok})
      # because the target (v2/"workspace_ready") is already achieved.
      oks = Enum.filter(results, fn {_, r} -> match?({:ok, _}, r) end)
      assert length(oks) == @n

      # But only one transition actually changed the DB state
      {:ok, final} = Store.read_run(run.id)
      assert final.state_version == 2
      assert final.status == "workspace_ready"

      # The first call should succeed via CAS update (state_version bumped from 1)
      {1, {:ok, first}} = hd(results)
      assert first.state_version == 2
    end

    test "stale version after different intermediate state returns error" do
      task_key = "conc-cas-stale-#{System.unique_integer([:positive])}"

      {:ok, run} = Store.accept(%{
        binding_id: @binding_id, binding_generation: 1,
        external_task_id: task_key,
        source_task_uri: URI.parse("resource://test-ws/kanban-task/task-src"),
        source_revision: "abc", requested_head_ref: "feature/stale"
      })

      # Transition from accepted → workspace_ready
      assert {:ok, _} = Store.transition(run.id, 1, "accepted", "workspace_ready")

      # Now try to transition from accepted → blocked (stale version)
      assert {:error, :stale_state_version} =
               Store.transition(run.id, 1, "accepted", "blocked")
    end
  end
end
