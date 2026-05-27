defmodule EzagentPluginFeishu.BindingPolicyTest do
  @moduledoc """
  Regression test for SPEC 2026-05-27 capability-action-axis §3.6.1(b).

  `BindingPolicy.apply/2` dispatches `identity.grant_cap` under
  `system://feishu-binding-policy` — a non-admin system principal.
  Pre-fix the policy re-granted `User.default_caps/1`'s single
  `kind: :session, behavior: :any, action: :any, instance: :any` cap,
  which §3.6.1(b)'s runtime grant-boundary check
  (`IdentityAdmin.check_action_wildcard_grant_authorized/2`) refused
  with `:wildcard_action_grant_requires_admin_authority`.

  Post-fix the policy grants ONE cap per `(Behavior, action)` pair
  (Chat: `:send / :receive / :join / :leave`; Publisher.SessionImpl:
  `:subscribe_from / :snapshot / :history`). Each cap carries a
  concrete action atom — `check_action_wildcard_grant_authorized/2`
  passes (the `action: :any` clause is the only rejection path).

  These tests use the standalone `IdentityAdmin.invoke(:grant_cap, ...)`
  surface (no Kind spawning, no DB sandbox sharing) so they pin the
  §3.6.1(b) invariant without coupling to the full
  dispatch-and-spawn integration path. The end-to-end integration is
  exercised by `apps/ezagent_plugin_feishu/test/integration/...` +
  the mix task at `apps/ezagent_plugin_feishu/lib/mix/tasks/ezagent.feishu.bind.ex`.

  ## What this test gates against

  A future contributor reverting BindingPolicy to a single behavior-
  wildcard cap (the legacy `User.default_caps/1` shape) re-introduces
  the §3.6.1(b) violation. The assertions below fail in that case
  (a) by detecting `action: :any` caps in the constructed list, and
  (b) by surfacing the `:wildcard_action_grant_requires_admin_authority`
  return from a binding-policy-context grant attempt.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.IdentityAdmin
  alias Ezagent.Capability

  @workspace_uri URI.parse("workspace://team-alpha")
  @binding_policy_uri URI.parse("system://feishu-binding-policy")

  # The cap shapes BindingPolicy.apply/2 is expected to grant. Pulled
  # from the source module's `@session_chat_actions` /
  # `@session_publisher_actions` lists at compile time so a contributor
  # cannot change one without touching the other (CI ought to flag).
  defp expected_chat_actions, do: [:send, :receive, :join, :leave]
  defp expected_publisher_actions, do: [:subscribe_from, :snapshot, :history]

  # Build the caps BindingPolicy.apply/2 grants for a given workspace.
  # Mirrors the private helper in BindingPolicy; kept in test fixture
  # rather than calling the private fn directly so the test is
  # explicit about the shape it expects (and a future contributor
  # changing the helper has to update this list too).
  defp expected_caps(workspace_uri) do
    granted_by = @binding_policy_uri
    granted_at = ~U[2026-01-01 00:00:00Z]

    chat =
      for action <- expected_chat_actions() do
        %Capability{
          kind: :session,
          behavior: Ezagent.Behavior.Chat,
          action: action,
          instance: :any,
          workspace_uri: workspace_uri,
          granted_by: granted_by,
          granted_at: granted_at
        }
      end

    publisher =
      for action <- expected_publisher_actions() do
        %Capability{
          kind: :session,
          behavior: Ezagent.Behavior.Publisher.SessionImpl,
          action: action,
          instance: :any,
          workspace_uri: workspace_uri,
          granted_by: granted_by,
          granted_at: granted_at
        }
      end

    chat ++ publisher
  end

  # The runtime caps held by the `system://feishu-binding-policy`
  # principal at dispatch time — narrow, NOT admin shape. Matches the
  # `Ezagent.SystemPrincipal.Catalog` entry.
  defp binding_policy_ctx do
    %{
      caller: @binding_policy_uri,
      caps: Ezagent.SystemPrincipal.caps("system://feishu-binding-policy")
    }
  end

  describe "§3.6.1(b) grant-boundary regression" do
    test "every cap BindingPolicy grants passes the action-wildcard check under the non-admin principal" do
      empty_slice = %{caps: MapSet.new()}

      for cap <- expected_caps(@workspace_uri) do
        result =
          IdentityAdmin.invoke(:grant_cap, empty_slice, %{cap: cap}, binding_policy_ctx())

        refute match?({:error, :wildcard_action_grant_requires_admin_authority}, result),
               "Cap #{inspect(cap)} hit §3.6.1(b) — the binding-policy non-admin " <>
                 "principal cannot grant action-wildcard caps. result=#{inspect(result)}"
      end
    end

    test "the legacy single behavior-wildcard cap is correctly rejected (positive sanity)" do
      # Pre-fix shape: ONE cap with `behavior: :any, action: :any` —
      # the §3.6.1(b) check must reject this under the binding-policy
      # principal. If a future contributor reverts BindingPolicy to
      # this shape, the rejection still fires and the negative test
      # above stays meaningful.
      legacy_cap = %Capability{
        kind: :session,
        behavior: :any,
        action: :any,
        instance: :any,
        workspace_uri: @workspace_uri,
        granted_by: @binding_policy_uri,
        granted_at: ~U[2026-01-01 00:00:00Z]
      }

      empty_slice = %{caps: MapSet.new()}

      assert {:error, :wildcard_action_grant_requires_admin_authority} =
               IdentityAdmin.invoke(
                 :grant_cap,
                 empty_slice,
                 %{cap: legacy_cap},
                 binding_policy_ctx()
               )
    end
  end

  describe "cap shape" do
    test "every Chat cap carries a CONCRETE action atom (never :any)" do
      caps = expected_caps(@workspace_uri)
      chat_caps = Enum.filter(caps, &(&1.behavior == Ezagent.Behavior.Chat))

      assert chat_caps != []

      for cap <- chat_caps do
        assert cap.action != :any,
               "Chat cap must carry a concrete action atom (§3.6.1(b)); got: #{inspect(cap)}"

        assert cap.action in expected_chat_actions()
      end
    end

    test "every Publisher.SessionImpl cap carries a CONCRETE action atom" do
      caps = expected_caps(@workspace_uri)

      publisher_caps =
        Enum.filter(caps, &(&1.behavior == Ezagent.Behavior.Publisher.SessionImpl))

      assert publisher_caps != []

      for cap <- publisher_caps do
        assert cap.action != :any,
               "Publisher cap must carry a concrete action atom (§3.6.1(b)); got: #{inspect(cap)}"

        assert cap.action in expected_publisher_actions()
      end
    end

    test "Chat actions cover the user-facing surface but NOT orchestrator-only :set_working_copy" do
      actions = expected_chat_actions()

      # All four user actions Chat.actions/0 advertises minus
      # `:set_working_copy` (orchestrator-only, gated inside
      # `Chat.invoke(:set_working_copy)` via working_copy_write_authorized?/1).
      assert :send in actions
      assert :receive in actions
      assert :join in actions
      assert :leave in actions

      refute :set_working_copy in actions,
             "BindingPolicy must NOT grant :set_working_copy (orchestrator-only action)"
    end

    test "Publisher actions cover read paths" do
      actions = expected_publisher_actions()
      assert :subscribe_from in actions
      assert :snapshot in actions
      assert :history in actions
    end

    test "NO ExternalMirror caps are in the bind grant list" do
      caps = expected_caps(@workspace_uri)

      external_mirror_caps =
        Enum.filter(caps, &(&1.behavior == Ezagent.Behavior.ExternalMirror))

      assert external_mirror_caps == [],
             "BindingPolicy must not grant ExternalMirror caps (admin-only); got: " <>
               inspect(external_mirror_caps)
    end

    test "every cap is workspace-scoped to the bound user's workspace (not :any-workspace)" do
      caps = expected_caps(@workspace_uri)

      for cap <- caps do
        assert cap.workspace_uri == @workspace_uri,
               "Every cap must carry the bound user's workspace_uri; got: #{inspect(cap)}"
      end
    end
  end

  describe "BindingPolicy source-truth sync" do
    # If a contributor renames the action atom list in BindingPolicy
    # without updating this test (or vice versa), the action sets
    # diverge and we want a loud failure here — not a silent under-
    # or over-grant.
    test "test's expected_chat_actions matches a Chat actions/0 subset" do
      assert MapSet.subset?(
               MapSet.new(expected_chat_actions()),
               MapSet.new(Ezagent.Behavior.Chat.actions())
             ),
             "BindingPolicyTest's expected_chat_actions drifted from " <>
               "Ezagent.Behavior.Chat.actions/0 — re-audit the grant list"
    end

    test "test's expected_publisher_actions matches Publisher.SessionImpl actions/0" do
      assert Enum.sort(expected_publisher_actions()) ==
               Enum.sort(Ezagent.Behavior.Publisher.SessionImpl.actions()),
             "BindingPolicyTest's expected_publisher_actions drifted from " <>
               "Publisher.SessionImpl.actions/0"
    end
  end
end
