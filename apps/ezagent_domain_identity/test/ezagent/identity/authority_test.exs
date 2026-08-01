defmodule Ezagent.Identity.AuthorityTest do
  @moduledoc """
  Membership-cap unification Phase B.1 (spec K2) — the public
  `Ezagent.Identity.Authority` manage-authority predicates.

  Extracted (single source of truth) from `ActionSet.IdentityAdmin`'s former
  private `holds_manage_over_target?/2` + `holds_workspace_admin_cap?/2`. The
  caps-list predicates are pure (hand-built caps, no spawn); `manages?/2`
  resolves the caller's DURABLE identity caps by URI (K2: NOT `ctx.caps`).
  """

  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [authority_signed_cap_as!: 4]

  alias Ezagent.Capability
  alias Ezagent.Identity.Authority

  @ws URI.new!("workspace://team-alpha")

  defp target_instance, do: URI.new!("entity://team-alpha/agent/widget-1")
  defp creator_uri, do: URI.new!("entity://team-alpha/user/creator-carla")

  # CreatorGrant.manage_cap/4 shape — cap(:agent, Manage, :any, target, ws).
  defp manage_cap_over_target(granter \\ creator_uri()) do
    Ezagent.CreatorGrant.manage_cap(:agent, target_instance(), @ws, granter)
  end

  # A workspace-admin cap scoped to a concrete workspace.
  defp workspace_admin_cap(ws \\ @ws) do
    %Capability{
      kind: :workspace,
      behavior: Ezagent.ActionSet.Workspace,
      action: :any,
      instance: :any,
      workspace_uri: ws,
      granted_by: creator_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  # An unrelated concrete cap that must never confer manage-authority.
  defp unrelated_cap do
    %Capability{
      kind: :agent,
      behavior: Ezagent.ActionSet.Identity,
      action: :read,
      instance: {:within_workspace, @ws},
      workspace_uri: @ws,
      granted_by: creator_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  describe "holds_manage_over_target?/2 (caps-list predicate)" do
    test "true when the list holds a Manage-:any cap covering the target" do
      assert Authority.holds_manage_over_target?([manage_cap_over_target()], target_instance())
    end

    test "a {:within_workspace, ws} Manage cap covers a concrete target (matches?/2, not equality)" do
      within_ws_manage = %Capability{
        kind: :agent,
        behavior: Ezagent.ActionSet.Manage,
        action: :any,
        instance: {:within_workspace, @ws},
        workspace_uri: @ws,
        granted_by: creator_uri(),
        granted_at: DateTime.utc_now()
      }

      assert Authority.holds_manage_over_target?([within_ws_manage], target_instance())
    end

    test "false for an unrelated cap / empty list" do
      refute Authority.holds_manage_over_target?([unrelated_cap()], target_instance())
      refute Authority.holds_manage_over_target?([], target_instance())
    end

    test "false when the Manage cap is scoped to a DIFFERENT concrete instance" do
      other = URI.new!("entity://team-alpha/agent/other-widget")
      elsewhere = Ezagent.CreatorGrant.manage_cap(:agent, other, @ws, creator_uri())
      refute Authority.holds_manage_over_target?([elsewhere], target_instance())
    end
  end

  describe "workspace_admin?/2 (caps-list predicate)" do
    test "true for a Workspace-:any cap scoped to the target workspace" do
      assert Authority.workspace_admin?([workspace_admin_cap()], @ws)
    end

    test "true for a Workspace-:any cap with workspace_uri: :any (cross-workspace)" do
      cross = %{workspace_admin_cap() | workspace_uri: :any}
      assert Authority.workspace_admin?([cross], @ws)
    end

    test "false for a Workspace cap scoped to a DIFFERENT workspace" do
      other_ws = %{workspace_admin_cap() | workspace_uri: URI.new!("workspace://team-beta")}
      refute Authority.workspace_admin?([other_ws], @ws)
    end

    test "false for an unrelated cap / empty list" do
      refute Authority.workspace_admin?([unrelated_cap()], @ws)
      refute Authority.workspace_admin?([], @ws)
    end
  end

  # NOTE: callers/targets are homed in a NON-system workspace (`team-alpha`) so
  # `AdminAuthority.admin?/2`'s `home_is_system?`/`member_of_system?` branch is
  # FALSE — otherwise a system-homed caller is admin-equivalent and every
  # `manages?/2` would pass trivially without exercising the manage/ws branches.
  describe "manages?/2 (URI-based, resolves DURABLE identity caps by URI)" do
    setup do
      caller = URI.new!("entity://team-alpha/user/mgr-#{System.unique_integer([:positive])}")
      {:ok, _row} = Ezagent.Users.create(caller, "pw-not-secret", [])
      {:ok, _pid} = Ezagent.SpawnRegistry.spawn(caller)
      %{caller: caller}
    end

    test "true when the caller HOLDS a Manage cap over the target (durable identity)", %{
      caller: caller
    } do
      target = URI.new!("entity://team-alpha/agent/managed-#{System.unique_integer([:positive])}")

      cap =
        Ezagent.CreatorGrant.manage_cap(:agent, target, Capability.workspace_of(target), caller)

      grant_to_identity(caller, cap)

      assert Authority.manages?(caller, target)
    end

    test "true when the caller is a workspace admin over the target's workspace", %{
      caller: caller
    } do
      target = URI.new!("entity://team-alpha/agent/managed-#{System.unique_integer([:positive])}")

      ws_cap = %Capability{
        kind: :workspace,
        behavior: Ezagent.ActionSet.Workspace,
        action: :any,
        instance: Capability.workspace_of(target),
        workspace_uri: Capability.workspace_of(target),
        granted_by: caller,
        granted_at: DateTime.utc_now()
      }

      grant_to_identity(caller, ws_cap)

      assert Authority.manages?(caller, target)
    end

    test "false when the caller holds no manage/admin authority over the target", %{
      caller: caller
    } do
      target =
        URI.new!("entity://team-beta/agent/unmanaged-#{System.unique_integer([:positive])}")

      refute Authority.manages?(caller, target)
    end

    test "false for non-URI args" do
      refute Authority.manages?(:nope, target_instance())
      refute Authority.manages?(creator_uri(), :nope)
    end
  end

  # Grant `cap` into `entity`'s durable identity slice via the real grant
  # chokepoint (admin caller), then wait for it to land.
  defp grant_to_identity(entity, cap) do
    {:ok, authority} = Ezagent.Cap.Authority.open(cap.instance, cap.kind)
    signed = authority_signed_cap_as!(authority, cap.granted_by, entity, cap)
    assert :ok = Ezagent.IdentityCaps.grant(entity, signed)
    wait_cap(entity, signed)
  end

  defp wait_cap(entity, cap, retries \\ 200) do
    held? =
      entity
      |> Ezagent.IdentityCaps.load()
      |> Enum.any?(&(Capability.identity_key(&1) == Capability.identity_key(cap)))

    cond do
      held? ->
        :ok

      retries > 0 ->
        Process.sleep(10)
        wait_cap(entity, cap, retries - 1)

      true ->
        flunk("cap never landed in #{URI.to_string(entity)}'s identity")
    end
  end
end
