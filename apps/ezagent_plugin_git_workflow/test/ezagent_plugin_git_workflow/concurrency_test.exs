defmodule EzagentPluginGitWorkflow.ConcurrencyTest do
  use ExUnit.Case, async: false

  alias EzagentCore.Repo
  alias EzagentPluginGitWorkflow.AcceptIntent
  alias EzagentPluginGitWorkflow.Store

  @moduletag :concurrency

  @n 20
  @timeout 30_000

  # ── Helpers ────────────────────────────────────────────────────

  defp build_intent(binding_id, overrides) do
    defaults = %{
      binding_id: binding_id,
      binding_generation: 1,
      external_task_id: "task-default",
      source_task_uri: Ezagent.URI.resource("test-ws", "kanban-task", "task-src"),
      source_revision: "abc123",
      requested_head_ref: nil
    }

    {:ok, intent} = Map.merge(defaults, overrides) |> AcceptIntent.new()
    intent
  end

  # ── Barrier ───────────────────────────────────────────────────

  defp await_barrier(barrier) do
    send(barrier, {:ready, self()})
    receive do: ({:go, ^barrier} -> :ok)
  end

  defp barrier_sync(n) do
    barrier = self()
    pids = for _ <- 1..n, do: receive(do: ({:ready, pid} -> pid))
    for pid <- pids, do: send(pid, {:go, barrier})
  end

  # ── Unboxed connection helpers ─────────────────────────────────
  # Sandbox.unboxed_run/2 gives each process a REAL, independent
  # Postgrex connection that commits immediately — no sandbox
  # transaction wrapping. No Sandbox.allow/3. No shared owner.

  defp run_unboxed(fun) do
    parent = self()
    caller_ref = make_ref()

    spawn_link(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        result = fun.()
        send(parent, {caller_ref, result})
      end)
    end)

    receive do
      {^caller_ref, result} -> result
    after
      @timeout -> exit(:timeout)
    end
  end

  defp insert_binding_unboxed(binding_id) do
    now = DateTime.utc_now()

    Repo.insert_all("git_workflow_bindings", [%{
      id: binding_id, generation: 1,
      workspace_uri: "workspace://test-ws",
      task_receiver_uri: "resource://test-ws/kanban-task/task-recv",
      credential_owner_uri: "entity://test-ws/user/credential-owner",
      repository_uri: "resource://test-ws/git-repository/my-repo",
      provider_adapter: "github",
      provider_host: "github.com", external_id: "owner/repo",
      owner_path: "owner", base_ref: "main", visibility: "public",
      allowed_head_namespace: "feature/", enabled: true,
      inserted_at: now, updated_at: now
    }], on_conflict: :nothing, conflict_target: [:id])
  end

  defp cleanup_unboxed(binding_id) do
    run_unboxed(fn ->
      Repo.query!("DELETE FROM git_workflow_runs WHERE binding_id = $1", [binding_id])
      Repo.query!("DELETE FROM git_workflow_bindings WHERE id = $1", [binding_id])
      :ok
    end)
  end

  # ── Concurrent identical accepts ─────────────────────────────

  describe "real multi-connection: concurrent identical accepts" do
    test "#{@n} concurrent identical accepts → all same run id, DB 1 row" do
      binding_id = "bnd-id-e2a-#{System.unique_integer([:positive])}"
      task_key = "conc-e2a-#{System.unique_integer([:positive])}"

      # Pre-barrier: commit the binding fixture via unboxed connection
      run_unboxed(fn -> insert_binding_unboxed(binding_id) end)

      intent = build_intent(binding_id, %{external_task_id: task_key})
      barrier = self()
      parent = self()
      ref = make_ref()

      tasks =
        for i <- 1..@n do
          Task.async(fn ->
            await_barrier(barrier)
            # Worker: only Store.accept — no fixture creation inside barrier
            result = run_unboxed(fn -> Store.accept(intent) end)
            send(parent, {ref, i, result})
          end)
        end

      barrier_sync(@n)
      Task.await_many(tasks, @timeout)

      results = for _ <- 1..@n, do: receive(do: ({^ref, _i, r} -> r))

      oks = Enum.filter(results, &match?({:ok, _}, &1))
      assert length(oks) == @n

      run_ids = oks |> Enum.map(fn {:ok, r} -> r.id end) |> Enum.uniq()
      assert length(run_ids) == 1

      run_unboxed(fn ->
        [[count]] =
          Repo.query!(
            "SELECT COUNT(*) FROM git_workflow_runs WHERE binding_id=$1 AND external_task_id=$2",
            [binding_id, task_key]
          ).rows
        assert count == 1
      end)

      cleanup_unboxed(binding_id)
    end
  end

  # ── Concurrent different-digest ───────────────────────────────

  describe "real multi-connection: different digest concurrency" do
    test "one winner, #{@n - 1} digest_conflict, DB 1 row" do
      binding_id = "bnd-dig-e2a-#{System.unique_integer([:positive])}"
      task_key = "conc-dig-real-#{System.unique_integer([:positive])}"

      run_unboxed(fn -> insert_binding_unboxed(binding_id) end)

      barrier = self()
      parent = self()
      ref = make_ref()

      tasks =
        for i <- 1..@n do
          Task.async(fn ->
            await_barrier(barrier)

            intent =
              build_intent(binding_id, %{
                external_task_id: task_key,
                source_revision: "rev-#{i}"
              })

            result = run_unboxed(fn -> Store.accept(intent) end)
            send(parent, {ref, i, result})
          end)
        end

      barrier_sync(@n)
      Task.await_many(tasks, @timeout)

      results = for _ <- 1..@n, do: receive(do: ({^ref, _i, r} -> r))

      oks = Enum.filter(results, &match?({:ok, _}, &1))
      conflicts = Enum.filter(results, &(&1 == {:error, :digest_conflict}))

      assert length(oks) + length(conflicts) == @n
      assert length(oks) == 1
      assert length(conflicts) == @n - 1

      cleanup_unboxed(binding_id)
    end
  end

  # ── Concurrent CAS ────────────────────────────────────────────

  describe "real multi-connection: concurrent CAS transitions" do
    test "competing next states: only one advances, version increments once" do
      binding_id = "bnd-cas-e2a-#{System.unique_integer([:positive])}"
      task_key = "conc-cas-real-#{System.unique_integer([:positive])}"

      run_unboxed(fn -> insert_binding_unboxed(binding_id) end)

      # Create run via unboxed_run so committed and visible to all tasks
      intent = build_intent(binding_id, %{external_task_id: task_key})
      {:ok, run} = run_unboxed(fn -> Store.accept(intent) end)

      barrier = self()
      parent = self()
      ref = make_ref()

      next_states = for i <- 1..@n, do: if(rem(i, 2) == 0, do: "workspace_ready", else: "blocked")

      tasks =
        for {next_s, i} <- Enum.with_index(next_states, 1) do
          Task.async(fn ->
            await_barrier(barrier)

            result =
              run_unboxed(fn ->
                Store.transition(run.id, 1, "accepted", next_s)
              end)

            send(parent, {ref, i, result})
          end)
        end

      barrier_sync(@n)
      Task.await_many(tasks, @timeout)

      results = for _ <- 1..@n, do: receive(do: ({^ref, _i, r} -> r))

      successes = Enum.filter(results, &match?({:ok, _}, &1))
      errors = Enum.filter(results, &match?({:error, _}, &1))

      assert length(successes) >= 1

      run_unboxed(fn ->
        {:ok, final} = Store.read_run(run.id)
        assert final.state_version == 2
        assert final.status in ["workspace_ready", "blocked"]
      end)

      for {:error, reason} <- errors do
        assert reason in [:stale_state_version, :workflow_state_conflict]
      end

      cleanup_unboxed(binding_id)
    end
  end
end
