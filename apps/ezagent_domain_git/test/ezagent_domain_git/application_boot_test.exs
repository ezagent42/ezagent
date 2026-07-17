defmodule EzagentDomainGit.ApplicationBootTest do
  use ExUnit.Case, async: false

  alias Ezagent.DomainGit.AdapterRegistry
  alias Ezagent.DomainGit.BootRegistration
  alias Ezagent.DomainGit.TestSupport.{FakeGitAdapterA, FakeGitAdapterB}
  alias Ezagent.Entity.GitTaskAccess

  @actions [
    :resolve_repository,
    :create_change_request,
    :read_change_request,
    :list_checks,
    :list_reviews,
    :provision_workspace,
    :cleanup_workspace
  ]
  @action_set Ezagent.ActionSet.GitTaskAccess

  setup do
    {:module, FakeGitAdapterA} = Code.ensure_loaded(FakeGitAdapterA)
    {:module, FakeGitAdapterB} = Code.ensure_loaded(FakeGitAdapterB)
    replace_registration([])
    on_exit(fn -> replace_registration([]) end)
    :ok
  end

  test "normal and repeated boot registers the complete action surface" do
    Enum.each(@actions, fn action ->
      assert {:ok, %{behavior: @action_set}} =
               Ezagent.CapabilityRegistry.lookup_subject(GitTaskAccess, action)
    end)

    replace_registration([])

    Enum.each(@actions, fn action ->
      assert {:ok, %{behavior: @action_set}} =
               Ezagent.CapabilityRegistry.lookup_subject(GitTaskAccess, action)
    end)
  end

  test "adapter declaration and rollback never execute adapter callbacks" do
    bomb = Ezagent.DomainGit.TestSupport.BootCallbackBomb
    {:module, ^bomb} = Code.ensure_loaded(bomb)

    assert :ok = replace_registration(adapters: [{"callback-bomb", bomb}])
    assert {:ok, ^bomb} = AdapterRegistry.lookup_for_action_set("callback-bomb")

    assert {:error, {:injected_registration_failure, 9}} =
             replace_registration(
               adapters: [{"callback-bomb", bomb}, {"never-reached", FakeGitAdapterB}],
               fail_at: 9
             )
  end

  test "Nth capability and adapter failures roll back attempt-owned rows only" do
    assert {:error, {:injected_registration_failure, 3}} = replace_registration(fail_at: 3)
    assert_no_actions()

    preexisting = :resolve_repository
    :ok = Ezagent.CapabilityRegistry.register(GitTaskAccess, preexisting, @action_set)
    :ok = AdapterRegistry.unregister("preexisting-a", FakeGitAdapterA)
    :ok = AdapterRegistry.unregister("attempt-b", FakeGitAdapterB)
    :ok = AdapterRegistry.register("preexisting-a", FakeGitAdapterA)

    assert {:error, {:injected_registration_failure, 10}} =
             replace_registration(
               adapters: [
                 {"preexisting-a", FakeGitAdapterA},
                 {"attempt-b", FakeGitAdapterB},
                 {"never-reached", Ezagent.DomainGit.TestSupport.BootCallbackBomb}
               ],
               fail_at: 10
             )

    assert {:ok, %{behavior: @action_set}} =
             Ezagent.CapabilityRegistry.lookup_subject(GitTaskAccess, preexisting)

    assert {:ok, FakeGitAdapterA} = AdapterRegistry.lookup_for_action_set("preexisting-a")
    assert :error = AdapterRegistry.lookup_for_action_set("attempt-b")
  end

  test "adapter registry restart reconciles declarations without partial ETS state" do
    :ok = AdapterRegistry.unregister("preexisting-a", FakeGitAdapterA)
    :ok = AdapterRegistry.register("preexisting-a", FakeGitAdapterA)

    replace_registration(
      adapters: [
        {"preexisting-a", FakeGitAdapterA},
        {"boot-b", FakeGitAdapterB}
      ]
    )

    :ok = Supervisor.terminate_child(EzagentDomainGit.Application, AdapterRegistry)
    assert {:ok, _pid} = Supervisor.restart_child(EzagentDomainGit.Application, AdapterRegistry)

    assert_eventually(fn ->
      AdapterRegistry.lookup_for_action_set("preexisting-a") == {:ok, FakeGitAdapterA} and
        AdapterRegistry.lookup_for_action_set("boot-b") == {:ok, FakeGitAdapterB}
    end)

    replace_registration([])

    assert :error = AdapterRegistry.lookup_for_action_set("preexisting-a")
    assert :error = AdapterRegistry.lookup_for_action_set("boot-b")
  end

  test "registry generation restart does not carry stale ownership onto a third-party row" do
    :ok = AdapterRegistry.unregister("generation-a", FakeGitAdapterA)
    replace_registration(adapters: [{"generation-a", FakeGitAdapterA}])

    :ok = :sys.suspend(BootRegistration)
    :ok = Supervisor.terminate_child(EzagentDomainGit.Application, AdapterRegistry)
    assert {:ok, _pid} = Supervisor.restart_child(EzagentDomainGit.Application, AdapterRegistry)
    assert :ok = AdapterRegistry.register("generation-a", FakeGitAdapterA)
    :ok = :sys.resume(BootRegistration)

    assert_eventually(fn ->
      AdapterRegistry.lookup_for_action_set("generation-a") == {:ok, FakeGitAdapterA}
    end)

    replace_registration([])
    assert {:ok, FakeGitAdapterA} = AdapterRegistry.lookup_for_action_set("generation-a")
    :ok = AdapterRegistry.unregister("generation-a", FakeGitAdapterA)
  end

  test "rapid registry restarts ignore stale and duplicate generation notifications" do
    :ok = AdapterRegistry.unregister("rapid-a", FakeGitAdapterA)
    replace_registration(adapters: [{"rapid-a", FakeGitAdapterA}])

    :ok = :sys.suspend(BootRegistration)
    :ok = Supervisor.terminate_child(EzagentDomainGit.Application, AdapterRegistry)

    assert {:ok, first_generation} =
             Supervisor.restart_child(EzagentDomainGit.Application, AdapterRegistry)

    :ok = Supervisor.terminate_child(EzagentDomainGit.Application, AdapterRegistry)

    assert {:ok, current_generation} =
             Supervisor.restart_child(EzagentDomainGit.Application, AdapterRegistry)

    refute first_generation == current_generation
    :ok = :sys.resume(BootRegistration)

    assert_eventually(fn ->
      AdapterRegistry.lookup_for_action_set("rapid-a") == {:ok, FakeGitAdapterA}
    end)

    send(BootRegistration, {:reconcile_adapters, current_generation})
    _state = :sys.get_state(BootRegistration)
    replace_registration([])
    assert :error = AdapterRegistry.lookup_for_action_set("rapid-a")
  end

  test "TaskAccessSupervisor start failure follows the post-registration rollback path" do
    Enum.each(@actions, fn action ->
      :ok = Ezagent.CapabilityRegistry.unregister(GitTaskAccess, action, @action_set)
    end)

    assert :ok = Application.stop(:ezagent_domain_git)

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_git, :task_access_child)
      Application.ensure_all_started(:ezagent_domain_git)
    end)

    Application.put_env(
      :ezagent_domain_git,
      :task_access_child,
      Ezagent.DomainGit.TestSupport.FailingBootChild
    )

    assert {:error, _reason} = Application.ensure_all_started(:ezagent_domain_git)
    assert_no_actions()
    assert :undefined = :ets.whereis(:ezagent_domain_git_adapter_registry)
  end

  test "later child failure rolls back the attempt and a subsequent application restart is complete" do
    Enum.each(@actions, fn action ->
      :ok = Ezagent.CapabilityRegistry.unregister(GitTaskAccess, action, @action_set)
    end)

    assert :ok = Application.stop(:ezagent_domain_git)

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_git, :later_boot_children)
      Application.ensure_all_started(:ezagent_domain_git)
    end)

    Application.put_env(:ezagent_domain_git, :later_boot_children, [
      Ezagent.DomainGit.TestSupport.FailingBootChild
    ])

    assert {:error, _reason} = Application.ensure_all_started(:ezagent_domain_git)
    assert :undefined = :ets.whereis(:ezagent_domain_git_adapter_registry)

    assert_no_actions()

    Application.delete_env(:ezagent_domain_git, :later_boot_children)
    assert {:ok, _started} = Application.ensure_all_started(:ezagent_domain_git)

    Enum.each(@actions, fn action ->
      assert {:ok, %{behavior: @action_set}} =
               Ezagent.CapabilityRegistry.lookup_subject(GitTaskAccess, action)
    end)
  end

  defp replace_registration(opts) do
    case Supervisor.terminate_child(EzagentDomainGit.Application, BootRegistration) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    case Supervisor.delete_child(EzagentDomainGit.Application, BootRegistration) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    case Supervisor.start_child(EzagentDomainGit.Application, {BootRegistration, opts}) do
      {:ok, _pid} -> :ok
      {:error, {reason, {:child, _, BootRegistration, _, _, _, _, _, _}}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp assert_no_actions do
    Enum.each(@actions, fn action ->
      assert :error = Ezagent.CapabilityRegistry.lookup_subject(GitTaskAccess, action)
      assert :error = Ezagent.BehaviorRegistry.lookup(GitTaskAccess, action)
    end)
  end

  defp assert_eventually(assertion, attempts \\ 50)

  defp assert_eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(assertion, attempts - 1)
    end
  end

  defp assert_eventually(_assertion, 0), do: flunk("condition did not become true")
end
