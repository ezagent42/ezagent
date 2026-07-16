defmodule Ezagent.World.E2EFixturesTest do
  use ExUnit.Case, async: true

  alias Ezagent.World.{DispatchContract, E2EFixtures, PluginPageRegistry, SlotRegistry}

  @fixture_path Path.expand("../../../assets/e2e/fixtures/world.e2e.fixtures.json", __DIR__)
  @tier1_families MapSet.new(~w(admin conversation kanban pty sessions workspace_plugins)a)

  test "checked-in browser fixtures are in sync with backend contract" do
    assert File.exists?(@fixture_path),
           "missing #{@fixture_path} — run `mix world.e2e.fixtures`"

    assert File.read!(@fixture_path) == E2EFixtures.manifest_json()
  end

  test "Tier-1 family matrix is projected from registered layout slots" do
    families = E2EFixtures.fixture_families()

    assert MapSet.new(Map.values(families)) == @tier1_families

    for {_name, fixture} <- E2EFixtures.manifest()["fixtures"] do
      assert SlotRegistry.layout_slot?(fixture["slot_type"])

      assert Atom.to_string(SlotRegistry.renderer_family(fixture["slot_type"])) ==
               fixture["renderer_family"]
    end
  end

  test "generated allowlist equals static dispatch contract plus registered plugin actions" do
    plugin_actions = PluginPageRegistry.pages() |> Enum.flat_map(& &1.actions)

    for action <- plugin_actions do
      assert action in DispatchContract.accepted_actions()
    end

    assert E2EFixtures.manifest()["accepted_actions"] == DispatchContract.accepted_actions()
    assert "chat.send" in DispatchContract.accepted_actions()
    assert "sessions.join" in DispatchContract.accepted_actions()
  end
end
