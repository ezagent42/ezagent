defmodule EzagentPluginDealScout.DefinitionSeedTest do
  @moduledoc """
  Stage D unit gate for the `socialware:dealscout` Definition —— 纯配置组合
  （config-as-data，照 kanban-team 的 S2 先例）。证明：

    * body 能 round-trip 过 `Ezagent.Socialware.Definition.new/1`（校验边界）；
    * 组合 hello 公开面配置：bases/shape 带 Surface+Turn、adapters 带
      external_feed、`web_anon_access: true` + `scope: :private`、
      `views: [Ezagent.ActionSet.HelloRender]`（hello `PageView.applies_to?`
      以 `"hello" in uses or HelloRender in views` 认领渲染，零改 hello）；
    * roles 只声明角色槽（#1180）：discover（dealscout-discover × cc-headless）
      + page（hello.builder × native），零参与者实例 URI；
    * routing_rules 是内容协议（像 kanban relay `__done__`）：
      `text_contains(update_signal)` → 已声明角色名 "page"，零实例 URI；
    * owner 只走 `%{type: :installer}`（`:fixed` 被 Definition.new 拒）。

  无 DB / materialize（那是下面 ConformanceTest 的活）。
  """
  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.DealScoutCrawl
  alias Ezagent.Socialware.Definition
  alias EzagentPluginDealScout.DefinitionSeed

  test "definition_body is a valid socialware Definition (round-trips through Definition.new)" do
    body = DefinitionSeed.definition_body()
    assert {:ok, %Definition{} = def} = Definition.new(body)
    assert def.name == "dealscout"
    # #1180: the `members` field is retired; participants live in `roles`.
    refute Map.has_key?(Map.from_struct(def), :members)
    refute Map.has_key?(body, :agents)
    refute Map.has_key?(body, :members)
  end

  test "composes hello's public face: Surface+Turn shape, external_feed adapter, anon-readable private scope" do
    {:ok, def} = Definition.new(DefinitionSeed.definition_body())
    # hello 公开面配置逐项复制（hello `app.ex` `seed_hello_definition` 同款）
    assert Ezagent.ActionSet.Surface in def.shape
    assert Ezagent.ActionSet.Turn in def.shape
    assert Ezagent.ActionSet.Session in def.bases
    assert Enum.any?(def.adapters, fn a ->
             (a[:adapter_id] || a["adapter_id"]) == "external_feed"
           end)

    # 公开面自助匿名可读；scope 留 :private（全域 public 才要 admin 门）
    assert def.visibility_policy.web_anon_access == true
    assert def.visibility_policy.scope == :private
  end

  test "views reference hello's HelloRender (display belongs to hello; dealscout declares no view/render)" do
    {:ok, def} = Definition.new(DefinitionSeed.definition_body())
    assert def.views == [Ezagent.ActionSet.HelloRender]
    # uses 声明依赖两个 plugin（hello 渲染面 + dealscout 爬取后台）
    assert "hello" in def.uses
    assert "dealscout" in def.uses
  end

  test "declares exactly the discover + page agent role-slots, zero instance URIs (#1180)" do
    {:ok, def} = Definition.new(DefinitionSeed.definition_body())
    agent_slots = Enum.filter(def.roles, &(&1.fill == :agent))
    assert Enum.sort(Enum.map(agent_slots, & &1.role_name)) == ["discover", "page"]

    discover = Enum.find(agent_slots, &(&1.role_name == "discover"))
    assert discover.recipe == "dealscout-discover"
    assert discover.flavor == "cc-headless"

    page = Enum.find(agent_slots, &(&1.role_name == "page"))
    assert page.recipe == "hello.builder"
    assert page.flavor == "native"

    Enum.each(agent_slots, fn slot ->
      refute String.contains?(slot.recipe, "://")
      refute String.contains?(slot.role_name, "://")
    end)
  end

  test "role-slot recipes resolve to plugin-declared recipe names (config references real recipes)" do
    declared =
      Enum.map(EzagentPluginDealScout.Recipes.all(), & &1.name) ++
        Enum.map(EzagentPluginHello.Application.roles(), & &1.name)

    {:ok, def} = Definition.new(DefinitionSeed.definition_body())
    Enum.each(def.roles, fn slot -> assert slot.recipe in declared end)
  end

  test "declares the content-triggered update-signal rule to the page role, zero instance URIs" do
    {:ok, def} = Definition.new(DefinitionSeed.definition_body())

    rule =
      Enum.find(def.routing_rules, fn r ->
        (Map.get(r, "rule_set") || Map.get(r, :rule_set)) == "dealscout-update"
      end)

    assert rule, "expected the dealscout-update routing rule"

    matcher = Map.get(rule, "matcher") || Map.get(rule, :matcher)
    assert (matcher["type"] || matcher[:type]) == "text_contains"
    # 标记从 update_signal/0 取（单一契约点），不硬编码字面量。
    arg = to_string(matcher["arg"] || matcher[:arg])
    assert arg == DealScoutCrawl.update_signal()
    refute String.contains?(arg, "://")

    receivers = Map.get(rule, "receivers") || Map.get(rule, :receivers)
    # 已声明角色名（conformance `routing_receivers_resolve` 只认这个），非 URI。
    assert receivers == ["page"]

    # 整条 rule 零参与者实例 URI（round-trip 安全，snapshot 回读不会被
    # reject_participant_instance_uris 拒）。
    refute inspect(rule) =~ ~r{entity://[^/]+/(agent|user)/}
  end

  test "installer-derived owner only (#1180 — :fixed owner is rejected)" do
    {:ok, def} = Definition.new(DefinitionSeed.definition_body())
    assert def.owner_policy == %{type: :installer}
  end
end

defmodule EzagentPluginDealScout.DealScoutConformanceTest do
  @moduledoc """
  自包含的 dealscout conformance gate（照 kanban `KanbanTeamConformanceTest`）：
  直接对 dealscout Definition 跑 domain_session 的
  `Ezagent.Socialware.Conformance.check/2`，断言全 12 条 assertion 全过——
  等价于 `mix ezagent.socialware.check dealscout`，但进测试套件常驻。

  环境按 mix 任务的 setup 复制：起 domain_session（socialware 生命周期宿主）、
  domain_socialware（注册 `external_feed` adapter）、plugin_hello（注册
  HelloRender 的 `{Session, :hello_render}` render cap + hello.* recipes）、
  plugin_dealscout（dealscout recipes）；code-seed 两家 recipe 进
  `workspace://system`（recipe/definition 都落 ConfigStore，用 DataCase 拿
  DB sandbox）；再 code-seed dealscout Definition。
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Socialware.{Conformance, Definition, DefinitionRegistry}
  alias EzagentPluginDealScout.DefinitionSeed

  setup do
    for app <- [
          :ezagent_domain_session,
          :ezagent_domain_socialware,
          :ezagent_plugin_hello,
          :ezagent_plugin_dealscout
        ] do
      {:ok, _} = Elixir.Application.ensure_all_started(app)
    end

    ws = Ezagent.URI.workspace(:system)

    # recipe 走 ConfigStore（seed_role_if_absent 恒定落 workspace://system），
    # 幂等；flush 让 lookup 从 ConfigStore 读而非残留 ETS。dealscout 的角色槽
    # 引两家 recipe：自己的 dealscout-discover + hello 的 hello.builder。
    recipes = EzagentPluginDealScout.Recipes.all() ++ EzagentPluginHello.Application.roles()

    Enum.each(recipes, fn recipe ->
      assert {:ok, _} = RecipeRegistry.seed_role_if_absent(recipe)
    end)

    :ok = RecipeRegistry.flush_cache()

    # code-seed dealscout Definition（幂等，镜像 hello/kanban 的 code-seed play）。
    assert {:ok, _} = DefinitionSeed.seed_definition(ws)

    {:ok, ws: ws}
  end

  test "dealscout passes all 12 socialware conformance assertions", %{ws: ws} do
    assert length(Conformance.assertions()) == 12

    # 与 mix 任务同源：从 registry lookup 被 seed 的 Definition。
    assert {:ok, %Definition{name: "dealscout"} = def, _obj} =
             DefinitionRegistry.lookup(ws, "dealscout")

    # 全 12 条 assertion 全过 —— :ok（fail-closed，任一坏引用是红）。
    assert Conformance.check(def, ws) == :ok
  end
end
