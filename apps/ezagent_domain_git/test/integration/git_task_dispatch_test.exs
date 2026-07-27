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
    SynchronizedGitAdapterB,
    WorkspaceProvisionProbe
  }

  alias Ezagent.Entity.GitTaskAccess

  @actions [
    :resolve_repository,
    :create_change_request,
    :read_change_request,
    :list_checks,
    :list_reviews,
    :provision_workspace,
    :cleanup_workspace,
    :collect_workspace_changes
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

    Process.register(self(), :git_task_workspace_effect_probe)

    restore_provisioner = install_workspace_probe()

    Enum.each(@actions, fn action ->
      assert {:ok, %{behavior: Ezagent.ActionSet.GitTaskAccess}} =
               Ezagent.CapabilityRegistry.lookup_subject(GitTaskAccess, action)
    end)

    Enum.each(@providers, fn {_provider, id, module, _label} ->
      assert {:module, ^module} = Code.ensure_loaded(module)
      assert :ok = AdapterRegistry.register(id, module)
    end)

    on_exit(fn ->
      restore_provisioner.()

      Enum.each(@providers, fn {_provider, id, module, _label} ->
        :ok = AdapterRegistry.unregister(id, module)
      end)
    end)

    :ok
  end

  defp install_workspace_probe do
    registry = Ezagent.DomainGit.WorkspaceProvisionRegistry
    original = registry.implementation()
    :ok = registry.replace_for_test(WorkspaceProvisionProbe)

    fn ->
      unless Process.whereis(registry) do
        {:ok, _pid} = Supervisor.restart_child(EzagentDomainGit.Application, registry)
      end

      case original do
        {:ok, implementation} ->
          :ok = registry.replace_for_test(implementation)

        {:error, :workspace_provisioner_not_registered} ->
          :ok = Supervisor.terminate_child(EzagentDomainGit.Application, registry)
          {:ok, _pid} = Supervisor.restart_child(EzagentDomainGit.Application, registry)
      end

      :ok
    end
  end

  test "workspace authorization mismatches never call the provision port" do
    {fixture, policy} = started_fixture(:resolve_repository, :"task11-sync-a")
    task_uri = task_uri(policy)
    valid = workspace_invocation(fixture, :provision_workspace, task_uri, policy.generation)

    attacker = Ezagent.URI.agent(Ezagent.URI.workspace_name!(fixture.workspace_uri), "attacker")
    # Dispatch AS the attacker: the authenticated principal must match the
    # caller, or the test would accidentally authorize the grantee's own cap.
    # The attacker clears the principal gate (a current agent) but the grantee-
    # bound cap fails the target gate for a different holder → `:missing_cap`.
    wrong_receiver = %{
      valid
      | ctx: %{valid.ctx | caller: attacker, authenticated_principal: attacker}
    }

    assert {:error, :missing_cap} = Ezagent.Invocation.dispatch(wrong_receiver)
    refute_receive {:workspace_effect, _, _}

    wrong_workspace_cap =
      workspace_artifact(
        fixture,
        :provision_workspace,
        fixture.grantee_uri,
        Ezagent.URI.workspace("other"),
        fixture.task_access_uri
      )

    wrong_workspace = %{valid | ctx: %{valid.ctx | caps: MapSet.new([wrong_workspace_cap])}}
    assert {:error, :missing_cap} = Ezagent.Invocation.dispatch(wrong_workspace)

    refute_receive {:workspace_effect, _, _}

    wrong_instance = Ezagent.URI.resource("git-task11-other", "git-task-access", "other")
    [valid_cap] = MapSet.to_list(valid.ctx.caps)
    wrong_instance_cap = %{valid_cap | instance: Ezagent.URI.instance(wrong_instance)}

    wrong_instance_invocation = %{
      valid
      | ctx: %{valid.ctx | caps: MapSet.new([wrong_instance_cap])}
    }

    assert {:error, :missing_cap} =
             Ezagent.Invocation.dispatch(wrong_instance_invocation)

    refute_receive {:workspace_effect, _, _}

    cleanup_cap = workspace_artifact(fixture, :cleanup_workspace, fixture.grantee_uri)

    wrong_action =
      %{
        valid
        | target:
            Ezagent.URI.with_action(
              fixture.task_access_uri,
              :git_task_access,
              :provision_workspace
            ),
          ctx: %{valid.ctx | caps: MapSet.new([cleanup_cap])}
      }

    assert {:error, :missing_cap} = Ezagent.Invocation.dispatch(wrong_action)
    refute_receive {:workspace_effect, _, _}

    [artifact] = MapSet.to_list(valid.ctx.caps)
    unsigned = %{artifact | signature: nil, key_id: nil, grantee_uri: nil}

    unsigned_invocation = %{valid | ctx: %{valid.ctx | caps: MapSet.new([unsigned])}}
    assert {:error, :missing_cap} = Ezagent.Invocation.dispatch(unsigned_invocation)

    refute_receive {:workspace_effect, _, _}
  end

  test "real boot, exact signed cap, and Router dispatch select only the policy provider" do
    Enum.each(@providers, fn {provider, _id, _module, label} ->
      {fixture, policy} = started_fixture(:resolve_repository, provider)

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
    {fixture, policy} = started_fixture(:resolve_repository, :"task11-sync-a")
    registry_before = AdapterRegistry.list_for_diagnostics()
    slice_before = Ezagent.Kind.read(fixture.task_access_uri, :git_task_access, spawn: :never)

    invocation = %{
      fixture.invocation
      | args: %{repository: policy.repository},
        ctx: %{fixture.invocation.ctx | caps: MapSet.new()}
    }

    assert {:error, :missing_cap} = Ezagent.Invocation.dispatch(invocation)
    assert AdapterRegistry.list_for_diagnostics() == registry_before

    assert Ezagent.Kind.read(fixture.task_access_uri, :git_task_access, spawn: :never) ==
             slice_before

    refute_received {:task11_adapter_call, _, _, _}
    refute_received {:task11_provider_mutation, _, _}
  end

  test "receiver-bound cap replay by another caller leaves both providers unchanged" do
    {fixture, policy} = started_fixture(:resolve_repository, :"task11-sync-a")
    workspace = Ezagent.URI.workspace_name!(fixture.workspace_uri)
    replay_attacker = Ezagent.URI.agent(workspace, "replay-attacker")

    # The replay attacker is itself a current principal, so the denial proves
    # receiver-binding: the grantee-bound cap fails the target gate for a
    # different holder and is dropped → `:missing_cap` (never authorized).
    invocation = %{
      fixture.invocation
      | args: %{repository: policy.repository},
        ctx: %{
          fixture.invocation.ctx
          | caller: replay_attacker,
            authenticated_principal: replay_attacker
        }
    }

    assert {:error, :missing_cap} = Ezagent.Invocation.dispatch(invocation)
    refute_received {:task11_adapter_call, _, _, _}
    refute_received {:task11_provider_mutation, _, _}
  end

  test "invalid signed artifact leaves both providers unchanged" do
    {fixture, policy} = started_fixture(:resolve_repository, :"task11-sync-a")
    [cap] = MapSet.to_list(fixture.invocation.ctx.caps)
    invalid_cap = %{cap | signature: <<0>>}

    invocation = %{
      fixture.invocation
      | args: %{repository: policy.repository},
        ctx: %{fixture.invocation.ctx | caps: MapSet.new([invalid_cap])}
    }

    assert {:error, :missing_cap} = Ezagent.Invocation.dispatch(invocation)
    refute_received {:task11_adapter_call, _, _, _}
    refute_received {:task11_provider_mutation, _, _}
  end

  test "unsigned raw capability leaves both providers unchanged" do
    {fixture, policy} = started_fixture(:resolve_repository, :"task11-sync-a")
    [cap] = MapSet.to_list(fixture.invocation.ctx.caps)
    raw_cap = %{cap | signature: nil, key_id: nil, grantee_uri: nil}

    invocation = %{
      fixture.invocation
      | args: %{repository: policy.repository},
        ctx: %{fixture.invocation.ctx | caps: MapSet.new([raw_cap])}
    }

    assert {:error, :missing_cap} = Ezagent.Invocation.dispatch(invocation)
    refute_received {:task11_adapter_call, _, _, _}
    refute_received {:task11_provider_mutation, _, _}
  end

  test "stale create reaches only the selected provider and performs no provider mutation" do
    {fixture, policy} = started_fixture(:create_change_request, :"task11-sync-b")
    args = create_args(policy, String.duplicate("b", 40))

    assert {:error, :stale_base} =
             Ezagent.Invocation.dispatch(%{fixture.invocation | args: args})

    assert_receive {:task11_adapter_call, "sync-b", :create_change_request, _context}
    refute_received {:task11_adapter_call, "sync-a", _, _}
    refute_received {:task11_provider_mutation, _, _}
  end

  defp fixture_coordinates do
    id = owner_id(self())

    GitCapFixture.coordinates(
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
        allowed_actions: [
          :resolve_repository,
          :create_change_request,
          :provision_workspace,
          :cleanup_workspace
        ],
        idempotency_inputs: %{task_id: "owner-#{owner_id(self())}", generation: 1}
      })

    policy
  end

  defp started_fixture(action, provider) do
    coordinates = fixture_coordinates()
    policy = policy(coordinates, provider)
    coordinates = GitCapFixture.bind_policy(coordinates, policy)
    assert {:ok, _pid} = TaskAccessSupervisor.ensure_started(policy)
    on_exit(fn -> TaskAccessSupervisor.teardown(coordinates.task_access_uri) end)
    {GitCapFixture.exact_task_cap(coordinates, action), policy}
  end

  defp create_args(policy, expected_base_sha) do
    {:ok, change} = FileChange.new(%{path: "README.md", operation: :upsert, content: "ok"})

    {:ok, request} =
      CreateChangeRequest.new(%{
        title: "Task 11",
        body: "integration proof",
        head_ref: policy.allowed_head_ref,
        expected_base_sha: %CommitSha{value: expected_base_sha},
        commit_date: ~U[2026-06-15 09:30:00Z]
      })

    %{repository: policy.repository, changes: [change], request: request}
  end

  defp workspace_invocation(fixture, action, task_uri, generation) do
    artifact = workspace_artifact(fixture, action, fixture.grantee_uri)

    %{
      fixture.invocation
      | target: Ezagent.URI.with_action(fixture.task_access_uri, :git_task_access, action),
        args: %{task_uri: task_uri, generation: generation},
        ctx: %{fixture.invocation.ctx | caps: MapSet.new([artifact])}
    }
  end

  defp workspace_artifact(
         fixture,
         action,
         receiver,
         workspace_uri \\ nil,
         task_access_uri \\ nil
       ) do
    capability =
      Ezagent.Capability.cap(
        :git_task_access,
        Ezagent.ActionSet.GitTaskAccess,
        action,
        Ezagent.URI.instance(task_access_uri || fixture.task_access_uri),
        workspace_uri || fixture.workspace_uri
      )

    {:ok, artifact} = Ezagent.Cap.issue({:admin, fixture.governance_uri}, receiver, capability)
    artifact
  end

  defp task_uri(policy) do
    workspace = Ezagent.URI.workspace_name!(policy.workspace_uri)
    Ezagent.URI.resource(workspace, "kanban-task", policy.task_id)
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
