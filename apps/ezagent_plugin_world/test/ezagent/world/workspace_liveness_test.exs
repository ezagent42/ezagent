defmodule Ezagent.World.WorkspaceLivenessTest do
  @moduledoc """
  Pins the world workspace liveness display to the owner-gated
  `Ezagent.LocalRuntime.kind_alive?/1` (#99 C — LocalRuntime 收口).

  `WorkspacePluginData` previously read liveness via a raw
  `Ezagent.KindRegistry.lookup/1` + `Process.alive?/1`. After the migration the
  `"live"` field on BOTH the workspaces list (`list_workspaces/2`, the old
  line-122 site) and the workspace detail (`workspace_live?/1`, the old line-164
  site) is derived from `kind_alive?/1`. Single-node the workspace owner gate is
  a no-op, so a live workspace must still read `live: true` and a missing one
  must not crash.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.User
  alias Ezagent.Workspace
  alias Ezagent.World.WorkspacePluginData

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    ws_name = "world-liveness-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")
    admin_caps = MapSet.new([Ezagent.Capability.admin_genesis_cap()])

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_caps: admin_caps}
  end

  test "live workspace reads live:true on detail + list surfaces (kind_alive? wiring)",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_caps: admin_caps} do
    # The owner-gated probe agrees the freshly-created workspace is alive HERE
    # (single-node: the WorkspaceOwnerGate is a no-op, so this is a plain liveness).
    assert Ezagent.LocalRuntime.kind_alive?(workspace_uri),
           "freshly created workspace Kind must be alive on its owner runtime"

    # --- DETAIL: workspace_live?/1 → kind_alive?/1 ---
    detail =
      WorkspacePluginData.state_for(
        %{
          component: "workspace_detail",
          name: ws_name,
          title: "Workspace",
          path: "/workspaces/#{ws_name}"
        },
        %{workspace_uri: workspace_uri, caller_uri: User.admin_uri(), caller_caps: admin_caps}
      )

    assert detail["not_found"] == false
    assert detail["live"] == true, "workspace_detail live must be true for a live workspace"

    # --- LIST: list_workspaces/2 → kind_alive?/1 per row ---
    list =
      WorkspacePluginData.state_for(
        %{component: "workspaces_list", title: "Workspaces", path: "/workspaces"},
        %{workspace_uri: workspace_uri, caller_uri: User.admin_uri(), caller_caps: admin_caps}
      )

    row = Enum.find(list["workspaces"], &(&1["name"] == ws_name))
    assert row != nil, "created workspace must appear in the workspaces list"
    assert row["live"] == true, "workspaces list live must be true for a live workspace"
  end

  test "missing workspace detail does not crash and reports not_found (no liveness probe)",
       %{admin_caps: admin_caps} do
    missing = "never-created-#{System.unique_integer([:positive])}"

    detail =
      WorkspacePluginData.state_for(
        %{
          component: "workspace_detail",
          name: missing,
          title: "Workspace",
          path: "/workspaces/#{missing}"
        },
        %{workspace_uri: nil, caller_uri: User.admin_uri(), caller_caps: admin_caps}
      )

    assert detail["not_found"] == true
  end
end
