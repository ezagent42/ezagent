defmodule Ezagent.DomainGit.TaskAccessLifecycleTest do
  use ExUnit.Case, async: false

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

  test "an absent ephemeral resource stays absent instead of lazy-restoring", %{uri: uri} do
    assert {:error, :not_found} = Ezagent.Kind.get_slice(uri, :git_task_access)
    assert {:error, :not_found} = Ezagent.SnapshotStore.latest(uri)
    assert :ok = TaskAccessSupervisor.teardown(uri)
    assert {:error, :not_found} = Ezagent.Kind.get_slice(uri, :git_task_access)
    assert {:error, :not_found} = Ezagent.SnapshotStore.latest(uri)
  end

  test "pre-spawns validated policy and reconciles a same-policy duplicate", %{
    policy: policy,
    uri: uri
  } do
    assert {:ok, pid} = TaskAccessSupervisor.ensure_started(policy)
    assert Process.alive?(pid)
    assert {:ok, %{policy: ^policy}} = Ezagent.Kind.get_slice(uri, :git_task_access)
    assert {:ok, ^pid} = TaskAccessSupervisor.ensure_started(policy)
  end

  test "rejects a conflicting policy for the same resource deterministically", %{policy: policy} do
    assert {:ok, pid} = TaskAccessSupervisor.ensure_started(policy)
    conflicting = %{policy | allowed_head_ref: "other"}

    assert {:error, :conflicting_initialization} =
             TaskAccessSupervisor.ensure_started(conflicting)

    assert {:ok, %{policy: ^policy}} =
             Ezagent.Kind.get_slice(GitTaskAccess.uri_from_args(policy), :git_task_access)

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
    assert {:error, :not_found} = Ezagent.Kind.get_slice(uri, :git_task_access)
    assert :ok = TaskAccessSupervisor.teardown(uri)
  end

  test "failed child start leaves no supervised child or live policy", %{policy: policy} do
    before = child_pids()
    forged = %{policy | provider_adapter: :redirected_provider}

    assert {:error, {:invalid_field, :provider_adapter}} =
             TaskAccessSupervisor.ensure_started(forged)

    assert child_pids() == before

    assert {:error, :not_found} =
             Ezagent.Kind.get_slice(GitTaskAccess.uri_from_args(policy), :git_task_access)
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
    assert {:ok, %{policy: ^policy}} = Ezagent.Kind.get_slice(uri, :git_task_access)
  end

  test "after teardown completes no policy-slice entry can begin", %{policy: policy, uri: uri} do
    assert {:ok, _pid} = TaskAccessSupervisor.ensure_started(policy)
    parent = self()

    reader =
      Task.async(fn ->
        receive do
          :after_teardown ->
            send(parent, {:sentinel_read, Ezagent.Kind.get_slice(uri, :git_task_access)})
        end
      end)

    assert :ok = TaskAccessSupervisor.teardown(uri)
    send(reader.pid, :after_teardown)
    assert_receive {:sentinel_read, {:error, :not_found}}, 1_000
    Task.await(reader)
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
