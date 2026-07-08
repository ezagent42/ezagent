defmodule EzagentPluginKanban.DemoPublishTest do
  @moduledoc """
  Deploy-seed publish gate for the kanban demo socialware — the acceptance test
  for the migration off the plugin boot self-publish onto the deploy-seed lane
  (deploy-seed SPEC §2/§4, mirroring hello). It drives the EXACT production
  lane: `Ezagent.Home.SocialwareSeed.seed!/1` copies the shipped
  `ezagent_web/priv/socialware_seed/kanban/` package into a temp deployment dir,
  then `Ezagent.Socialware.ManifestSeed.scan_dir!/2` resolves + publishes it
  through the governed import lane (parse → resolve → conformance →
  `ConfigGovernance.Socialware.publish_or_upgrade`). No `Demo.publish` primitive
  is involved anymore — production has none.

    * **idempotency three-state** (P0 §5 `publish_or_upgrade/2`): first scan
      `:published` → unchanged re-scan `:exists` (NO new CR / revision) → EDITED
      manifest `:upgraded` (a new immutable revision).
    * **conformance**: the PUBLISHED definition passes all 15
      `Ezagent.Socialware.Conformance` assertions — the same guarantee
      `mix ezagent.socialware.check kanban` gives.
    * **PUBLIC + cross-workspace discoverable** via `DefinitionRegistry.list/1`
      from a DIFFERENT workspace (the "Socialware 下拉" listing).

  Environment mirrors the `mix ezagent.socialware.check` setup: domain_session +
  kanban plugin started, the kanban recipes code-seeded into `workspace://system`
  (`RoleSeedHook` skips in test), DataCase DB sandbox. Only the kanban package is
  scanned — the sibling flagships (`hello` / `autoservice`) seeded into the same
  temp dir are pruned first, since they reference plugin views / recipes not
  booted in this domain+kanban-only env (the manifest_seed boot-fallback play).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Socialware.{Conformance, Definition, DefinitionRegistry, ManifestSeed}

  setup do
    {:ok, _} = Elixir.Application.ensure_all_started(:ezagent_domain_session)
    {:ok, _} = Elixir.Application.ensure_all_started(:ezagent_plugin_kanban)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    ws = Ezagent.URI.workspace(:system)

    # `RoleSeedHook` skips in :test — seed the kanban recipes explicitly so
    # conformance's fail-closed `lookup_recipe` resolves them.
    Enum.each(EzagentPluginKanban.Application.roles(), fn recipe ->
      assert {:ok, _} = RecipeRegistry.seed_role_if_absent(recipe)
    end)

    :ok = RecipeRegistry.flush_cache()

    {:ok, ws: ws}
  end

  test "idempotency three-state: :published → :exists (no new revision) → :upgraded", %{ws: ws} do
    dir = seed_kanban_only!()

    # 1) first publish through the REAL deploy-seed lane (seed! → scan_dir!) —
    #    the exact call the boot fallback + `mix ezagent.home.init` make.
    assert [%{name: "kanban", result: :published}] = ManifestSeed.scan_dir!(dir, source: "deploy")
    assert {:ok, _definition, obj_v1} = DefinitionRegistry.lookup(ws, "kanban")

    # 2) unchanged re-scan (a re-boot / re-seed) no-ops: NO new CR, NO new
    #    revision minted.
    assert [%{name: "kanban", result: :exists}] = ManifestSeed.scan_dir!(dir, source: "deploy")
    assert {:ok, _definition, obj_after} = DefinitionRegistry.lookup(ws, "kanban")
    assert obj_after.id == obj_v1.id

    # 3) an EDITED manifest re-promotes (:upgraded, killing the R-2 silent
    #    swallow) — the same governed lane, a new immutable revision.
    edit_manifest_description!(dir, "edited kanban manifest (upgrade)")
    assert [%{name: "kanban", result: :upgraded}] = ManifestSeed.scan_dir!(dir, source: "deploy")

    assert {:ok, _definition, obj_v2} = DefinitionRegistry.lookup(ws, "kanban")
    refute obj_v2.id == obj_v1.id
  end

  test "published kanban is PUBLIC, cross-workspace discoverable, and passes all 15 conformance assertions",
       %{ws: ws} do
    dir = seed_kanban_only!()
    assert [%{name: "kanban", result: :published}] = ManifestSeed.scan_dir!(dir, source: "deploy")

    # PUBLIC + discoverable from a DIFFERENT workspace via the normal listing.
    other_ws_name = "kanban-discoverer-#{System.unique_integer([:positive])}"
    {:ok, _} = Ezagent.Workspace.create(other_ws_name, %{})
    other_ws = Ezagent.URI.workspace(other_ws_name)

    assert Enum.any?(DefinitionRegistry.list(other_ws), fn row ->
             row.name == "kanban" and row.public? == true
           end)

    # Materializable: all 15 conformance assertions green — the same guarantee
    # `mix ezagent.socialware.check kanban` gives, proving install works.
    assert length(Conformance.assertions()) == 15

    assert {:ok, %Definition{name: "kanban"} = definition, _obj} =
             DefinitionRegistry.lookup(ws, "kanban")

    assert Conformance.check(definition, ws) == :ok

    # still exactly one public `kanban` entry (no duplicate definition).
    assert length(Enum.filter(DefinitionRegistry.list(other_ws), &(&1.name == "kanban"))) == 1
  end

  # Seed the shipped kanban deploy-seed package into a fresh temp deployment dir
  # (the exact `Ezagent.Home.SocialwareSeed.seed!/0` copy), then prune every
  # sibling flagship so only the kanban package is scanned.
  defp seed_kanban_only! do
    dir = Path.join(System.tmp_dir!(), "kanban-seed-#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    :ok = Ezagent.Home.SocialwareSeed.seed!(dest: dir)

    for pkg <- File.ls!(dir), pkg != "kanban" do
      File.rm_rf!(Path.join(dir, pkg))
    end

    assert File.exists?(Path.join(dir, "kanban/manifest.yaml")),
           "seed! must have copied the shipped kanban package"

    dir
  end

  # Edit the seeded manifest's description in place so the next scan sees new
  # content (→ `:upgraded`). The `description:` scalar is unique in the file.
  defp edit_manifest_description!(dir, new_description) do
    path = Path.join(dir, "kanban/manifest.yaml")
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
