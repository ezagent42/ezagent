defmodule EzagentPluginLiveview.AgentApiKeysLiveTest do
  @moduledoc """
  Allen 2026-05-26 — ApiKeys-to-Agent flip.

  Invariants tested:

  - `/identities/agents/:uri/api-keys` mounts against a live Agent Kind
    and exposes the masked-list / add-form surface.
  - The legacy `/identities/users/:uri/api-keys` route is GONE (no
    Phoenix route matches).
  - Admin caller sees the edit form regardless of `creator_uri`.
  - Add → list round-trip works against a freshly-spawned curl agent.
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

  defp spawn_curl_agent(opts \\ []) do
    agent_uri =
      Ezagent.URI.new!(
        "entity://team-alpha/agent/curl_apikeys-#{System.unique_integer([:positive])}"
      )

    {:ok, _pid} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(agent_uri, "curl", opts)
    agent_uri
  end

  test "GET /identities/agents/:uri/api-keys renders for an admin caller", %{conn: conn} do
    agent_uri = spawn_curl_agent()
    encoded = URI.encode_www_form(URI.to_string(agent_uri))

    {:ok, _lv, html} = live(conn, "/identities/agents/#{encoded}/api-keys")

    assert html =~ "API Keys"
    assert html =~ URI.to_string(agent_uri)
    # Fresh agent has no stored keys.
    assert html =~ "No API keys yet" or html =~ "Stored keys (0)"
    # Add form is rendered (admin is implicitly authorized).
    assert html =~ "Add / rotate key"
  end

  test "put -> list round-trip persists the key on the agent slice", %{conn: conn} do
    agent_uri = spawn_curl_agent()
    encoded = URI.encode_www_form(URI.to_string(agent_uri))

    {:ok, lv, _html} = live(conn, "/identities/agents/#{encoded}/api-keys")

    lv
    |> form("#add-key-form form", %{
      "api_key" => %{"provider" => "deepseek", "key" => "sk-abcd1234efgh5678"}
    })
    |> render_submit()

    html = render(lv)
    assert html =~ "Saved key for"
    assert html =~ "deepseek"
    # Masked form shows; plaintext does NOT leak back.
    assert html =~ "sk-abcd...5678"
    refute html =~ "sk-abcd1234efgh5678"
  end

  test "legacy /identities/users/:uri/api-keys route is GONE (falls through to fallback)",
       %{conn: conn} do
    admin_uri_str = URI.to_string(Ezagent.Entity.User.admin_uri())
    encoded = URI.encode_www_form(admin_uri_str)

    # The router has a catch-all `get "/*path", FallbackController` that
    # swallows otherwise-unmatched paths; the legacy route is gone iff
    # the request lands on that fallback (not the AgentApiKeysLive
    # mount). The fallback returns 404.
    conn = get(conn, "/identities/users/#{encoded}/api-keys")
    assert conn.status == 404
  end

  test "non-admin creator (via AgentLineage) is recognized by lookup_creator_uri",
       %{conn: _admin_conn} do
    # Allen 2026-05-26 (codex LOW closure) — exercise the non-admin
    # creator-resolution path. `Behavior.Workspace.do_create_agent`
    # records the spawn caller in `Ezagent.AgentLineage`; both the LV
    # mount and `Behavior.ApiKeys.data_owner/1` consult lineage as
    # tier-2 fallback when the slice's `:creator_uri` is nil. The
    # full mount-against-conn coverage stays in the admin test; this
    # asserts the resolution layer itself (no LV-conn dependency).
    # Build the creator URI canonically (`Ezagent.URI.new!`), matching the
    # representation production uses. AgentLineage now persists URIs as
    # canonical strings and re-parses them via `Ezagent.URI.new!` on
    # lookup, so a stdlib `URI.parse/1` here (which sets the deprecated
    # `:authority` field that the canonical form drops) would fail the
    # strict `^pin` round-trip. (post-lifecycle remediation: lineage
    # gained durable string backing; the string round-trip canonicalizes.)
    creator_uri =
      Ezagent.URI.new!("entity://team-alpha/user/creator-#{System.unique_integer([:positive])}")

    agent_uri = spawn_curl_agent()
    :ok = Ezagent.AgentLineage.record(agent_uri, creator_uri)

    # `Behavior.ApiKeys.data_owner/1` resolves the creator via lineage.
    assert ^creator_uri = Ezagent.Behavior.ApiKeys.data_owner(agent_uri)
  end

  test "stranger (no lineage, no slice creator) gets :no_owner from data_owner",
       %{conn: _admin_conn} do
    # Codex LOW closure (2026-05-26) — assert the negative posture:
    # a non-creator non-admin has no resolution path, so
    # `data_owner/1` returns `:no_owner`. Combined with the LV
    # mount's `is_admin? or @creator?` gate, this is what collapses
    # the edit affordance to admin-only for unrelated callers — the
    # FOOTGUN is closed because the gate is structurally correct,
    # not because we're trying to render a friendly error for the
    # stranger (the dispatch they trigger fails earlier with
    # `:unauthorized`, which the LV renders as an "Error loading
    # keys" card — that's the actual production UX).
    agent_uri = spawn_curl_agent(lineage?: false)
    # No AgentLineage.record / no slice creator_uri.

    assert :no_owner = Ezagent.Behavior.ApiKeys.data_owner(agent_uri)
  end
end
