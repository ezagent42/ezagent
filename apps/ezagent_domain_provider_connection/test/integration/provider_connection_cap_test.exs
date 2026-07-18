defmodule Ezagent.ProviderConnectionCapTest do
  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.ProviderConnection
  alias Ezagent.Entity.User

  test "every owner command resolves only through the central User dispatch registry" do
    for action <- ProviderConnection.actions() do
      assert {:ok, %{kind: User, behavior: ProviderConnection, action: ^action}} =
               Ezagent.CapabilityRegistry.lookup_subject(User, action)
    end
  end
end
