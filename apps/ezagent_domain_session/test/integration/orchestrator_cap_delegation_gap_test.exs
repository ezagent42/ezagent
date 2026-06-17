defmodule EzagentDomainInstanceMessage.Integration.OrchestratorCapDelegationGapTest do
  @moduledoc """
  PR-a (SPEC `docs/superpowers/specs/2026-06-16-dynamic-mount-unmount-entity-model.md`
  §6) — DEFERRAL evidence.

  §6 asks `Orchestrator.Caps` to be migrated off the
  `system://template-materialize` + owner-as-caller workaround onto the new
  manager-delegated `grant_cap` path (caller = owner, `ctx.caps` = owner's
  REAL caps). PR-a does NOT make that migration, because it is structurally
  infeasible for a non-admin session owner: the orchestrator's scoped cap #2
  (`cap(:agent, :any, :any, {:spawned_by, orch}, ws)`) is covered by NO cap a
  non-admin owner holds — not its default session cap, not its
  OrchestratorAdmin :restart cap, and NOT even the §5 Manage cap over the
  orchestrator (a CONCRETE-behavior Manage cap cannot, by the asymmetric
  `Capability.Match`, authorize a `behavior: :any` request). The authority
  cap #2 needs lives ONLY in `system://template-materialize`.

  This test pins that fact so a future migration attempt sees it fail by
  construction (and so the spec's incorrect premise — "naive migration fails
  `:grant_not_owner`" — is corrected: caps #1/#2 never reach the
  resolved-owner branch; they hinge on workspace-admin / delegation, not
  data-ownership).

  When §6 is unblocked (Allen rules on the authority gap — e.g. grant the
  owner a broader delegable cap, or keep cap #2 minted under the system
  principal), DELETE this test and replace it with the real parity test.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability

  @workspace_uri URI.new!("workspace://team-alpha")

  test "non-admin owner holds NO cap covering orchestrator scoped cap #2 (agent/spawned_by), even with the §5 Manage cap" do
    owner = URI.new!("entity://team-alpha/user/alice")
    session_uri = URI.new!("session://team-alpha/default/s1")
    orch = URI.new!("entity://team-alpha/agent/cc_orchestrator-s1")

    owner_caps =
      Ezagent.Entity.User.default_caps(@workspace_uri) ++
        [
          %Capability{
            kind: :session,
            behavior: Ezagent.Behavior.OrchestratorAdmin,
            action: :restart,
            instance: session_uri,
            workspace_uri: @workspace_uri,
            granted_by: owner,
            granted_at: DateTime.utc_now()
          },
          # §5 — the Manage cap PR-a now grants the owner over the orchestrator.
          Ezagent.CreatorGrant.manage_cap(:agent, orch, @workspace_uri, owner)
        ]

    # Orchestrator scoped cap #1 — cap(:session, :any, :any, {:within_session}, ws).
    needed_cap1 = %{
      kind: :session,
      behavior: :any,
      action: :any,
      instance: {:within_session, session_uri},
      workspace_uri: @workspace_uri
    }

    # Orchestrator scoped cap #2 — cap(:agent, :any, :any, {:spawned_by}, ws).
    needed_cap2 = %{
      kind: :agent,
      behavior: :any,
      action: :any,
      instance: {:spawned_by, orch},
      workspace_uri: @workspace_uri
    }

    cap1_delegable = Enum.any?(owner_caps, &Capability.matches?(&1, needed_cap1))
    cap2_delegable = Enum.any?(owner_caps, &Capability.matches?(&1, needed_cap2))

    # Cap #1 IS delegable (the default session/:any/:any/:any/ws cap covers a
    # within-session-scoped request) — so a placement-broadened manager check
    # COULD authorize it. Documented for the future §6 design.
    assert cap1_delegable,
           "expected the owner's default session cap to cover orchestrator cap #1"

    # Cap #2 is NOT delegable by ANY owner cap — the structural blocker.
    refute cap2_delegable,
           "orchestrator cap #2 (agent/:any/{:spawned_by}) must NOT be authorizable by " <>
             "any non-admin owner cap, incl the §5 Manage cap — this is why §6 owner-" <>
             "delegation migration is infeasible and is DEFERRED in PR-a"
  end
end
