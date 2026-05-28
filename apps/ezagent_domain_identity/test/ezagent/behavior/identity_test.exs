defmodule Ezagent.Behavior.IdentityTest do
  @moduledoc """
  P2-b migration (2026-05-28): rewritten to exercise the new-contract
  `handle_list_caps/2` and `handle_has_cap?/2` handlers. Dispatch
  parity through Kind.Runtime lives in
  `identity_migration_parity_test.exs`.
  """
  use ExUnit.Case, async: true
  alias Ezagent.Behavior.Identity
  alias Ezagent.{Capability, Entity.User}

  defp ctx_with_caps(caps) do
    %{
      caller: :system,
      caps: MapSet.new(),
      self_uri: URI.parse("entity://user/team-alpha/test"),
      reply: :sync,
      read: fn key, default ->
        case key do
          :caps -> caps
          _ -> default
        end
      end
    }
  end

  describe "init_slice/1" do
    test "default initial_caps contains owner-derived self-Identity cap (PR-OWN-3)" do
      uri = URI.new!("entity://user/team-alpha/x")
      assert %{caps: caps} = Identity.init_slice(%{uri: uri})
      assert MapSet.size(caps) == 1

      [self_cap] = MapSet.to_list(caps)
      assert self_cap.behavior == Identity
      assert self_cap.instance == uri
    end

    test "init_slice without :uri arg yields empty MapSet" do
      assert %{caps: caps} = Identity.init_slice(%{})
      assert MapSet.size(caps) == 0
    end

    test "accepts initial_caps as MapSet (admin path)" do
      admin_caps = Ezagent.SystemPrincipal.caps("system://bootstrap")
      assert %{caps: caps} = Identity.init_slice(%{initial_caps: admin_caps})
      assert caps == admin_caps
    end

    test "accepts initial_caps as list" do
      [cap] = MapSet.to_list(Ezagent.SystemPrincipal.caps("system://bootstrap"))
      assert %{caps: caps} = Identity.init_slice(%{initial_caps: [cap]})
      assert MapSet.size(caps) == 1
    end
  end

  describe "handle_list_caps/2" do
    test "returns list of all caps in slice (read via ctx[:read])" do
      caps = Ezagent.SystemPrincipal.caps("system://bootstrap")
      ctx = ctx_with_caps(caps)

      assert {:ok, %{caps: list}, []} = Identity.handle_list_caps(%{}, ctx)
      assert length(list) == MapSet.size(caps)
    end

    test "empty caps yields empty list" do
      ctx = ctx_with_caps(MapSet.new())
      assert {:ok, %{caps: []}, []} = Identity.handle_list_caps(%{}, ctx)
    end
  end

  describe "handle_has_cap?/2" do
    test "returns true for admin all-cap match" do
      caps = Ezagent.SystemPrincipal.caps("system://bootstrap")
      ctx = ctx_with_caps(caps)

      needed = %{
        kind: :session,
        behavior: Ezagent.Behavior.Chat,
        instance: URI.new!("session://default/system/main"),
        workspace_uri: URI.new!("workspace://team-alpha")
      }

      assert {:ok, %{has: true}, []} = Identity.handle_has_cap?(%{cap: needed}, ctx)
    end

    test "returns false when no caps match" do
      ctx = ctx_with_caps(MapSet.new())

      needed = %{
        kind: :session,
        behavior: Ezagent.Behavior.Chat,
        instance: URI.new!("session://default/system/main"),
        workspace_uri: URI.new!("workspace://team-alpha")
      }

      assert {:ok, %{has: false}, []} = Identity.handle_has_cap?(%{cap: needed}, ctx)
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

    test "__actions__/0 declares both actions with :call mode" do
      action_specs = Identity.__actions__()
      assert Map.has_key?(action_specs, :list_caps)
      assert Map.has_key?(action_specs, :has_cap?)
      assert action_specs[:list_caps].modes == [:call]
      assert action_specs[:has_cap?].modes == [:call]
    end

    test "new-contract markers" do
      assert Identity.__behavior__?() == true
      assert Ezagent.Behavior.IdentityAdmin.__behavior__?() == true
    end
  end

  describe "Capability.matches? integration sanity" do
    test "admin all-cap matches arbitrary needed cap (the gate Phase 3d uses)" do
      slice = Identity.init_slice(%{initial_caps: Ezagent.SystemPrincipal.caps("system://bootstrap")})

      [admin_cap] = MapSet.to_list(slice.caps)

      assert Capability.matches?(admin_cap, %{
               kind: :anything,
               behavior: SomeMod,
               instance: URI.new!("entity://agent/team-alpha/test_X"),
               workspace_uri: URI.new!("workspace://team-alpha")
             })
    end
  end
end
