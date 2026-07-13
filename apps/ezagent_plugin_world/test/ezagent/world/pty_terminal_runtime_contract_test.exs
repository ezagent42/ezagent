defmodule Ezagent.World.PtyTerminalRuntimeContractTest do
  use ExUnit.Case, async: true

  @assets_dir Path.expand("../../../assets", __DIR__)

  test "World PTY surface owns its xterm runtime and stylesheet" do
    dependencies =
      @assets_dir
      |> Path.join("package.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("dependencies")

    source =
      @assets_dir
      |> Path.join("src/components/PtyTerminal.tsx")
      |> File.read!()

    assert dependencies["xterm"] == "^5.3.0"
    assert dependencies["xterm-addon-fit"] == "^0.8.0"

    assert source =~ ~s(import {Terminal} from "xterm")
    assert source =~ ~s(import {FitAddon} from "xterm-addon-fit")
    assert source =~ ~s(import "xterm/css/xterm.css")

    refute source =~ "window.Terminal"
    refute source =~ "window.FitAddon"
    refute source =~ "xterm runtime is not loaded."
  end
end
