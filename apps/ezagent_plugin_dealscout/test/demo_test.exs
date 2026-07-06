defmodule EzagentPluginDealScout.DemoTest do
  @moduledoc """
  Shape gate for the dealscout demo socialware manifest
  (`EzagentPluginDealScout.Demo` — the boot-publish one-source-of-truth, the
  hello #162 / kanban golden-template play). Proves the config-authored
  manifest resolves through `Ezagent.Socialware.ManifestResolver.resolve/1`
  (the fail-closed authoring boundary), composes hello's public face
  (Surface+Turn shape, `hello_render` view, `external_feed` adapter,
  anon-readable), declares exactly the `discover` + `page` agent role-slots
  with zero participant instance URIs (role-slot #1180), carries ONLY the
  content-triggered update-signal rule (never hello's `always → chat` — the
  kanban-handoff red line), and is public / supervised / ANON-readable /
  installer-owned. No DB here (resolve is ETS-only: PluginRegistry +
  SessionViewRegistry, both populated at app start); publish/idempotency/
  conformance live in `demo_publish_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.DealScoutCrawl
  alias Ezagent.Socialware.{Definition, ManifestResolver}
  alias EzagentPluginDealScout.Demo

  defp resolve!(opts \\ []) do
    assert {:ok, %Definition{} = definition} = ManifestResolver.resolve(Demo.manifest_attrs(opts))
    definition
  end

  test "manifest resolves through ManifestResolver (string name-refs → Definition)" do
    definition = resolve!()
    assert definition.name == "dealscout"
    # uses 声明依赖两个 plugin（hello 渲染面 + dealscout 爬取后台）
    assert definition.uses == ["hello", "dealscout"]
    # `"hello_render"` resolved through hello's registered PageView to the
    # backing view read ActionSet — dealscout declares NO view/render of its own.
    assert definition.views == [Ezagent.ActionSet.HelloRender]
    # #1180: the `members` field is retired; participants live in `roles`.
    refute Map.has_key?(Map.from_struct(definition), :members)
  end

  test "manifest resolves with a per-run unique name (the test-isolation seam)" do
    name = "dealscout-demo-#{System.unique_integer([:positive])}"
    definition = resolve!(name: name)
    assert definition.name == name
  end

  test "composes hello's public face: Surface+Turn shape, external_feed adapter" do
    definition = resolve!()
    # hello 公开面配置逐项复制（hello `app.ex` `seed_hello_definition` 同款）
    assert Ezagent.ActionSet.Surface in definition.shape
    assert Ezagent.ActionSet.Turn in definition.shape
    assert Ezagent.ActionSet.Session in definition.bases

    assert Enum.any?(definition.adapters, fn a ->
             (a[:adapter_id] || a["adapter_id"]) == "external_feed"
           end)
  end

  test "declares exactly the discover + page agent role-slots, zero instance URIs (#1180)" do
    definition = resolve!()
    agent_slots = Enum.filter(definition.roles, &(&1.fill == :agent))
    assert Enum.sort(Enum.map(agent_slots, & &1.role_name)) == ["discover", "page"]

    discover = Enum.find(agent_slots, &(&1.role_name == "discover"))
    assert discover.recipe == "dealscout-discover"
    assert discover.flavor == "cc-headless"

    page = Enum.find(agent_slots, &(&1.role_name == "page"))
    # 【显式临时 ALT】A①（#1201 ③）落地后回切 "hello.builder"（demo.ex 槽注释）。
    assert page.recipe == "dealscout-page-alt"
    assert page.flavor == "native"

    Enum.each(agent_slots, fn slot ->
      refute String.contains?(slot.recipe, "://")
      refute String.contains?(slot.role_name, "://")
    end)
  end

  test "the :flavor option swaps ONLY the discover slot (page stays the ALT recipe × native)" do
    definition = resolve!(flavor: "dealscout-demo-stub")
    discover = Enum.find(definition.roles, &(&1.role_name == "discover"))
    page = Enum.find(definition.roles, &(&1.role_name == "page"))

    assert discover.flavor == "dealscout-demo-stub"
    assert discover.recipe == "dealscout-discover"
    # page 槽是页面刷新腿（临时 ALT recipe × native），不随 stub 换。
    # A①（#1201 ③）落地后回切 "hello.builder"。
    assert page.flavor == "native"
    assert page.recipe == "dealscout-page-alt"
  end

  test "role-slot recipes resolve to plugin-declared recipe names (config references real recipes)" do
    declared =
      Enum.map(EzagentPluginDealScout.Recipes.all(), & &1.name) ++
        Enum.map(EzagentPluginHello.Application.roles(), & &1.name)

    definition = resolve!()
    Enum.each(definition.roles, fn slot -> assert slot.recipe in declared end)
  end

  test "routing is ONLY the content-triggered update rule — never hello's always→chat (red line)" do
    definition = resolve!()
    assert [rule] = definition.routing_rules

    matcher = Map.get(rule, "matcher") || Map.get(rule, :matcher)
    assert (matcher["type"] || matcher[:type]) == "text_contains"
    # 标记从 update_signal/0 取（单一契约点），不硬编码字面量。
    arg = to_string(matcher["arg"] || matcher[:arg])
    assert arg == DealScoutCrawl.update_signal()
    refute String.contains?(arg, "://")

    # 已声明角色名（conformance `routing_receivers_resolve` 只认这个），非 URI。
    assert (Map.get(rule, "receivers") || Map.get(rule, :receivers)) == ["page"]
    assert (Map.get(rule, "rule_set") || Map.get(rule, :rule_set)) == "dealscout-update"

    # NO `always` matcher anywhere (the hello chat route must not be copied).
    refute Enum.any?(definition.routing_rules, fn r ->
             m = Map.get(r, "matcher") || Map.get(r, :matcher) || %{}
             (m["type"] || m[:type]) == "always"
           end)

    # the whole rule set carries NO participant instance URI (round-trip safety).
    refute inspect(definition.routing_rules) =~ ~r{entity://[^/]+/(agent|user)/}
  end

  test "public + supervised + ANON-readable visibility with installer owner (差异 vs kanban)" do
    definition = resolve!()
    # scope public → cross-workspace discoverable ("Socialware 下拉" entry)…
    assert definition.visibility_policy.scope == :public
    assert definition.visibility_policy.publish_policy == :supervised
    # …AND an anonymous public page (dealscout 公开面给匿名访客看线索页 —
    # kanban 是 false，产品语义不同)。
    assert definition.visibility_policy.web_anon_access == true
    # #1180: owner 只准 installer-derived（`:fixed` 被 Definition.new 拒）。
    assert definition.owner_policy == %{type: :installer}
  end

  test "legends member_set names OUR roles, fronting the update rule-set" do
    definition = resolve!()
    legend = definition.legends["dealscout"]
    assert legend
    assert Enum.sort(legend["member_set"]) == ["discover", "page"]
    assert legend["bound_rule_set"] == "dealscout-update"
    assert legend["fold"] == false
  end
end
