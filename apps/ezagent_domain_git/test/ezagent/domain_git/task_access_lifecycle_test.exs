defmodule Ezagent.DomainGit.TaskAccessLifecycleTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.DomainGit.RepositoryRef
  alias Ezagent.DomainGit.TaskAccessSupervisor
  alias Ezagent.Entity.GitTaskAccess

  @actions [
    :resolve_repository,
    :create_change_request,
    :read_change_request,
    :list_checks,
    :list_reviews
  ]

  setup do
    policy = policy("access-#{System.unique_integer([:positive])}")
    uri = GitTaskAccess.uri_from_args(policy)

    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    %{policy: policy, uri: uri}
  end

  test "an absent ephemeral entity stays absent instead of lazy-restoring", %{uri: uri} do
    assert {:error, :not_live} = Ezagent.Kind.read(uri, :git_task_access, spawn: :never)
    assert {:error, :not_found} = Ezagent.SnapshotStore.latest(uri)
    assert :ok = TaskAccessSupervisor.teardown(uri)
    assert {:error, :not_live} = Ezagent.Kind.read(uri, :git_task_access, spawn: :never)
    assert {:error, :not_found} = Ezagent.SnapshotStore.latest(uri)
  end

  test "pre-spawns validated policy and reconciles a same-policy duplicate", %{
    policy: policy,
    uri: uri
  } do
    assert {:ok, pid} = TaskAccessSupervisor.ensure_started(policy)
    assert Process.alive?(pid)
    assert {:ok, %{policy: ^policy}} = Ezagent.Kind.read(uri, :git_task_access, spawn: :never)
    assert {:ok, ^pid} = TaskAccessSupervisor.ensure_started(policy)
  end

  test "rejects a conflicting full policy already live at the deterministic URI", %{
    policy: policy
  } do
    conflicting = %{policy | allowed_head_ref: "other"}
    conflicting_uri = GitTaskAccess.uri_from_args(conflicting)
    on_exit(fn -> Ezagent.Kind.terminate(conflicting_uri) end)

    assert {:ok, pid} =
             Ezagent.Kind.spawn(GitTaskAccess, %{uri: conflicting_uri, policy: conflicting})

    assert {:error, :conflicting_initialization} =
             GitTaskAccess.initialization_result(conflicting_uri, policy)

    assert {:ok, %{policy: ^conflicting}} =
             Ezagent.Kind.read(conflicting_uri, :git_task_access, spawn: :never)

    assert Process.alive?(pid)
  end

  test "concurrent same-policy starts converge and clean up the losing child", %{policy: policy} do
    results =
      1..8
      |> Task.async_stream(fn _ -> TaskAccessSupervisor.ensure_started(policy) end,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _pid}, &1))
    assert results |> Enum.map(fn {:ok, pid} -> pid end) |> Enum.uniq() |> length() == 1
    assert length(child_pids()) == 1

    uri = GitTaskAccess.uri_from_args(policy)

    assert 1 ==
             TaskAccessSupervisor
             |> DynamicSupervisor.which_children()
             |> Enum.count(fn {_, pid, _, _} ->
               match?({:ok, ^pid}, Ezagent.KindRegistry.lookup(uri))
             end)
  end

  test "supervised teardown removes the child and is idempotent", %{policy: policy, uri: uri} do
    assert {:ok, pid} = TaskAccessSupervisor.ensure_started(policy)
    assert child?(pid)

    assert :ok = TaskAccessSupervisor.teardown(uri)
    refute Process.alive?(pid)
    assert {:error, :not_live} = Ezagent.Kind.read(uri, :git_task_access, spawn: :never)
    assert :ok = TaskAccessSupervisor.teardown(uri)
  end

  test "failed child start leaves no supervised child or live policy", %{policy: policy} do
    before = child_pids()
    forged = %{policy | provider_adapter: :redirected_provider}

    assert {:error, {:invalid_field, :provider_adapter}} =
             TaskAccessSupervisor.ensure_started(forged)

    assert child_pids() == before

    assert {:error, :not_live} =
             Ezagent.Kind.read(GitTaskAccess.uri_from_args(policy), :git_task_access,
               spawn: :never
             )
  end

  test "starting the named supervisor repeatedly reports the existing owner" do
    pid = Process.whereis(TaskAccessSupervisor)
    assert is_pid(pid)
    assert {:error, {:already_started, ^pid}} = TaskAccessSupervisor.start_link([])
  end

  test "a supervised child restart replaces its registry owner", %{
    policy: policy,
    uri: uri
  } do
    assert {:ok, child_pid} = TaskAccessSupervisor.ensure_started(policy)
    ref = Process.monitor(child_pid)
    Process.exit(child_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^child_pid, :killed}, 1_000

    wait_until(fn ->
      match?({:ok, replacement} when replacement != child_pid, Ezagent.KindRegistry.lookup(uri))
    end)

    assert {:ok, replacement_child} = Ezagent.KindRegistry.lookup(uri)
    assert replacement_child != child_pid
    assert {:ok, %{policy: ^policy}} = Ezagent.Kind.read(uri, :git_task_access, spawn: :never)
  end

  test "teardown linearizes before a concurrent start, which becomes ready", %{
    policy: policy,
    uri: uri
  } do
    parent = self()

    teardown_task =
      Task.async(fn ->
        TaskAccessSupervisor.with_lifecycle(uri, fn ->
          send(parent, :teardown_entered)
          receive do: (:finish_teardown -> TaskAccessSupervisor.teardown(uri))
        end)
      end)

    assert_receive :teardown_entered
    start_task = Task.async(fn -> TaskAccessSupervisor.ensure_started(policy) end)
    assert Task.yield(start_task, 20) == nil
    send(teardown_task.pid, :finish_teardown)

    assert :ok = Task.await(teardown_task)
    assert {:ok, live_pid} = Task.await(start_task)
    assert {:ok, ^live_pid} = Ezagent.KindRegistry.lookup(uri)
    assert Ezagent.ReadyGate.status(uri) == :ready
    assert {:ok, %{policy: ^policy}} = Ezagent.Kind.read(uri, :git_task_access, spawn: :never)
  end

  defp policy(id) do
    workspace = "acme"

    {:ok, repository} =
      RepositoryRef.new(%{
        repository_uri: Ezagent.URI.resource(workspace, "git-repository", "repo-42"),
        provider_adapter: :fake_git,
        provider_host: "git.example",
        external_id: "42",
        owner_path: "acme/widgets",
        base_ref: "main",
        visibility: :private
      })

    {:ok, policy} =
      GitTaskAccess.new(%{
        id: id,
        task_id: "task-17",
        generation: 3,
        workspace_uri: Ezagent.URI.workspace(workspace),
        credential_owner_uri: Ezagent.URI.user(workspace, "owner"),
        grantee_uri: Ezagent.URI.agent(workspace, "codex-17"),
        repository: repository,
        provider_adapter: :fake_git,
        allowed_head_ref: "task/task-17-g3",
        allowed_actions: @actions,
        idempotency_inputs: %{task_id: "task-17", generation: 3}
      })

    policy
  end

  defp child?(pid), do: pid in child_pids()

  defp child_pids do
    TaskAccessSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.sort()
  end

  defp wait_until(fun, attempts \\ 100)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition did not become true")
end
