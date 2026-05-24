defmodule Ezagent.Behavior.IdentityTest do
  use ExUnit.Case, async: true
  alias Ezagent.Behavior.Identity
  alias Ezagent.{Capability, Entity.User}

  describe "init_slice/1" do
    test "default initial_caps is empty MapSet" do
      assert %{caps: caps} = Identity.init_slice(%{uri: URI.new!("entity://user/default/x")})
      assert MapSet.size(caps) == 0
    end

    test "accepts initial_caps as MapSet (admin path)" do
      admin_caps = User.admin_caps()
      assert %{caps: caps} = Identity.init_slice(%{initial_caps: admin_caps})
      assert caps == admin_caps
    end

    test "accepts initial_caps as list" do
      [cap] = MapSet.to_list(User.admin_caps())
      assert %{caps: caps} = Identity.init_slice(%{initial_caps: [cap]})
      assert MapSet.size(caps) == 1
    end
  end

  describe "invoke(:list_caps, ...)" do
    test "returns list of all caps in slice" do
      slice = Identity.init_slice(%{initial_caps: User.admin_caps()})

      assert {:ok, ^slice, %{caps: list}} = Identity.invoke(:list_caps, slice, %{}, %{})
      assert length(list) == MapSet.size(slice.caps)
    end
  end

  describe "invoke(:has_cap?, ...)" do
    test "returns true for admin all-cap match" do
      slice = Identity.init_slice(%{initial_caps: User.admin_caps()})

      needed = %{
        kind: :session,
        behavior: Ezagent.Behavior.Chat,
        instance: URI.new!("session://default/default/main"),
        workspace_uri: URI.new!("workspace://default")
      }

      assert {:ok, ^slice, %{has: true}} = Identity.invoke(:has_cap?, slice, %{cap: needed}, %{})
    end

    test "returns false when no caps match" do
      slice = Identity.init_slice(%{})

      needed = %{
        kind: :session,
        behavior: Ezagent.Behavior.Chat,
        instance: URI.new!("session://default/default/main"),
        workspace_uri: URI.new!("workspace://default")
      }

      assert {:ok, ^slice, %{has: false}} = Identity.invoke(:has_cap?, slice, %{cap: needed}, %{})
    end
  end

  describe "Behavior contract" do
    test "actions/0" do
      # PR-OWN-3: split — Identity holds only safe actions;
      # :grant_cap and :revoke_cap moved to IdentityAdmin.
      assert Identity.actions() == [:list_caps, :has_cap?]
      assert Ezagent.Behavior.IdentityAdmin.actions() == [:grant_cap, :revoke_cap]
    end

    test "state_slice/0" do
      assert Identity.state_slice() == :identity
    end

    test "interface/0 declares both actions with :call mode" do
      iface = Identity.interface()
      assert Map.has_key?(iface, :list_caps)
      assert Map.has_key?(iface, :has_cap?)
      assert iface[:list_caps].modes == [:call]
      assert iface[:has_cap?].modes == [:call]
    end
  end

  describe "Capability.matches? integration sanity" do
    test "admin all-cap matches arbitrary needed cap (the gate Phase 3d uses)" do
      slice = Identity.init_slice(%{initial_caps: User.admin_caps()})

      [admin_cap] = MapSet.to_list(slice.caps)

      assert Capability.matches?(admin_cap, %{
               kind: :anything,
               behavior: SomeMod,
               instance: URI.new!("entity://agent/default/test_X"),
               workspace_uri: URI.new!("workspace://default")
             })
    end
  end
end
