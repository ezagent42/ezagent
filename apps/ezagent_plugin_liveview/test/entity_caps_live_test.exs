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

    # The agents these tests spawn live in `entity://team-alpha/agent/…`.
    # IdentitiesLive filters its directory to the operator's current
    # workspace (Task #55), so the session must view team-alpha — without
    # it the admin lands in `workspace://system` and the team-alpha agent
    # is filtered out of the listing. (post-lifecycle remediation.)
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://team-alpha"
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
      URI.parse(
        "entity://team-alpha/agent/test_caps-render-#{System.unique_integer([:positive])}"
      )

    {:ok, _pid} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(agent_uri, "test")

    encoded = URI.encode_www_form(URI.to_string(agent_uri))
    {:ok, _lv, html} = live(conn, "/identities/agents/#{encoded}/caps")

    assert html =~ "Caps for"
    assert html =~ URI.to_string(agent_uri)
    assert html =~ "Grant new cap"
    # A fresh agent is provisioned with exactly one structural baseline
    # cap at spawn: the owner-derived self-Identity cap that lets it read
    # its own caps (PR-OWN-3, asserted by Identity.create/1's unit test).
    # The caps table therefore renders that row, not the empty state.
    assert html =~ "Ezagent.Behavior.Identity"
    refute html =~ "No caps. Grant one above."
  end

  test "grant + revoke round-trip works on a live agent", %{conn: conn} do
    agent_uri =
      Ezagent.URI.new!("entity://team-alpha/agent/test_caps-grant-#{System.unique_integer([:positive])}")

    {:ok, _pid} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(agent_uri, "test")

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

    # The agent now holds two caps: its structural self-Identity baseline
    # cap (provisioned at spawn, PR-OWN-3) plus the just-granted :echo
    # cap. Revoke every row (index 0 each time — the list re-renders and
    # shrinks) so the round-trip drains both and lands on the empty
    # state. (post-lifecycle remediation: the old test assumed a fresh
    # agent had zero caps, ignoring the baseline self-cap.)
    revoke_sel = "button[phx-click=\"revoke\"][phx-value-index=\"0\"]"

    revoke_all = fn revoke_all ->
      if has_element?(lv, revoke_sel) do
        lv |> element(revoke_sel) |> render_click()
        revoke_all.(revoke_all)
      end
    end

    revoke_all.(revoke_all)

    html = render(lv)
    assert html =~ "Revoked cap"
    assert html =~ "No caps. Grant one above."
  end

  test "/identities lists agents with a Caps link", %{conn: conn} do
    agent_uri =
      Ezagent.URI.new!("entity://team-alpha/agent/test_caps-list-#{System.unique_integer([:positive])}")

    {:ok, _pid} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(agent_uri, "test")

    {:ok, _lv, html} = live(conn, "/identities")

    encoded = URI.encode_www_form(URI.to_string(agent_uri))
    assert html =~ "/identities/agents/#{encoded}/caps"
  end
end
