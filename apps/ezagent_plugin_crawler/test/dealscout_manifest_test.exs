defmodule EzagentPluginCrawler.DealscoutManifestTest do
  @moduledoc """
  Shape gate for the dealscout socialware manifest — config-driven, zero plugin
  code shell (Decision #156: socialware = config-only bundle; the former
  plugin-side `Demo` wrapper module is dissolved). The one
  source of truth is the deploy-seed package `apps/ezagent_web/priv/
  socialware_seed/dealscout/manifest.yaml` (carried in the release box like
  `autoservice` / `hello` / `kanban`), loaded here DIRECTLY via
  `Ezagent.Socialware.ShippedManifest.load!/2` — the same shared loader the
  other flagships' fixtures use. Production publishes this SAME file through
  the deploy-seed lane (`Ezagent.Home.SocialwareSeed` copy →
  `Ezagent.Socialware.ManifestSeed` scan/publish), never a plugin module.

  Proves the YAML file exists + parses, that the parsed manifest resolves
  through `Ezagent.Socialware.ManifestResolver.resolve/1` (the fail-closed
  authoring boundary), composes the platform public face (Surface+Turn shape,
  crawler 自带的 `crawler_render` view——段4 D2 显示自包含, `external_feed`
  adapter, anon-readable), declares
  exactly the `discover` + `page` agent role-slots with zero participant
  instance URIs (role-slot #1180), carries ONLY the content-triggered
  update-signal rule (never hello's `always → chat` — the kanban-handoff red
  line; receiver = `orchestrator`, the requires-declared 编排脑 —— 2026-07-10
  零人工中继修正：native page 从不收消息 #1201 ②, 信号照 kanban 先例路由给
  操作员, 规则挂 `dealscout-crawl-directive` prompt template 渲染成自动化
  执行指令), and is public / supervised / ANON-readable / installer-owned.
  Publish/idempotency/conformance live in `dealscout_manifest_publish_test.exs`.

  ## Why DataCase（段3 起）

  历史上本 gate 是 no-DB（resolve 只查 PluginRegistry + SessionViewRegistry
  两张 ETS）。D5 给 manifest 加了 `requires: [orchestrator]`，resolver 的
  `ensure_required_published` 经 `DefinitionRegistry.lookup`（ConfigStore，
  DB-backed）核验被依赖定义已发布——所以 setup 里 seed builtin definitions
  且本 gate 转 DataCase（照 domain_session `manifest_resolver_test.exs`）。

  ## The single-slot flavor override (spec D8), test-side

  `ShippedManifest.load!/2`'s shared `:flavor` seam swaps EVERY agent slot —
  right for kanban (both slots cc-headless), wrong for dealscout, whose `page`
  slot is pinned `crawler-page × native`（crawler 通用页面发布腿，段4 D2）.
  Per D8 we do NOT grow the shared module for one
  consumer: this test carries its own thin `:discover_flavor` helper — a
  post-`load!` Map transform that touches ONLY the `discover` slot.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.Crawler

  alias Ezagent.Socialware.{
    Definition,
    DefinitionRegistry,
    ManifestResolver,
    ManifestYaml,
    ShippedManifest
  }

  @manifest_relpath "dealscout/manifest.yaml"

  setup do
    # D5：resolve 现在核验 requires（builtin orchestrator 定义须已发布，
    # DefinitionRegistry/ConfigStore 车道）——moduledoc §Why DataCase。
    {:ok, _} = Elixir.Application.ensure_all_started(:ezagent_domain_session)
    :ok = seed_builtins()
    :ok
  end

  defp seed_builtins do
    case DefinitionRegistry.seed_builtin_definitions() do
      :ok -> :ok
      {:error, {:socialware_definition_seed_collision, _}} -> :ok
    end
  end

  # D8 单槽 override（moduledoc §The single-slot flavor override）：`:name`
  # 透传共享 loader；`:discover_flavor` 在 load! 之后只换 discover 槽。
  defp manifest_attrs(opts \\ []) do
    {discover_flavor, opts} = Keyword.pop(opts, :discover_flavor)

    @manifest_relpath
    |> ShippedManifest.load!(opts)
    |> put_discover_flavor(discover_flavor)
  end

  defp put_discover_flavor(attrs, nil), do: attrs

  defp put_discover_flavor(attrs, flavor) when is_binary(flavor) do
    Map.update!(attrs, "roles", fn roles ->
      Enum.map(roles, fn
        %{"fill" => "agent", "role_name" => "discover"} = slot ->
          Map.put(slot, "flavor", flavor)

        slot ->
          slot
      end)
    end)
  end

  defp resolve!(opts \\ []) do
    assert {:ok, %Definition{} = definition} = ManifestResolver.resolve(manifest_attrs(opts))
    definition
  end

  test "the manifest source is the deploy-seed YAML file: exists, parses, and IS the loaded attrs" do
    path = ShippedManifest.path(@manifest_relpath)
    assert File.exists?(path)
    assert String.ends_with?(path, "priv/socialware_seed/dealscout/manifest.yaml")

    # `manifest_attrs/0` (no overrides) is EXACTLY the parsed YAML — the loader
    # adds nothing, so the config file is the one source of truth.
    assert {:ok, parsed} = ManifestYaml.parse(File.read!(path))
    assert parsed == manifest_attrs()

    # field equivalence with the retired code-attrs shape (string-keyed,
    # resolver-ready): stable name + the parse-normalized module list.
    assert parsed["name"] == "dealscout"
    assert parsed["uses"] == ["crawler"]
    assert Ezagent.ActionSet.Session in parsed["bases"]
    assert Crawler in parsed["shape"]
    assert parsed["views"] == ["crawler_render"]
  end

  test "manifest resolves through ManifestResolver (string name-refs → Definition)" do
    definition = resolve!()
    assert definition.name == "dealscout"

    # uses 只声明 crawler（段4 D3 诚实化：显示/页面发布是 crawler 自带件，
    # 不再借 hello——rename 后的通用能力名）
    assert definition.uses == ["crawler"]
    # D5（段3，照 hello #1230）：requires 递归带上平台 orchestrator（builtin
    # code-seed 定义）——解"装完会话没人应答"（gap⑪）；conformance 的
    # requires_published / requires_cycle_free 在 publish 测试整套跑。
    assert definition.requires == ["orchestrator"]
    # `"crawler_render"` resolved through crawler's registered LeadsView to the
    # backing view read ActionSet（段4 D2：显示自包含，不再借 hello 的
    # hello_render）。
    assert definition.views == [Ezagent.ActionSet.CrawlerRender]
    # #1180: the `members` field is retired; participants live in `roles`.
    refute Map.has_key?(Map.from_struct(definition), :members)
  end

  test "manifest resolves with a per-run unique name (the test-isolation seam)" do
    name = "dealscout-demo-#{System.unique_integer([:positive])}"
    definition = resolve!(name: name)
    assert definition.name == name
  end

  test "composes the platform public face: Surface+Turn shape, external_feed adapter" do
    definition = resolve!()
    # 平台公开面组件逐项在场（hello 先例的同一套 domain ActionSet 配置）
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

  test "declares exactly the discover + dealscout-assistant + page agent role-slots, zero instance URIs (#1180)" do
    definition = resolve!()
    agent_slots = Enum.filter(definition.roles, &(&1.fill == :agent))

    assert Enum.sort(Enum.map(agent_slots, & &1.role_name)) ==
             ["dealscout-assistant", "discover", "page"]

    # 入库操作员（零人工中继 case-2，kanban-assistant 模具）：cc-headless
    # 真脑，常设职责在 recipe persona（可信渠道，非消息载权）。
    assistant = Enum.find(agent_slots, &(&1.role_name == "dealscout-assistant"))
    assert assistant.recipe == "dealscout-assistant"
    assert assistant.flavor == "cc-headless"

    discover = Enum.find(agent_slots, &(&1.role_name == "discover"))
    assert discover.recipe == "dealscout-discover"
    # 2026-07-10 段3 D1：cc-headless 物化必崩（平台 gap，绕开不修）→ 换 hello
    # builder/responser 已验证的 py 物化车道（script-carrying recipe）。
    assert discover.flavor == "py"

    page = Enum.find(agent_slots, &(&1.role_name == "page"))

    # 段4 D2：page 槽 = crawler 通用页面发布腿（把留存线索驱动 Turn/Surface
    # 落 committed 公开页），取代曾借 hello Generator 的临时 ALT。
    assert page.recipe == "crawler-page"
    assert page.flavor == "native"

    Enum.each(agent_slots, fn slot ->
      refute String.contains?(slot.recipe, "://")
      refute String.contains?(slot.role_name, "://")
    end)
  end

  test "the :discover_flavor helper swaps ONLY the discover slot (page stays crawler-page × native)" do
    definition = resolve!(discover_flavor: "dealscout-demo-stub")
    discover = Enum.find(definition.roles, &(&1.role_name == "discover"))
    page = Enum.find(definition.roles, &(&1.role_name == "page"))

    assert discover.flavor == "dealscout-demo-stub"
    assert discover.recipe == "dealscout-discover"
    # page 槽是页面发布腿（crawler 通用 recipe × native），不随 stub 换。
    assert page.flavor == "native"
    assert page.recipe == "crawler-page"
  end

  test "role-slot recipes resolve to plugin-declared recipe names (config references real recipes)" do
    declared = Enum.map(EzagentPluginCrawler.Recipes.all(), & &1.name)

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

    # 内容标记腿的 arg 是 manifest 本体携带的字面（权威载体），零 URI。
    refute String.contains?(update_marker_from_manifest(), "://")

    # from_role 硬锁的 arg 是已声明的 discover 角色名（非 URI）——其他成员
    # 发同标记不再误触发（负例断言在 matcher 语义层，core matcher_test 已锁）。
    fr = Enum.find(items, &((&1["type"] || &1[:type]) == "from_role"))
    assert to_string(fr["arg"] || fr[:arg]) == "discover"

    # receiver = dealscout-assistant（专属入库操作员，2026-07-10 零人工中继
    # case-2：native page 不做 receiver（#1201 ②，与 #1319 L2
    # receivers_can_receive 相容）；orchestrator 中间形态三轮 e2e 被 cc 真脑
    # 按"消息自证授权"拒（09e/09g/09h）——duty 走 persona 渠道的专属操作员）。
    assert (Map.get(rule, "receivers") || Map.get(rule, :receivers)) == ["dealscout-assistant"]
    assert (Map.get(rule, "rule_set") || Map.get(rule, :rule_set)) == "dealscout-update"

    # 规则挂 prompt_template_ref：投递渲染成带 {session} 的自动化执行指令。
    assert (Map.get(rule, "prompt_template_ref") || Map.get(rule, :prompt_template_ref)) ==
             "dealscout-crawl-directive"

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
    assert Enum.sort(legend["member_set"]) == ["dealscout-assistant", "discover", "page"]
    assert legend["bound_rule_set"] == "dealscout-update"
    assert legend["fold"] == false
  end

  test "legends carry the 协作协议速查 (protocol) — the in-band lingo card for newcomers" do
    definition = resolve!()
    protocol = definition.legends["dealscout"]["protocol"]
    assert is_binary(protocol)

    # 讲清三件事：discover 爬完自动触发页面刷新；手动触发用 crawl_now；
    # 更新信号标记的含义（与 manifest routing 的 text_contains arg 一致）。
    assert protocol =~ "discover"
    assert protocol =~ "crawl_now"
    assert protocol =~ update_marker_from_manifest()

    # 纯说明数据：legend 机制只读 member_set/bound_rule_set/fold，protocol
    # 不参与路由——机制字段仍原样在场（上一测试锁了值）。
    assert Map.take(definition.legends["dealscout"], ["member_set", "bound_rule_set", "fold"])
           |> map_size() == 3
  end

  test "update-signal contract: manifest YAML is the authoritative carrier, code constants must match" do
    # 契约锁反转（Decision #156，kanban relay-back marker 同款）：以前是代码
    # `Crawler.update_signal/0` 为基准锁 manifest；现在 manifest YAML 是权威
    # 载体——从 parse 后的 manifest 本体读出 routing 的 text_contains arg /
    # receivers，断言 emit 侧代码常量（内容协议的发信方）与之逐字节一致。
    # 常量漂移 = emit 的信号不再命中自家 routing 规则，这里当场红。
    assert Crawler.update_signal() == update_marker_from_manifest()

    # page 角色槽名同理：直接 dispatch 腿按 `Crawler.page_role/0` 从 session
    # members 解析 page 成员，必须就是 manifest `roles` 声明的 page 槽名
    # （2026-07-10 起 routing receiver 是 orchestrator——native page 从不收
    # 消息 #1201 ②；page 槽仍是发布腿的解析契约点，权威载体从 receivers
    # 挪到 roles）。
    page_slot =
      Enum.find(manifest_attrs()["roles"], fn slot ->
        slot["fill"] == "agent" and slot["recipe"] == "crawler-page"
      end)

    assert page_slot["role_name"] == Crawler.page_role()

    # emit 侧镜像 #2（段3）：discover 的 py script（"回复中自带触发"形态的
    # 信号发信方）在 recipe 装配时从 `Crawler.update_signal/0` 注入同一字面量
    # ——script 内容必须带 manifest 权威标记，且占位符不得残留（残留 = 装配
    # 断链，script 启动时也会 fail-loud，这里提前当场红）。
    discover_recipe =
      Enum.find(EzagentPluginCrawler.Recipes.all(), &(&1.name == "dealscout-discover"))

    assert discover_recipe.script =~ update_marker_from_manifest()
    refute discover_recipe.script =~ EzagentPluginCrawler.Recipes.update_signal_placeholder()
  end

  test "trigger template + assistant persona: duty in persona (trusted), template only renders the event" do
    # 2026-07-10 零人工中继三轮 e2e 收敛（09e/09g/09h）：cc 真脑一致拒绝
    # "路由消息自证授权/消息教它执行特权动作"（拒得对）。所以分工是：
    # ① 触发模板（prompt_template）只报事实：{body} 原文 + {session} 靶
    #    （PromptTemplate v1 校验 {body} 必须在场），不自证协议、不内嵌
    #    执行机制、不出现让 agent 自己摸集群 cookie 的字样；
    # ② 职责与官方 CLI 执行步骤在 dealscout-assistant 的 recipe persona 里
    #    （materialize 写进它 sandbox 的 CLAUDE.md——安装者配置的可信渠道，
    #    kanban-assistant skill 同款分工）。
    attrs = manifest_attrs()
    [rule] = attrs["routing_rules"]
    ref = rule["prompt_template_ref"]
    template = attrs["prompt_templates"][ref]

    assert is_binary(template)
    assert :ok == Ezagent.Routing.PromptTemplate.validate(template)
    assert template =~ "{session}"
    assert template =~ "dealscout-assistant"
    refute template =~ "runtime/cookie"
    refute template =~ "erpc"

    persona =
      EzagentPluginCrawler.Recipes.all()
      |> Enum.find(&(&1.name == "dealscout-assistant"))
      |> Map.fetch!(:prompt)

    # persona 教官方 CLI 工具面（`mix ezagent session crawl_now/search`，
    # 凭证由 CLI 内部处理）+ 身份 env + 如实汇报纪律。
    assert persona =~ "mix ezagent session search"
    assert persona =~ "mix ezagent session crawl_now"
    assert persona =~ "EZAGENT_USER_TOKEN"
    assert persona =~ "EZAGENT_ENTITY_URI"
    refute persona =~ "runtime/cookie"

    # caps：操作员 recipe 申请 crawler 动作 cap（kanban-assistant 模具；
    # role-slot 授予的 scope 边界见返回件——e2e 如实拍 CapBAC 裁决）。
    caps =
      EzagentPluginCrawler.Recipes.all()
      |> Enum.find(&(&1.name == "dealscout-assistant"))
      |> Map.fetch!(:requested_caps)

    assert %{behavior: Crawler, action: :crawl_now} in caps
    assert %{behavior: Crawler, action: :search} in caps
    assert %{behavior: Ezagent.ActionSet.CrawlerPage, action: :publish_page} in caps

    # 官方 CLI 工具面的另一半：crawler 插件把这两个动作注册成 Session Kind
    # 全局 dispatchable 行为（email plugin 先例），CLI 子命令树才长出
    # `session crawl_now/search`。
    declared = EzagentPluginCrawler.Application.behaviors()
    assert {Ezagent.Entity.Session, :crawl_now, Crawler} in declared
    assert {Ezagent.Entity.Session, :search, Crawler} in declared
  end

  # Extract the update-signal `text_contains` arg from the PARSED manifest (raw
  # attrs, pre-resolve) — the config-driven read of the contract marker.
  defp update_marker_from_manifest do
    [rule] = manifest_attrs()["routing_rules"]

    tc =
      Enum.find(rule["matcher"]["items"], &(&1["type"] == "text_contains")) ||
        raise "no text_contains leg in the dealscout update matcher"

    to_string(tc["arg"])
  end
end
