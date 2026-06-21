defmodule EzagentWeb.WorldHostRoutingTest do
  use EzagentWeb.ConnCase

  import Phoenix.LiveViewTest

  setup do
    prior_home = System.get_env("EZAGENT_HOME")

    home =
      Path.join(System.tmp_dir!(), "ezagent_world_live_#{System.unique_integer([:positive])}")

    System.put_env("EZAGENT_HOME", home)

    on_exit(fn ->
      if prior_home,
        do: System.put_env("EZAGENT_HOME", prior_home),
        else: System.delete_env("EZAGENT_HOME")

      File.rm_rf!(home)
    end)

    :ok
  end

  test "world.ezagent.chat root mounts the world React shell", %{conn: conn} do
    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, view, html} = live(conn, "/")

    assert html =~ ~s(id="world-root")
    assert has_element?(view, "#world-root[phx-hook='WorldRenderer'][phx-update='ignore']")
    assert has_element?(view, "#world-root[data-world-component='sessions_table']")
    assert html =~ "session://system/default/main"
    assert html =~ "layout_editor"
  end

  test "world sessions_table dispatch joins through Invocation.dispatch", %{conn: conn} do
    caller = "entity://system/user/world_join_#{System.unique_integer([:positive])}"
    caller_uri = Ezagent.URI.new!(caller)
    session_uri = Ezagent.URI.new!("session://system/default/main")

    :ok = create_read_only_user(caller_uri, [session_join_cap(caller_uri, session_uri)])

    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => caller,
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, view, _html} = live(conn, "/")

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "sessions.join",
        "args" => %{"session_uri" => "session://system/default/main"}
      })

    assert html =~ ~s(data-last-dispatch="ok")
    assert html =~ ~s(data-current-session-uri="session://system/default/main")
  end

  test "world.ezagent.chat sessions path stays inside the world scope", %{conn: conn} do
    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, view, html} = live(conn, "/sessions")

    assert html =~ ~s(id="world-root")
    assert has_element?(view, "#world-root[data-world-component='sessions_table']")
  end

  test "world sessions_table dispatch denies caller without caps", %{conn: conn} do
    caller = "entity://system/user/world_no_caps_#{System.unique_integer([:positive])}"

    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => caller,
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, view, _html} = live(conn, "/")

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "sessions.join",
        "args" => %{"session_uri" => "session://system/default/main"}
      })

    assert html =~ ~s(data-last-dispatch="error:unauthorized")
  end

  test "world layout manage dispatch persists and reloads for admin", %{conn: conn} do
    workspace_uri = Ezagent.URI.workspace(:system)
    layout = persisted_order_layout(workspace_uri)

    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, view, _html} = live(conn, "/")

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "layout.manage",
        "args" => %{"layout" => layout}
      })

    assert html =~ ~s(data-last-dispatch="ok")

    assert ["sessions_table", "layout_editor"] =
             workspace_uri
             |> Ezagent.World.LayoutManager.read_layout()
             |> Map.fetch!("components")
             |> Enum.map(& &1["type"])

    {:ok, _view, html} = live(conn, "/")
    assert html =~ "sessions_table"
    assert html =~ "layout_editor"
  end

  test "world layout manage dispatch denies caller without manage cap", %{conn: conn} do
    caller = "entity://system/user/world_layout_no_caps_#{System.unique_integer([:positive])}"
    layout = persisted_order_layout(Ezagent.URI.workspace(:system))

    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => caller,
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, view, _html} = live(conn, "/")

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "layout.manage",
        "args" => %{"layout" => layout}
      })

    assert html =~ ~s(data-last-dispatch="error:unauthorized")
  end

  defp create_read_only_user(uri, caps) do
    result =
      case Ezagent.Users.create_read_only(uri, caps) do
        {:ok, _} -> :ok
        {:error, %Ecto.Changeset{errors: [uri: {"has already been taken", _}]}} -> :ok
      end

    with :ok <- result do
      Ezagent.Entity.spawn_principal(uri)
    end
  end

  defp session_join_cap(caller_uri, session_uri) do
    %Ezagent.Capability{
      kind: :session,
      behavior: Ezagent.Behavior.Session,
      action: :join,
      instance: session_uri,
      workspace_uri: Ezagent.URI.workspace(:system),
      granted_by: caller_uri,
      granted_at: DateTime.utc_now()
    }
  end

  defp persisted_order_layout(workspace_uri) do
    [editor, sessions] = Ezagent.World.LayoutManager.default_layout(workspace_uri)["components"]

    %{
      "version" => 1,
      "scope" => URI.to_string(workspace_uri),
      "components" => [
        %{sessions | "placement" => %{"x" => 0, "y" => 0, "w" => 12, "h" => 6}},
        %{editor | "placement" => %{"x" => 0, "y" => 6, "w" => 12, "h" => 2}}
      ]
    }
  end
end
