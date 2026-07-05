defmodule EzagentPluginKanban.KanbanTeamTest do
  @moduledoc """
  S2 unit gate for the `socialware:kanban-team` Definition — proves the
  config-as-data body round-trips through `Ezagent.Socialware.Definition.new/1`
  (the validation boundary), declares exactly the TWO agent role-slots
  (`pm-coordinator` + `dev-together`, both cc-headless active) with the correct
  flavors, carries ZERO participant instance URIs (role-slot #1180), and is
  private / non-anon / installer-owned. No DB / materialize here (that is the S3
  integration + conformance gate).

  ## Why NOT a kanban-manager role-slot (the S2 modeling fix)

  The `kanban-manager` (recipe `kanban-manager` × flavor `native`) is `passive`
  (`application.ex` `kanban_manager_recipe/0` `passive: true`). It is a
  WORKSPACE-LEVEL board data actor addressed by `entity://<ws>/agent/<id>`, NOT a
  session participant. Declaring it as an agent role-slot would make materialize
  call `session.join` on it and hit the RF-6 passive-join gate
  (`{:passive_actor_cannot_join, _}`, `session.ex:723`). So the board is NOT in
  `roles`; the team is exactly pm + dev, and the board is created by the
  world/owner (existing `/plugins/kanban` create path) and driven by the pm via
  its kanban action caps dispatched to the board URI. This test asserts the fix:
  kanban-manager is absent from `roles`.
  """
  use ExUnit.Case, async: true

  alias EzagentPluginKanban.KanbanTeam
  alias Ezagent.Socialware.Definition

  test "definition_body is a valid socialware Definition (round-trips)" do
    body = KanbanTeam.definition_body()
    assert {:ok, %Definition{} = def} = Definition.new(body)
    assert def.name == "kanban-team"
    # #1180: the `members` field is retired; participants live in `roles`.
    refute Map.has_key?(Map.from_struct(def), :members)
  end

  test "declares exactly pm-coordinator + dev-together agent role-slots, zero instance URIs" do
    {:ok, def} = Definition.new(KanbanTeam.definition_body())
    agent_slots = Enum.filter(def.roles, &(&1.fill == :agent))
    role_names = Enum.map(agent_slots, & &1.role_name)
    assert "pm-coordinator" in role_names
    assert "dev-together" in role_names
    # exactly two agent slots — pm + dev, both active cc-headless.
    assert Enum.sort(role_names) == ["dev-together", "pm-coordinator"]

    Enum.each(agent_slots, fn a ->
      assert a.fill == :agent
      assert is_binary(a.recipe) and a.recipe != ""
      assert is_binary(a.role_name) and a.role_name != ""
      refute String.contains?(a.recipe, "://")
      refute String.contains?(a.role_name, "://")
    end)

    pm_slot = Enum.find(def.roles, &(&1.role_name == "pm-coordinator"))
    assert pm_slot.flavor == "cc-headless"
    dev_slot = Enum.find(def.roles, &(&1.role_name == "dev-together"))
    assert dev_slot.flavor == "cc-headless"
  end

  test "kanban-manager is NOT a role-slot (passive board actor, not a session member) — regression guard" do
    {:ok, def} = Definition.new(KanbanTeam.definition_body())
    role_names = Enum.map(def.roles, & &1.role_name)
    # The board is a workspace-level URI-dispatch actor, never a session
    # participant — declaring it would trip the RF-6 passive-join gate at
    # materialize (`{:passive_actor_cannot_join, _}`, session.ex:723).
    refute "kanban-manager" in role_names
    # but it IS still a kanban plugin recipe (the workspace board actor).
    assert "kanban-manager" in Enum.map(EzagentPluginKanban.Application.roles(), & &1.name)
  end

  test "private, non-anon visibility with installer owner" do
    {:ok, def} = Definition.new(KanbanTeam.definition_body())
    assert def.visibility_policy.scope == :private
    assert def.visibility_policy.web_anon_access == false
    assert def.owner_policy == %{type: :installer}
  end

  test "recipe names in role-slots are a subset of the kanban plugin roles/0 recipes" do
    {:ok, def} = Definition.new(KanbanTeam.definition_body())
    slot_recipes = def.roles |> Enum.map(& &1.recipe) |> Enum.sort()
    declared = EzagentPluginKanban.Application.roles() |> Enum.map(& &1.name)
    # every declared role-slot resolves to a real kanban plugin recipe...
    Enum.each(slot_recipes, fn r -> assert r in declared end)
    # ...and the team is exactly the two session participants (pm + dev); the
    # third roles/0 recipe (kanban-manager) is the workspace board actor, not a
    # member.
    assert slot_recipes == ["dev-together", "pm-coordinator"]
  end

  test "declares a content-triggered relay-back rule to the pm role, zero instance URIs (S3)" do
    {:ok, def} = Definition.new(KanbanTeam.definition_body())

    rule =
      Enum.find(def.routing_rules, fn r ->
        (Map.get(r, "rule_set") || Map.get(r, :rule_set)) == "relay-back"
      end)

    assert rule, "expected a relay-back routing rule"

    matcher = Map.get(rule, "matcher") || Map.get(rule, :matcher)
    # content-trigger: text_contains "__done__" — never {:from, uri}, never a URI.
    assert (matcher["type"] || matcher[:type]) in ["text_contains", "mention"]
    arg = to_string(matcher["arg"] || matcher[:arg])
    assert arg == KanbanTeam.relay_done_marker()
    refute String.contains?(arg, "://")

    receivers = Map.get(rule, "receivers") || Map.get(rule, :receivers)
    # role_name (declared role), NOT a URI.
    assert receivers == ["pm-coordinator"]

    # the whole rule carries NO participant instance URI (round-trip safety).
    refute inspect(rule) =~ ~r{entity://[^/]+/(agent|user)/}
    # and no legend needed for the minimal header-triggered closure.
    assert def.legends == %{}
  end
end

defmodule EzagentPluginKanban.KanbanTeamConformanceTest do
  @moduledoc """
  自包含的 kanban-team conformance gate（取代坏掉的 bare `mix ezagent.socialware.check`
  —— 那个 gate 因 `DefinitionRegistry.list_names/1` 缺失只静默验 chat+socialware，
  不覆盖 kanban-team）。

  这里直接对 kanban-team 的 Definition 跑 domain_session 的
  `Ezagent.Socialware.Conformance.check/2`（conformance.ex:36，公开入口，返回
  `:ok | {:error, failures}`），断言全 12 条 assertion 全过。`ezagent_domain_session`
  是 kanban 的 test-only dep（mix.exs `only: :test`），所以调它自包含、不越界。

  环境按 `mix ezagent.socialware.check` 的 setup 复制：起 domain_session、code-seed
  三个 kanban recipe 进 `workspace://system`（`RecipeRegistry.seed_role_if_absent/2`
  → ConfigStore，read-through lookup 命中），再 code-seed kanban-team Definition。
  用 DataCase 拿 DB sandbox（recipe/definition 都落 ConfigStore）。
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Socialware.{Conformance, Definition, DefinitionRegistry}
  alias EzagentPluginKanban.{Application, KanbanTeam}

  setup do
    # domain_session 拥有整个 socialware 生命周期（Conformance/DefinitionRegistry/
    # Installation）；kanban 插件提供 recipe + "kanban" plugin 注册（uses: ["kanban"]）。
    {:ok, _} = Elixir.Application.ensure_all_started(:ezagent_domain_session)
    {:ok, _} = Elixir.Application.ensure_all_started(:ezagent_plugin_kanban)

    # UriQueryResolvers 幂等注册（其他 kanban e2e 也这么起）。
    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    ws = Ezagent.URI.workspace(:system)

    # recipe 走 ConfigStore（seed_role_if_absent 恒定落 workspace://system），
    # 幂等；flush 让 lookup 从 ConfigStore 读而非残留 ETS。
    Enum.each(Application.roles(), fn recipe ->
      assert {:ok, _} = RecipeRegistry.seed_role_if_absent(recipe)
    end)

    :ok = RecipeRegistry.flush_cache()

    # code-seed kanban-team Definition（幂等，镜像 hello 的 code-seed play）。
    assert {:ok, _} = KanbanTeam.seed_definition(ws)

    {:ok, ws: ws}
  end

  test "kanban-team passes all 12 socialware conformance assertions", %{ws: ws} do
    # 这个 checker 恰好枚举 12 条 assertion（conformance.ex assertions/0）。
    assert length(Conformance.assertions()) == 12

    # 取被 seed 的 Definition（与 mix 任务同源：从 registry lookup）。
    assert {:ok, %Definition{name: "kanban-team"} = def, _obj} =
             DefinitionRegistry.lookup(ws, "kanban-team")

    # 全 12 条 assertion 全过 —— :ok（fail-closed，任一坏引用是红）。
    assert Conformance.check(def, ws) == :ok
  end
end
