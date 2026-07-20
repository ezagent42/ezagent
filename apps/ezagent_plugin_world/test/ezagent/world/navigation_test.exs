defmodule Ezagent.World.NavigationTest do
  use ExUnit.Case, async: true

  alias Ezagent.World.Navigation

  test "returns patch target for static world paths" do
    assert Navigation.patch_to("/identities/agents/new") == {:ok, "/identities/agents/new"}
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
  end

  test "rejects unknown in-app paths" do
    assert Navigation.patch_to("/unknown") == :error
  end
end
