defmodule Ezagent.Socialware.ManifestSeedTest do
  use EzagentCore.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Socialware.{DefinitionRegistry, ManifestSeed}

  @workspace Ezagent.URI.workspace(:system)

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_native)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_kb)
    {:ok, _} = RecipeRegistry.seed_role_if_absent(EzagentPluginKb.Application.kb_recipe())

    Ezagent.PluginRegistry.register(Ezagent.Socialware.ManifestSeedFixturePlugin)
    Ezagent.UI.SessionViewRegistry.init()

    :ok =
      Ezagent.UI.SessionViewRegistry.register(Ezagent.Socialware.ManifestSeedFixturePageView)

    :ok =
      Ezagent.CapabilityRegistry.register(
        Ezagent.Entity.Session,
        :manifest_seed_yaml_render,
        Ezagent.Socialware.ManifestSeedFixtureBehavior
      )

    on_exit(fn -> Ezagent.PluginRegistry.unregister("manifest-seed-fixture") end)
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
        |> String.replace("- manifest-seed-fixture", "- crawler")

      write_manifest(root, "needs-crawler", yaml)

      err =
        assert_raise RuntimeError, fn ->
          ManifestSeed.scan_dir!(root, source: "deploy")
        end

      assert err.message =~ "socialware manifest #{name}"
      assert err.message =~ ~s(requires plugin "crawler" which is not installed)
    end
  end

  describe "scan_all!/1 — one late lane over the single deploy dir" do
    test "no-op when boot scanning is disabled (test default)" do
      root = tmp_root()
      name = "seed-yaml-disabled-#{uniq()}"
      recipe = seed_recipe()
      write_manifest(root, "one", manifest_yaml(name, recipe))

      assert :ok = ManifestSeed.scan_all!(deploy_dir: root)
      assert :error = DefinitionRegistry.lookup(@workspace, name)
    end

    test "publishes autoservice from the deploy-seed dir" do
      enable_scan!()
      # the recipe the autoservice manifest's role slot references — seeded at
      # domain_session boot in dev/prod (seed_manifest_boot_recipes).
      {:ok, _} = RecipeRegistry.seed_role_if_absent(%{name: "autoservice-agent"})

      # Deploy-seed SPEC §6: autoservice moved out of domain_session priv into
      # the ezagent_web socialware_seed source; it is published via the
      # deployment directory, not app-priv enumeration.
      deploy_root = tmp_root()
      copy_autoservice_seed!(deploy_root)

      assert :ok = ManifestSeed.scan_all!(deploy_dir: deploy_root)

      assert {:ok, %{}, _object} = DefinitionRegistry.lookup(@workspace, "autoservice-tier1")
    end

    test "collects multiple manifests from the deploy dir in one lane" do
      enable_scan!()
      {:ok, _} = RecipeRegistry.seed_role_if_absent(%{name: "autoservice-agent"})
      deploy_root = tmp_root()
      recipe = seed_recipe()
      name = "seed-yaml-deploy-first-#{uniq()}"
      write_manifest(deploy_root, "one", manifest_yaml(name, recipe))
      copy_autoservice_seed!(deploy_root)

      assert :ok = ManifestSeed.scan_all!(deploy_dir: deploy_root)

      # the hand-written deploy manifest AND the seeded autoservice both landed
      assert {:ok, %{}, _} = DefinitionRegistry.lookup(@workspace, name)
      assert {:ok, %{}, _} = DefinitionRegistry.lookup(@workspace, "autoservice-tier1")
    end

    test "boot fallback: no deploy_dir override seeds the deploy dir (SocialwareSeed.seed!) before scan" do
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

      # Domain-session's isolated test application does not start the web app,
      # but the production umbrella/release has it loaded and its priv tree is
      # the shipped autoservice seed source enumerated by seed!/0.
      case Application.load(:ezagent_web) do
        :ok -> :ok
        {:error, {:already_loaded, :ezagent_web}} -> :ok
      end

      # The no-:deploy_dir path runs the deploy-seed fallback
      # (`Ezagent.Home.SocialwareSeed.seed!/0`) before resolving + scanning the
      # dir. Drive that seed + then scan the seeded dir directly.
      #
      # (Why not the full `scan_all!/0` here: it also PUBLISHES every shipped
      # flagship, and `hello` references a plugin-registered view `hello_render`
      # that isn't available in this domain-isolated test — it needs the hello
      # plugin booted, which a domain-tier test cannot compile-depend on. So we
      # prune the plugin-flagship packages and assert the plugin-agnostic
      # `autoservice` flagship lands. Full-boot publish of plugin flagships is
      # covered by the deploy-seed e2e, docs/e2e/2026-07-08/deploy-seed/.)
      :ok = Ezagent.Home.SocialwareSeed.seed!()
      assert File.dir?(deploy_dir), "fallback seed! must create the deploy dir"
      assert File.exists?(Path.join(deploy_dir, "autoservice/manifest.yaml"))

      for pkg <- File.ls!(deploy_dir), pkg != "autoservice" do
        File.rm_rf!(Path.join(deploy_dir, pkg))
      end

      results = ManifestSeed.scan_dir!(deploy_dir, source: "deploy")
      assert Enum.any?(results, &(&1.name == "autoservice-tier1" and &1.result == :published))
      assert {:ok, %{}, _} = DefinitionRegistry.lookup(@workspace, "autoservice-tier1")
    end
  end

  describe "scan_dir/2 — per-package isolation (#206/#1633 follow-up ③)" do
    test "one unresolvable package fails in isolation — the healthy package still seeds, not raised" do
      root = tmp_root()
      good_name = "seed-yaml-good-#{uniq()}"
      recipe = seed_recipe()
      write_manifest(root, "good", manifest_yaml(good_name, recipe))
      # #206-representative failure shape: a role slot references a recipe
      # that was never registered — `Conformance` returns
      # `{:error, {:unknown_agent_recipe, _}}`, the same tuple-return failure
      # class the old whole-scan `scan_dir!/2` turned into a boot-aborting raise.
      write_manifest(root, "bad", "name: bad-pkg\nroles:\n  - recipe: missing\n")

      {summary, log} =
        with_log(fn -> ManifestSeed.scan_dir(root, source: "deploy") end)

      # good package genuinely landed — assert by MEMBERSHIP, not position
      # (manifest_paths/1 sorts alphabetically, so "bad" runs before "good").
      assert Enum.any?(summary.ok, &(&1.name == good_name and &1.result == :published))
      assert {:ok, %{}, _object} = DefinitionRegistry.lookup(@workspace, good_name)

      # bad package is REPORTED as failed, not silently dropped
      assert Enum.any?(summary.failed, &(&1.name == "bad-pkg"))
      assert :error = DefinitionRegistry.lookup(@workspace, "bad-pkg")

      # the failure is LOUD — logged at :error, with the package name + reason
      # — plus a summary line stating the overall N-ok/M-failed outcome.
      assert log =~ "[error]"
      assert log =~ "bad-pkg"
      assert log =~ "socialware manifest seed (deploy): 1 ok, 1 failed"
    end

    test "a package whose sibling recipes.yaml RAISES internally is isolated too — not just the {:error, tuple} shape" do
      root = tmp_root()
      good_name = "seed-yaml-good-raise-#{uniq()}"
      recipe = seed_recipe()
      write_manifest(root, "good", manifest_yaml(good_name, recipe))

      # `seed_sibling_recipes/1` RAISES (not a returned {:error, tuple}) when a
      # sibling recipes.yaml lacks a top-level `recipes:` list — and it runs
      # BEFORE the manifest.yaml is even read/parsed. This exercises the
      # try/rescue/catch boundary in `safe_import_manifest_path/1`, distinct
      # from the tuple-return failures covered above.
      write_manifest(root, "bad-raise", "name: bad-pkg-raise\nroles: []\n")
      File.write!(Path.join([root, "bad-raise", "recipes.yaml"]), "not_recipes: []\n")

      {summary, log} = with_log(fn -> ManifestSeed.scan_dir(root, source: "deploy") end)

      assert Enum.any?(summary.ok, &(&1.name == good_name and &1.result == :published))
      assert {:ok, %{}, _object} = DefinitionRegistry.lookup(@workspace, good_name)

      # the raising package is reported under its directory name (its
      # manifest.yaml was never reached/parsed, so there is no manifest
      # `name:` to report — the failure is still surfaced, not swallowed).
      assert Enum.any?(summary.failed, &(&1.name == "bad-raise"))
      assert :error = DefinitionRegistry.lookup(@workspace, "bad-pkg-raise")

      assert log =~ "[error]"
      assert log =~ "must have a top-level"
      assert log =~ "socialware manifest seed (deploy): 1 ok, 1 failed"
    end

    test "does not raise / abort — scan_dir/2 always returns, even when every package fails" do
      root = tmp_root()
      write_manifest(root, "bad-one", "name: bad-pkg-one\nroles:\n  - recipe: missing\n")
      write_manifest(root, "bad-two", "name: bad-pkg-two\nroles:\n  - recipe: also-missing\n")

      {summary, log} = with_log(fn -> ManifestSeed.scan_dir(root, source: "deploy") end)

      assert summary.ok == []
      assert length(summary.failed) == 2
      assert Enum.any?(summary.failed, &(&1.name == "bad-pkg-one"))
      assert Enum.any?(summary.failed, &(&1.name == "bad-pkg-two"))
      assert log =~ "socialware manifest seed (deploy): 0 ok, 2 failed"
    end

    test "scan_all/1 (boot lane) isolates a bad package the same way and never raises" do
      enable_scan!()
      {:ok, _} = RecipeRegistry.seed_role_if_absent(%{name: "autoservice-agent"})

      deploy_root = tmp_root()
      copy_autoservice_seed!(deploy_root)
      write_manifest(deploy_root, "bad", "name: bad-pkg-boot\nroles:\n  - recipe: missing\n")

      {summary, log} = with_log(fn -> ManifestSeed.scan_all(deploy_dir: deploy_root) end)

      assert Enum.any?(summary.ok, &(&1.name == "autoservice-tier1" and &1.result == :published))
      assert {:ok, %{}, _} = DefinitionRegistry.lookup(@workspace, "autoservice-tier1")

      assert Enum.any?(summary.failed, &(&1.name == "bad-pkg-boot"))
      assert :error = DefinitionRegistry.lookup(@workspace, "bad-pkg-boot")
      assert log =~ "bad-pkg-boot"
    end
  end

  defp enable_scan! do
    prev = Application.get_env(:ezagent_domain_session, :socialware_manifest_boot_scan)
    Application.put_env(:ezagent_domain_session, :socialware_manifest_boot_scan, true)

    on_exit(fn ->
      Application.put_env(:ezagent_domain_session, :socialware_manifest_boot_scan, prev)
    end)
  end

  # Copy the shipped autoservice seed package (ezagent_web socialware_seed
  # source) into a deployment dir, mirroring Ezagent.Home.SocialwareSeed.seed!/0.
  defp copy_autoservice_seed!(deploy_root) do
    src = Path.join(List.to_string(:code.priv_dir(:ezagent_web)), "socialware_seed/autoservice")
    File.cp_r!(src, Path.join(deploy_root, "autoservice"))
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
      - manifest-seed-fixture
    bases:
      - Ezagent.ActionSet.Session
    views:
      - manifest_seed_yaml_page
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
