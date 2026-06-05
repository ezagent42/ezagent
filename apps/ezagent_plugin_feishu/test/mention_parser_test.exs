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
    assert URI.to_string(uri) == "entity://team-alpha/agent/#{name}"
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

  test "@<entity-name> resolves without consulting stored flavor" do
    name = unique_agent_name("full")
    spawn_agent!(name)

    assert [%URI{} = uri] = MentionParser.extract_agent_mentions("@#{name} hi")
    assert URI.to_string(uri) == "entity://team-alpha/agent/#{name}"
  end

  test "non-binary input returns []" do
    assert [] = MentionParser.extract_agent_mentions(nil)
    assert [] = MentionParser.extract_agent_mentions(123)
  end

  # team-routing-unification §3.6 (PR-6, codex-redesign) — legend precedence at
  # the parser. `extract_mentions/2` consults the session legend registry
  # BEFORE the URI-mention path and returns `{mentions, legend_triggers}`. A
  # legend token is surfaced as a SYMBOLIC NAME in `legend_triggers` (NOT
  # pre-canonicalized to concrete URIs — the send path fires the entry rule via
  # the Resolver, carrying ctx + expanding magic receivers). The legend name
  # never enters `mentions` (it is not a castable URI).
  describe "extract_mentions/2 — legend precedence (GATE b)" do
    test "a legend token surfaces as a SYMBOLIC name in legend_triggers, not in mentions" do
      legends =
        Ezagent.Routing.Legend.put(%{}, "传话游戏",
          member_set: ["relay-cc"],
          bound_rule_set: "telephone"
        )

      # No live agent named 传话游戏 exists; without legend precedence the CJK
      # token silent-drops. WITH precedence it surfaces as a legend trigger.
      assert {[], ["传话游戏"]} = MentionParser.extract_mentions("@传话游戏 开始", legends)
    end

    test "a legend takes precedence even if a concrete agent shares the typed token" do
      name = unique_agent_name("collide")
      spawn_agent!(name)

      # Register a legend whose NAME equals the typed token the live agent
      # would otherwise match.
      legends =
        Ezagent.Routing.Legend.put(%{}, name,
          member_set: [],
          bound_rule_set: "rs-#{name}"
        )

      # Legend wins: the token rides legend_triggers; the colliding agent URI is
      # NOT in mentions (the legend token is removed from the URI-mention scan).
      assert {[], [^name]} = MentionParser.extract_mentions("@#{name} go", legends)
    end

    test "non-legend mentions still resolve to concrete agent URIs (mixed)" do
      name = unique_agent_name("mixed")
      spawn_agent!(name)

      legends =
        Ezagent.Routing.Legend.put(%{}, "传话游戏", member_set: [], bound_rule_set: "telephone")

      {mentions, legend_triggers} =
        MentionParser.extract_mentions("@传话游戏 and @#{name}", legends)

      assert legend_triggers == ["传话游戏"]
      assert Enum.any?(mentions, &(URI.to_string(&1) == "entity://team-alpha/agent/#{name}"))
    end

    test "empty legends → {extract_agent_mentions, []}" do
      name = unique_agent_name("nolegend")
      spawn_agent!(name)

      assert {[%URI{} = uri], []} = MentionParser.extract_mentions("@#{name} hi", %{})
      assert URI.to_string(uri) == "entity://team-alpha/agent/#{name}"
    end
  end

  # codex 2026-06-01 MED #5 — left-boundary: `foo@name` must NOT match.
  describe "extract_agent_mentions/1 — left boundary" do
    test "an @ glued to a preceding word char (email-like) does not mention" do
      name = unique_agent_name("boundary")
      spawn_agent!(name)

      # Glued: `foo@<name>` — no left boundary, must NOT resolve.
      assert [] = MentionParser.extract_agent_mentions("mail foo@#{name} now")

      # Space-separated: `@<name>` — resolves as before.
      assert [%URI{}] = MentionParser.extract_agent_mentions("ping @#{name} now")
    end
  end

  defp unique_agent_name(prefix) do
    "pr16-#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp spawn_agent!(name) do
    uri = Ezagent.URI.agent("team-alpha", name)
    {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: uri})
    on_exit(fn -> :ok end)
    :ok
  end
end
