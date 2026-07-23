defmodule Ezagent.Workspace.TaskWorkspace.SignedE2ETest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Kind.Template.PreStart, as: CorePreStart
  alias Ezagent.DomainGit.{RepositoryRef, TaskAccessSupervisor}
  alias Ezagent.DomainGit.WorkspaceProvisionRegistry
  alias Ezagent.Entity.GitTaskAccess
  alias Ezagent.Workspace.TaskWorkspace.{AgentStart, PreStart, Provision, Provisioner}

  setup do
    # #195 currency: dispatch AS the cold task-worker agent grantee requires it
    # to be a CURRENT principal. Swap in a loader that reports agent grantees as
    # current via held caps (NOT a live Kind — the grantee is spawned fresh by
    # AgentStart, so a durable identity snapshot would collide) while delegating
    # every other principal to the real loader.
    cap_config = Application.fetch_env!(:ezagent_core, Ezagent.Cap)

    Application.put_env(
      :ezagent_core,
      Ezagent.Cap,
      Keyword.put(
        cap_config,
        :authority_loader,
        EzagentDomainWorkspace.TestSupport.SignedE2EAuthorityLoader
      )
    )

    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, cap_config) end)

    previous_home = System.get_env("EZAGENT_HOME")
    previous_provisioner = WorkspaceProvisionRegistry.implementation()
    previous_pre_start = GenServer.call(CorePreStart, :implementation)
    :ok = WorkspaceProvisionRegistry.replace_for_test(Provisioner)
    :ok = CorePreStart.replace_for_test(PreStart)

    root =
      Path.join(System.tmp_dir!(), "task-workspace-e2e-#{System.unique_integer([:positive])}")

    System.put_env("EZAGENT_HOME", root)
    origin = local_origin!(root)
    owner = self()

    Application.put_env(:ezagent_domain_workspace, :task_workspace_remote_builder, fn _, _ ->
      %{remote_url: origin, allow_local_fixture: true}
    end)

    Application.put_env(:ezagent_domain_workspace, :sidecar_gate_test_owner, owner)
    Application.put_env(:ezagent_domain_workspace, :provisioner_test_owner, owner)

    Application.put_env(
      :ezagent_domain_workspace,
      :task_workspace_retirement,
      EzagentDomainWorkspace.TestSupport.FakeTaskWorkspaceRetirement
    )

    flavor = "signed-e2e-#{System.unique_integer([:positive])}"

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: EzagentDomainWorkspace.TestSupport.TaskWorkspaceTemplateClass
      })

    on_exit(fn ->
      :ok = WorkspaceProvisionRegistry.replace_for_test(nil)

      case previous_provisioner do
        {:ok, implementation} -> :ok = WorkspaceProvisionRegistry.register(implementation)
        {:error, :workspace_provisioner_not_registered} -> :ok
      end

      case previous_pre_start do
        {:ok, implementation} -> :ok = CorePreStart.replace_for_test(implementation)
        {:error, :template_pre_start_not_registered} -> :ok = CorePreStart.replace_for_test(nil)
      end

      System.put_env("EZAGENT_HOME", previous_home || "")
      if is_nil(previous_home), do: System.delete_env("EZAGENT_HOME")
      Application.delete_env(:ezagent_domain_workspace, :task_workspace_remote_builder)
      Application.delete_env(:ezagent_domain_workspace, :sidecar_gate_test_owner)
      Application.delete_env(:ezagent_domain_workspace, :sidecar_gate_test_provenance)
      Application.delete_env(:ezagent_domain_workspace, :provisioner_test_owner)
      Application.delete_env(:ezagent_domain_workspace, :task_workspace_retirement)
      File.rm_rf!(root)
    end)

    %{root: root, flavor: flavor}
  end

  test "signed provision starts one probe sidecar and signed cleanup removes its worktree",
       fixture do
    context = start_policy(:public)
    Application.put_env(:ezagent_domain_workspace, :sidecar_gate_test_provenance, context.owner)

    assert {:ok, ready} = dispatch(context, :provision_workspace)
    assert ready.status == :ready
    assert File.dir?(ready.cwd)

    agent_uri = Ezagent.URI.agent(context.workspace_name, "worker")

    Ezagent.Agent.TestLaunchPostCommitPublisher.inject(
      agent_uri,
      :barrier_after_commit,
      self()
    )

    on_exit(fn -> Ezagent.Agent.TestLaunchPostCommitPublisher.clear(agent_uri) end)

    start_task =
      Task.async(fn ->
        AgentStart.start(
          %{flavor: fixture.flavor, project_cwd: "/untrusted"},
          agent_uri,
          context.owner,
          context.workspace_uri,
          %{
            provision_id: ready.provision_id,
            task_access_uri: context.task_access_uri,
            task_uri: context.task_uri,
            generation: ready.generation
          }
        )
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), start_task.pid)

    assert_receive {:launch_receipt_committed, facts, init_pid}
    provision = Repo.get_by!(Provision, provision_id: ready.provision_id)
    assert facts.attempt_id == provision.creation_attempt_id
    assert facts.agent_uri == agent_uri
    assert facts.root_uri == context.owner
    assert facts.workspace_uri == context.workspace_uri

    assert {:ok, receipt} =
             Ezagent.Agent.CreationInventory.exact(
               facts.attempt_id,
               agent_uri,
               context.owner,
               context.workspace_uri
             )

    assert receipt.creation_attempt_id == facts.attempt_id
    send(init_pid, :release_after_commit)
    assert {:ok, %{fresh?: true}} = Task.await(start_task, 5_000)

    assert {:ok, attempt_id} =
             Ezagent.Agent.CreationInventory.find_attempt(agent_uri, context.workspace_uri)

    assert is_binary(attempt_id)
    assert {:ok, owner_uri} = Ezagent.AgentLineage.lookup(agent_uri)
    assert owner_uri == context.owner
    assert Repo.get_by!(Provision, provision_id: ready.provision_id).status == :sidecar_started

    assert_receive {:instantiate_called, %{"cwd" => cwd}}
    assert cwd == ready.cwd
    refute_receive {:instantiate_called, _}

    assert {:ok, %{status: :cleaned}} = dispatch(context, :cleanup_workspace)
    assert_receive {:retire_agent, agent_uri_string, retirement_attempt}
    assert agent_uri_string == URI.to_string(agent_uri)
    assert retirement_attempt == facts.attempt_id
    assert_receive {:retirement_facts, retirement_facts}
    assert retirement_facts.attempt_id == facts.attempt_id
    assert retirement_facts.agent_uri == facts.agent_uri
    assert retirement_facts.root_uri == facts.root_uri
    assert retirement_facts.workspace_uri == facts.workspace_uri
    cleaned = Repo.get_by!(Provision, provision_id: ready.provision_id)

    assert :ok =
             Ezagent.Workspace.TaskWorkspace.GitRunner.verify_absent(%{
               cache_path: Path.join(Path.dirname(cleaned.worktree_path), cleaned.cache_identity),
               worktree_path: cleaned.worktree_path,
               worktree_identity: cleaned.worktree_identity
             })

    refute File.exists?(ready.cwd)
    assert cleaned.status == :cleaned
  end

  test "signed adopted Agent has no receipt and cleanup never retires it", fixture do
    context = start_policy(:public)
    Application.put_env(:ezagent_domain_workspace, :sidecar_gate_test_provenance, context.owner)
    assert {:ok, ready} = dispatch(context, :provision_workspace)
    agent_uri = Ezagent.URI.agent(context.workspace_name, "worker")
    assert {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri})
    :ok = Ezagent.AgentLineage.record(agent_uri, context.owner)
    :ok = Ezagent.WorkspaceRegistry.bind(agent_uri, context.workspace_uri)

    assert {:error, :sidecar_start_not_fresh} =
             AgentStart.start(
               %{flavor: fixture.flavor, project_cwd: "/untrusted"},
               agent_uri,
               context.owner,
               context.workspace_uri,
               %{
                 provision_id: ready.provision_id,
                 task_access_uri: context.task_access_uri,
                 task_uri: context.task_uri,
                 generation: ready.generation
               }
             )

    assert {:error, :creation_attempt_not_found} =
             Ezagent.Agent.CreationInventory.find_attempt(agent_uri, context.workspace_uri)

    assert {:ok, %{status: :cleaned}} = dispatch(context, :cleanup_workspace)
    refute_receive {:retire_agent, _, _}
    refute_receive {:retirement_facts, _}
    assert {:ok, _pid} = Ezagent.KindRegistry.lookup(agent_uri)
  end

  test "unauthorized and private provision attempts have zero effects", fixture do
    unauthorized = start_policy(:public)
    before_entries = tree_entries(fixture.root)

    assert {:error, :missing_cap} =
             dispatch(unauthorized, :provision_workspace, caps: MapSet.new())

    assert Repo.aggregate(Provision, :count) == 0
    assert tree_entries(fixture.root) == before_entries
    refute_receive {:instantiate_called, _}

    private = start_policy(:private)
    assert {:error, :private_checkout_not_supported} = dispatch(private, :provision_workspace)
    assert Repo.aggregate(Provision, :count) == 0
    assert tree_entries(fixture.root) == before_entries
    refute_receive {:instantiate_called, _}
  end

  test "commit, branch, and dirty-tree drift each prevent AgentStart instantiate", fixture do
    for mutation <- [:other_commit, :other_branch, :dirty_file] do
      context = start_policy(:public)
      Application.put_env(:ezagent_domain_workspace, :sidecar_gate_test_provenance, context.owner)
      assert {:ok, ready} = dispatch(context, :provision_workspace)
      mutate_worktree!(ready.cwd, mutation)
      agent_uri = Ezagent.URI.agent(context.workspace_name, "worker")

      assert {:error, reason} =
               AgentStart.start(
                 %{flavor: fixture.flavor, project_cwd: "/untrusted"},
                 agent_uri,
                 context.owner,
                 context.workspace_uri,
                 %{
                   provision_id: ready.provision_id,
                   task_access_uri: context.task_access_uri,
                   task_uri: context.task_uri,
                   generation: ready.generation
                 }
               )

      expected =
        if mutation == :dirty_file, do: :workspace_not_clean, else: :workspace_checkout_mismatch

      assert reason == expected
      refute_receive {:instantiate_called, _}
      assert Repo.get_by!(Provision, provision_id: ready.provision_id).status == :cleanup_pending
    end
  end

  defp start_policy(visibility) do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    workspace_name = "signed-e2e-#{suffix}"
    workspace_uri = Ezagent.URI.workspace(workspace_name)
    task_uri = Ezagent.URI.resource(workspace_name, "kanban-task", "task")
    grantee = Ezagent.URI.agent(workspace_name, "worker")
    owner = Ezagent.URI.user(workspace_name, "owner")

    {:ok, repository} =
      RepositoryRef.new(%{
        repository_uri: Ezagent.URI.resource(workspace_name, "git-repository", "repo"),
        provider_adapter: :fixture,
        provider_host: "git.example.test",
        external_id: "repo",
        owner_path: "acme/repo",
        base_ref: "main",
        visibility: visibility
      })

    {:ok, policy} =
      GitTaskAccess.new(%{
        id: "access-#{suffix}",
        task_id: "task",
        generation: 1,
        workspace_uri: workspace_uri,
        credential_owner_uri: owner,
        grantee_uri: grantee,
        repository: repository,
        provider_adapter: :fixture,
        allowed_head_ref: "task/head",
        allowed_actions: [:provision_workspace, :cleanup_workspace],
        idempotency_inputs: %{task_id: "task", generation: 1}
      })

    {:ok, _pid} = TaskAccessSupervisor.ensure_started(policy)

    assert {:ok, %{policy: ^policy}} =
             Ezagent.Kind.get_slice(GitTaskAccess.uri_from_args(policy), :git_task_access)

    on_exit(fn -> TaskAccessSupervisor.teardown(GitTaskAccess.uri_from_args(policy)) end)

    %{
      policy: policy,
      task_access_uri: GitTaskAccess.uri_from_args(policy),
      task_uri: task_uri,
      workspace_name: workspace_name,
      workspace_uri: workspace_uri,
      grantee: grantee,
      owner: owner
    }
  end

  defp dispatch(context, action, opts \\ []) do
    capability =
      Ezagent.Capability.cap(
        :git_task_access,
        Ezagent.ActionSet.GitTaskAccess,
        action,
        Ezagent.URI.instance(context.task_access_uri),
        context.workspace_uri
      )

    {:ok, artifact} =
      Ezagent.Cap.issue(
        {:admin, Ezagent.URI.user(:system, :admin)},
        context.grantee,
        capability
      )

    caps = Keyword.get(opts, :caps, MapSet.new([artifact]))

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: Ezagent.URI.with_action(context.task_access_uri, :git_task_access, action),
      mode: :call,
      args: %{task_uri: context.task_uri, generation: context.policy.generation},
      # #195: the holder is fixed at the auth boundary — the grantee is the
      # authenticated presenter, so dispatch ctx must carry it explicitly.
      ctx: %{
        caller: context.grantee,
        authenticated_principal: context.grantee,
        caps: caps,
        reply: {:caller_inbox, self()}
      },
      origin: :trusted_internal
    })
  end

  defp tree_entries(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.sort()
  end

  defp local_origin!(root) do
    source = Path.join(root, "source")
    origin = Path.join(root, "origin.git")
    File.mkdir_p!(source)
    git!(root, ["init", "--bare", origin])
    git!(source, ["init", "-b", "main"])
    File.write!(Path.join(source, "README.md"), "fixture\n")
    git!(source, ["add", "README.md"])

    git!(source, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.test",
      "commit",
      "-m",
      "fixture"
    ])

    git!(source, ["remote", "add", "origin", origin])
    git!(source, ["push", "origin", "main"])
    git!(root, ["--git-dir", origin, "symbolic-ref", "HEAD", "refs/heads/main"])
    origin
  end

  defp git!(cd, args) do
    {_output, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    :ok
  end

  defp mutate_worktree!(cwd, :other_commit) do
    File.write!(Path.join(cwd, "commit-drift"), "drift\n")
    git!(cwd, ["add", "commit-drift"])

    git!(cwd, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.test",
      "commit",
      "-m",
      "commit drift"
    ])
  end

  defp mutate_worktree!(cwd, :other_branch), do: git!(cwd, ["checkout", "-b", "other-branch"])

  defp mutate_worktree!(cwd, :dirty_file) do
    File.write!(Path.join(cwd, "untracked"), "dirty\n")
  end
end
