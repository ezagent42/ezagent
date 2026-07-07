defmodule EzagentPluginCrawler.DemoTest do
  @moduledoc """
  Shape gate for the dealscout demo socialware manifest — since the #1213 YAML
  migration the one-source-of-truth is
  `priv/socialware/dealscout/manifest.yaml`, loaded by the
  `EzagentPluginCrawler.Demo` thin loader via
  `Ezagent.Socialware.ManifestYaml.parse/1` (the hello #162 / kanban
  golden-template play, now as a config FILE). Proves the YAML file exists +
  parses, that the parsed manifest resolves through
  `Ezagent.Socialware.ManifestResolver.resolve/1`
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

  alias Ezagent.ActionSet.Crawler
  alias Ezagent.Socialware.{Definition, ManifestResolver, ManifestYaml}
  alias EzagentPluginCrawler.Demo

  defp resolve!(opts \\ []) do
    assert {:ok, %Definition{} = definition} = ManifestResolver.resolve(Demo.manifest_attrs(opts))
    definition
  end

  test "the manifest source is the priv YAML file: exists, parses, and IS manifest_attrs/0" do
    path = Demo.manifest_path()
    assert File.exists?(path)
    assert String.ends_with?(path, "priv/socialware/dealscout/manifest.yaml")

    # `manifest_attrs/0` (no overrides) is EXACTLY the parsed YAML — the loader
    # adds nothing, so the config file is the one source of truth (#1213).
    assert {:ok, parsed} = ManifestYaml.parse(File.read!(path))
    assert parsed == Demo.manifest_attrs()

    # field equivalence with the retired code-attrs shape (string-keyed,
    # resolver-ready): stable name + the parse-normalized module list.
    assert parsed["name"] == "dealscout"
    assert parsed["uses"] == ["hello", "crawler"]
    assert Ezagent.ActionSet.Session in parsed["bases"]
    assert Crawler in parsed["shape"]
    assert parsed["views"] == ["hello_render"]
  end

  test "manifest resolves through ManifestResolver (string name-refs → Definition)" do
    definition = resolve!()
    assert definition.name == "dealscout"

    # uses 声明依赖两个 plugin（hello 渲染面 + crawler 爬取后台——rename 后的通用能力名）
    assert definition.uses == ["hello", "crawler"]
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

    # 2026-07-07 真浏览器 e2e 修正：session 本体是 `:crawl_now` 的宿主
    # （handler 读 ctx.session_uri + session config slice），shape 必须带
    # Crawler,否则 live dispatch `{:unknown_action, :crawl_now}`。
    assert Crawler in definition.shape

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
      Enum.map(EzagentPluginCrawler.Recipes.all(), & &1.name) ++
        Enum.map(EzagentPluginHello.Application.roles(), & &1.name)

    definition = resolve!()
    Enum.each(definition.roles, fn slot -> assert slot.recipe in declared end)
  end

  test "routing is ONLY the content-triggered update rule — never hello's always→chat (red line)" do
    definition = resolve!()
    assert [rule] = definition.routing_rules

    matcher = Map.get(rule, "matcher") || Map.get(rule, :matcher)
    # #1212 from_role 硬锁（#1201 ⑥ 预案，kanban 同款）：
    # and(text_contains __dealscout_update__, from_role discover)
    assert (matcher["type"] || matcher[:type]) == "and"
    items = matcher["items"] || matcher[:items]
    assert %{"type" => "text_contains", "arg" => "__dealscout_update__"} in items
    assert %{"type" => "from_role", "arg" => "discover"} in items

    # 内容标记腿的 arg 从 update_signal/0 取（单一契约点），零 URI。
    tc = Enum.find(items, &((&1["type"] || &1[:type]) == "text_contains"))
    arg = to_string(tc["arg"] || tc[:arg])
    assert arg == Crawler.update_signal()
    refute String.contains?(arg, "://")

    # from_role 硬锁的 arg 是已声明的 discover 角色名（非 URI）——其他成员
    # 发同标记不再误触发（负例断言在 matcher 语义层，core matcher_test 已锁）。
    fr = Enum.find(items, &((&1["type"] || &1[:type]) == "from_role"))
    assert to_string(fr["arg"] || fr[:arg]) == "discover"

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

  test "legends carry the 协作协议速查 (protocol) — the in-band lingo card for newcomers" do
    definition = resolve!()
    protocol = definition.legends["dealscout"]["protocol"]
    assert is_binary(protocol)

    # 讲清三件事：discover 爬完自动触发页面刷新；手动触发用 crawl_now；
    # __dealscout_update__ 更新信号标记的含义（与 update_signal/0 契约点一致）。
    assert protocol =~ "discover"
    assert protocol =~ "crawl_now"
    assert protocol =~ Crawler.update_signal()

    # 纯说明数据：legend 机制只读 member_set/bound_rule_set/fold，protocol
    # 不参与路由——机制字段仍原样在场（上一测试锁了值）。
    assert Map.take(definition.legends["dealscout"], ["member_set", "bound_rule_set", "fold"])
           |> map_size() == 3
  end
end
