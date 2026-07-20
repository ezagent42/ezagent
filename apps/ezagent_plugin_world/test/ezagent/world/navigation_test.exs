defmodule Ezagent.World.NavigationTest do
  use ExUnit.Case, async: true

  alias Ezagent.World.Navigation

  test "returns patch target for static world paths" do
    assert Navigation.target("/identities/agents/new") == {:patch, "/identities/agents/new"}
  end

  test "preserves query string for safe world paths" do
    assert Navigation.target("/sessions?session=session%3A%2F%2Fsystem%2Fdefault%2Fdemo") ==
             {:patch, "/sessions?session=session%3A%2F%2Fsystem%2Fdefault%2Fdemo"}
  end

  test "returns patch target for dynamic world paths" do
    assert Navigation.target("/identities/agents/entity%3A%2F%2Fsystem%2Fagent%2Fdemo/api-keys") ==
             {:patch, "/identities/agents/entity%3A%2F%2Fsystem%2Fagent%2Fdemo/api-keys"}
  end

  test "returns patch target for workspace template creation paths" do
    assert Navigation.target("/workspaces/team-alpha/templates/new") ==
             {:patch, "/workspaces/team-alpha/templates/new"}
  end

  test "uses live navigation for the Bindings route across the admin live session" do
    path = "/admin/sessions/session%3A%2F%2Fsystem%2Fdefault%2Fdemo/external_mirror"

    assert Navigation.target(path) == {:navigate, path}
  end

  test "rejects external, protocol-relative, and hash targets" do
    assert Navigation.target("https://example.com/sessions") == :error
    assert Navigation.target("//example.com/sessions") == :error
    assert Navigation.target("/sessions#fragment") == :error
  end

  test "rejects unknown in-app paths" do
    assert Navigation.target("/unknown") == :error
  end
end
