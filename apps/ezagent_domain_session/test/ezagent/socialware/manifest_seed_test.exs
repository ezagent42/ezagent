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

  describe "scan_dir!/2 — parameterized single-directory core" do
    test "imports manifests idempotently" do
      root = tmp_root()
      name = "seed-yaml-#{uniq()}"
      recipe = seed_recipe()
      write_manifest(root, "one", manifest_yaml(name, recipe))

      assert [%{name: ^name, result: :published}] = ManifestSeed.scan_dir!(root)
      assert {:ok, %{}, _object} = DefinitionRegistry.lookup(@workspace, name)

      assert [%{name: ^name, result: :exists}] = ManifestSeed.scan_dir!(root)
    end

    test "a missing directory is silently empty (deploy dir absent = skip)" do
      missing = Path.join(System.tmp_dir!(), "manifest-seed-missing-#{uniq()}")
      refute File.dir?(missing)
      assert ManifestSeed.scan_dir!(missing) == []
    end

    test "raises loud on broken manifest content" do
      root = tmp_root()
      write_manifest(root, "broken", "name: broken\nroles:\n  - recipe: missing\n")

      assert_raise RuntimeError, ~r/socialware manifest seed failed/, fn ->
        ManifestSeed.scan_dir!(root)
      end
    end

    test "raises a readable error when uses names a plugin that is not installed" do
      root = tmp_root()
      name = "seed-yaml-missing-plugin-#{uniq()}"
      recipe = seed_recipe()

      yaml =
        manifest_yaml(name, recipe)
        |> String.replace("- manifest-yaml-fixture", "- crawler")

      write_manifest(root, "needs-crawler", yaml)

      err =
        assert_raise RuntimeError, fn ->
          ManifestSeed.scan_dir!(root, source: "deploy")
        end

      assert err.message =~ "socialware manifest #{name}"
      assert err.message =~ ~s(requires plugin "crawler" which is not installed)
    end
  end

  describe "scan_all!/1 — one late lane over deploy dir + started app privs" do
    test "no-op when boot scanning is disabled (test default)" do
      root = tmp_root()
      name = "seed-yaml-disabled-#{uniq()}"
      recipe = seed_recipe()
      write_manifest(root, "one", manifest_yaml(name, recipe))

      assert :ok = ManifestSeed.scan_all!(sources: [{"deploy", root}])
      assert :error = DefinitionRegistry.lookup(@workspace, name)
    end

    test "sweeps explicitly injected sources in order" do
      enable_scan!()
      deploy_root = tmp_root()
      app_root = tmp_root()
      recipe = seed_recipe()
      deploy_name = "seed-yaml-deploy-#{uniq()}"
      app_name = "seed-yaml-app-#{uniq()}"
      write_manifest(deploy_root, "one", manifest_yaml(deploy_name, recipe))
      write_manifest(app_root, "two", manifest_yaml(app_name, recipe))

      assert :ok =
               ManifestSeed.scan_all!(sources: [{"deploy", deploy_root}, {"some_app", app_root}])

      assert {:ok, %{}, _} = DefinitionRegistry.lookup(@workspace, deploy_name)
      assert {:ok, %{}, _} = DefinitionRegistry.lookup(@workspace, app_name)
    end

    test "publishes autoservice from domain_session priv via default app enumeration" do
      enable_scan!()
      # the recipe the autoservice manifest's role slot references — seeded at
      # domain_session boot in dev/prod (seed_manifest_boot_recipes).
      {:ok, _} = RecipeRegistry.seed_role_if_absent(%{name: "autoservice-agent"})

      missing_deploy = Path.join(System.tmp_dir!(), "manifest-seed-nodeploy-#{uniq()}")
      refute File.dir?(missing_deploy)

      assert :ok = ManifestSeed.scan_all!(deploy_dir: missing_deploy)

      assert {:ok, %{}, _object} = DefinitionRegistry.lookup(@workspace, "autoservice-tier1")
    end

    test "collects the deploy dir ahead of app privs when it exists" do
      enable_scan!()
      {:ok, _} = RecipeRegistry.seed_role_if_absent(%{name: "autoservice-agent"})
      deploy_root = tmp_root()
      recipe = seed_recipe()
      name = "seed-yaml-deploy-first-#{uniq()}"
      write_manifest(deploy_root, "one", manifest_yaml(name, recipe))

      assert :ok = ManifestSeed.scan_all!(deploy_dir: deploy_root)

      # deploy-dir manifest AND the app-priv autoservice both landed in one lane
      assert {:ok, %{}, _} = DefinitionRegistry.lookup(@workspace, name)
      assert {:ok, %{}, _} = DefinitionRegistry.lookup(@workspace, "autoservice-tier1")
    end

    test "boot fallback: scan_all! without a deploy_dir override seeds the deploy dir first" do
      enable_scan!()
      {:ok, _} = RecipeRegistry.seed_role_if_absent(%{name: "autoservice-agent"})

      tmp = Path.join(System.tmp_dir!(), "sw-boot-fallback-#{uniq()}")
      File.rm_rf!(tmp)
      prev_home = System.get_env("EZAGENT_HOME")
      System.put_env("EZAGENT_HOME", tmp)

      on_exit(fn ->
        if prev_home,
          do: System.put_env("EZAGENT_HOME", prev_home),
          else: System.delete_env("EZAGENT_HOME")

        File.rm_rf!(tmp)
      end)

      deploy_dir = Ezagent.System.FsResolver.path!(Ezagent.URI.system_principal("socialware"))
      refute File.dir?(deploy_dir)

      # No :deploy_dir override → the default path runs the deploy-seed fallback
      # (Ezagent.Home.SocialwareSeed.seed!/0) before resolving + scanning it.
      assert :ok = ManifestSeed.scan_all!()

      # the fallback created (seeded) the deployment dir ahead of the scan
      assert File.dir?(deploy_dir)
      # autoservice-tier1 is published (via the deploy-seed dir once migrated;
      # via app-priv enumeration until then) — the flagship lands either way
      assert {:ok, %{}, _} = DefinitionRegistry.lookup(@workspace, "autoservice-tier1")
    end
  end

  defp enable_scan! do
    prev = Application.get_env(:ezagent_domain_session, :socialware_manifest_boot_scan)
    Application.put_env(:ezagent_domain_session, :socialware_manifest_boot_scan, true)

    on_exit(fn ->
      Application.put_env(:ezagent_domain_session, :socialware_manifest_boot_scan, prev)
    end)
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
