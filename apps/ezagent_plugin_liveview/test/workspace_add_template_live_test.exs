defmodule EzagentPluginLiveview.WorkspaceAddTemplateLiveTest do
  @moduledoc """
  Phase 5 PR 1 invariant test: Workspace LV add-template (form mode)
  results in a Session spawned via GenericSession Template Class
  end-to-end (LV → Workspace.add_template → trigger_instantiate →
  TemplateRegistry → Class.instantiate → SpawnRegistry).
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

  test "add-template form mode → GenericSession Class spawns Session live", %{conn: conn} do
    ws_name = "add-tmpl-test-#{System.unique_integer([:positive])}"
    {:ok, _} = Ezagent.Workspace.create(ws_name)

    session_name = "test-#{System.unique_integer([:positive])}"

    {:ok, lv, _html} = live(conn, "/workspaces/#{ws_name}")

    # Phase 5 PR 2: select_template_class drives which form_fields render.
    # Default is alphabetically first (cc.pty) so click session.generic.
    lv
    |> element("button[phx-click='select_template_class'][phx-value-class='session.generic']")
    |> render_click()

    lv
    |> form("#add-template form",
      add_template: %{
        tmpl_name: "main",
        session_name: session_name,
        members_csv: "entity://system/user/admin"
      }
    )
    |> render_submit()

    # Verify persistence
    assert %{session_templates: %{"main" => tmpl}} =
             Ezagent.Workspace.Store.get_by_name(ws_name)

    assert tmpl["class"] == "session.generic"
    assert tmpl["session_name"] == session_name

    # Wait for the Session Kind to be alive in KindRegistry. SPEC v3
    # §3.6 (Phase 9 PR-7) — sessions live at
    # `session://<workspace>/generic/<session_name>`.
    session_uri = Ezagent.URI.session(ws_name, :generic, session_name)
    Process.sleep(100)
    assert {:ok, _pid} = Ezagent.KindRegistry.lookup(session_uri)
  end

  test "remove_template drops the entry from persisted Workspace", %{conn: conn} do
    ws_name = "rm-tmpl-test-#{System.unique_integer([:positive])}"
    {:ok, _} = Ezagent.Workspace.create(ws_name)

    :ok =
      Ezagent.Workspace.add_template(ws_name, "foo", %{
        "class" => "session.generic",
        "session_name" => "foosession-#{System.unique_integer([:positive])}",
        "members" => []
      })

    {:ok, lv, _html} = live(conn, "/workspaces/#{ws_name}")

    lv
    |> element("button[phx-click='remove_template'][phx-value-name='foo']")
    |> render_click()

    assert %{session_templates: tmpls} = Ezagent.Workspace.Store.get_by_name(ws_name)
    refute Map.has_key?(tmpls, "foo")
  end
end
