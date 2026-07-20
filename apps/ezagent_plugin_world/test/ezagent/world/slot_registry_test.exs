defmodule Ezagent.World.SlotRegistryTest do
  @moduledoc """
  Layer-1 of the two-layer typed-slot gate (handoff §3.2): every route slot the
  LiveView can produce MUST be a registered layout slot, and the checked-in
  manifest MUST be in sync with the SoT registry. Layer-2 (the JS/TS mount gate)
  lives in `slot_mount_gate_test.exs` (PR-1b).
  """
  use ExUnit.Case, async: true

  alias Ezagent.World.SlotRegistry

  @world_live Path.expand("../../../lib/ezagent_plugin_world/world_live.ex", __DIR__)
  @manifest Path.expand("../../../assets/src/slots.manifest.json", __DIR__)

  test "registry is internally consistent" do
    slots = SlotRegistry.layout_slots()
    assert map_size(slots) > 0

    for {type, spec} <- slots do
      assert spec.type == type
      assert spec.category == :layout_slot
      assert is_atom(spec.renderer_family)
      assert is_binary(spec.title) and spec.title != ""
    end

    # Every declared renderer family maps to at least one slot.
    families = slots |> Map.values() |> Enum.map(& &1.renderer_family) |> MapSet.new()
    assert MapSet.size(families) > 0
  end

  test "plugin page slots are resolved at runtime after the plugin registry starts" do
    assert %{renderer_family: :kanban, data_source: EzagentPluginKanban.WorldData} =
             SlotRegistry.slot("kanban")
  end

  test "Layer-1 gate: every route slot in world_live.ex is registered" do
    registered = SlotRegistry.layout_slot_types()

    route_components =
      @world_live
      |> File.read!()
      |> then(&Regex.scan(~r/component:\s*"([a-z_]+)"/, &1, capture: :all_but_first))
      |> List.flatten()
      |> MapSet.new()

    assert MapSet.size(route_components) > 0, "no route component strings found — regex drift?"

    unregistered = MapSet.difference(route_components, registered) |> MapSet.to_list()

    assert unregistered == [],
           "world_live.ex routes produce unregistered layout slots #{inspect(unregistered)} — " <>
             "register them in Ezagent.World.SlotRegistry"
  end

  test "checked-in slot manifest is in sync with the registry (run `mix world.slots.manifest`)" do
    assert File.exists?(@manifest), "missing #{@manifest} — run `mix world.slots.manifest`"
    assert File.read!(@manifest) == SlotRegistry.manifest_json()
  end
end
