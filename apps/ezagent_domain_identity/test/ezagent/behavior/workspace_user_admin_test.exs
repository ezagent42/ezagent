defmodule Ezagent.ActionSet.WorkspaceUserAdminTest do
  @moduledoc """
  Contract-surface tests for the dispatch-backed
  `Ezagent.ActionSet.WorkspaceUserAdmin` — the codex PR #356 r1 CRIT
  fix that carves `:create_user` out of `Behavior.Workspace` so the
  cap subject is distinct.

  P2-b migration (2026-05-28): rewritten to exercise the new-contract
  `handle_create_user/2` handler. Full happy-path coverage stays in
  `apps/ezagent_domain_workspace/test/integration/create_user_dispatch_test.exs`
  (end-to-end through `Ezagent.Workspace.create_user/3`).
  """

  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.WorkspaceUserAdmin, as: WUA

  defp empty_ctx do
    %{
      caller: nil,
      caps: MapSet.new(),
      self_uri: Ezagent.URI.new!("workspace://x"),
      reply: :sync,
      read: fn _key, default -> default end
    }
  end

  describe "contract surface" do
    test "actions/0 lists create_user + disable_user" do
      assert Enum.sort(WUA.actions()) == [:create_user, :disable_user]
    end

    test "new-contract marker __behavior__?/0 is true" do
      assert WUA.__behavior__?() == true
    end

    test "__action_names__/0 covers both actions" do
      assert Enum.sort(WUA.__action_names__()) == [:create_user, :disable_user]
    end

    test "required_caps/0 has an entry per action with the SPEC v2 struct shape" do
      caps = WUA.required_caps()

      for action <- WUA.actions() do
        assert Map.has_key?(caps, action),
               "required_caps/0 missing #{action} — dispatch step 5.5 would crash"
      end

      # Each action carves its OWN cap subject (distinct action axis).
      for action <- [:create_user, :disable_user] do
        %Ezagent.Capability{kind: kind, behavior: behavior, action: cap_action} = caps[action]
        assert kind == :workspace
        assert behavior == Ezagent.ActionSet.WorkspaceUserAdmin
        assert cap_action == action
        refute behavior == Ezagent.ActionSet.Workspace
      end
    end

    test "state_slice/0 is :workspace_user_admin (distinct from :workspace)" do
      assert WUA.state_slice() == :workspace_user_admin
      refute WUA.state_slice() == :workspace
    end

    # Phase B: `init_slice/1` → `create/1` (PERSISTENT state).
    test "create/1 starts with create_count: 0" do
      assert WUA.create(%{}) == {:ok, %{create_count: 0}}
    end

    test "__actions__/0 covers every action in actions/0" do
      action_specs = WUA.__actions__()

      for action <- WUA.actions() do
        assert Map.has_key?(action_specs, action), "__actions__/0 missing #{action}"
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
      assert {:error, :user_uri_required} =
               WUA.handle_create_user(%{}, empty_ctx())
    end

    test "non-entity URI surfaces as :bad_user_uri" do
      assert {:error, {:bad_user_uri, "workspace://x", _msg}} =
               WUA.handle_create_user(%{user_uri: "workspace://x"}, empty_ctx())
    end

    test "bad self_uri (not a workspace scheme) returns :bad_workspace_uri" do
      ctx = %{empty_ctx() | self_uri: Ezagent.URI.new!("entity://x/user/y")}

      assert {:error, {:bad_workspace_uri, _}} =
               WUA.handle_create_user(%{user_uri: "entity://x/user/y"}, ctx)
    end
  end

  describe "disable_user argument validation (pure, no DB)" do
    test "missing user_uri returns {:error, :user_uri_required}" do
      assert {:error, :user_uri_required} = WUA.handle_disable_user(%{}, empty_ctx())
    end

    test "non-entity URI surfaces as :bad_user_uri" do
      assert {:error, {:bad_user_uri, "workspace://x", _}} =
               WUA.handle_disable_user(%{user_uri: "workspace://x"}, empty_ctx())
    end

    test "non-string reason is rejected" do
      assert {:error, {:bad_reason, 123}} =
               WUA.handle_disable_user(%{user_uri: "entity://x/user/y", reason: 123}, empty_ctx())
    end

    test "cross-workspace user (vs self workspace) is refused before any DB write" do
      # empty_ctx self_uri is workspace://x; the user is in team-alpha.
      assert {:error, {:cross_workspace_user, _}} =
               WUA.handle_disable_user(%{user_uri: "entity://team-alpha/user/y"}, empty_ctx())
    end

    test "missing caller (actor) fails closed with :missing_actor" do
      ctx = %{empty_ctx() | self_uri: Ezagent.URI.new!("workspace://team-alpha")}

      assert {:error, :missing_actor} =
               WUA.handle_disable_user(%{user_uri: "entity://team-alpha/user/y"}, ctx)
    end

    test "an operator cannot disable their OWN account (self-lockout guard)" do
      self_uri = "entity://team-alpha/user/me"

      ctx = %{
        empty_ctx()
        | self_uri: Ezagent.URI.new!("workspace://team-alpha"),
          caller: Ezagent.URI.new!(self_uri)
      }

      assert {:error, :self_offboard_denied} =
               WUA.handle_disable_user(%{user_uri: self_uri}, ctx)
    end
  end
end
