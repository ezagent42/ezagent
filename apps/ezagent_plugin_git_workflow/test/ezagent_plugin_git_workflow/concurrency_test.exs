defmodule EzagentPluginGitWorkflow.ConcurrencyTest do
  use EzagentPluginGitWorkflow.ConnCase, async: false

  alias EzagentCore.Repo
  alias EzagentPluginGitWorkflow.AcceptIntent
  alias EzagentPluginGitWorkflow.Store

  @moduletag :concurrency

  @n 20
  @timeout 30_000

  @binding_id "bnd_conc_real"

  defp build_intent(overrides \\ %{}) do
    defaults = %{
      binding_id: @binding_id,
      binding_generation: 1,
      external_task_id: "task-default",
      source_task_uri: Ezagent.URI.resource("test-ws", "kanban-task", "task-src"),
      source_revision: "abc123",
      requested_head_ref: "feature/conc"
    }

    {:ok, intent} = Map.merge(defaults, overrides) |> AcceptIntent.new()
    intent
  end

  setup do
    # Insert binding through the sandbox (test process connection)
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

  # ── Independent connection runner ─────────────────────────────
  # Each task runs inside Sandbox.unboxed_run/2, which spawns a fresh
  # process with a REAL Postgrex connection that commits immediately.
  # Operations from different tasks are visible to each other —
  # this is true multi-connection PostgreSQL concurrency.
  # No Sandbox.allow/3. No shared owner connection.

  # Each unboxed connection needs its own binding visible.
  defp ensure_binding_unboxed do
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
  end

  defp run_unboxed_with_binding(fun) do
    parent = self()
    caller_ref = make_ref()

    spawn_link(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        ensure_binding_unboxed()
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

  # ── Concurrent identical accepts ─────────────────────────────

  describe "real multi-connection: concurrent identical accepts" do
    test "#{@n} concurrent identical accepts → all same run id, DB 1 row" do
      task_key = "conc-real-#{System.unique_integer([:positive])}"
      intent = build_intent(%{external_task_id: task_key})
      barrier = self()
      parent = self()
      ref = make_ref()

      tasks =
        for i <- 1..@n do
          Task.async(fn ->
            await_barrier(barrier)
            result = run_unboxed_with_binding(fn -> Store.accept(intent) end)
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

      # DB verification — binding was inserted in test tx, but unboxed_run
      # writes are committed and visible here when read through test connection.
      # Actually, test tx can't see unboxed writes. Let's verify via unboxed read.
      run_unboxed_with_binding(fn ->
        [[count]] =
          Repo.query!(
            "SELECT COUNT(*) FROM git_workflow_runs WHERE binding_id=$1 AND external_task_id=$2",
            [@binding_id, task_key]
          ).rows
        assert count == 1
      end)
    end
  end

  # ── Concurrent different-digest ───────────────────────────────

  describe "real multi-connection: different digest concurrency" do
    test "one winner, #{@n - 1} digest_conflict, DB 1 row" do
      task_key = "conc-dig-real-#{System.unique_integer([:positive])}"
      barrier = self()
      parent = self()
      ref = make_ref()

      tasks =
        for i <- 1..@n do
          Task.async(fn ->
            await_barrier(barrier)

            intent = build_intent(%{
              external_task_id: task_key,
              source_revision: "rev-#{i}"
            })

            result = run_unboxed_with_binding(fn -> Store.accept(intent) end)
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
    end
  end

  # ── Concurrent CAS ────────────────────────────────────────────

  describe "real multi-connection: concurrent CAS transitions" do
    test "competing next states: only one advances, version increments once" do
      task_key = "conc-cas-real-#{System.unique_integer([:positive])}"

      # Create run via unboxed_run so committed and visible to all tasks
      intent = build_intent(%{external_task_id: task_key})
      {:ok, run} = run_unboxed_with_binding(fn -> Store.accept(intent) end)

      barrier = self()
      parent = self()
      ref = make_ref()

      # Use competing next states to prove only one advances
      next_states = for i <- 1..@n, do: if(rem(i, 2) == 0, do: "workspace_ready", else: "blocked")

      tasks =
        for {next_s, i} <- Enum.with_index(next_states, 1) do
          Task.async(fn ->
            await_barrier(barrier)
            result = run_unboxed_with_binding(fn ->
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

      # Only 1 state change happens (version 1→2). But exact retries also
      # return {:ok, _}. What matters: at least 1 success and state_version
      # advanced only once.
      assert length(successes) >= 1

      # Only one state version advance
      run_unboxed_with_binding(fn ->
        {:ok, final} = Store.read_run(run.id)
        assert final.state_version == 2
        assert final.status in ["workspace_ready", "blocked"]
      end)

      # All errors are stale or conflict
      for {:error, reason} <- errors do
        assert reason in [:stale_state_version, :workflow_state_conflict]
      end
    end
  end
end
