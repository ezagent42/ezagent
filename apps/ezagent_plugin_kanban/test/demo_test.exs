defmodule EzagentPluginKanban.DemoTest do
  @moduledoc """
  Shape gate for the kanban demo socialware manifest — since the #1213 YAML
  migration the one-source-of-truth is `priv/socialware/kanban/manifest.yaml`,
  loaded by the `EzagentPluginKanban.Demo` thin loader via
  `Ezagent.Socialware.ManifestYaml.parse/1` (the hello #162 golden-template
  play, now as a config FILE). Proves the YAML file exists + parses, that the
  parsed manifest resolves through
  `Ezagent.Socialware.ManifestResolver.resolve/1` (the fail-closed authoring
  boundary), declares exactly the TWO agent role-slots (`kanban-assistant` +
  `dev-together`, both cc-headless active) with zero participant instance URIs
  (role-slot #1180), carries ONLY the #1190 relay-back routing rule (never
  hello's `always → chat` — the handoff red line), and is public / supervised /
  non-anon / installer-owned. No DB here (resolve is ETS-only: PluginRegistry +
  SessionViewRegistry, both populated at app start); publish/idempotency/
  conformance live in `demo_publish_test.exs`.

  ## Why NOT a kanban-manager role-slot (the S2 modeling fix, kept vs the handoff)

  Allen's handoff example writes `kanban-manager × native` into `roles`, but the
  `kanban-manager` recipe is `passive: true` (`application.ex`
  `kanban_manager_recipe/0`) and the RF-6 passive-join gate rejects a passive
  actor at `session.join` (`{:passive_actor_cannot_join, _}`; locked by
  `test/e2e/role_native_create_test.exs`). Declaring it as an agent role-slot
  would crash materialize — the board modeling bug S2 already fixed. So `roles`
  stays pm + dev, the board stays a workspace-level URI-dispatch actor, and this
  divergence is reported back to Allen in the return doc. This test locks it.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Socialware.{Definition, ManifestResolver, ManifestYaml}
  alias EzagentPluginKanban.Demo

  defp resolve!(opts \\ []) do
    assert {:ok, %Definition{} = definition} = ManifestResolver.resolve(Demo.manifest_attrs(opts))
    definition
  end

  test "the manifest source is the priv YAML file: exists, parses, and IS manifest_attrs/0" do
    path = Demo.manifest_path()
    assert File.exists?(path)
    assert String.ends_with?(path, "priv/socialware/kanban/manifest.yaml")

    # `manifest_attrs/0` (no overrides) is EXACTLY the parsed YAML — the loader
    # adds nothing, so the config file is the one source of truth (#1213).
    assert {:ok, parsed} = ManifestYaml.parse(File.read!(path))
    assert parsed == Demo.manifest_attrs()

    # field equivalence with the retired code-attrs shape (string-keyed,
    # resolver-ready): stable name + the parse-normalized module list.
    assert parsed["name"] == "kanban"
    assert parsed["uses"] == ["kanban"]
    assert parsed["bases"] == [Ezagent.ActionSet.Session]
    assert parsed["views"] == ["kanban_render"]
  end

  test "manifest resolves through ManifestResolver (string name-refs → Definition)" do
    definition = resolve!()
    assert definition.name == "kanban"
    assert definition.uses == ["kanban"]
    # `"kanban_render"` resolved through the registered BoardView to the
    # backing view read ActionSet.
    assert definition.views == [Ezagent.ActionSet.KanbanRender]
    # #1180: the `members` field is retired; participants live in `roles`.
    refute Map.has_key?(Map.from_struct(definition), :members)
  end

  test "manifest resolves with a per-run unique name (the test-isolation seam)" do
    name = "kanban-demo-#{System.unique_integer([:positive])}"
    definition = resolve!(name: name)
    assert definition.name == name
  end

  test "declares exactly kanban-assistant + dev-together agent role-slots, zero instance URIs" do
    definition = resolve!()
    agent_slots = Enum.filter(definition.roles, &(&1.fill == :agent))

    assert Enum.sort(Enum.map(agent_slots, & &1.role_name)) == [
             "dev-together",
             "kanban-assistant"
           ]

    Enum.each(agent_slots, fn slot ->
      assert slot.fill == :agent
      assert slot.flavor == "cc-headless"
      assert is_binary(slot.recipe) and slot.recipe != ""
      refute String.contains?(slot.recipe, "://")
      refute String.contains?(slot.role_name, "://")
    end)
  end

  test "the :flavor option swaps BOTH slots' flavor (integration stub seam), nothing else" do
    definition = resolve!(flavor: "kanban-demo-stub")
    assert Enum.map(definition.roles, & &1.flavor) == ["kanban-demo-stub", "kanban-demo-stub"]

    assert Enum.sort(Enum.map(definition.roles, & &1.recipe)) == [
             "dev-together",
             "kanban-assistant"
           ]
  end

  test "kanban-manager is NOT a role-slot (passive board actor, RF-6) — the handoff divergence, locked" do
    definition = resolve!()
    refute "kanban-manager" in Enum.map(definition.roles, & &1.role_name)
    # but it IS still a kanban plugin recipe (the workspace board actor).
    assert "kanban-manager" in Enum.map(EzagentPluginKanban.Application.roles(), & &1.name)
  end

  test "recipe names in role-slots are a subset of the kanban plugin roles/0 recipes" do
    definition = resolve!()
    declared = Enum.map(EzagentPluginKanban.Application.roles(), & &1.name)
    Enum.each(definition.roles, fn slot -> assert slot.recipe in declared end)
  end

  test "public + supervised + NON-anon visibility with installer owner (the hello diffs)" do
    definition = resolve!()
    # scope public → cross-workspace discoverable ("Socialware 下拉" entry)…
    assert definition.visibility_policy.scope == :public
    assert definition.visibility_policy.publish_policy == :supervised
    # …but NOT an anonymous public page (kanban boards are member-facing).
    assert definition.visibility_policy.web_anon_access == false
    assert definition.owner_policy == %{type: :installer}
  end

  test "routing is ONLY the #1190 relay-back rule — never hello's always→chat (handoff red line)" do
    definition = resolve!()
    assert [rule] = definition.routing_rules

    matcher = Map.get(rule, "matcher") || Map.get(rule, :matcher)
    assert (matcher["type"] || matcher[:type]) == "and"
    # #1212 from_role 硬锁：and(text_contains __done__, from_role dev-together)
    items = matcher["items"] || matcher[:items]
    assert %{"type" => "text_contains", "arg" => "__done__"} in items
    assert %{"type" => "from_role", "arg" => "dev-together"} in items
    # 内容标记腿的 arg = 契约点字面（零 URI）
    tc = Enum.find(items, &((&1["type"] || &1[:type]) == "text_contains"))
    arg = to_string(tc["arg"] || tc[:arg])
    assert arg == Demo.relay_done_marker()
    refute String.contains?(arg, "://")

    assert (Map.get(rule, "receivers") || Map.get(rule, :receivers)) == ["kanban-assistant"]
    assert (Map.get(rule, "rule_set") || Map.get(rule, :rule_set)) == "relay-back"

    # NO `always` matcher anywhere (the hello chat route must not be copied).
    refute Enum.any?(definition.routing_rules, fn r ->
             m = Map.get(r, "matcher") || Map.get(r, :matcher) || %{}
             (m["type"] || m[:type]) == "always"
           end)

    # the whole rule set carries NO participant instance URI (round-trip safety).
    refute inspect(definition.routing_rules) =~ ~r{entity://[^/]+/(agent|user)/}
  end

  test "legends member_set names OUR roles, fronting the relay rule-set" do
    definition = resolve!()
    legend = definition.legends["kanban"]
    assert legend
    assert Enum.sort(legend["member_set"]) == ["dev-together", "kanban-assistant"]
    assert legend["bound_rule_set"] == "relay-back"
    assert legend["fold"] == false
  end
end
