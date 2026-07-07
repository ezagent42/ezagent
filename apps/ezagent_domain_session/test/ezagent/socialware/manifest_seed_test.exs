defmodule Ezagent.Socialware.ManifestSeedTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Socialware.{DefinitionRegistry, ManifestSeed}

  @workspace Ezagent.URI.workspace(:system)

  setup do
    Ezagent.PluginRegistry.register(Ezagent.Socialware.ManifestYamlTest.FixturePlugin)
    Ezagent.UI.SessionViewRegistry.init()
    :ok = Ezagent.UI.SessionViewRegistry.register(Ezagent.Socialware.ManifestYamlTest.PageView)

    :ok =
      Ezagent.CapabilityRegistry.register(
        Ezagent.Entity.Session,
        :yaml_render,
        Ezagent.Socialware.ManifestYamlTest.RenderBehavior
      )

    on_exit(fn -> Ezagent.PluginRegistry.unregister("manifest-yaml-fixture") end)
    :ok
  end

  test "boot scan imports manifests idempotently" do
    root = tmp_root()
    name = "seed-yaml-#{uniq()}"
    recipe = seed_recipe()
    write_manifest(root, "autoservice", manifest_yaml(name, recipe))

    assert {:ok, [%{name: ^name, result: :published}]} = ManifestSeed.scan_priv_manifests(root)
    assert {:ok, %{}, _object} = DefinitionRegistry.lookup(@workspace, name)

    assert {:ok, [%{name: ^name, result: :exists}]} = ManifestSeed.scan_priv_manifests(root)
  end

  test "boot scan fails loud on a broken manifest" do
    root = tmp_root()
    write_manifest(root, "broken", "name: broken\nroles:\n  - recipe: missing\n")

    assert {:error, {:manifest_seed_failed, _path, _reason}} = ManifestSeed.scan_priv_manifests(root)
  end

  defp write_manifest(root, dir, yaml) do
    path = Path.join([root, dir])
    File.mkdir_p!(path)
    File.write!(Path.join(path, "manifest.yaml"), yaml)
  end

  defp manifest_yaml(name, recipe) do
    """
    name: #{name}
    uses:
      - manifest-yaml-fixture
    bases:
      - Ezagent.ActionSet.Session
    views:
      - yaml_page
    roles:
      - role_name: agent
        fill: agent
        recipe: #{recipe}
        flavor: py
    visibility_policy:
      scope: private
      publish_policy: auto
      web_anon_access: false
    """
  end

  defp seed_recipe do
    name = "seed-yaml-recipe-#{uniq()}"
    RecipeRegistry.invalidate(RecipeRegistry.system_workspace_uri(), name)

    {:ok, _} =
      RecipeRegistry.seed_role_if_absent(%{
        name: name,
        requested_caps: [%{behavior: Ezagent.ActionSet.Identity, action: :list_caps}]
      })

    name
  end

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "manifest-seed-#{uniq()}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end

  defp uniq, do: System.unique_integer([:positive])
end
