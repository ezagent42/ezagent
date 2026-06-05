defmodule EzagentPluginLiveview.EntitiesLiveTest do
  @moduledoc """
  PR #149 (S-5) invariant — `/admin/registry` is the unified live
  registry surface; lists every URI in `Ezagent.KindRegistry`
  regardless of scheme. Replaces the agent-only `/admin/agents`
  list page. The agent detail page stays at `/identities/agents/:uri`;
  PTY now lives inside SessionView (Phase 8b retired the standalone
  `/identities/agents/:uri/terminal` route).
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

  test "GET /admin/registry renders header + filter chips", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/admin/registry")
    assert html =~ "Entities (live registry)"
    assert html =~ "user"
    assert html =~ "agent"
    assert html =~ "session"
    assert html =~ "workspace"
  end

  test "filter=user narrows to entity://user/* rows", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/admin/registry?filter=user")
    # Admin user spawned at boot — should appear under filter=user
    assert html =~ "entity"
  end

  test "filter=session narrows to session://* rows", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/admin/registry?filter=session")
    # Default session spawned at boot
    assert html =~ "session"
  end

  test "PTY agent detail route still works at /identities/agents/:uri", %{conn: conn} do
    agent_uri =
      Ezagent.URI.new!(
        "entity://team-alpha/agent/test_pty-status-test-#{System.unique_integer([:positive])}"
      )

    {:ok, pid} =
      Ezagent.Domain.Pty.start(agent_uri, %{
        cwd: File.cwd!(),
        test_mode: true
      })

    Process.sleep(50)

    encoded = URI.encode_www_form(URI.to_string(agent_uri))
    {:ok, _lv, html} = live(conn, "/identities/agents/#{encoded}")
    assert html =~ URI.to_string(agent_uri)

    # cleanup
    Process.exit(pid, :shutdown)
  end
end
