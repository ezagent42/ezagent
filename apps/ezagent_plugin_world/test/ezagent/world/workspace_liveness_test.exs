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
  alias Ezagent.Socialware.{Definition, DefinitionRegistry}
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
    admin = User.admin_uri()
    :ok = Ezagent.Entity.spawn_principal(admin)
    admin_caps = MapSet.new(Ezagent.IdentityCaps.load(admin))

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

  test "new template state carries installable socialware catalog with role slots",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_caps: admin_caps} do
    definition_name = "world-template-catalog-#{System.unique_integer([:positive])}"
    second_definition_name = "world-template-catalog-extra-#{System.unique_integer([:positive])}"

    {:ok, definition} =
      Definition.new(%{
        name: definition_name,
        title: "Template catalog fixture",
        description: "Selectable from the world template builder.",
        uses: ["hello"],
        bases: [Ezagent.ActionSet.Session],
        roles: [
          %{role_name: "front-desk", fill: :agent, recipe: "hello.front-desk", flavor: "hello"}
        ],
        visibility_policy: %{publish_policy: :auto, web_anon_access: true}
      })

    {:ok, second_definition} =
      Definition.new(%{
        name: second_definition_name,
        title: "Extra template catalog fixture",
        bases: [Ezagent.ActionSet.Session],
        roles: [
          %{role_name: "builder", fill: :agent, recipe: "hello.builder", flavor: "hello"}
        ],
        visibility_policy: %{publish_policy: :auto, web_anon_access: true}
      })

    {:ok, _object} =
      DefinitionRegistry.write_definition(definition,
        workspace_uri: workspace_uri,
        caller_workspace_uri: workspace_uri,
        actor_uri: User.admin_uri(),
        caps: admin_caps
      )

    {:ok, _object} =
      DefinitionRegistry.write_definition(second_definition,
        workspace_uri: workspace_uri,
        caller_workspace_uri: workspace_uri,
        actor_uri: User.admin_uri(),
        caps: admin_caps
      )

    detail =
      WorkspacePluginData.state_for(
        %{
          component: "workspace_template_new",
          name: ws_name,
          title: "New Template",
          path: "/workspaces/#{ws_name}/templates/new"
        },
        %{workspace_uri: workspace_uri, caller_uri: User.admin_uri(), caller_caps: admin_caps}
      )

    row = Enum.find(detail["socialwares"], &(&1["name"] == definition_name))
    second_row = Enum.find(detail["socialwares"], &(&1["name"] == second_definition_name))

    assert detail["agent_flavors"] ==
             Ezagent.AgentFlavorRegistry.list_all()
             |> Enum.map(fn {flavor, _declaration} -> flavor end)
             |> Enum.sort()

    assert row["title"] == "Template catalog fixture"
    assert second_row["title"] == "Extra template catalog fixture"

    assert [%{"role_name" => "front-desk", "fill" => "agent", "recipe" => "hello.front-desk"}] =
             row["roles"]

    assert detail["template_mode"] == "new"
  end
end
