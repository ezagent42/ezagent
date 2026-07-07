defmodule EzagentPluginKanban.DemoPublishTest do
  @moduledoc """
  Boot-publish gate for the kanban demo socialware (`EzagentPluginKanban.Demo`,
  since #1213 a thin loader over `priv/socialware/kanban/manifest.yaml` walking
  the `ManifestYaml.import/2` chain: parse → resolve → check_candidate →
  publish_or_upgrade), the hello #162 golden-template play — ExUnit drives the
  SAME `publish/0` the boot call site runs (skipped in `:test` for Ecto-sandbox
  reasons, exactly hello's `maybe_publish_hello_demo` split), inside a
  checked-out sandbox:

    * **idempotency three-state** (P0 §5 `publish_or_upgrade/2`): first publish
      `:published` → unchanged redeploy `:exists` (NO new CR / revision) →
      EDITED manifest `:upgraded` (a new immutable revision).
    * **conformance**: the PUBLISHED definition passes all 12
      `Ezagent.Socialware.Conformance` assertions — the same guarantee
      `mix ezagent.socialware.check kanban` gives.
    * **PUBLIC + cross-workspace discoverable** via `DefinitionRegistry.list/1`
      from a DIFFERENT workspace (the "Socialware 下拉" listing).

  Environment mirrors the `mix ezagent.socialware.check` setup: domain_session +
  kanban plugin started, the kanban recipes code-seeded into
  `workspace://system` (`RoleSeedHook` skips in test), DataCase DB sandbox.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.ConfigGovernance.Socialware, as: Governance
  alias Ezagent.Socialware.{Conformance, Definition, DefinitionRegistry, ManifestResolver}
  alias EzagentPluginKanban.Demo

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
    # 1) first publish through the REAL governance flow (open_cr → stage →
    #    publish) — the exact call the boot site makes.
    assert {:ok, :published} = Demo.publish()
    assert Demo.published?()
    assert {:ok, _definition, obj_v1} = DefinitionRegistry.lookup(ws, "kanban")

    # 2) unchanged redeploy (a re-boot / supervisor restart) no-ops: NO new CR,
    #    NO new revision minted.
    assert {:ok, :exists} = Demo.publish()
    assert {:ok, _definition, obj_after} = DefinitionRegistry.lookup(ws, "kanban")
    assert obj_after.id == obj_v1.id

    # 3) an EDITED manifest re-promotes (:upgraded, killing the R-2 silent
    #    swallow) — same admin authority the boot publish uses.
    edited = Map.put(Demo.manifest_attrs(), "description", "edited kanban manifest (upgrade)")
    assert {:ok, %Definition{} = def_v2} = ManifestResolver.resolve(edited)
    assert {:ok, :upgraded} = Governance.publish_or_upgrade(def_v2, admin_ctx(ws))

    assert {:ok, _definition, obj_v2} = DefinitionRegistry.lookup(ws, "kanban")
    refute obj_v2.id == obj_v1.id
    assert obj_v2.content_hash == Definition.content_hash(Definition.body(def_v2))
  end

  test "published kanban is PUBLIC, cross-workspace discoverable, and passes all 12 conformance assertions",
       %{ws: ws} do
    assert {:ok, :published} = Demo.publish()

    # PUBLIC + discoverable from a DIFFERENT workspace via the normal listing.
    other_ws_name = "kanban-discoverer-#{System.unique_integer([:positive])}"
    {:ok, _} = Ezagent.Workspace.create(other_ws_name, %{})
    other_ws = Ezagent.URI.workspace(other_ws_name)

    assert Enum.any?(DefinitionRegistry.list(other_ws), fn row ->
             row.name == "kanban" and row.public? == true
           end)

    # Materializable: all 12 conformance assertions green — the same guarantee
    # `mix ezagent.socialware.check kanban` gives, proving install works.
    # 13 = 原 12 + #1212 的 role-DAG conformance 断言
    assert length(Conformance.assertions()) == 13

    assert {:ok, %Definition{name: "kanban"} = definition, _obj} =
             DefinitionRegistry.lookup(ws, "kanban")

    assert Conformance.check(definition, ws) == :ok

    # still exactly one public `kanban` entry (no duplicate definition).
    assert length(Enum.filter(DefinitionRegistry.list(other_ws), &(&1.name == "kanban"))) == 1
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
          Governance.manage_cap("kanban", ws, admin),
          Ezagent.Capability.admin_genesis_cap()
        ])
    }
  end
end
