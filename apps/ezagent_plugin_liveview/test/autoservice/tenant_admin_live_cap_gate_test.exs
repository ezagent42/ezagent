defmodule EzagentPluginLiveview.AutoService.TenantAdminLiveCapGateTest do
  @moduledoc """
  Unit test for the server-side cap-gate helper of the tenant content-admin
  LiveView. The gate mirrors `EzagentPluginAutoservice.Roles.bundle(:admin, ws)`:
  an entity may write/publish only if it holds a workspace-admin cap
  (`kind: :workspace`, `behavior: Ezagent.Behavior.Workspace`,
  `action: :any`) scoped to the workspace (or `:any`).
  """
  use ExUnit.Case, async: true

  alias EzagentPluginLiveview.AutoService.TenantAdminLive

  @ws URI.new!("workspace://acme")
  @other_ws URI.new!("workspace://other")

  @granted_by URI.new!("system://bootstrap/default")

  defp admin_cap(workspace_uri) do
    %Ezagent.Capability{
      kind: :workspace,
      behavior: Ezagent.Behavior.Workspace,
      action: :any,
      instance: workspace_uri,
      workspace_uri: workspace_uri,
      granted_by: @granted_by,
      granted_at: DateTime.utc_now()
    }
  end

  test "grants when admin workspace cap scoped to this workspace is present" do
    assert TenantAdminLive.admin_cap?([admin_cap(@ws)], @ws)
  end

  test "grants when admin cap is workspace_uri: :any" do
    cap = %{admin_cap(@ws) | workspace_uri: :any}
    assert TenantAdminLive.admin_cap?([cap], @ws)
  end

  test "denies when admin cap is scoped to a DIFFERENT workspace" do
    refute TenantAdminLive.admin_cap?([admin_cap(@other_ws)], @ws)
  end

  test "denies with empty caps (no admin cap)" do
    refute TenantAdminLive.admin_cap?([], @ws)
  end

  test "denies with only a session cap (customer/operator bundle shape)" do
    session_cap = %Ezagent.Capability{
      kind: :session,
      behavior: :any,
      action: :send,
      instance: :any,
      workspace_uri: @ws,
      granted_by: @granted_by,
      granted_at: DateTime.utc_now()
    }

    refute TenantAdminLive.admin_cap?([session_cap], @ws)
  end

  test "denies when caps is not a list" do
    refute TenantAdminLive.admin_cap?(nil, @ws)
  end
end
