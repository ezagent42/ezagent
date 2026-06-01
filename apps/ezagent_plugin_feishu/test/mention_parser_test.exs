defmodule EzagentPluginFeishu.MentionParserTest do
  @moduledoc """
  Phase 6 PR 16 — @text-grep agent mention parser.

  Tests use SpawnRegistry to materialize a per-test agent so the
  liveness check passes deterministically — no dependency on what
  happens to be live in the dev BEAM.
  """
  use EzagentCore.DataCase, async: false

  alias EzagentPluginFeishu.MentionParser

  test "no @ tokens returns []" do
    assert [] = MentionParser.extract_agent_mentions("just plain text")
  end

  test "@<name> for unknown agent returns []" do
    assert [] = MentionParser.extract_agent_mentions("@nobody-here hello")
  end

  test "@<name> for live agent returns that URI" do
    name = unique_agent_name("solo")
    spawn_agent!(name)

    assert [%URI{} = uri] = MentionParser.extract_agent_mentions("@#{name} look")
    # PR #141 SPEC v2: agent URIs are entity://agent/<flavor>_<name>
    assert URI.to_string(uri) == "entity://agent/team-alpha/cc_#{name}"
  end

  test "duplicates dedup'd" do
    name = unique_agent_name("dup")
    spawn_agent!(name)

    uris = MentionParser.extract_agent_mentions("@#{name} ping @#{name} again")
    assert length(uris) == 1
  end

  test "multiple @s — only live agents pass" do
    live_name = unique_agent_name("live")
    spawn_agent!(live_name)

    uris = MentionParser.extract_agent_mentions("@#{live_name} and @no-such-agent-zzz")
    assert length(uris) == 1
  end

  test "@<full-entity-name> with flavor prefix also resolves (2026-05-26 Allen UX fix)" do
    # Allen's Feishu UX: operator sees `cc_<name>` in the LV MemberPanel
    # and types that full handle in Feishu. The parser must match BOTH
    # the suffix-after-flavor `<name>` (original SPEC §5.14 design) AND
    # the full entity_name `cc_<name>` (the MemberPanel-visible handle).
    # Pre-fix, only the suffix matched — Feishu @-mention silently
    # failed to populate `messages.mentions`, breaking cc routing
    # for every @-mention typed from Feishu side.
    name = unique_agent_name("full")
    spawn_agent!(name)

    # The agent's URI is `entity://agent/team-alpha/cc_<name>`.
    # Match A: typing the suffix-after-flavor (`@<name>`).
    assert [%URI{} = uri_suffix] = MentionParser.extract_agent_mentions("@#{name} hi")
    assert URI.to_string(uri_suffix) == "entity://agent/team-alpha/cc_#{name}"

    # Match B: typing the full entity_name including flavor (`@cc_<name>`).
    assert [%URI{} = uri_full] = MentionParser.extract_agent_mentions("@cc_#{name} hi")
    assert URI.to_string(uri_full) == "entity://agent/team-alpha/cc_#{name}"
  end

  test "non-binary input returns []" do
    assert [] = MentionParser.extract_agent_mentions(nil)
    assert [] = MentionParser.extract_agent_mentions(123)
  end

  # team-routing-unification §3.6 (PR-6) — legend precedence at the parser.
  # `extract_mentions/2` consults the session legend registry BEFORE the
  # URI-mention path: a legend is intercepted and resolved to its bound
  # rule-set entry's CONCRETE receiver URIs (firing the flow's first hop), so a
  # legend NAME never mis-routes through the concrete-URI matcher AND never
  # enters message.mentions as a non-castable string.
  describe "extract_mentions/2 — legend precedence (GATE b)" do
    test "a legend resolves to its bound rule-set entry's concrete receiver URI" do
      entry_receiver = "entity://agent/team-alpha/cc_relay#{System.unique_integer([:positive])}"
      seed_entry!("telephone", entry_receiver)

      legends =
        Ezagent.Routing.Legend.put(%{}, "传话游戏",
          member_set: ["relay-cc"],
          bound_rule_set: "telephone"
        )

      # No live agent named 传话游戏 exists; without legend precedence the
      # CJK token silent-drops. WITH precedence it fires the entry → its
      # concrete receiver URI is emitted (persistence-safe).
      assert [%URI{} = uri] = MentionParser.extract_mentions("@传话游戏 开始", legends)
      assert URI.to_string(uri) == entry_receiver
    end

    test "a legend takes precedence even if a concrete agent shares the typed token" do
      name = unique_agent_name("collide")
      spawn_agent!(name)

      entry_receiver = "entity://agent/team-alpha/cc_relay#{System.unique_integer([:positive])}"
      seed_entry!("rs-#{name}", entry_receiver)

      # Register a legend whose NAME equals the typed token the live agent
      # would otherwise match (full entity name `cc_<name>`).
      legends =
        Ezagent.Routing.Legend.put(%{}, "cc_#{name}",
          member_set: [],
          bound_rule_set: "rs-#{name}"
        )

      # Legend wins: the legend's entry receiver, NOT the colliding agent URI.
      assert [%URI{} = uri] = MentionParser.extract_mentions("@cc_#{name} go", legends)
      assert URI.to_string(uri) == entry_receiver
    end

    test "non-legend mentions still resolve to concrete agent URIs (mixed)" do
      name = unique_agent_name("mixed")
      spawn_agent!(name)

      entry_receiver = "entity://agent/team-alpha/cc_relay#{System.unique_integer([:positive])}"
      seed_entry!("telephone", entry_receiver)

      legends =
        Ezagent.Routing.Legend.put(%{}, "传话游戏", member_set: [], bound_rule_set: "telephone")

      out = MentionParser.extract_mentions("@传话游戏 and @#{name}", legends)

      assert Enum.any?(out, &(URI.to_string(&1) == entry_receiver))
      assert Enum.any?(out, &(URI.to_string(&1) == "entity://agent/team-alpha/cc_#{name}"))
    end

    test "empty legends → behaves like extract_agent_mentions (URI-only)" do
      name = unique_agent_name("nolegend")
      spawn_agent!(name)

      assert [%URI{} = uri] = MentionParser.extract_mentions("@#{name} hi", %{})
      assert URI.to_string(uri) == "entity://agent/team-alpha/cc_#{name}"
    end
  end

  # Seed a single-receiver rule-set entry (position 0) so a legend bound to
  # `rule_set` resolves to `receiver`.
  defp seed_entry!(rule_set, receiver) do
    {:ok, _} =
      Ezagent.Routing.RuleStore.add(
        EzagentDomainChat.Routing.MentionRouting,
        Ezagent.Routing.Matcher.mention(rule_set),
        [receiver],
        URI.new!("entity://user/system/admin"),
        rule_set: rule_set,
        position: 0,
        prompt_template_ref: "telephone_hop"
      )

    :ok
  end

  defp unique_agent_name(prefix) do
    "pr16-#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp spawn_agent!(name) do
    # PR #141 SPEC v2: agent URIs are entity://agent/<flavor>_<name>;
    # the AgentTypeRegistry needs a registered fn for whatever flavor
    # we use. The chat plugin registers "cc" → Entity.Agent in normal
    # boot, so spawn one of those here.
    uri = URI.parse("entity://agent/team-alpha/cc_" <> name)
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    on_exit(fn -> :ok end)
    :ok
  end
end
