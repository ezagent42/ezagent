defmodule Ezagent.World.RefreshSurfaceRegistryTest do
  use ExUnit.Case, async: true

  alias Ezagent.World.{RefreshSurfaceBuilder, RefreshSurfaceRegistry, UiSurfaceProvider}

  @entity_uri Ezagent.URI.new!("entity://refresh-test/agent/board")

  test "registered pages and standalone renderers enumerate through one surface registry" do
    surfaces = RefreshSurfaceRegistry.all()

    assert %{component: "kanban", target: {:route, :entity_uri}} =
             RefreshSurfaceRegistry.by_component("kanban")

    assert %{component: "conversation", target: {:assign, :current_session_uri}} =
             RefreshSurfaceRegistry.by_component("conversation")

    assert Enum.all?(surfaces, &function_exported?(&1.state_builder, :refresh_state, 2))
  end

  test "builds a caller-scoped partial state from the declared builder" do
    surface = %{
      id: "test_surface",
      component: "test_surface",
      target: {:route, :entity_uri},
      state_builder: RefreshSurfaceBuilder,
      provider: __MODULE__
    }

    assert {:ok, %{"entity_uri" => entity_uri, "marker" => "updated"}} =
             RefreshSurfaceRegistry.build_state(surface, @entity_uri, %{marker: "updated"})

    assert entity_uri == URI.to_string(@entity_uri)
  end

  test "rejects incomplete and unsafe standalone declarations" do
    refute UiSurfaceProvider.valid_refresh_surface?(%{
             id: "bad",
             component: "bad",
             target: {:assign, "current_session_uri"},
             state_builder: RefreshSurfaceBuilder
           })

    refute UiSurfaceProvider.valid_refresh_surface?(%{
             id: "bad",
             component: "bad",
             target: {:assign, :current_session_uri},
             state_builder: String
           })
  end
end
