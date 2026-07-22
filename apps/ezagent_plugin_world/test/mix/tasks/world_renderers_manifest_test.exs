defmodule Mix.Tasks.World.Renderers.ManifestTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.World.Renderers.Manifest

  test "generated source contains each declared renderer and no plugin-specific host code" do
    source = Manifest.generated_source()

    for page <- Ezagent.World.PluginPageRegistry.pages() do
      assert source =~ inspect(page.key)
      assert source =~ page.renderer.export
    end

    assert source =~ "pluginPageRenderers"
    assert source =~ "pluginPageFullBleedFamilies"
  end

  test "checked-in renderer manifest matches declarations" do
    assert File.read!(Manifest.manifest_path()) == Manifest.generated_source()
  end
end
