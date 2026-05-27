defmodule EzagentPluginLiveview.AdminDashboardLiveTest do
  @moduledoc """
  Regression tests for `/admin` LV.

  ## Bug 1 regression (Allen 2026-05-26)

  `assign_overview/1` previously rebound `:workspaces` to an integer
  (count of `workspace://` Kinds in the registry) — the same assign
  key `EzagentWeb.LiveAuth.require_entity_mount/2` writes as a LIST
  of workspace maps for the universal `AppShell` workspace-dropdown.
  The integer flowed through `AppShell.app_shell` →
  `outer_command_bar` → `workspace_dropdown` →
  `<%= for ws <- @workspaces do %>` and crashed with
  `Protocol.UndefinedError: protocol Enumerable not implemented
  for Integer.` for every `/admin` mount.

  The fix renames the KPI count assign to `:workspaces_count`; this
  test asserts the page renders + the KPI value shows + the
  workspace dropdown's list-iteration path doesn't crash.
  """

  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint EzagentWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())
      })

    {:ok, conn: conn}
  end

  test "GET /admin renders without crashing — `:workspaces` assign is a list, not a count",
       %{conn: conn} do
    # The mount used to crash with Protocol.UndefinedError before the
    # count/list assign-key collision was fixed (Bug 1, 2026-05-26).
    # If the bug re-appears, `live/2` raises here.
    {:ok, _lv, html} = live(conn, "/admin")

    # KPI count uses the renamed `_count` assigns (no longer collides
    # with the universal chrome's `:workspaces` list).
    assert html =~ ~s(id="kpi-workspaces")
    assert html =~ ~s(id="kpi-sessions")
    assert html =~ ~s(id="kpi-identities")
    assert html =~ ~s(id="kpi-kinds")

    # Workspace-dropdown list-iteration ran without crashing. Either
    # the placeholder ("No workspaces yet") or at least one workspace
    # row is rendered — `live_auth` lists
    # `Ezagent.Workspace.list_workspaces_for/2` (SPEC
    # 2026-05-27-workspace-cap-based-visibility) which returns the
    # caller-scoped view of seeded workspaces post-boot.
    assert html =~ "Workspaces" or html =~ "Manage workspaces"
  end
end
