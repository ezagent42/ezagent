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
end
