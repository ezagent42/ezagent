defmodule Ezagent.Integration.CapActionAxisInvariantTest do
  @moduledoc """
  SPEC 2026-05-27 capability-action-axis §5 B1 + B2 — **THE MERGE GATE
  TEST**.

  This is the invariant test that proves the bug PR #408 round-3
  surfaced is structurally fixed: a workspace member with a narrow
  `Behavior.Workspace :create_session` cap MUST NOT also satisfy the
  cap-check for `:add_member` (the over-grant the cap struct's missing
  action axis silently produced).

  Per `feedback_completion_requires_invariant_test`: a phase claim of
  "done" is only valid when an invariant test fails when the
  architectural goal is unmet. This test is THE GATE — if it ever
  passes against a Capability struct that discards the action axis,
  the merge is unsafe.

  B1: workspace member with `:create_session` cap is DENIED `:add_member`.
  B2: same member, same cap, `:create_session` is ALLOWED.

  Async-safe at the matcher level: this test exercises the structural
  matcher contract via `Capability.matches?/2` against the cap shapes
  the production dispatch step 5.5 builds. We do NOT spin up a full
  Workspace Kind + Identity slice here — that's covered by integration
  tests like `create_session_dispatch_test.exs`. The B1/B2 invariant
  is a pure-data contract: the matcher MUST reject narrow caps for
  wrong actions.
  """

  use ExUnit.Case, async: true

  alias Ezagent.Capability

  @workspace_uri URI.new!("workspace://team-alpha")
  @other_user_uri URI.new!("entity://team-alpha/user/member-2")

  describe "B1 (THE MERGE GATE) — workspace member with :create_session does NOT satisfy :add_member" do
    test "narrow :create_session cap is REJECTED for :add_member dispatch" do
      # Setup: the member holds exactly ONE cap, narrow to :create_session
      # on Behavior.Workspace in the workspace.
      member_cap = %Capability{
        kind: :workspace,
        behavior: Ezagent.ActionSet.Workspace,
        action: :create_session,
        instance: @workspace_uri,
        workspace_uri: @workspace_uri,
        granted_by: URI.new!("system://template-materialize"),
        granted_at: DateTime.utc_now()
      }

      # The needed-cap shape dispatch step 5.5 builds when a caller
      # dispatches `workspace.add_member` on the workspace:
      #
      #   target = URI.new!("workspace://team-alpha?action=workspace.add_member")
      #   needed = cap_for_action(Ezagent.Entity.Workspace, :add_member, target)
      #
      # The needed map has `action: :add_member`. The member's cap has
      # `action: :create_session`. The matcher MUST reject.
      needed_for_add_member = %{
        kind: :workspace,
        behavior: Ezagent.ActionSet.Workspace,
        action: :add_member,
        instance: @workspace_uri,
        workspace_uri: @workspace_uri
      }

      # THE GATE — if this passes, the action axis is broken.
      refute Capability.matches?(member_cap, needed_for_add_member),
             """
             THE MERGE GATE: workspace member with a `:create_session` cap MUST NOT
             satisfy `:add_member`'s cap-check. This is the PR #408 round-3
             over-grant bug — the matcher's pre-SPEC `kind × behavior × instance ×
             workspace_uri` 4-axis match silently discarded the action atom, so
             any Behavior.Workspace cap on the workspace passed the cap-check for
             every Behavior.Workspace action.

             If this test FAILS, the action axis is not load-bearing — `matches?/2`
             is matching too broadly. Check:
               1. `Capability.matches?/2` reads `action_of(cap)` for the cap axis
               2. The needed-map's `:action` is the dispatched action atom
               3. `field_match?/2` requires equality OR `:any` (no other wildcard).

             SPEC 2026-05-27 capability-action-axis §5 B1 — completion gate.
             """

      # Defense-in-depth: also check `:remove_member`, `:set_routing_rules`,
      # `:create_agent` — every Behavior.Workspace action OTHER than
      # `:create_session` MUST be rejected by the narrow cap.
      for action <- [
            :add_member,
            :remove_member,
            :set_routing_rules,
            :create_agent,
            :list_members,
            :add_template,
            :remove_template,
            :list_templates,
            :list_routing_rules,
            :instantiate
          ] do
        needed = %{
          kind: :workspace,
          behavior: Ezagent.ActionSet.Workspace,
          action: action,
          instance: @workspace_uri,
          workspace_uri: @workspace_uri
        }

        refute Capability.matches?(member_cap, needed),
               "narrow :create_session cap MUST NOT satisfy `Behavior.Workspace :#{action}`'s cap-check (B1 defense-in-depth — every other action axis must reject)"
      end
    end

    test "non-member URI in args is irrelevant — cap check fires on action axis alone" do
      # Sanity check: the `args` field (e.g. `%{member: other_user_uri}`)
      # is part of the dispatched invocation but NOT part of the cap
      # match. The matcher operates over the needed-cap shape only.
      _ = @other_user_uri

      member_cap = %Capability{
        kind: :workspace,
        behavior: Ezagent.ActionSet.Workspace,
        action: :create_session,
        instance: @workspace_uri,
        workspace_uri: @workspace_uri,
        granted_by: URI.new!("system://template-materialize"),
        granted_at: DateTime.utc_now()
      }

      needed_for_add_member = %{
        kind: :workspace,
        behavior: Ezagent.ActionSet.Workspace,
        action: :add_member,
        instance: @workspace_uri,
        workspace_uri: @workspace_uri
      }

      refute Capability.matches?(member_cap, needed_for_add_member)
    end
  end

  describe "B2 — same member, same cap → :create_session is ALLOWED" do
    test "narrow :create_session cap MATCHES the :create_session needed-cap" do
      member_cap = %Capability{
        kind: :workspace,
        behavior: Ezagent.ActionSet.Workspace,
        action: :create_session,
        instance: @workspace_uri,
        workspace_uri: @workspace_uri,
        granted_by: URI.new!("system://template-materialize"),
        granted_at: DateTime.utc_now()
      }

      needed_for_create_session = %{
        kind: :workspace,
        behavior: Ezagent.ActionSet.Workspace,
        action: :create_session,
        instance: @workspace_uri,
        workspace_uri: @workspace_uri
      }

      assert Capability.matches?(member_cap, needed_for_create_session),
             "narrow :create_session cap MUST authorize :create_session dispatch — that's the cap's intended purpose; without this match, the SPEC fix would over-narrow (B2 positive control)"
    end

    test "wildcard HELD cap matches concrete NEEDED action (held-side :any)" do
      # The matcher semantic is asymmetric (and correctly so): a HELD
      # `:any` is the wildcard authorization ("I can do any action");
      # a NEEDED concrete is the dispatch demand. The matcher succeeds
      # when held authorizes needed. A NEEDED `:any` doesn't occur at
      # the dispatch chokepoint (dispatch always passes the concrete
      # action being dispatched).
      wildcard_held = %Capability{
        kind: :workspace,
        behavior: Ezagent.ActionSet.Workspace,
        action: :any,
        instance: @workspace_uri,
        workspace_uri: @workspace_uri,
        granted_by: URI.new!("system://template-materialize"),
        granted_at: DateTime.utc_now()
      }

      needed_concrete = %{
        kind: :workspace,
        behavior: Ezagent.ActionSet.Workspace,
        action: :create_session,
        instance: @workspace_uri,
        workspace_uri: @workspace_uri
      }

      assert Capability.matches?(wildcard_held, needed_concrete),
             "an action-wildcard HELD cap MUST authorize any concrete NEEDED action — that's the wildcard semantic this SPEC preserves for system principals and admin caps"
    end
  end
end
