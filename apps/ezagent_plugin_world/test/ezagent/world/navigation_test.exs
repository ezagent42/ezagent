defmodule Ezagent.World.NavigationTest do
  use ExUnit.Case, async: true

  alias Ezagent.World.Navigation

  test "returns patch target for static world paths" do
    assert Navigation.patch_to("/identities/agents/new") == {:ok, "/identities/agents/new"}
  end

  test "classifies ordinary world paths as patches" do
    assert Navigation.navigation_for("/plugins") == {:ok, :patch, "/plugins"}
  end

  test "classifies every Manage admin target as a cross-session navigate" do
    assert Navigation.navigation_for("/admin") == {:ok, :navigate, "/admin"}
    assert Navigation.navigation_for("/admin/caps") == {:ok, :navigate, "/admin/caps"}
    assert Navigation.navigation_for("/admin/settings") == {:ok, :navigate, "/admin/settings"}
    assert Navigation.navigation_for("/admin/settings?section=routing") ==
             {:ok, :navigate, "/admin/settings?section=routing"}
  end

  test "classifies the overview admin-session route as a cross-session navigate" do
    assert Navigation.navigation_for("/overview") == {:ok, :navigate, "/overview"}
  end

  test "preserves query string for safe world paths" do
    assert Navigation.patch_to("/sessions?session=session%3A%2F%2Fsystem%2Fdefault%2Fdemo") ==
             {:ok, "/sessions?session=session%3A%2F%2Fsystem%2Fdefault%2Fdemo"}
  end

  test "returns patch target for dynamic world paths" do
    assert Navigation.patch_to("/identities/agents/entity%3A%2F%2Fsystem%2Fagent%2Fdemo/api-keys") ==
             {:ok, "/identities/agents/entity%3A%2F%2Fsystem%2Fagent%2Fdemo/api-keys"}
  end

  test "returns patch target for workspace template creation paths" do
    assert Navigation.patch_to("/workspaces/team-alpha/templates/new") ==
             {:ok, "/workspaces/team-alpha/templates/new"}
  end

  test "rejects external, protocol-relative, and hash targets" do
    assert Navigation.patch_to("https://example.com/sessions") == :error
    assert Navigation.patch_to("//example.com/sessions") == :error
    assert Navigation.patch_to("/sessions#fragment") == :error
    assert Navigation.navigation_for("https://example.com/sessions") == :error
    assert Navigation.navigation_for("//example.com/sessions") == :error
    assert Navigation.navigation_for("/sessions#fragment") == :error
  end

  test "rejects unknown in-app paths" do
    assert Navigation.patch_to("/unknown") == :error
    assert Navigation.navigation_for("/unknown") == :error
  end
end
