defmodule EzagentPluginLiveview.EntityCapsLiveTest do
  @moduledoc """
  Phase 8c PR-G — EntityCapsLive serves both user + agent cap surfaces.

  Invariants tested:

  - `/identities/users/:uri/caps` still renders (legacy route preserved
    after rename from UserCapsLive).
  - `/identities/agents/:uri/caps` renders for a live Agent Kind and
    exposes the grant form.
  - Grant + revoke round-trip works against a live Agent (agents
    carry `Ezagent.Behavior.Identity` per
    `Ezagent.Entity.Agent.behaviors/0`).
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

  test "GET /identities/users/:uri/caps still renders (legacy alias preserved)", %{conn: conn} do
    admin_uri_str = URI.to_string(Ezagent.Entity.User.admin_uri())
    encoded = URI.encode_www_form(admin_uri_str)

    {:ok, _lv, html} = live(conn, "/identities/users/#{encoded}/caps")
    assert html =~ "Caps for"
    assert html =~ admin_uri_str
    assert html =~ "Grant new cap"
  end

  test "GET /identities/agents/:uri/caps renders grant form for a live agent", %{conn: conn} do
    agent_uri =
      URI.parse("entity://agent/team-alpha/test_caps-render-#{System.unique_integer([:positive])}")

    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(agent_uri)

    encoded = URI.encode_www_form(URI.to_string(agent_uri))
    {:ok, _lv, html} = live(conn, "/identities/agents/#{encoded}/caps")

    assert html =~ "Caps for"
    assert html =~ URI.to_string(agent_uri)
    assert html =~ "Grant new cap"
    # Fresh agent has no caps by default.
    assert html =~ "No caps. Grant one above."
  end

  test "grant + revoke round-trip works on a live agent", %{conn: conn} do
    agent_uri =
      URI.parse("entity://agent/team-alpha/test_caps-grant-#{System.unique_integer([:positive])}")

    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(agent_uri)

    encoded = URI.encode_www_form(URI.to_string(agent_uri))
    {:ok, lv, _html} = live(conn, "/identities/agents/#{encoded}/caps")

    # Grant a cap.
    lv
    |> form("#grant-cap-form", %{
      "grant" => %{"kind" => "echo", "behavior" => "any", "instance" => "any"}
    })
    |> render_submit()

    html = render(lv)
    assert html =~ "Granted cap to"
    assert html =~ ":echo"

    # Revoke it (index 0).
    lv |> element("button[phx-click=\"revoke\"][phx-value-index=\"0\"]") |> render_click()

    html = render(lv)
    assert html =~ "Revoked cap"
    assert html =~ "No caps. Grant one above."
  end

  test "/identities lists agents with a Caps link", %{conn: conn} do
    agent_uri =
      URI.parse("entity://agent/team-alpha/test_caps-list-#{System.unique_integer([:positive])}")

    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(agent_uri)

    {:ok, _lv, html} = live(conn, "/identities")

    encoded = URI.encode_www_form(URI.to_string(agent_uri))
    assert html =~ "/identities/agents/#{encoded}/caps"
  end
end
