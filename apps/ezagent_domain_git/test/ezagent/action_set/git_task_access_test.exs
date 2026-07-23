defmodule Ezagent.ActionSet.GitTaskAccessTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.DomainGit.{
    ChangeRequestId,
    CommitSha,
    CreateChangeRequest,
    FileChange,
    RepositoryRef,
    TaskAccessSupervisor
  }

  alias Ezagent.DomainGit.TestSupport.{
    GitCapFixture,
    GitEffectProbe,
    ProbeGitAdapterA,
    ProbeGitAdapterB,
    WorkspaceProvisionProbe
  }

  alias Ezagent.Entity.GitTaskAccess

  @provider_actions [
    :resolve_repository,
    :create_change_request,
    :read_change_request,
    :list_checks,
    :list_reviews
  ]
  @actions @provider_actions ++ [:provision_workspace, :cleanup_workspace]

  setup_all do
    registry = Ezagent.DomainGit.WorkspaceProvisionRegistry
    original = registry.implementation()
    :ok = registry.replace_for_test(WorkspaceProvisionProbe)

    on_exit(fn ->
      case original do
        {:ok, implementation} ->
          :ok = registry.replace_for_test(implementation)

        {:error, :workspace_provisioner_not_registered} ->
          :ok = Supervisor.terminate_child(EzagentDomainGit.Application, registry)
          {:ok, _pid} = Supervisor.restart_child(EzagentDomainGit.Application, registry)
      end
    end)

    :ok
  end

  setup do
    Process.register(self(), :git_task_workspace_effect_probe)
    start_supervised!({GitEffectProbe, self()})
    register_adapter("probe-git-adapter-a", ProbeGitAdapterA)
    register_adapter("probe-git-adapter-b", ProbeGitAdapterB)
    {fixture, policy} = started_fixture(:resolve_repository)
    on_exit(fn -> TaskAccessSupervisor.teardown(fixture.task_access_uri) end)
    %{fixture: fixture, policy: policy}
  end

  test "authorized exact task generation provisions through the registered port", %{
    fixture: fixture,
    policy: policy
  } do
    task_uri = task_uri(policy)
    invocation = workspace_invocation(fixture, :provision_workspace, task_uri, policy.generation)

    assert {:ok, %{status: :ready}} = Ezagent.Invocation.dispatch(invocation)

    assert_receive {:workspace_effect, :prepare,
                    %{task_uri: ^task_uri, generation: 1, operation: :prepare}}
  end

  test "wrong generation and unknown arguments stop before workspace effects", %{
    fixture: fixture,
    policy: policy
  } do
    task_uri = task_uri(policy)

    assert {:error, :task_generation_mismatch} =
             fixture
             |> workspace_invocation(:provision_workspace, task_uri, policy.generation + 1)
             |> Ezagent.Invocation.dispatch()

    refute_receive {:workspace_effect, _, _}

    invocation =
      fixture
      |> workspace_invocation(:provision_workspace, task_uri, policy.generation)
      |> Map.update!(:args, &Map.put(&1, :local_path, "/tmp/forged"))

    assert {:error, {:unknown_invocation_keys, [:local_path]}} =
             Ezagent.Invocation.dispatch(invocation)

    refute_receive {:workspace_effect, _, _}

    string_key_invocation = %{
      invocation
      | args: %{"task_uri" => task_uri, generation: policy.generation}
    }

    assert {:error, {:invalid_args, [{[:task_uri], :missing}]}} =
             Ezagent.Invocation.dispatch(string_key_invocation)

    refute_receive {:workspace_effect, _, _}
  end

  test "provision capability cannot invoke cleanup", %{fixture: fixture, policy: policy} do
    cleanup_invocation =
      workspace_invocation(fixture, :cleanup_workspace, task_uri(policy), policy.generation)

    provision_only = workspace_artifact(fixture, :provision_workspace, fixture.grantee_uri)

    invocation = %{
      cleanup_invocation
      | ctx: %{cleanup_invocation.ctx | caps: MapSet.new([provision_only])}
    }

    assert {:error, :missing_cap} = Ezagent.Invocation.dispatch(invocation)
    refute_receive {:workspace_effect, _, _}
  end

  test "authorized exact cleanup capability invokes the cleanup port", %{
    fixture: fixture,
    policy: policy
  } do
    task_uri = task_uri(policy)
    invocation = workspace_invocation(fixture, :cleanup_workspace, task_uri, policy.generation)

    assert {:ok, %{status: :cleaned}} = Ezagent.Invocation.dispatch(invocation)

    assert_receive {:workspace_effect, :cleanup,
                    %{task_uri: ^task_uri, generation: 1, operation: :cleanup}}
  end

  test "authorization and generation failures do not consult the provision registry", %{
    fixture: fixture,
    policy: policy
  } do
    :ok =
      Supervisor.terminate_child(
        EzagentDomainGit.Application,
        Ezagent.DomainGit.WorkspaceProvisionRegistry
      )

    on_exit(&restart_workspace_registry/0)
    task_uri = task_uri(policy)
    valid = workspace_invocation(fixture, :provision_workspace, task_uri, policy.generation)
    unauthorized = %{valid | ctx: %{valid.ctx | caps: MapSet.new()}}

    assert {:error, :missing_cap} = Ezagent.Invocation.dispatch(unauthorized)

    assert {:error, :task_generation_mismatch} =
             fixture
             |> workspace_invocation(:provision_workspace, task_uri, policy.generation + 1)
             |> Ezagent.Invocation.dispatch()

    refute_receive {:workspace_effect, _, _}
  end

  test "real dispatch denies missing exact capability before the handler", %{fixture: fixture} do
    invocation = %{fixture.invocation | ctx: %{fixture.invocation.ctx | caps: MapSet.new()}}
    ref = GitEffectProbe.ref()
    assert {:error, :missing_cap} = Ezagent.Invocation.dispatch(invocation)
    refute_received {:git_probe, ^ref, _, _, _}
  end

  test "both selected fake providers receive handler-built operation context" do
    Enum.each([:"probe-git-adapter-a", :"probe-git-adapter-b"], fn provider ->
      {fixture, policy} = started_fixture(:resolve_repository, provider)

      invocation = %{fixture.invocation | args: %{repository: policy.repository}}
      assert {:ok, %RepositoryRef{}} = Ezagent.Invocation.dispatch(invocation)

      ref = GitEffectProbe.ref()

      assert_received {:git_probe, ^ref, :adapter, :resolve_repository, context}
      assert context.task_access_uri == fixture.task_access_uri
      assert context.caller_uri == fixture.grantee_uri
      assert context.grantee_uri == fixture.grantee_uri

      assert :ok = TaskAccessSupervisor.teardown(fixture.task_access_uri)
      flush_probe()
    end)
  end

  test "all five closed operations dispatch and callback trips every effect sentinel" do
    Enum.each(@provider_actions, fn action ->
      {fixture, policy} = started_fixture(action)
      invocation = %{fixture.invocation | args: operation_args(action, policy)}
      ref = GitEffectProbe.ref()

      assert {:ok, _result} = Ezagent.Invocation.dispatch(invocation)

      for sentinel <- [:adapter, :http, :secret, :filesystem] do
        assert_received {:git_probe, ^ref, ^sentinel, ^action, _context}
      end

      assert :ok = TaskAccessSupervisor.teardown(fixture.task_access_uri)
      flush_probe()
    end)
  end

  test "dynamic stale base enters provider but returns before provider mutation" do
    {fixture, policy} = started_fixture(:create_change_request)
    args = operation_args(:create_change_request, policy)
    stale = %{args.request | expected_base_sha: %CommitSha{value: String.duplicate("b", 40)}}
    invocation = %{fixture.invocation | args: %{args | request: stale}}
    ref = GitEffectProbe.ref()

    assert {:error, :stale_base} = Ezagent.Invocation.dispatch(invocation)
    assert_received {:git_probe, ^ref, :adapter, :create_change_request, _context}
    refute_received {:git_probe, ^ref, :mutation, :create_change_request}
  end

  test "static policy and caller-coordinate mismatches stop before adapter lookup" do
    {fixture, policy} = started_fixture(:create_change_request)
    valid = operation_args(:create_change_request, policy)
    ref = GitEffectProbe.ref()

    wrong_repository = %{policy.repository | external_id: "other"}

    assert {:error, :repository_mismatch} =
             dispatch(fixture, %{valid | repository: wrong_repository})

    refute_received {:git_probe, ^ref, :adapter, _, _}

    wrong_head = %{valid | request: %{valid.request | head_ref: "other"}}
    assert {:error, :head_ref_not_allowed} = dispatch(fixture, wrong_head)
    refute_received {:git_probe, ^ref, :adapter, _, _}

    invalid_sha = %{valid.request | expected_base_sha: %CommitSha{value: "bad"}}
    assert {:error, _reason} = dispatch(fixture, %{valid | request: invalid_sha})
    refute_received {:git_probe, ^ref, :adapter, _, _}

    for injected <- [
          %{provider_adapter: :attacker},
          %{base_ref: "attacker"},
          %{operation_context: %{caller_uri: fixture.grantee_uri}},
          %{workspace_uri: Ezagent.URI.workspace("other")}
        ] do
      assert {:error, _reason} = dispatch(fixture, Map.merge(valid, injected))
      refute_received {:git_probe, ^ref, :adapter, _, _}
    end

    refute_received {:git_probe, ^ref, :adapter, _, _}
    refute_received {:git_probe, ^ref, :http, _, _}
    refute_received {:git_probe, ^ref, :secret, _, _}
    refute_received {:git_probe, ^ref, :filesystem, _, _}
  end

  test "teardown waits for an in-flight callback and no callback starts afterwards" do
    {fixture, policy} = started_fixture(:resolve_repository)
    invocation = %{fixture.invocation | args: operation_args(:resolve_repository, policy)}
    ref = GitEffectProbe.ref()
    :ok = GitEffectProbe.block_next()

    dispatch_task = Task.async(fn -> Ezagent.Invocation.dispatch(invocation) end)
    assert_receive {:git_probe, ^ref, :callback_waiting, callback_pid}
    teardown_task = Task.async(fn -> TaskAccessSupervisor.teardown(fixture.task_access_uri) end)
    refute Task.yield(teardown_task, 0)

    send(callback_pid, {:git_probe_release, ref})
    assert {:ok, %RepositoryRef{}} = Task.await(dispatch_task)
    assert :ok = Task.await(teardown_task)
    flush_probe()

    assert {:error, _reason} = Ezagent.Invocation.dispatch(invocation)
    refute_received {:git_probe, ^ref, :adapter, _, _}
  end

  test "wrong resource, workspace, provider, and unsupported action never enter an adapter" do
    {fixture, policy} = started_fixture(:resolve_repository)
    ref = GitEffectProbe.ref()

    wrong_resource =
      Ezagent.URI.resource("git-fixture", "git-task-access", "other")
      |> Ezagent.URI.with_action(:git_task_access, :resolve_repository)

    assert {:error, _reason} =
             Ezagent.Invocation.dispatch(%{
               fixture.invocation
               | target: wrong_resource,
                 args: %{repository: policy.repository}
             })

    wrong_workspace = %{
      policy.repository
      | repository_uri: Ezagent.URI.resource("other", "git-repository", "widgets")
    }

    assert {:error, :repository_mismatch} =
             dispatch(fixture, %{repository: wrong_workspace})

    wrong_provider = %{policy.repository | provider_adapter: :other}
    assert {:error, :repository_mismatch} = dispatch(fixture, %{repository: wrong_provider})

    unsupported = %{
      fixture.invocation
      | target: Ezagent.URI.with_action(fixture.task_access_uri, :git_task_access, :merge),
        args: %{}
    }

    assert {:error, _reason} = Ezagent.Invocation.dispatch(unsupported)
    refute_received {:git_probe, ^ref, :adapter, _, _}
  end

  test "every action rejects unknown atom and string keys before adapter effects" do
    forbidden = [
      :credential,
      :token,
      :client,
      :req,
      :path,
      :cap,
      :context,
      :provider_adapter,
      :base_ref
    ]

    Enum.each(@provider_actions, fn action ->
      {fixture, policy} = started_fixture(action)
      valid = operation_args(action, policy)
      ref = GitEffectProbe.ref()

      Enum.each(forbidden, fn key ->
        assert {:error, {:unknown_invocation_keys, [^key]}} =
                 dispatch(fixture, Map.put(valid, key, :attacker))

        refute_received {:git_probe, ^ref, :adapter, _, _}
      end)

      assert {:error, {:unknown_invocation_keys, ["repository"]}} =
               dispatch(fixture, Map.put(valid, "repository", policy.repository))

      refute_received {:git_probe, ^ref, :adapter, _, _}
      assert :ok = TaskAccessSupervisor.teardown(fixture.task_access_uri)
    end)
  end

  test "authorization and static mismatches preserve their errors while adapter registry is unavailable" do
    {fixture, policy} = started_fixture(:resolve_repository)
    valid = operation_args(:resolve_repository, policy)

    assert :ok =
             Supervisor.terminate_child(
               EzagentDomainGit.Application,
               Ezagent.DomainGit.AdapterRegistry
             )

    on_exit(&restart_adapter_registry/0)

    unauthorized = %{fixture.invocation | ctx: %{fixture.invocation.ctx | caps: MapSet.new()}}
    assert {:error, :missing_cap} = Ezagent.Invocation.dispatch(unauthorized)

    wrong_repository = %{policy.repository | external_id: "other"}
    assert {:error, :repository_mismatch} = dispatch(fixture, %{repository: wrong_repository})

    assert {:error, :registry_unavailable} = dispatch(fixture, valid)
  end

  test "malformed create requests keep construction errors and never reach lookup effects" do
    {fixture, policy} = started_fixture(:create_change_request)
    valid = operation_args(:create_change_request, policy)
    ref = GitEffectProbe.ref()

    cases = [
      {"not-a-request", {:invalid_field, :request}},
      {%{title: "missing head"}, {:invalid_field, :request}},
      {%{valid.request | head_ref: "refs/invalid"}, {:invalid_field, :head_ref}},
      {%{valid.request | expected_base_sha: %CommitSha{value: "bad"}},
       {:invalid_field, :expected_base_sha}}
    ]

    Enum.each(cases, fn {request, reason} ->
      assert {:error, ^reason} = dispatch(fixture, %{valid | request: request})
      refute_received {:git_probe, ^ref, :adapter, _, _}
    end)
  end

  defp policy(fixture, provider_adapter) do
    workspace = Ezagent.URI.workspace_name!(fixture.workspace_uri)

    {:ok, repository} =
      RepositoryRef.new(%{
        repository_uri: Ezagent.URI.resource(workspace, "git-repository", "widgets"),
        provider_adapter: provider_adapter,
        provider_host: "git.example.test",
        external_id: "repo-1",
        owner_path: "acme/widgets",
        base_ref: "main",
        visibility: :private
      })

    {:ok, policy} =
      GitTaskAccess.new(%{
        id: fixture.task_access_uri.path |> String.split("/") |> List.last(),
        task_id: "task-8",
        generation: 1,
        workspace_uri: fixture.workspace_uri,
        credential_owner_uri: Ezagent.URI.user(workspace, "owner"),
        grantee_uri: fixture.grantee_uri,
        repository: repository,
        provider_adapter: provider_adapter,
        allowed_head_ref: "task/task-8",
        allowed_actions: @actions,
        idempotency_inputs: %{task_id: "task-8", generation: 1}
      })

    policy
  end

  defp started_fixture(action, provider_adapter \\ :"probe-git-adapter-a") do
    coordinates = GitCapFixture.coordinates()
    policy = policy(coordinates, provider_adapter)
    coordinates = GitCapFixture.bind_policy(coordinates, policy)
    assert {:ok, _pid} = TaskAccessSupervisor.ensure_started(policy)
    {GitCapFixture.exact_task_cap(coordinates, action), policy}
  end

  defp operation_args(:resolve_repository, policy), do: %{repository: policy.repository}

  defp operation_args(:create_change_request, policy) do
    {:ok, change} = FileChange.new(%{path: "README.md", operation: :upsert, content: "ok"})

    {:ok, request} =
      CreateChangeRequest.new(%{
        title: "Task 8",
        body: "body",
        head_ref: policy.allowed_head_ref,
        expected_base_sha: %CommitSha{value: String.duplicate("a", 40)}
      })

    %{
      repository: policy.repository,
      changes: [change],
      request: request
    }
  end

  defp operation_args(:read_change_request, policy),
    do: %{repository: policy.repository, change_request_id: %ChangeRequestId{external_id: "1"}}

  defp operation_args(:list_checks, policy),
    do: %{repository: policy.repository, commit_sha: %CommitSha{value: String.duplicate("a", 40)}}

  defp operation_args(:list_reviews, policy),
    do: %{repository: policy.repository, change_request_id: %ChangeRequestId{external_id: "1"}}

  defp workspace_invocation(fixture, action, task_uri, generation) do
    artifact = workspace_artifact(fixture, action, fixture.grantee_uri)

    %{
      fixture.invocation
      | target: Ezagent.URI.with_action(fixture.task_access_uri, :git_task_access, action),
        args: %{task_uri: task_uri, generation: generation},
        ctx: %{fixture.invocation.ctx | caps: MapSet.new([artifact])}
    }
  end

  defp workspace_artifact(fixture, action, receiver) do
    capability =
      Ezagent.Capability.cap(
        :git_task_access,
        Ezagent.ActionSet.GitTaskAccess,
        action,
        Ezagent.URI.instance(fixture.task_access_uri),
        fixture.workspace_uri
      )

    {:ok, artifact} = Ezagent.Cap.issue({:admin, fixture.governance_uri}, receiver, capability)
    artifact
  end

  defp task_uri(policy) do
    workspace = Ezagent.URI.workspace_name!(policy.workspace_uri)
    Ezagent.URI.resource(workspace, "kanban-task", policy.task_id)
  end

  defp dispatch(fixture, args),
    do: Ezagent.Invocation.dispatch(%{fixture.invocation | args: args})

  defp register_adapter(id, module) do
    {:module, ^module} = Code.ensure_loaded(module)

    case Ezagent.DomainGit.AdapterRegistry.register(id, module) do
      :ok -> :ok
      {:ok, :already_registered} -> :ok
    end
  end

  defp flush_probe do
    receive do
      {:git_probe, _, _, _, _} -> flush_probe()
      {:git_probe, _, _, _} -> flush_probe()
    after
      0 -> :ok
    end
  end

  defp restart_adapter_registry do
    case Supervisor.restart_child(EzagentDomainGit.Application, Ezagent.DomainGit.AdapterRegistry) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
    end
  end

  defp restart_workspace_registry do
    case Supervisor.restart_child(
           EzagentDomainGit.Application,
           Ezagent.DomainGit.WorkspaceProvisionRegistry
         ) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
    end

    :ok = Ezagent.DomainGit.WorkspaceProvisionRegistry.register(WorkspaceProvisionProbe)
  end
end
