defmodule Ezagent.Behavior.WorkspaceUserAdminTest do
  @moduledoc """
  Contract-surface tests for the dispatch-backed
  `Ezagent.Behavior.WorkspaceUserAdmin` — the codex PR #356 r1 CRIT
  fix that carves `:create_user` out of `Behavior.Workspace` so the
  cap subject is distinct.

  The full happy-path/edge-case integration coverage is in
  `apps/ezagent_domain_workspace/test/integration/create_user_dispatch_test.exs`
  which exercises the facade `Ezagent.Workspace.create_user/3` end
  to end (now via the new dispatch target).
  """

  use ExUnit.Case, async: true

  alias Ezagent.Behavior.WorkspaceUserAdmin, as: WUA

  describe "contract surface" do
    test "actions/0 lists :create_user only" do
      assert WUA.actions() == [:create_user]
    end

    test "required_caps/0 has an entry per action with the SPEC v2 struct shape" do
      caps = WUA.required_caps()

      for action <- WUA.actions() do
        assert Map.has_key?(caps, action),
               "required_caps/0 missing #{action} — dispatch step 5.5 would crash"
      end

      %Ezagent.Capability{kind: kind, behavior: behavior} = caps[:create_user]
      assert kind == :workspace
      # P15: cap BEHAVIOR field is the MODULE — this is the key
      # difference vs `Behavior.Workspace`'s caps; a holder of one is
      # NOT a holder of the other even on the same target workspace.
      assert behavior == Ezagent.Behavior.WorkspaceUserAdmin
      refute behavior == Ezagent.Behavior.Workspace
    end

    test "state_slice/0 is :workspace_user_admin (distinct from :workspace)" do
      assert WUA.state_slice() == :workspace_user_admin
      refute WUA.state_slice() == :workspace
    end

    test "init_slice/1 starts with create_count: 0" do
      assert WUA.init_slice(%{}) == %{create_count: 0}
    end

    test "interface/0 covers every action in actions/0" do
      iface = WUA.interface()

      for action <- WUA.actions() do
        assert Map.has_key?(iface, action), "interface/0 missing #{action}"
      end
    end

    test "cap_subjects/0 has one row per action with a human description" do
      subjects = Map.new(WUA.cap_subjects())

      for action <- WUA.actions() do
        assert is_binary(subjects[action]) and String.length(subjects[action]) > 10
      end
    end

    test "data_owner/0 is :any (workspace-admin grantable)" do
      assert WUA.data_owner(:create_user) == :any
    end
  end

  describe "argument validation (pure, no DB)" do
    test "missing user_uri returns {:error, :user_uri_required}" do
      slice = WUA.init_slice(%{})
      ctx = %{caller: nil, caps: MapSet.new(), self_uri: URI.parse("workspace://x")}

      assert {:error, :user_uri_required} =
               WUA.invoke(:create_user, slice, %{}, ctx)
    end

    test "non-entity URI surfaces as :bad_user_uri" do
      slice = WUA.init_slice(%{})
      ctx = %{caller: nil, caps: MapSet.new(), self_uri: URI.parse("workspace://x")}

      assert {:error, {:bad_user_uri, "workspace://x", _msg}} =
               WUA.invoke(:create_user, slice, %{user_uri: "workspace://x"}, ctx)
    end

    test "bad self_uri (not a workspace scheme) returns :bad_workspace_uri" do
      slice = WUA.init_slice(%{})

      ctx = %{
        caller: nil,
        caps: MapSet.new(),
        self_uri: URI.parse("entity://user/x/y")
      }

      assert {:error, {:bad_workspace_uri, _}} =
               WUA.invoke(
                 :create_user,
                 slice,
                 %{user_uri: "entity://user/x/y"},
                 ctx
               )
    end
  end
end
