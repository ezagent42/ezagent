defmodule EzagentPluginCrawler.DemoPublishTest do
  @moduledoc """
  Boot-publish gate for the dealscout demo socialware
  (`EzagentPluginCrawler.Demo`), the hello #162 / kanban golden-template play
  — ExUnit drives the SAME `publish/0` the boot call site runs (skipped in
  `:test` for Ecto-sandbox reasons, exactly hello's `maybe_publish_hello_demo`
  split), inside a checked-out sandbox:

    * **idempotency three-state** (P0 §5 `publish_or_upgrade/2`): first publish
      `:published` → unchanged redeploy `:exists` (NO new CR / revision) →
      EDITED manifest `:upgraded` (a new immutable revision).
    * **conformance**: the PUBLISHED definition passes all 12
      `Ezagent.Socialware.Conformance` assertions — the same guarantee
      `mix ezagent.socialware.check dealscout` gives.
    * **PUBLIC + cross-workspace discoverable** via `DefinitionRegistry.list/1`
      from a DIFFERENT workspace (the "Socialware 下拉" listing).

  Environment mirrors the `mix ezagent.socialware.check` setup: domain_session
  （socialware 生命周期宿主）+ domain_socialware（注册 `external_feed`
  adapter）+ plugin_hello（注册 HelloRender 的 `{Session, :hello_render}`
  render cap + hello.* recipes）+ plugin_crawler（dealscout demo recipes）；
  code-seed 两家 recipe 进 `workspace://system`（`RoleSeedHook` skips in
  test）；DataCase DB sandbox.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Socialware.ConfigGovernance.Socialware, as: Governance
  alias Ezagent.Socialware.{Conformance, Definition, DefinitionRegistry, ManifestResolver}
  alias EzagentPluginCrawler.Demo

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
    # 角色槽当前都引自家 recipe（dealscout-discover + 临时 ALT
    # dealscout-page-alt）；hello 家照旧一起 seed（A① 落地后 page 槽回切
    # hello.builder 时这里不用再动）。
    recipes = EzagentPluginCrawler.Recipes.all() ++ EzagentPluginHello.Application.roles()

    Enum.each(recipes, fn recipe ->
      assert {:ok, _} = RecipeRegistry.seed_role_if_absent(recipe)
    end)

    :ok = RecipeRegistry.flush_cache()

    {:ok, ws: ws}
  end

  test "idempotency three-state: :published → :exists (no new revision) → :upgraded", %{ws: ws} do
    # 1) first publish through the REAL governance flow (open_cr → stage →
    #    publish) — the exact call the boot site makes.
    assert {:ok, :published} = Demo.publish()
    assert Demo.published?()
    assert {:ok, _definition, obj_v1} = DefinitionRegistry.lookup(ws, "dealscout")

    # 2) unchanged redeploy (a re-boot / supervisor restart) no-ops: NO new CR,
    #    NO new revision minted.
    assert {:ok, :exists} = Demo.publish()
    assert {:ok, _definition, obj_after} = DefinitionRegistry.lookup(ws, "dealscout")
    assert obj_after.id == obj_v1.id

    # 3) an EDITED manifest re-promotes (:upgraded, killing the R-2 silent
    #    swallow) — same admin authority the boot publish uses.
    edited =
      Map.put(Demo.manifest_attrs(), "description", "edited dealscout manifest (upgrade)")

    assert {:ok, %Definition{} = def_v2} = ManifestResolver.resolve(edited)
    assert {:ok, :upgraded} = Governance.publish_or_upgrade(def_v2, admin_ctx(ws))

    assert {:ok, _definition, obj_v2} = DefinitionRegistry.lookup(ws, "dealscout")
    refute obj_v2.id == obj_v1.id
    assert obj_v2.content_hash == Definition.content_hash(Definition.body(def_v2))
  end

  test "published dealscout is PUBLIC, cross-workspace discoverable, and passes all 12 conformance assertions",
       %{ws: ws} do
    assert {:ok, :published} = Demo.publish()

    # PUBLIC + discoverable from a DIFFERENT workspace via the normal listing.
    other_ws_name = "dealscout-discoverer-#{System.unique_integer([:positive])}"
    {:ok, _} = Ezagent.Workspace.create(other_ws_name, %{})
    other_ws = Ezagent.URI.workspace(other_ws_name)

    assert Enum.any?(DefinitionRegistry.list(other_ws), fn row ->
             row.name == "dealscout" and row.public? == true
           end)

    # Materializable: all 12 conformance assertions green — the same guarantee
    # `mix ezagent.socialware.check dealscout` gives, proving install works.
    assert length(Conformance.assertions()) == 12

    assert {:ok, %Definition{name: "dealscout"} = definition, _obj} =
             DefinitionRegistry.lookup(ws, "dealscout")

    assert Conformance.check(definition, ws) == :ok

    # still exactly one public `dealscout` entry (no duplicate definition).
    assert length(Enum.filter(DefinitionRegistry.list(other_ws), &(&1.name == "dealscout"))) ==
             1
  end

  # Mirrors `Demo`'s private `admin_ctx/2` (kept private there, hello parity) —
  # the bootstrap admin + manage cap + the public-scope admin genesis gate.
  defp admin_ctx(ws) do
    admin = Ezagent.URI.user(:system, :admin)

    %{
      caller: admin,
      workspace_uri: ws,
      caps:
        MapSet.new([
          Governance.manage_cap("dealscout", ws, admin),
          Ezagent.Capability.admin_genesis_cap()
        ])
    }
  end
end
