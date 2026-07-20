defmodule Ezagent.World.PresenterCapsDispatchGateTest do
  use ExUnit.Case, async: true

  @world_lib Path.expand("../../lib", __DIR__)

  test "World actions do not dispatch mount-time current_caps directly" do
    candidates =
      Path.wildcard(Path.join(@world_lib, "ezagent/world/**/*.{ex,exs}")) ++
        [Path.join(@world_lib, "ezagent_plugin_world/world_live.ex")]

    offenders =
      candidates
      |> Enum.reject(&String.ends_with?(&1, "/presenter_caps.ex"))
      |> Enum.filter(fn path ->
        source = File.read!(path)

        String.contains?(source, "assigns.current_caps") or
          String.contains?(source, "Map.get(socket.assigns, :current_caps")
      end)

    assert offenders == [],
           "external dispatches must use PresenterCaps; direct mount snapshot reads: " <>
             inspect(Enum.map(offenders, &Path.relative_to(&1, @world_lib)))
  end
end
