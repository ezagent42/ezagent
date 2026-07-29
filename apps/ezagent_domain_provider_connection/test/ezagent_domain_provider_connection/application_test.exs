defmodule EzagentDomainProviderConnection.ApplicationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ezagent.ActionSet.ProviderConnection
  alias Ezagent.{BehaviorRegistry, CapabilityRegistry}
  alias Ezagent.Entity.User

  test "exclusive supervisor ownership makes a losing starter registry-neutral" do
    assert {:error, {:already_started, winner}} =
             EzagentDomainProviderConnection.Application.start(:normal, [])

    assert winner == Process.whereis(EzagentDomainProviderConnection.Application)

    for action <- ProviderConnection.actions() do
      assert {:ok, %{behavior: ProviderConnection}} =
               CapabilityRegistry.lookup_subject(User, action)

      assert {:ok, ProviderConnection} = BehaviorRegistry.lookup(User, action)
    end
  end

  test "application stop removes exactly its seven declarations" do
    assert :ok = Application.stop(:ezagent_domain_provider_connection)

    for action <- ProviderConnection.actions() do
      assert :error = CapabilityRegistry.lookup_subject(User, action)
      assert :error = BehaviorRegistry.lookup(User, action)
    end

    on_exit(fn -> Application.ensure_all_started(:ezagent_domain_provider_connection) end)
  end

  test "healthy owner adopts identical declarations and removes them on stop" do
    assert :ok = Application.stop(:ezagent_domain_provider_connection)

    for action <- ProviderConnection.actions() do
      :ok = CapabilityRegistry.register(User, action, ProviderConnection)
    end

    assert {:ok, _started} = Application.ensure_all_started(:ezagent_domain_provider_connection)
    assert :ok = Application.stop(:ezagent_domain_provider_connection)

    for action <- ProviderConnection.actions() do
      assert :error = CapabilityRegistry.lookup_subject(User, action)
      assert :error = BehaviorRegistry.lookup(User, action)
    end

    on_exit(fn -> Application.ensure_all_started(:ezagent_domain_provider_connection) end)
  end

  test "registry owner restores all seven declarations after core ETS recreation" do
    subjects = :ets.tab2list(Ezagent.CapabilityRegistry.Subjects.table())
    behaviors = :ets.tab2list(Ezagent.BehaviorRegistry.table())

    # Each owner recreates ONLY the table(s) it actually owns (see the
    # root-cause note on `EzagentCore.EtsOwner.recreate_capability_tables_for_test/0`)
    # — recreating `BehaviorRegistry`'s table from the wrong owner process
    # silently reassigns its real ETS ownership and orphans it on the
    # next genuine `EzagentCore.EtsOwner` crash.
    :ok = EzagentActor.EtsOwner.recreate_capability_tables_for_test()
    :ok = EzagentCore.EtsOwner.recreate_capability_tables_for_test()
    {:ok, _owner, generation} = EzagentCore.EtsReadiness.subscribe()
    :ok = Ezagent.ProviderConnection.RegistryOwner.await_generation(generation)
    assert declarations_ready?()

    true = :ets.insert(Ezagent.CapabilityRegistry.Subjects.table(), subjects)
    true = :ets.insert(Ezagent.BehaviorRegistry.table(), behaviors)
  end

  test "registry owner follows actual EtsOwner restarts with one live monitor" do
    registry_owner = Process.whereis(Ezagent.ProviderConnection.RegistryOwner)
    old_ets_owner = Process.whereis(EzagentCore.EtsOwner)
    backups = backup_core_tables(old_ets_owner)
    {:ok, ^old_ets_owner, old_generation} = EzagentCore.EtsReadiness.subscribe()

    assert %{owner_pid: ^old_ets_owner, owner_ref: old_ref} = :sys.get_state(registry_owner)
    assert is_reference(old_ref)
    assert monitor_count(registry_owner) == 1

    Process.exit(old_ets_owner, :kill)
    assert_receive {:ets_owner_ready, new_owner, first_generation}, 5_000
    assert is_pid(new_owner)
    assert new_owner != old_ets_owner
    assert first_generation > old_generation

    restore_core_tables(backups)
    :ok = Ezagent.ProviderConnection.RegistryOwner.await_generation(first_generation)

    state = :sys.get_state(registry_owner)
    assert state.owner_pid == new_owner
    assert is_reference(state.owner_ref)
    assert monitor_count(registry_owner) == 1
    assert declarations_ready?()

    new_ref = :sys.get_state(registry_owner).owner_ref
    assert new_ref != old_ref

    Process.exit(new_owner, :kill)
    assert_receive {:ets_owner_ready, replacement, second_generation}, 5_000
    assert is_pid(replacement)
    assert replacement != new_owner
    assert second_generation > first_generation

    restore_core_tables(backups)
    :ok = Ezagent.ProviderConnection.RegistryOwner.await_generation(second_generation)
    assert monitor_count(registry_owner) == 1
    assert declarations_ready?()
  end

  test "registry owner cleanup is safe when capability tables are absent" do
    tables = [Ezagent.CapabilityRegistry.Subjects.table(), Ezagent.BehaviorRegistry.table()]
    backups = Map.new(tables, &{&1, :ets.tab2list(&1)})

    log =
      capture_log(fn ->
        Enum.each(tables, &:ets.delete/1)
        assert :ok = Application.stop(:ezagent_domain_provider_connection)
      end)

    refute log =~ "terminating"
    refute log =~ "ArgumentError"

    # Each owner recreates ONLY the table it actually owns — see the
    # root-cause note on `EzagentCore.EtsOwner.recreate_capability_tables_for_test/0`.
    :ok = EzagentActor.EtsOwner.recreate_capability_tables_for_test()
    :ok = EzagentCore.EtsOwner.recreate_capability_tables_for_test()

    Enum.each(backups, fn {table, rows} ->
      true = :ets.insert(table, rows)
    end)

    assert {:ok, _started} =
             Application.ensure_all_started(:ezagent_domain_provider_connection)

    assert declarations_ready?()

    on_exit(fn ->
      if :ets.whereis(Ezagent.BehaviorRegistry.table()) == :undefined do
        EzagentActor.EtsOwner.recreate_capability_tables_for_test()
      end

      if :ets.whereis(Ezagent.CapabilityRegistry.Subjects.table()) == :undefined do
        EzagentCore.EtsOwner.recreate_capability_tables_for_test()
      end

      Application.ensure_all_started(:ezagent_domain_provider_connection)
    end)
  end

  defp declarations_ready? do
    Enum.all?(ProviderConnection.actions(), fn action ->
      match?(
        {:ok, %{behavior: ProviderConnection}},
        CapabilityRegistry.lookup_subject(User, action)
      ) and BehaviorRegistry.lookup(User, action) == {:ok, ProviderConnection}
    end)
  rescue
    ArgumentError -> false
  end

  defp monitor_count(pid) do
    {:monitors, monitors} = Process.info(pid, :monitors)
    Enum.count(monitors, fn {kind, _target} -> kind == :process end)
  end

  defp backup_core_tables(owner) do
    owner
    |> :sys.get_state()
    |> Map.fetch!(:tables)
    |> Map.new(fn table -> {table, :ets.tab2list(table)} end)
  end

  defp restore_core_tables(backups) do
    Enum.each(backups, fn {table, rows} ->
      if :ets.whereis(table) != :undefined, do: :ets.insert(table, rows)
    end)
  end
end
