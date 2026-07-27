defmodule Ezagent.DomainGit.WorkspaceChangePortTest do
  use ExUnit.Case, async: false

  alias Ezagent.DomainGit.WorkspaceChangePort
  alias Ezagent.DomainGit.WorkspaceChangeRegistry

  defmodule FakeCollector do
    @behaviour WorkspaceChangePort

    @impl true
    def collect(request),
      do: {:ok, [%{path: "fake.txt", operation: :upsert, content: request.provision_id}]}
  end

  setup do
    original = WorkspaceChangeRegistry.implementation()
    restart_registry()

    on_exit(fn ->
      restart_registry()

      case original do
        {:ok, implementation} -> :ok = WorkspaceChangeRegistry.register(implementation)
        {:error, :workspace_change_collector_not_registered} -> :ok
      end
    end)
  end

  test "registers exactly one conforming implementation idempotently" do
    assert :ok = WorkspaceChangeRegistry.register(FakeCollector)
    assert :ok = WorkspaceChangeRegistry.register(FakeCollector)
    assert {:ok, FakeCollector} = WorkspaceChangeRegistry.implementation()

    assert {:error, :conflicting_workspace_change_collector} =
             WorkspaceChangeRegistry.register(__MODULE__)
  end

  test "rejects an unregistered lookup with a stable error" do
    assert {:error, :workspace_change_collector_not_registered} =
             WorkspaceChangeRegistry.implementation()
  end

  test "request rejects caller-selected repository and path coordinates" do
    assert {:error, :unknown_fields} =
             WorkspaceChangePort.Request.new(%{
               task_access_uri: URI.parse("entity://ws/worker/gta_#{String.duplicate("a", 64)}"),
               task_uri: URI.parse("resource://ws/kanban-task/t"),
               generation: 1,
               provision_id: "provision",
               local_path: "/tmp/forged"
             })
  end

  test "request requires every field" do
    assert {:error, {:missing_field, :provision_id}} =
             WorkspaceChangePort.Request.new(%{
               task_access_uri: URI.parse("entity://ws/worker/gta_#{String.duplicate("a", 64)}"),
               task_uri: URI.parse("resource://ws/kanban-task/t"),
               generation: 1
             })
  end

  test "request validates the type of every field, not just presence" do
    base = %{
      task_access_uri: URI.parse("entity://ws/worker/gta_#{String.duplicate("a", 64)}"),
      task_uri: URI.parse("resource://ws/kanban-task/t"),
      generation: 1,
      provision_id: "provision"
    }

    assert {:ok, %WorkspaceChangePort.Request{}} = WorkspaceChangePort.Request.new(base)

    assert {:error, {:invalid_field, :task_access_uri}} =
             WorkspaceChangePort.Request.new(%{base | task_access_uri: "not-a-uri"})

    assert {:error, {:invalid_field, :task_uri}} =
             WorkspaceChangePort.Request.new(%{base | task_uri: "not-a-uri"})

    assert {:error, {:invalid_field, :generation}} =
             WorkspaceChangePort.Request.new(%{base | generation: 0})

    assert {:error, {:invalid_field, :generation}} =
             WorkspaceChangePort.Request.new(%{base | generation: "1"})

    assert {:error, {:invalid_field, :provision_id}} =
             WorkspaceChangePort.Request.new(%{base | provision_id: ""})

    assert {:error, {:invalid_field, :provision_id}} =
             WorkspaceChangePort.Request.new(%{base | provision_id: :not_a_string})
  end

  test "request has no authorized constructor — collection proves ownership by fresh-read, not policy re-presentation" do
    # Deliberate: adding `new_authorized/2` here would also make
    # apps/ezagent_domain_workspace/test/invariants/task_workspace_boundary_test.exs's
    # bare-substring `assert_only_production_calls("Request.new_authorized",
    # [...])` check see a second call site (any file that aliases this
    # module as `Request` and calls `.new_authorized` would match, since
    # that assertion matches text, not a fully-qualified module). Collection
    # doesn't need policy-bound construction, so this stays absent.
    refute function_exported?(WorkspaceChangePort.Request, :new_authorized, 2)
  end

  defp restart_registry do
    :ok = Supervisor.terminate_child(EzagentDomainGit.Application, WorkspaceChangeRegistry)
    {:ok, _pid} = Supervisor.restart_child(EzagentDomainGit.Application, WorkspaceChangeRegistry)
    :ok
  end
end
