defmodule EzagentWeb.WorldHostRoutingTest do
  use EzagentWeb.ConnCase

  import Phoenix.LiveViewTest

  test "world.ezagent.chat root mounts the world React shell", %{conn: conn} do
    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())
      })

    {:ok, view, html} = live(conn, "/")

    assert html =~ ~s(id="world-root")
    assert has_element?(view, "#world-root[phx-hook='WorldRenderer'][phx-update='ignore']")
  end
end
