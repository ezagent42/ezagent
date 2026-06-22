defmodule EzagentPluginHello.RegistrationTest do
  use ExUnit.Case, async: true

  test ":grant_cap lives on IdentityAdmin (the privileged write behavior)" do
    assert :grant_cap in Ezagent.Behavior.IdentityAdmin.actions()
    refute :grant_cap in Ezagent.Behavior.Identity.actions()
  end

  test "the HelloBuilder Kind routes :grant_cap to the IdentityAdmin behavior" do
    assert {:ok, Ezagent.Behavior.IdentityAdmin} =
             Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.HelloBuilder, :grant_cap)
  end

  test "the HelloBuilder Kind routes :list_caps to the Identity behavior" do
    assert {:ok, Ezagent.Behavior.Identity} =
             Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.HelloBuilder, :list_caps)
  end

  test "the HelloBuilder Kind routes :receive to its own behavior" do
    assert {:ok, Ezagent.Behavior.HelloBuilder} =
             Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.HelloBuilder, :receive)
  end
end
