defmodule EzagentWeb.WorldAdminRouteGateTest do
  @moduledoc """
  Read-plane PR-4 rework (F3) — the world operator plane (`/overview` +
  `/admin/*`) sits behind the centralized `:require_admin` live session,
  not merely `:require_entity`. An authenticated NON-admin deep-linking
  into the operator surface is rejected (redirect + flash), never shown
  cross-tenant counts/registries/templates. The bootstrap admin AND a
  promoted system operator (non-bootstrap, accepted by the same
  `is_system_member?` clause the on_mount uses) still get in.
  """
  use EzagentWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @admin_paths ["/admin", "/overview", "/admin/templates"]

  # The world app serves only on the world host scope (test env:
  # "world.") — mirror WorldHostRoutingTest's host pinning, else the
  # WorldHostScope plug falls through to the 404 catch-all.
  setup do
    ensure_world_layouts_registered!()
    {:ok, world_conn: Map.put(build_conn(), :host, "world.ezagent.chat")}
  end

  defp sign_in(conn, entity_uri, workspace) do
    Plug.Test.init_test_session(conn, %{
      "current_entity_uri" => entity_uri,
      "current_workspace_uri" => workspace
    })
  end

  defp fresh_user(workspace, label) do
    uri = "entity://#{workspace}/user/#{label}-#{System.unique_integer([:positive])}"
    {:ok, _row} = Ezagent.Users.create(uri, "pw-#{System.unique_integer([:positive])}", [])
    uri
  end

  # See WorldHostRoutingTest — a full umbrella sweep can wipe the world
  # layout registration; ensure-if-absent with the exact production spec.
  defp ensure_world_layouts_registered! do
    fs_types_table = :ezagent_resource_fs_types
    world_layouts = "world-layouts"

    if :ets.lookup(fs_types_table, world_layouts) == [] do
      {^world_layouts, spec} =
        Enum.find(EzagentPluginWorld.Application.resource_types(), fn {type, _spec} ->
          type == world_layouts
        end)

      :ok = Ezagent.Resource.FsResolver.register_type(world_layouts, spec)
      on_exit(fn -> Ezagent.Resource.FsResolver.unregister_type(world_layouts) end)
    end

    :ok
  end

  describe "an authenticated NON-admin is rejected" do
    setup do
      {:ok, non_admin: fresh_user("team-alpha", "gate-nonadmin")}
    end

    for path <- @admin_paths do
      test "GET #{path} redirects to /sessions with the admin-required flash", %{
        world_conn: conn,
        non_admin: non_admin
      } do
        out =
          conn
          |> sign_in(non_admin, "workspace://team-alpha")
          |> get(unquote(path))

        assert redirected_to(out) == "/sessions"
        assert Phoenix.Flash.get(out.assigns.flash, :error) =~ "Admin access required"
      end
    end
  end

  describe "operators still get in" do
    test "the bootstrap admin mounts /admin", %{world_conn: conn} do
      admin = URI.to_string(Ezagent.Entity.User.admin_uri())

      conn = sign_in(conn, admin, "workspace://system")

      assert {:ok, view, _html} = live(conn, "/admin")
      assert has_element?(view, "#world-root")
    end

    test "a promoted (non-bootstrap) system operator mounts /admin", %{world_conn: conn} do
      promoted = fresh_user("system", "gate-promoted")

      conn = sign_in(conn, promoted, "workspace://system")

      assert {:ok, view, _html} = live(conn, "/admin")
      assert has_element?(view, "#world-root")
    end
  end
end
