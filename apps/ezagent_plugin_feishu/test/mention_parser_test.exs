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

  test "non-binary input returns []" do
    assert [] = MentionParser.extract_agent_mentions(nil)
    assert [] = MentionParser.extract_agent_mentions(123)
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
