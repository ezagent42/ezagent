defmodule Ezagent.World.E2EFixturesTest do
  use ExUnit.Case, async: true

  alias Ezagent.World.{
    DispatchContract,
    E2EFixtures,
    PluginPageRegistry,
    SlotRegistry,
    StateContract
  }

  @fixture_path Path.expand("../../../assets/e2e/fixtures/world.e2e.fixtures.json", __DIR__)
  @tier1_families MapSet.new(
                    ~w(admin conversation kanban overview pty sessions workspace_plugins)a
                  )

  test "checked-in browser fixtures are in sync with backend contract" do
    assert File.exists?(@fixture_path),
           "missing #{@fixture_path} — run `mix world.e2e.fixtures`"

    assert File.read!(@fixture_path) == E2EFixtures.manifest_json()
  end

  test "generated JSON recursively sorts object keys across OTP versions" do
    ordered_manifest = Jason.decode!(E2EFixtures.manifest_json(), objects: :ordered_objects)

    assert_sorted_object_keys(ordered_manifest)
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

  test "every generated fixture satisfies the backend minimum-state contract" do
    for {_name, %{slot_type: slot_type, state: state}} <- StateContract.fixtures() do
      assert StateContract.validate!(slot_type, state) == state
      assert Enum.sort(Map.keys(state)) == StateContract.required_keys(slot_type)
    end

    assert_raise ArgumentError, ~r/missing contract keys/, fn ->
      StateContract.validate!("overview", %{"component" => "overview"})
    end
  end

  test "generated allowlist equals static dispatch contract plus registered plugin actions" do
    plugin_actions = PluginPageRegistry.pages() |> Enum.flat_map(& &1.actions)

    for action <- plugin_actions do
      assert action in DispatchContract.accepted_actions()
    end

    assert E2EFixtures.manifest()["accepted_actions"] == DispatchContract.accepted_actions()
    assert "chat.send" in DispatchContract.accepted_actions()
    assert "session.create" in DispatchContract.accepted_actions()
    assert "sessions.join" in DispatchContract.accepted_actions()
  end

  defp assert_sorted_object_keys(%Jason.OrderedObject{values: values}) do
    keys = Enum.map(values, fn {key, _value} -> key end)

    assert keys == Enum.sort(keys)

    for {_key, value} <- values do
      assert_sorted_object_keys(value)
    end
  end

  defp assert_sorted_object_keys(values) when is_list(values) do
    Enum.each(values, &assert_sorted_object_keys/1)
  end

  defp assert_sorted_object_keys(_value), do: :ok
end
