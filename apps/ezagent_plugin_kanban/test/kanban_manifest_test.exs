defmodule EzagentPluginKanban.KanbanManifestTest do
  @moduledoc """
  Shape gate for the kanban socialware manifest — config-driven, zero plugin
  code shell (Decision #156: socialware = config-only bundle; the former
  plugin-side `Demo` wrapper module is dissolved). The one source of
  truth is the deploy-seed package `apps/ezagent_web/priv/socialware_seed/
  kanban/manifest.yaml` (carried in the release box like `autoservice` /
  `hello`), loaded here DIRECTLY via `Ezagent.Socialware.ShippedManifest.load!/2`
  — the same shared loader hello's fixtures use. Production publishes this SAME
  file through the deploy-seed lane (`Ezagent.Home.SocialwareSeed` copy →
  `Ezagent.Socialware.ManifestSeed` scan/publish), never a plugin module.

  Proves the YAML file exists + parses, that the parsed manifest resolves
  through `Ezagent.Socialware.ManifestResolver.resolve/1` (the fail-closed
  authoring boundary), declares exactly the TWO agent role-slots
  (`kanban-assistant` + `dev-together`, both cc-headless active) with zero
  participant instance URIs (role-slot #1180), carries ONLY the #1190
  relay-back routing rule (never hello's `always → chat` — the handoff red
  line), and is public / supervised / non-anon / installer-owned. No DB here
  (resolve is ETS-only: PluginRegistry + SessionViewRegistry, both populated at
  app start); publish/idempotency/conformance live in
  `kanban_manifest_publish_test.exs`.

  ## The relay-back marker contract lock (spec §4.2), config-driven

  The `__done__` completion marker is the SINGLE contract point between the
  routing transport and the skill protocol. It used to be re-declared in code
  (`Demo.relay_done_marker/0`); now the manifest YAML is the authoritative
  carrier and this test reads the marker OUT of the parsed routing rule and
  locks it against (a) the spec literal and (b) the two kanban-assistant skill
  references (`.claude/skills/kanban-assistant/references/*`, whose skill side
  `relay-signal-check.sh` also locks). Three-way lock: manifest ⟷ spec literal
  ⟷ skill references.

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

  alias Ezagent.Socialware.{Definition, ManifestResolver, ManifestYaml, ShippedManifest}

  @manifest_relpath "kanban/manifest.yaml"

  # The dev-together completion marker (spec §4.2 contract literal). The
  # manifest routing rule's `text_contains` arg MUST be byte-identical to this
  # AND to the `__done__` marker in the two kanban-assistant skill references
  # (locked below + by `.claude/skills/kanban-assistant/scripts/
  # relay-signal-check.sh`).
  @relay_done_marker "__done__"

  @skill_references [
    ".claude/skills/kanban-assistant/references/kanban-team-collaboration.md",
    ".claude/skills/kanban-assistant/references/dev-together-relay-overlay.md"
  ]

  defp manifest_attrs(opts \\ []), do: ShippedManifest.load!(@manifest_relpath, opts)

  defp resolve!(opts \\ []) do
    assert {:ok, %Definition{} = definition} = ManifestResolver.resolve(manifest_attrs(opts))
    definition
  end

  test "the manifest source is the deploy-seed YAML file: exists, parses, and IS the loaded attrs" do
    path = ShippedManifest.path(@manifest_relpath)
    assert File.exists?(path)
    assert String.ends_with?(path, "priv/socialware_seed/kanban/manifest.yaml")

    # `load!/1` (no overrides) is EXACTLY the parsed YAML — the loader adds
    # nothing, so the config file is the one source of truth.
    assert {:ok, parsed} = ManifestYaml.parse(File.read!(path))
    assert parsed == manifest_attrs()

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
    assert %{"type" => "text_contains", "arg" => @relay_done_marker} in items
    assert %{"type" => "from_role", "arg" => "dev-together"} in items
    # 内容标记腿的 arg = 契约点字面（零 URI）
    assert relay_marker_from_manifest() == @relay_done_marker
    refute String.contains?(relay_marker_from_manifest(), "://")

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

  test "relay-back marker contract (spec §4.2): manifest arg == spec literal == skill references" do
    # (a) manifest side: the marker read OUT of the parsed YAML routing rule is
    # the spec contract literal — the manifest is the authoritative carrier.
    assert relay_marker_from_manifest() == @relay_done_marker

    # (b) skill side: byte-identical marker in both kanban-assistant references
    # (the protocol docs agents actually read; `relay-signal-check.sh` locks
    # them too — this keeps manifest ⟷ skill mutually consistent from ExUnit).
    repo_root = Path.expand("../../..", __DIR__)

    Enum.each(@skill_references, fn relpath ->
      path = Path.join(repo_root, relpath)
      assert File.exists?(path), "skill reference missing: #{relpath}"

      assert File.read!(path) =~ @relay_done_marker,
             "marker #{inspect(@relay_done_marker)} missing from #{relpath}"
    end)
  end

  test "legends member_set names OUR roles, fronting the relay rule-set" do
    definition = resolve!()
    legend = definition.legends["kanban"]
    assert legend
    assert Enum.sort(legend["member_set"]) == ["dev-together", "kanban-assistant"]
    assert legend["bound_rule_set"] == "relay-back"
    assert legend["fold"] == false
  end

  # Extract the relay-back `text_contains` arg from the PARSED manifest (raw
  # attrs, pre-resolve) — the config-driven read of the contract marker.
  defp relay_marker_from_manifest do
    [rule] = manifest_attrs()["routing_rules"]

    tc =
      Enum.find(rule["matcher"]["items"], &(&1["type"] == "text_contains")) ||
        raise "no text_contains leg in the kanban relay-back matcher"

    to_string(tc["arg"])
  end
end
