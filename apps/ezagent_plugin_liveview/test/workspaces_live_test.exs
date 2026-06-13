defmodule EzagentPluginLiveview.WorkspacesLiveTest do
  use ExUnit.Case

  # #52 Mode-A: cross-tier LiveView suite — mounts views that resolve
  # sibling-app domain modules; runs only in the umbrella. Excluded
  # standalone (`cd apps/ezagent_plugin_liveview && mix test`).
  @moduletag :umbrella_only
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

  test "GET /workspaces lists the bootstrapped system workspace", %{conn: conn} do
    {:ok, lv, html} = live(conn, "/workspaces")

    assert html =~ "Workspaces"
    assert html =~ "+ New Workspace"
    assert has_element?(lv, "#workspaces-table")
    refute has_element?(lv, "#empty")
    assert html =~ "workspace://system"
  end

  test "create form spawns + persists a workspace", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/workspaces")

    name = "lv-create-#{System.unique_integer([:positive])}"

    lv
    |> form("#create-workspace form", new_workspace: %{name: name})
    |> render_submit()

    html = render(lv)
    assert html =~ name
    assert html =~ "workspace://#{name}"

    # And it's persisted (Store) + live (KindRegistry)
    assert %{name: ^name} = Ezagent.Workspace.Store.get_by_name(name)
    assert {:ok, _pid} = Ezagent.KindRegistry.lookup(Ezagent.Entity.Workspace.uri_for(name))
  end

  test "detail page for non-existent workspace shows 'not found'", %{conn: conn} do
    {:ok, _lv, html} =
      live(conn, "/workspaces/never-existed-#{System.unique_integer([:positive])}")

    assert html =~ "Workspace not found"
  end

  test "detail page shows existing workspace + members section", %{conn: conn} do
    name = "lv-detail-#{System.unique_integer([:positive])}"
    {:ok, _} = Ezagent.Workspace.create(name)

    {:ok, _lv, html} = live(conn, "/workspaces/#{name}")
    assert html =~ "Workspace: <code>#{name}</code>"
    assert html =~ "Members (0)"
    assert html =~ "No members"
  end

  test "add_member from detail page persists + appears in list", %{conn: conn} do
    name = "lv-add-#{System.unique_integer([:positive])}"
    {:ok, _} = Ezagent.Workspace.create(name)

    {:ok, lv, _html} = live(conn, "/workspaces/#{name}")

    # V1 UI PR-1 — the add-member uri_picker is scoped to THIS
    # workspace; the member URI's workspace segment must match `name`.
    # The hidden input is JS-managed, so pass the value via
    # render_submit/2 extras.
    member = "entity://#{name}/agent/test_test-add"

    lv
    |> form("#members form")
    |> render_submit(%{add_member: %{member_uri: member}})

    html = render(lv)
    assert html =~ member
    assert html =~ "Members (1)"
  end

  # V1 UI PR-1 (SPEC §1.6) — server-side revalidation of the
  # add-member uri_picker submission.
  test "add_member rejects a tampered out-of-workspace URI", %{conn: conn} do
    name = "lv-reject-#{System.unique_integer([:positive])}"
    {:ok, _} = Ezagent.Workspace.create(name)

    {:ok, lv, _html} = live(conn, "/workspaces/#{name}")

    lv
    |> form("#members form")
    |> render_submit(%{add_member: %{member_uri: "entity://other-tenant/agent/cc_leak"}})

    html = render(lv)
    assert html =~ "Rejected"
    assert html =~ "Members (0)"
  end
end
