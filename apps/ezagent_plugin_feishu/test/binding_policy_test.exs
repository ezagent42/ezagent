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
  (Chat: `:send / :join / :leave`; Publisher.SessionImpl:
  `:subscribe_from / :snapshot / :history`). Each cap carries a
  concrete action atom — `check_action_wildcard_grant_authorized/2`
  passes (the `action: :any` clause is the only rejection path).

  ## Codex r1 HIGH-1 fix — iterate production, not a fixture

  Prior version of this test hard-coded an `expected_caps/1` fixture
  that paralleled `BindingPolicy.session_participation_caps/1`. A
  contributor reverting BindingPolicy to a single `action: :any` cap
  would leave the FIXTURE unchanged, so the §3.6.1(b) check on
  fixture entries would still pass — the regression test would
  silently lose its teeth.

  This revision pulls the cap list FROM the production module via
  `BindingPolicy.caps_for_apply/1` (a `@doc false` test seam). Now
  a revert that re-introduces `action: :any` makes the per-cap
  grant-boundary assertion fail; an additive grant of a new
  Behavior/action drives the explicit shape assertions to fail.

  These tests call the standalone `IdentityAdmin.handle_grant_cap/2`
  handler (no Kind spawning, no DB sandbox sharing) so they pin the
  §3.6.1(b) invariant without coupling to the full
  dispatch-and-spawn integration path. (Pre-Lifecycle-migration this was
  `IdentityAdmin.invoke(:grant_cap, slice, args, ctx)`; the retired
  `invoke/4` Behavior callback is gone — Phase C — and the handler is
  now the `handle_<action>(args, ctx)` clause the dispatch path calls.
  The slice is supplied to the handler through `ctx[:read]`, matching
  the runtime.) The end-to-end integration is exercised by the mix task
  `apps/ezagent_plugin_feishu/lib/mix/tasks/ezagent.feishu.bind.ex`.

  ## What this test gates against

  * Reverting BindingPolicy to a single behavior-wildcard cap →
    `:wildcard_action_grant_requires_admin_authority` surfaces on
    iteration of the production grant list.
  * Adding a new `(Behavior, action)` to the production grants
    without auditing — the shape-assertion tests fail because the
    sorted action lists won't match the pinned expectations.
  * Granting an `action: :any` cap from the BindingPolicy site —
    the action-axis assertion fails (no cap in the production list
    is allowed to have `action: :any`).
  """
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.IdentityAdmin
  alias Ezagent.Capability
  alias EzagentPluginFeishu.BindingPolicy

  @workspace_uri URI.parse("workspace://team-alpha")
  @binding_policy_uri URI.parse("system://feishu-binding-policy")

  # Pinned action expectations. These MUST match
  # `BindingPolicy.@session_chat_actions` and
  # `@session_publisher_actions`. The drift-detection test below
  # asserts the production module's caps_for_apply/1 output yields
  # exactly these action sets — a contributor changing one without
  # the other gets a loud failure here.
  @expected_chat_actions [:send, :join, :leave]
  @expected_publisher_actions [:subscribe_from, :snapshot, :history]

  # The runtime caps held by the `system://feishu-binding-policy`
  # principal at dispatch time — narrow, NOT admin shape. Matches the
  # `Ezagent.SystemPrincipal.Catalog` entry.
  defp binding_policy_ctx(slice \\ %{caps: MapSet.new()}) do
    %{
      caller: @binding_policy_uri,
      caps: Ezagent.SystemPrincipal.caps("system://feishu-binding-policy"),
      # The Lifecycle handler reads its slice via `ctx[:read]` (the
      # runtime injects this closure). The §3.6.1(b) rejection paths
      # return BEFORE any read, but supply it so the success branch is
      # also exercisable with the same shape the runtime uses.
      read: fn key, default -> Map.get(slice, key, default) end
    }
  end

  defp production_caps, do: BindingPolicy.caps_for_apply(@workspace_uri)

  describe "§3.6.1(b) grant-boundary regression" do
    test "every cap the production module would grant passes the action-wildcard check under the non-admin principal" do
      caps = production_caps()

      # Sanity — the production module must actually emit some caps
      # for a real workspace, else we'd be asserting nothing.
      assert caps != []

      for cap <- caps do
        result =
          IdentityAdmin.handle_grant_cap(%{cap: cap}, binding_policy_ctx())

        refute match?({:error, :wildcard_action_grant_requires_admin_authority}, result),
               "Cap #{inspect(cap)} hit §3.6.1(b) — the binding-policy non-admin " <>
                 "principal cannot grant action-wildcard caps. result=#{inspect(result)}"
      end
    end

    test "the legacy single behavior-wildcard cap is correctly rejected (positive sanity)" do
      # Pre-fix shape: ONE cap with `behavior: :any, action: :any` —
      # the §3.6.1(b) check must reject this under the binding-policy
      # principal. If a future contributor reverts BindingPolicy to
      # this shape, the iteration test above also fails (now sourced
      # from production). This positive sanity verifies the gate
      # itself still works.
      legacy_cap = %Capability{
        kind: :session,
        behavior: :any,
        action: :any,
        instance: :any,
        workspace_uri: @workspace_uri,
        granted_by: @binding_policy_uri,
        granted_at: ~U[2026-01-01 00:00:00Z]
      }

      assert {:error, :wildcard_action_grant_requires_admin_authority} =
               IdentityAdmin.handle_grant_cap(
                 %{cap: legacy_cap},
                 binding_policy_ctx()
               )
    end
  end

  describe "production cap-list shape (iterated from BindingPolicy.caps_for_apply/1)" do
    test "every production cap carries a CONCRETE action atom (never :any)" do
      for cap <- production_caps() do
        assert cap.action != :any,
               "Every BindingPolicy cap must carry a concrete action atom (§3.6.1(b)); " <>
                 "got: #{inspect(cap)}"
      end
    end

    test "Chat caps cover exactly the pinned action set" do
      chat_caps = Enum.filter(production_caps(), &(&1.behavior == Ezagent.Behavior.Chat))
      chat_actions = chat_caps |> Enum.map(& &1.action) |> Enum.sort()

      assert chat_actions == Enum.sort(@expected_chat_actions),
             "BindingPolicy Chat actions drifted from pinned expectation " <>
               "#{inspect(@expected_chat_actions)}; got: #{inspect(chat_actions)}"
    end

    test "Publisher.SessionImpl caps cover exactly the pinned action set" do
      publisher_caps =
        Enum.filter(production_caps(), &(&1.behavior == Ezagent.Behavior.Publisher.SessionImpl))

      publisher_actions = publisher_caps |> Enum.map(& &1.action) |> Enum.sort()

      assert publisher_actions == Enum.sort(@expected_publisher_actions),
             "BindingPolicy Publisher.SessionImpl actions drifted from pinned " <>
               "expectation #{inspect(@expected_publisher_actions)}; got: " <>
               inspect(publisher_actions)
    end

    test "Chat :set_working_copy is NOT granted (orchestrator-only)" do
      chat_actions =
        production_caps()
        |> Enum.filter(&(&1.behavior == Ezagent.Behavior.Chat))
        |> Enum.map(& &1.action)

      refute :set_working_copy in chat_actions,
             "BindingPolicy must NOT grant Chat :set_working_copy (orchestrator-only action " <>
               "gated by working_copy_write_authorized?/1)"
    end

    test "Chat :receive is NOT granted (registered on User/Agent Kinds, not Session)" do
      chat_actions =
        production_caps()
        |> Enum.filter(&(&1.behavior == Ezagent.Behavior.Chat))
        |> Enum.map(& &1.action)

      refute :receive in chat_actions,
             "BindingPolicy must NOT grant Chat :receive on :session Kind — " <>
               ":receive is registered on User/Agent Kinds " <>
               "(see ezagent_domain_chat/application.ex:609-610); the dispatch " <>
               "fan-out runs under system://chat-router caps, not the bound user's caps. " <>
               "A :session-Kind :receive cap is structurally dead weight."
    end

    test "NO ExternalMirror caps are granted (admin-only)" do
      external_mirror_caps =
        Enum.filter(production_caps(), &(&1.behavior == Ezagent.Behavior.ExternalMirror))

      assert external_mirror_caps == [],
             "BindingPolicy must not grant ExternalMirror caps (admin-only); got: " <>
               inspect(external_mirror_caps)
    end

    test "every production cap is workspace-scoped to the caller's workspace (not :any-workspace)" do
      for cap <- production_caps() do
        assert cap.workspace_uri == @workspace_uri,
               "Every cap must carry the bound user's workspace_uri; got: #{inspect(cap)}"
      end
    end

    test "every production cap has kind: :session" do
      # Session-participation grants live on the :session Kind axis.
      # If a contributor adds a User-Kind grant (e.g. :receive on User
      # for some reason), they must update this assertion + audit the
      # action set.
      for cap <- production_caps() do
        assert cap.kind == :session,
               "Every cap must be kind: :session; got: #{inspect(cap)}"
      end
    end

    test "granted_by is the binding-policy system principal (not the operator)" do
      for cap <- production_caps() do
        assert cap.granted_by == @binding_policy_uri,
               "granted_by must be the binding-policy system principal for provenance; " <>
                 "got: #{inspect(cap.granted_by)}"
      end
    end
  end

  describe "source-of-truth sync (test fixture ↔ production module ↔ Behavior actions/0)" do
    # If the production module's action lists diverge from this test's
    # pinned expectations, the per-Behavior shape tests already fire.
    # These additional drift checks gate against silently widening
    # past a Behavior's actual `actions/0` list (e.g. typo'd action
    # atom that compiles but never matches at dispatch).

    test "pinned chat actions are a subset of Ezagent.Behavior.Chat.actions/0" do
      assert MapSet.subset?(
               MapSet.new(@expected_chat_actions),
               MapSet.new(Ezagent.Behavior.Chat.actions())
             ),
             "Pinned Chat action set is no longer a subset of " <>
               "Ezagent.Behavior.Chat.actions/0 — re-audit the grant list"
    end

    test "pinned publisher actions exactly equal Publisher.SessionImpl.actions/0" do
      assert Enum.sort(@expected_publisher_actions) ==
               Enum.sort(Ezagent.Behavior.Publisher.SessionImpl.actions()),
             "Pinned Publisher.SessionImpl action set drifted from " <>
               "Publisher.SessionImpl.actions/0"
    end
  end
end
