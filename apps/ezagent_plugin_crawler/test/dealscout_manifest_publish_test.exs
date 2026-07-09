defmodule EzagentPluginCrawler.DealscoutManifestPublishTest do
  @moduledoc """
  Deploy-seed publish gate for the dealscout socialware — config-driven end to
  end (Decision #156: socialware carries zero code; the former plugin-side
  `Demo` wrapper shell is dissolved, the manifest YAML is
  the one source of truth). It drives the EXACT production lane
  (deploy-seed SPEC §2/§4, mirroring hello / kanban): `Ezagent.Home.SocialwareSeed.seed!/1` copies the
  shipped `ezagent_web/priv/socialware_seed/dealscout/` package into a temp
  deployment dir, then `Ezagent.Socialware.ManifestSeed.scan_dir!/2` resolves +
  publishes it through the governed import lane (parse → resolve → conformance →
  `ConfigGovernance.Socialware.publish_or_upgrade`). No plugin publish
  primitive is involved anywhere — production has none.

    * **idempotency three-state** (P0 §5 `publish_or_upgrade/2`): first scan
      `:published` → unchanged re-scan `:exists` (NO new CR / revision) → EDITED
      manifest `:upgraded` (a new immutable revision).
    * **conformance**: the PUBLISHED definition passes all 15
      `Ezagent.Socialware.Conformance` assertions — the same guarantee
      `mix ezagent.socialware.check dealscout` gives.
    * **PUBLIC + cross-workspace discoverable** via `DefinitionRegistry.list/1`
      from a DIFFERENT workspace (the "Socialware 下拉" listing).

  Environment mirrors the `mix ezagent.socialware.check` setup: domain_session
  （socialware 生命周期宿主）+ domain_socialware（注册 `external_feed`
  adapter）+ plugin_hello（注册 HelloRender 的 `{Session, :hello_render}`
  render cap + hello.* recipes）+ plugin_crawler（dealscout demo recipes）；
  code-seed 两家 recipe 进 `workspace://system`（`RoleSeedHook` skips in
  test）；DataCase DB sandbox. Only the dealscout package is scanned — the
  sibling flagships (`hello` / `autoservice` / `kanban`) seeded into the same
  temp dir are pruned first, since they reference plugin views / recipes not
  booted in this domain+hello+crawler env (the manifest_seed boot-fallback play).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Socialware.{Conformance, Definition, DefinitionRegistry, ManifestSeed}

  setup do
    for app <- [
          :ezagent_domain_session,
          :ezagent_domain_socialware,
          :ezagent_plugin_hello,
          :ezagent_plugin_crawler
        ] do
      {:ok, _} = Elixir.Application.ensure_all_started(app)
    end

    ws = Ezagent.URI.workspace(:system)

    # `RoleSeedHook` skips in :test — seed both recipe families explicitly so
    # conformance's fail-closed `lookup_recipe` resolves them: dealscout 的
    # 角色槽都引 crawler 插件自家 recipe（dealscout-discover + 通用页面发布腿
    # crawler-page，段4 D2）。
    recipes = EzagentPluginCrawler.Recipes.all() ++ EzagentPluginHello.Application.roles()

    Enum.each(recipes, fn recipe ->
      assert {:ok, _} = RecipeRegistry.seed_role_if_absent(recipe)
    end)

    :ok = RecipeRegistry.flush_cache()

    # D5：manifest 带 requires: [orchestrator]，resolve/conformance 核验被
    # 依赖定义已发布——seed builtin definitions（幂等）。
    :ok =
      case DefinitionRegistry.seed_builtin_definitions() do
        :ok -> :ok
        {:error, {:socialware_definition_seed_collision, _}} -> :ok
      end

    {:ok, ws: ws}
  end

  test "idempotency three-state: :published → :exists (no new revision) → :upgraded", %{ws: ws} do
    dir = seed_dealscout_only!()

    # 1) first publish through the REAL deploy-seed lane (seed! → scan_dir!) —
    #    the exact call the boot fallback + `mix ezagent.home.init` make.
    assert [%{name: "dealscout", result: :published}] =
             ManifestSeed.scan_dir!(dir, source: "deploy")

    assert {:ok, _definition, obj_v1} = DefinitionRegistry.lookup(ws, "dealscout")

    # 2) unchanged re-scan (a re-boot / re-seed) no-ops: NO new CR, NO new
    #    revision minted.
    assert [%{name: "dealscout", result: :exists}] =
             ManifestSeed.scan_dir!(dir, source: "deploy")

    assert {:ok, _definition, obj_after} = DefinitionRegistry.lookup(ws, "dealscout")
    assert obj_after.id == obj_v1.id

    # 3) an EDITED manifest re-promotes (:upgraded, killing the R-2 silent
    #    swallow) — the same governed lane, a new immutable revision.
    edit_manifest_description!(dir, "edited dealscout manifest (upgrade)")

    assert [%{name: "dealscout", result: :upgraded}] =
             ManifestSeed.scan_dir!(dir, source: "deploy")

    assert {:ok, _definition, obj_v2} = DefinitionRegistry.lookup(ws, "dealscout")
    refute obj_v2.id == obj_v1.id
  end

  test "published dealscout is PUBLIC, cross-workspace discoverable, and passes all 15 conformance assertions",
       %{ws: ws} do
    dir = seed_dealscout_only!()

    assert [%{name: "dealscout", result: :published}] =
             ManifestSeed.scan_dir!(dir, source: "deploy")

    # PUBLIC + discoverable from a DIFFERENT workspace via the normal listing.
    other_ws_name = "dealscout-discoverer-#{System.unique_integer([:positive])}"
    {:ok, _} = Ezagent.Workspace.create(other_ws_name, %{})
    other_ws = Ezagent.URI.workspace(other_ws_name)

    assert Enum.any?(DefinitionRegistry.list(other_ws), fn row ->
             row.name == "dealscout" and row.public? == true
           end)

    # Materializable: all 15 conformance assertions green — the same guarantee
    # `mix ezagent.socialware.check dealscout` gives, proving install works.
    assert length(Conformance.assertions()) == 15

    assert {:ok, %Definition{name: "dealscout"} = definition, _obj} =
             DefinitionRegistry.lookup(ws, "dealscout")

    assert Conformance.check(definition, ws) == :ok

    # still exactly one public `dealscout` entry (no duplicate definition).
    assert length(Enum.filter(DefinitionRegistry.list(other_ws), &(&1.name == "dealscout"))) ==
             1
  end

  # Seed the shipped dealscout deploy-seed package into a fresh temp deployment
  # dir (the exact `Ezagent.Home.SocialwareSeed.seed!/0` copy), then prune every
  # sibling flagship so only the dealscout package is scanned.
  defp seed_dealscout_only! do
    dir = Path.join(System.tmp_dir!(), "dealscout-seed-#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    :ok = Ezagent.Home.SocialwareSeed.seed!(dest: dir)

    for pkg <- File.ls!(dir), pkg != "dealscout" do
      File.rm_rf!(Path.join(dir, pkg))
    end

    assert File.exists?(Path.join(dir, "dealscout/manifest.yaml")),
           "seed! must have copied the shipped dealscout package"

    dir
  end

  # Edit the seeded manifest's description in place so the next scan sees new
  # content (→ `:upgraded`). The `description:` scalar is unique in the file.
  defp edit_manifest_description!(dir, new_description) do
    path = Path.join(dir, "dealscout/manifest.yaml")
    yaml = File.read!(path)

    edited =
      String.replace(
        yaml,
        ~r/^description: .*$/m,
        "description: #{inspect(new_description)}",
        global: false
      )

    assert edited != yaml, "the description line must have been rewritten"
    File.write!(path, edited)
  end
end
