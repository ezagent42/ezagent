defmodule Ezagent.DomainGit.Integration.GitTaskDispatchTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.DomainGit.{
    AdapterRegistry,
    CommitSha,
    CreateChangeRequest,
    FileChange,
    RepositoryRef,
    TaskAccessSupervisor
  }

  alias Ezagent.DomainGit.TestSupport.{
    GitCapFixture,
    SynchronizedGitAdapterA,
    SynchronizedGitAdapterB
  }

  alias Ezagent.Entity.GitTaskAccess

  @actions [
    :resolve_repository,
    :create_change_request,
    :read_change_request,
    :list_checks,
    :list_reviews
  ]
  @providers [
    {:"task11-sync-a", "task11-sync-a", SynchronizedGitAdapterA, "sync-a"},
    {:"task11-sync-b", "task11-sync-b", SynchronizedGitAdapterB, "sync-b"}
  ]

  setup do
    assert Process.whereis(EzagentDomainGit.Application)
    assert Process.whereis(AdapterRegistry)
    assert Process.whereis(TaskAccessSupervisor)
    assert Process.whereis(Ezagent.DomainGit.BootRegistration)

    Enum.each(@actions, fn action ->
      assert {:ok, %{behavior: Ezagent.ActionSet.GitTaskAccess}} =
               Ezagent.CapabilityRegistry.lookup_subject(GitTaskAccess, action)
    end)

    Enum.each(@providers, fn {_provider, id, module, _label} ->
      assert {:module, ^module} = Code.ensure_loaded(module)
      assert :ok = AdapterRegistry.register(id, module)
    end)

    on_exit(fn ->
      Enum.each(@providers, fn {_provider, id, module, _label} ->
        :ok = AdapterRegistry.unregister(id, module)
      end)
    end)

    :ok
  end

  test "real boot, exact signed cap, and Router dispatch select only the policy provider" do
    Enum.each(@providers, fn {provider, _id, _module, label} ->
      fixture = fixture(:resolve_repository)
      policy = policy(fixture, provider)
      start_resource(fixture, policy)

      invocation = %{fixture.invocation | args: %{repository: policy.repository}}
      expected_external_id = String.replace(label, "sync", "fake")

      assert {:ok, %RepositoryRef{external_id: ^expected_external_id}} =
               Ezagent.Invocation.dispatch(invocation)

      assert_receive {:task11_adapter_call, ^label, :resolve_repository, operation_context}
      assert operation_context.task_access_uri == fixture.task_access_uri
      assert operation_context.caller_uri == fixture.grantee_uri
      assert operation_context.grantee_uri == fixture.grantee_uri

      other_label = if label == "sync-a", do: "sync-b", else: "sync-a"
      refute_received {:task11_adapter_call, ^other_label, _, _}
      assert :ok = TaskAccessSupervisor.teardown(fixture.task_access_uri)
    end)
  end

  test "missing cap leaves registry, resource state, and both providers unchanged" do
    fixture = fixture(:resolve_repository)
    policy = policy(fixture, :"task11-sync-a")
    start_resource(fixture, policy)
    registry_before = AdapterRegistry.list_for_diagnostics()
    slice_before = Ezagent.Kind.get_slice(fixture.task_access_uri, :git_task_access)

    invocation = %{
      fixture.invocation
      | args: %{repository: policy.repository},
        ctx: %{fixture.invocation.ctx | caps: MapSet.new()}
    }

    assert {:error, :unauthorized} = Ezagent.Invocation.dispatch(invocation)
    assert AdapterRegistry.list_for_diagnostics() == registry_before
    assert Ezagent.Kind.get_slice(fixture.task_access_uri, :git_task_access) == slice_before
    refute_received {:task11_adapter_call, _, _, _}
    refute_received {:task11_provider_mutation, _, _}
  end

  test "stale create reaches only the selected provider and performs no provider mutation" do
    fixture = fixture(:create_change_request)
    policy = policy(fixture, :"task11-sync-b")
    start_resource(fixture, policy)
    args = create_args(policy, String.duplicate("b", 40))

    assert {:error, :stale_base} =
             Ezagent.Invocation.dispatch(%{fixture.invocation | args: args})

    assert_receive {:task11_adapter_call, "sync-b", :create_change_request, _context}
    refute_received {:task11_adapter_call, "sync-a", _, _}
    refute_received {:task11_provider_mutation, _, _}
  end

  defp fixture(action) do
    id = owner_id(self())

    GitCapFixture.exact_task_cap(action,
      workspace_name: "git-task11-#{id}",
      task_access_id: "task11-#{id}"
    )
  end

  defp policy(fixture, provider) do
    workspace = Ezagent.URI.workspace_name!(fixture.workspace_uri)

    {:ok, repository} =
      RepositoryRef.new(%{
        repository_uri: Ezagent.URI.resource(workspace, "git-repository", "widgets"),
        provider_adapter: provider,
        provider_host: "git.example.test",
        external_id: "repo-1",
        owner_path: "acme/widgets",
        base_ref: "main",
        visibility: :private
      })

    {:ok, policy} =
      GitTaskAccess.new(%{
        id: List.last(String.split(fixture.task_access_uri.path, "/")),
        task_id: "owner-#{owner_id(self())}",
        generation: 1,
        workspace_uri: fixture.workspace_uri,
        credential_owner_uri: Ezagent.URI.user(workspace, "owner"),
        grantee_uri: fixture.grantee_uri,
        repository: repository,
        provider_adapter: provider,
        allowed_head_ref: "task/task-11",
        allowed_actions: [:resolve_repository, :create_change_request],
        idempotency_inputs: %{task_id: "owner-#{owner_id(self())}", generation: 1}
      })

    policy
  end

  defp start_resource(fixture, policy) do
    assert {:ok, _pid} = TaskAccessSupervisor.ensure_started(policy)
    on_exit(fn -> TaskAccessSupervisor.teardown(fixture.task_access_uri) end)
  end

  defp create_args(policy, expected_base_sha) do
    {:ok, change} = FileChange.new(%{path: "README.md", operation: :upsert, content: "ok"})

    {:ok, request} =
      CreateChangeRequest.new(%{
        title: "Task 11",
        body: "integration proof",
        head_ref: policy.allowed_head_ref,
        expected_base_sha: %CommitSha{value: expected_base_sha}
      })

    %{repository: policy.repository, changes: [change], request: request}
  end

  defp owner_id(pid) do
    pid
    |> :erlang.pid_to_list()
    |> List.to_string()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
    |> String.replace(".", "-")
  end
end
