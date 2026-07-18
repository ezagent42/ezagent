defmodule Ezagent.ActionSet.IdentityManagerDelegatedGrantTest do
  @moduledoc """
  PR-a (SPEC `docs/superpowers/specs/2026-06-16-dynamic-mount-unmount-entity-model.md`
  §1, Decision #88) — the creator/manager-delegated `grant_cap` path.

  These are the synthetic property tests that ARE the consumer of the §1
  control (the orchestrator migration §6 is deferred). They prove the
  fail-closed / delegation-bounded properties of the manager branch directly:

    1. A manager (holds `Manage :any` over the target) can grant a cap whose
       scope IS covered by a cap the manager itself holds → `:ok`, recorded
       with `via_manage: true` provenance.
    2. A manager granting a cap it does NOT hold → fail-closed
       `:grant_not_delegable` (before any write — no `:set` effect).
    3. Asymmetric match: a manager holding a CONCRETE-action cap cannot grant
       a `:any`-action (wildcard) request over the same target.
    4. A wildcard-action cap grant by a non-admin manager is still rejected
       (`check_action_wildcard_grant_authorized` unchanged — admin-only).
    5. A non-manager non-owner non-admin caller is still rejected
       `:grant_not_owner` (the pre-existing branch is unchanged).

  The target behavior is a stub whose `data_owner/1` resolves to a concrete
  `%URI{}` so the cap-to-grant reaches the resolved-owner branch (the only
  branch the manager check lives in).
  """

  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [authority_signed_cap_as!: 4]

  alias Ezagent.ActionSet.IdentityAdmin
  alias Ezagent.{Capability, CapabilityRegistry}

  @workspace_uri URI.new!("workspace://team-alpha")

  # A behavior whose data_owner/1 resolves a concrete %URI{} owner — so a
  # cap scoped to it reaches the `%URI{} = owner` branch of
  # check_grant_authorized/2 (where the manager check lives). The owner is
  # the instance URI itself (the target manages its own slice).
  defmodule OwnedStubBehavior do
    @moduledoc false
    def data_owner(%URI{} = instance), do: instance
    def data_owner(_), do: :no_owner
  end

  # The instance being managed/equipped (a normal entity, NOT the caller).
  defp target_instance, do: URI.new!("entity://team-alpha/agent/widget-1")

  # The manager principal (caller) — NOT the data-owner of the target.
  defp manager_uri, do: URI.new!("entity://team-alpha/user/manager-mona")

  # The Manage cap the manager holds OVER the target — the
  # `CreatorGrant.manage_cap/4` shape: cap(:agent, Manage, :any, target, ws).
  defp manage_cap_over_target do
    Ezagent.CreatorGrant.manage_cap(:agent, target_instance(), @workspace_uri, manager_uri())
  end

  # A concrete cap the manager holds whose SCOPE COVERS the target — used to
  # prove a delegable grant succeeds. The manager holds `cap(:agent,
  # SomeBehavior, :read, :within_workspace, ws)` which covers a concrete
  # `cap(:agent, SomeBehavior, :read, target, ws)` request.
  defp held_delegable_cap(behavior, action) do
    %Capability{
      kind: :agent,
      behavior: behavior,
      action: action,
      instance: {:within_workspace, @workspace_uri},
      workspace_uri: @workspace_uri,
      granted_by: manager_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  # The cap-to-grant: concrete behavior + concrete action over the target.
  defp cap_to_grant(behavior, action) do
    cap = %Capability{
      kind: :agent,
      behavior: behavior,
      action: action,
      instance: target_instance(),
      workspace_uri: @workspace_uri,
      granted_by: manager_uri(),
      granted_at: DateTime.utc_now()
    }

    {:ok, authority} = Ezagent.Cap.Authority.open(target_instance(), :agent)

    authority_signed_cap_as!(
      authority,
      manager_uri(),
      target_instance(),
      cap
    )
  end

  defp ctx_for(caller_caps) do
    %{
      caller: manager_uri(),
      caps: MapSet.new(caller_caps),
      self_uri: target_instance(),
      read: fn :caps, _d -> MapSet.new() end
    }
  end

  defp authorize(caller_caps, cap) do
    CapabilityRegistry.authorize_grant(caller_caps, cap, %{caller: manager_uri()})
  end

  test "manager CAN grant a cap whose scope its held caps cover (via_manage provenance)" do
    cap = cap_to_grant(OwnedStubBehavior, :read)

    # Manager holds: Manage over target + a delegable concrete cap covering it.
    caller_caps = [manage_cap_over_target(), held_delegable_cap(OwnedStubBehavior, :read)]

    assert :ok = authorize(caller_caps, cap)

    {:ok, %{caps: granted}, effects} =
      IdentityAdmin.handle_grant_cap(%{cap: cap}, ctx_for(caller_caps))

    assert Enum.any?(
             granted,
             &match?(%Capability{behavior: OwnedStubBehavior, action: :read}, &1)
           )

    assert {:set, :caps, _} = Enum.find(effects, &match?({:set, :caps, _}, &1))

    # §4 — manager provenance recorded on the emit, NOT the struct.
    assert {:emit, :cap_granted, payload} =
             Enum.find(effects, &match?({:emit, :cap_granted, _}, &1))

    assert payload.via_manage == true
  end

  test "manager CANNOT grant a cap it does not hold → :grant_not_delegable (fail-closed, no write)" do
    cap = cap_to_grant(OwnedStubBehavior, :write)

    # Manager holds Manage over the target, but only a :read delegable cap —
    # NOT :write. The grant of :write must be refused before any write.
    caller_caps = [manage_cap_over_target(), held_delegable_cap(OwnedStubBehavior, :read)]

    assert {:error, :grant_not_delegable} =
             authorize(caller_caps, cap)
  end

  test "delegation is scope-bounded — a held cap scoped to a DIFFERENT instance does not authorize" do
    # The manager holds Manage over the target AND a delegable :read cap, but
    # that delegable cap is scoped to a DIFFERENT concrete instance (not the
    # target, not a covering scope). matches?(held, needed-for-target) is false
    # → the cap-to-grant over the target is not delegable.
    other_instance = URI.new!("entity://team-alpha/agent/other-widget")

    held_elsewhere = %Capability{
      kind: :agent,
      behavior: OwnedStubBehavior,
      action: :read,
      instance: other_instance,
      workspace_uri: @workspace_uri,
      granted_by: manager_uri(),
      granted_at: DateTime.utc_now()
    }

    cap = cap_to_grant(OwnedStubBehavior, :read)
    caller_caps = [manage_cap_over_target(), held_elsewhere]

    assert {:error, :grant_not_delegable} =
             authorize(caller_caps, cap)
  end

  test "asymmetric match (delegation bound) — concrete held cap rejects a :any-action grant over a concrete target" do
    # action: :any over a CONCRETE instance → check_action_wildcard_grant_authorized
    # requires admin (scope_bounded_instance? false for a bare %URI{}). A
    # non-admin manager is therefore rejected at the wildcard-action guard.
    cap = cap_to_grant(OwnedStubBehavior, :any)
    caller_caps = [manage_cap_over_target(), held_delegable_cap(OwnedStubBehavior, :read)]

    assert {:error, :wildcard_action_grant_requires_admin_authority} =
             authorize(caller_caps, cap)
  end

  test "non-manager non-owner non-admin caller is still rejected :grant_not_owner" do
    cap = cap_to_grant(OwnedStubBehavior, :read)

    # Caller holds the delegable cap but NOT a Manage cap over the target →
    # it is not a manager, so the pre-existing branch rejects it.
    caller_caps = [held_delegable_cap(OwnedStubBehavior, :read)]

    assert {:error, :grant_not_owner} =
             authorize(caller_caps, cap)
  end

  test "manager holding Manage but NO delegable cap at all → :grant_not_delegable" do
    cap = cap_to_grant(OwnedStubBehavior, :read)

    # Only the Manage cap, nothing delegable → fail-closed.
    caller_caps = [manage_cap_over_target()]

    assert {:error, :grant_not_delegable} =
             authorize(caller_caps, cap)
  end

  test "self and admin keep delegation-unbounded behavior (manager bound does not apply)" do
    cap = cap_to_grant(OwnedStubBehavior, :write)

    # Admin caller: holds bootstrap wildcard, no delegable :write cap. Admin
    # must still succeed (the delegation bound is manager-case ONLY).
    admin_ctx = %{
      caller: URI.new!("entity://system/user/admin"),
      caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
      self_uri: target_instance(),
      read: fn :caps, _d -> MapSet.new() end
    }

    assert :ok =
             CapabilityRegistry.authorize_grant(admin_ctx.caps, cap, %{caller: admin_ctx.caller})

    assert {:ok, _result, effects} = IdentityAdmin.handle_grant_cap(%{cap: cap}, admin_ctx)

    assert {:emit, :cap_granted, payload} =
             Enum.find(effects, &match?({:emit, :cap_granted, _}, &1))

    # Admin grant is NOT manager-delegated.
    assert payload.via_manage == false
  end
end
