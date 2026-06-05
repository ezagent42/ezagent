defmodule EzagentPluginLiveview.SnapshotsLiveTest do
  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ezagent.Test.SnapshotFixtures

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

  test "GET /admin/snapshots renders header", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/admin/snapshots")
    assert html =~ "Snapshots"
  end

  test "snapshot list shows persisted rows", %{conn: conn} do
    uri = URI.parse("entity://user/team-alpha/snap-lv-#{System.unique_integer([:positive])}")

    :ok =
      SnapshotFixtures.save_kind_snapshot(uri, Ezagent.Entity.User, %{
        identity: %{caps: MapSet.new()}
      })

    {:ok, _lv, html} = live(conn, "/admin/snapshots")
    assert html =~ URI.to_string(uri)
  end

  test "clear deletes the snapshot row", %{conn: conn} do
    uri = URI.parse("entity://user/team-alpha/snap-clear-#{System.unique_integer([:positive])}")
    uri_str = URI.to_string(uri)

    :ok =
      SnapshotFixtures.save_kind_snapshot(uri, Ezagent.Entity.User, %{
        identity: %{caps: MapSet.new()}
      })

    assert %{} = Ezagent.Ecto.KindSnapshot.get(uri_str)

    {:ok, lv, _html} = live(conn, "/admin/snapshots")

    lv
    |> element("button[phx-click='clear'][phx-value-uri='#{uri_str}']")
    |> render_click()

    assert nil == Ezagent.Ecto.KindSnapshot.get(uri_str)
  end
end
