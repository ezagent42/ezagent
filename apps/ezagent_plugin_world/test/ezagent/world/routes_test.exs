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
end
