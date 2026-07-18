defmodule EzagentDomainProviderConnection.ApplicationTest do
  use ExUnit.Case, async: false

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

    :ok = EzagentCore.EtsOwner.recreate_capability_tables_for_test()

    eventually(fn ->
      Enum.all?(ProviderConnection.actions(), fn action ->
        match?(
          {:ok, %{behavior: ProviderConnection}},
          CapabilityRegistry.lookup_subject(User, action)
        ) and BehaviorRegistry.lookup(User, action) == {:ok, ProviderConnection}
      end)
    end)

    true = :ets.insert(Ezagent.CapabilityRegistry.Subjects.table(), subjects)
    true = :ets.insert(Ezagent.BehaviorRegistry.table(), behaviors)
  end

  defp eventually(assertion, attempts \\ 100)
  defp eventually(assertion, 0), do: assert(assertion.())

  defp eventually(assertion, attempts) do
    if assertion.() do
      :ok
    else
      receive do
      after
        10 -> eventually(assertion, attempts - 1)
      end
    end
  end
end
