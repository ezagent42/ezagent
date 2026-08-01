defmodule Ezagent.E2E.Category05.Scenario14GrantCapActionAxisTest do
  @moduledoc """
  E2E scenario 14 — Grant cap via LV (action-axis).

  Cross-references `docs/scenarios/14-grant-cap-action-axis/scenario.md`.

  This file exercises the **structural** invariants of the 5-axis cap
  shape `{kind, behavior, action, instance, workspace_uri}` from a
  caller's perspective:

  - Narrow grant authorizes ONLY the intended action.
  - Narrow grant denies adjacent actions on the same Behavior.
  - Narrow grant denies adjacent instances (different session).
  - Narrow grant denies adjacent behaviors.
  - Wildcards (`:any`) on each axis broaden correctly.
  - `granted_by` / `granted_at` provenance does not change matcher semantics.

  Verification surface (per `feedback_esr_e2e_standards`):
  Pure matcher-level invariants — no LV / Feishu / agent surface in this
  file. The LV grant form, mid-tier serialization, and snapshot round-trip
  are covered by sibling integration tests (cited in scenario.md
  cross-references). This file is the "structural cap-axis E2E gate"
  Phase 2 Behavior migrations must regression-pass.

  Scenario `scenario: "14-grant-cap-action-axis"` (per moduletag).
  """

  use ExUnit.Case, async: true

  import Ezagent.Test.CapHelper

  alias Ezagent.Capability

  @moduletag scenario: "14-grant-cap-action-axis"

  @system_ws URI.new!("workspace://system")
  @tenant_ws URI.new!("workspace://team-alpha")
  @session_a URI.new!("session://team-alpha/default/sess_a")
  @session_b URI.new!("session://team-alpha/default/sess_b")

  describe "narrow grant — action axis enforced" do
    test "narrow `:send` cap matches `:send` needed (positive control)" do
      held =
        cap(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :send,
          instance: @session_a,
          workspace_uri: @tenant_ws
        )

      needed =
        needed(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :send,
          instance: @session_a,
          workspace_uri: @tenant_ws
        )

      assert Capability.matches?(held, needed),
             "narrow `:send` cap MUST authorize `:send` dispatch — that's the cap's purpose"
    end

    test "narrow `:send` cap REJECTS `:join` (sibling action on Chat)" do
      held =
        cap(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :send,
          instance: @session_a,
          workspace_uri: @tenant_ws
        )

      needed =
        needed(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :join,
          instance: @session_a,
          workspace_uri: @tenant_ws
        )

      refute Capability.matches?(held, needed),
             "narrow `:send` MUST NOT cross the action axis to `:join` — this is the SPEC 2026-05-27 invariant"
    end

    test "narrow `:send` cap REJECTS `:receive` (another sibling action)" do
      held =
        cap(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :send,
          instance: @session_a,
          workspace_uri: @tenant_ws
        )

      needed =
        needed(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :receive,
          instance: @session_a,
          workspace_uri: @tenant_ws
        )

      refute Capability.matches?(held, needed)
    end
  end

  describe "narrow grant — instance axis enforced" do
    test "session-scoped cap REJECTS dispatch on a different session" do
      held =
        cap(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :send,
          instance: @session_a,
          workspace_uri: @tenant_ws
        )

      needed =
        needed(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :send,
          instance: @session_b,
          workspace_uri: @tenant_ws
        )

      refute Capability.matches?(held, needed),
             "instance-narrow cap on session_a MUST NOT authorize session_b — same workspace, sibling session"
    end

    test "wildcard `:any` instance authorizes ANY session under the same workspace" do
      held =
        cap(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :send,
          instance: :any,
          workspace_uri: @tenant_ws
        )

      for inst <- [@session_a, @session_b] do
        needed =
          needed(
            kind: :session,
            behavior: Ezagent.ActionSet.Session,
            action: :send,
            instance: inst,
            workspace_uri: @tenant_ws
          )

        assert Capability.matches?(held, needed),
               "instance-wildcard cap MUST authorize `#{URI.to_string(inst)}`"
      end
    end
  end

  describe "narrow grant — behavior axis enforced" do
    test "Chat cap REJECTS Routing dispatch (different behavior)" do
      held =
        cap(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :send,
          instance: @session_a,
          workspace_uri: @tenant_ws
        )

      needed =
        needed(
          kind: :session,
          behavior: Ezagent.ActionSet.Routing,
          action: :add_rule,
          instance: @session_a,
          workspace_uri: @tenant_ws
        )

      refute Capability.matches?(held, needed),
             "Chat cap MUST NOT authorize Routing — behavior axis is load-bearing"
    end
  end

  describe "narrow grant — workspace axis enforced" do
    test "tenant-scoped cap REJECTS dispatch under workspace://system" do
      held =
        cap(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :send,
          instance: @session_a,
          workspace_uri: @tenant_ws
        )

      # Same action/behavior/instance but workspace_uri differs.
      needed =
        needed(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :send,
          instance: @session_a,
          workspace_uri: @system_ws
        )

      refute Capability.matches?(held, needed),
             "team-alpha cap MUST NOT authorize dispatch labelled workspace://system"
    end
  end

  describe "admin invariant — structural superset (Decision #81)" do
    test "admin's 5-axis wildcard cap matches every concrete needed" do
      # The exact shape `Ezagent.SystemPrincipal.caps/1` mints for the
      # bootstrap admin per `Capability.admin_invariant?/1`.
      admin =
        %Capability{
          kind: :any,
          behavior: :any,
          action: :any,
          instance: :any,
          workspace_uri: :any,
          granted_by: Ezagent.URI.user(:system, :admin),
          granted_at: ~U[2026-01-01 00:00:00Z]
        }

      assert Capability.admin_invariant?(admin),
             "the admin invariant must be structurally recognized — Decision #81 chokepoint"

      # Sample 5 distinct (kind, behavior, action, instance, workspace) tuples
      # — admin must authorize every one.
      cases = [
        {:session, Ezagent.ActionSet.Session, :send, @session_a, @tenant_ws},
        {:session, Ezagent.ActionSet.Routing, :add_rule, @session_b, @system_ws},
        {:workspace, Ezagent.ActionSet.Workspace, :add_member, @tenant_ws, @tenant_ws},
        {:user, Ezagent.ActionSet.Identity, :grant_cap, @session_a, @system_ws},
        {:any, :any, :any, @session_b, :any}
      ]

      for {k, b, a, i, w} <- cases do
        n = needed(kind: k, behavior: b, action: a, instance: i, workspace_uri: w)
        assert Capability.matches?(admin, n), "admin must authorize #{inspect(n)}"
      end
    end

    test "admin invariant cannot be revoked via `revoke/2`" do
      admin =
        %Capability{
          kind: :any,
          behavior: :any,
          action: :any,
          instance: :any,
          workspace_uri: :any,
          granted_by: Ezagent.URI.user(:system, :admin),
          granted_at: ~U[2026-01-01 00:00:00Z]
        }

      held = MapSet.new([admin])

      assert {:error, :cannot_revoke_admin} = Capability.revoke(held, admin),
             "revoke MUST refuse to delete the structural admin cap — Decision #81 chokepoint"
    end
  end

  describe "revoke parity — identity tuple match" do
    test "revoke removes a cap by identity tuple, ignoring provenance" do
      held_cap =
        cap(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :send,
          instance: @session_a,
          workspace_uri: @tenant_ws,
          granted_at: ~U[2026-05-01 10:00:00Z]
        )

      # Revoke target arrives via a different code path (e.g. CLI input
      # round-tripped through `normalize!/2`); same identity tuple, fresh
      # granted_at.
      revoke_target =
        cap(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :send,
          instance: @session_a,
          workspace_uri: @tenant_ws,
          granted_at: DateTime.utc_now()
        )

      held = MapSet.new([held_cap])
      assert {:ok, new_held} = Capability.revoke(held, revoke_target)

      assert MapSet.size(new_held) == 0,
             "revoke MUST match on identity tuple — provenance divergence must not silently no-op (codex HIGH-1 fix 2026-05-26)"
    end

    test "revoke is idempotent — re-revoking returns :ok with no change" do
      held = MapSet.new([])

      target =
        cap(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :send,
          instance: @session_a,
          workspace_uri: @tenant_ws
        )

      assert {:ok, ^held} = Capability.revoke(held, target)
    end

    test "revoke preserves OTHER caps with different identity tuples" do
      keeper =
        cap(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :join,
          instance: @session_a,
          workspace_uri: @tenant_ws
        )

      victim =
        cap(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :send,
          instance: @session_a,
          workspace_uri: @tenant_ws
        )

      held = MapSet.new([keeper, victim])
      assert {:ok, new_held} = Capability.revoke(held, victim)

      assert MapSet.size(new_held) == 1
      assert MapSet.member?(new_held, keeper), "non-target cap MUST be preserved"
    end
  end

  describe "serialization round-trip preserves action axis" do
    test "to_map/from_map round-trip keeps `:action`" do
      original =
        cap(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :send,
          instance: @session_a,
          workspace_uri: @tenant_ws
        )

      json_map = Capability.to_map(original)
      assert json_map["action"] == "send"

      restored = Capability.from_map(json_map)
      assert restored.action == :send
      assert restored.kind == :session
      assert restored.behavior == Ezagent.ActionSet.Session

      # Behavioral equivalence — the restored cap must match the same
      # needed shapes as the original.
      needed =
        needed(
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :send,
          instance: @session_a,
          workspace_uri: @tenant_ws
        )

      assert Capability.matches?(restored, needed)
    end

    test "from_map rejects a missing `action` key" do
      incomplete_map = %{
        "kind" => "session",
        "behavior" => "Ezagent.ActionSet.Session",
        "instance" => URI.to_string(@session_a),
        "workspace_uri" => URI.to_string(@tenant_ws),
        "granted_by" => "entity://system/user/admin",
        "granted_at" => "2026-05-01T00:00:00Z"
      }

      assert_raise KeyError, fn -> Capability.from_map(incomplete_map) end
    end
  end
end
