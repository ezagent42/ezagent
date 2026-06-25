defmodule Ezagent.World.RoutesTest do
  use ExUnit.Case, async: true

  alias Ezagent.World.Routes

  @agent_uri "entity://acme/agent/my-agent"
  @encoded URI.encode_www_form(@agent_uri)

  test "agent config sub-route resolves to agent_config component" do
    url = "https://example.com/identities/agents/#{@encoded}/config"
    route = Routes.route_for(%{}, url)

    assert route.component == "agent_config"
    assert route.title == "Agent Config"
    assert route.path == "/identities/agents/#{@encoded}/config"
    assert %URI{scheme: "entity"} = route.entity_uri
    assert URI.to_string(route.entity_uri) == @agent_uri
  end

  test "agent api-keys sub-route still resolves correctly (regression)" do
    url = "https://example.com/identities/agents/#{@encoded}/api-keys"
    route = Routes.route_for(%{}, url)

    assert route.component == "agent_api_keys"
    assert %URI{scheme: "entity"} = route.entity_uri
  end

  test "agent extensions sub-route still resolves correctly (regression)" do
    url = "https://example.com/identities/agents/#{@encoded}/extensions"
    route = Routes.route_for(%{}, url)

    assert route.component == "agent_extensions"
  end

  test "agent detail sub-route still resolves correctly (regression)" do
    url = "https://example.com/identities/agents/#{@encoded}"
    route = Routes.route_for(%{}, url)

    assert route.component == "agent_detail"
    assert %URI{scheme: "entity"} = route.entity_uri
  end

  # kanban-as-role K4 — the world kanban surface. The list page + the detail page
  # (entity_uri = a kanban-manager agent's entity://<ws>/agent/<id>). Regression
  # for the e2e gap where `/plugins/kanban` rendered "此路径无处可去" because the
  # router live-route was missing (added in ezagent_web/router.ex) — this asserts
  # `route_for` produces the kanban route so the LiveView mounts the surface.
  test "kanban list route (entity_uri=nil) resolves to the kanban component" do
    route = Routes.route_for(%{}, "https://example.com/plugins/kanban")

    assert route.component == "kanban"
    assert route.group == :workspace_plugins
    assert route.entity_uri == nil
  end

  test "kanban detail route resolves to the kanban component with the kanban-manager agent URI" do
    kanban_uri = "entity://acme/agent/kanban-mgr-1"
    encoded = URI.encode_www_form(kanban_uri)
    route = Routes.route_for(%{}, "https://example.com/plugins/kanban/#{encoded}")

    assert route.component == "kanban"
    assert route.group == :workspace_plugins
    assert %URI{scheme: "entity"} = route.entity_uri
    assert URI.to_string(route.entity_uri) == kanban_uri
  end
end
