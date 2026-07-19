defmodule EzagentPluginFeishu.MentionParserTest do
  @moduledoc """
  Phase 6 PR 16 — @text-grep agent mention parser.

  Read-plane PR-4 rework: resolution is CALLER-scoped
  (`extract_agent_mentions/2`, `extract_mentions/3`) — the parser walks
  the caller-visible live agents of the caller's workspace via
  `WorkspaceReads.agents/2` (mention-scoped), never the global registry.
  Tests therefore seed: the team-alpha workspace, a declared-member
  caller, and per-test agents that are declared members (shared roster)
  with a durable snapshot row (the chokepoint's base listing) AND a live
  Kind (the mention liveness filter).
  """
  use EzagentCore.DataCase, async: false

  alias EzagentPluginFeishu.MentionParser

  setup do
    ensure_workspace("team-alpha")

    caller =
      Ezagent.URI.user("team-alpha", "mention-caller-#{System.unique_integer([:positive])}")

    {:ok, _row} = Ezagent.Users.create(caller, nil, [])
    :ok = add_workspace_member("team-alpha", caller)

    {:ok, caller: caller}
  end

  test "no @ tokens returns []", %{caller: caller} do
    assert [] = MentionParser.extract_agent_mentions("just plain text", caller)
  end

  test "@<name> for unknown agent returns []", %{caller: caller} do
    assert [] = MentionParser.extract_agent_mentions("@nobody-here hello", caller)
  end

  test "@<name> for live caller-visible agent returns that URI", %{caller: caller} do
    name = unique_agent_name("solo")
    spawn_agent!(name)

    assert [%URI{} = uri] = MentionParser.extract_agent_mentions("@#{name} look", caller)
    assert URI.to_string(uri) == "entity://team-alpha/agent/#{name}"
  end

  test "duplicates dedup'd", %{caller: caller} do
    name = unique_agent_name("dup")
    spawn_agent!(name)

    uris = MentionParser.extract_agent_mentions("@#{name} ping @#{name} again", caller)
    assert length(uris) == 1
  end

  test "multiple @s — only live agents pass", %{caller: caller} do
    live_name = unique_agent_name("live")
    spawn_agent!(live_name)

    uris = MentionParser.extract_agent_mentions("@#{live_name} and @no-such-agent-zzz", caller)
    assert length(uris) == 1
  end

  test "@<entity-name> resolves without consulting stored flavor", %{caller: caller} do
    name = unique_agent_name("full")
    spawn_agent!(name)

    assert [%URI{} = uri] = MentionParser.extract_agent_mentions("@#{name} hi", caller)
    assert URI.to_string(uri) == "entity://team-alpha/agent/#{name}"
  end

  test "non-binary input returns []", %{caller: caller} do
    assert [] = MentionParser.extract_agent_mentions(nil, caller)
    assert [] = MentionParser.extract_agent_mentions(123, caller)
  end

  test "a caller with no workspace membership resolves NOTHING (mention-scoped, fail-closed)" do
    name = unique_agent_name("scoped")
    spawn_agent!(name)

    outsider =
      Ezagent.URI.new!("entity://team-alpha/user/outsider-#{System.unique_integer([:positive])}")

    assert [] = MentionParser.extract_agent_mentions("@#{name} hi", outsider)
    assert [] = MentionParser.extract_agent_mentions("@#{name} hi", nil)
  end

  # team-routing-unification §3.6 (PR-6, codex-redesign) — legend precedence at
  # the parser. `extract_mentions/3` consults the session legend registry
  # BEFORE the URI-mention path and returns `{mentions, legend_triggers}`. A
  # legend token is surfaced as a SYMBOLIC NAME in `legend_triggers` (NOT
  # pre-canonicalized to concrete URIs — the send path fires the entry rule via
  # the Resolver, carrying ctx + expanding magic receivers). The legend name
  # never enters `mentions` (it is not a castable URI).
  describe "extract_mentions/3 — legend precedence (GATE b)" do
    test "a legend token surfaces as a SYMBOLIC name in legend_triggers, not in mentions",
         %{caller: caller} do
      legends =
        Ezagent.Routing.Legend.put(%{}, "传话游戏",
          member_set: ["relay-cc"],
          bound_rule_set: "telephone"
        )

      # No live agent named 传话游戏 exists; without legend precedence the CJK
      # token silent-drops. WITH precedence it surfaces as a legend trigger.
      assert {[], ["传话游戏"]} = MentionParser.extract_mentions("@传话游戏 开始", legends, caller)
    end

    test "a legend takes precedence even if a concrete agent shares the typed token",
         %{caller: caller} do
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
      assert {[], [^name]} = MentionParser.extract_mentions("@#{name} go", legends, caller)
    end

    test "non-legend mentions still resolve to concrete agent URIs (mixed)", %{caller: caller} do
      name = unique_agent_name("mixed")
      spawn_agent!(name)

      legends =
        Ezagent.Routing.Legend.put(%{}, "传话游戏", member_set: [], bound_rule_set: "telephone")

      {mentions, legend_triggers} =
        MentionParser.extract_mentions("@传话游戏 and @#{name}", legends, caller)

      assert legend_triggers == ["传话游戏"]
      assert Enum.any?(mentions, &(URI.to_string(&1) == "entity://team-alpha/agent/#{name}"))
    end

    test "empty legends → {extract_agent_mentions, []}", %{caller: caller} do
      name = unique_agent_name("nolegend")
      spawn_agent!(name)

      assert {[%URI{} = uri], []} = MentionParser.extract_mentions("@#{name} hi", %{}, caller)
      assert URI.to_string(uri) == "entity://team-alpha/agent/#{name}"
    end
  end

  # codex 2026-06-01 MED #5 — left-boundary: `foo@name` must NOT match.
  describe "extract_agent_mentions/2 — left boundary" do
    test "an @ glued to a preceding word char (email-like) does not mention", %{caller: caller} do
      name = unique_agent_name("boundary")
      spawn_agent!(name)

      # Glued: `foo@<name>` — no left boundary, must NOT resolve.
      assert [] = MentionParser.extract_agent_mentions("mail foo@#{name} now", caller)

      # Space-separated: `@<name>` — resolves as before.
      assert [%URI{}] = MentionParser.extract_agent_mentions("ping @#{name} now", caller)
    end
  end

  defp unique_agent_name(prefix) do
    "pr16-#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp spawn_agent!(name) do
    uri = Ezagent.URI.agent("team-alpha", name)
    {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: uri})
    # The chokepoint's base listing is snapshot-sourced (live ∪ dormant);
    # the mention filter then keeps only LIVE agents.
    {:ok, _snap} = Ezagent.SnapshotStore.write(uri, %{}, kind_type: :agent)
    :ok = add_workspace_member("team-alpha", uri)
    on_exit(fn -> :ok end)
    uri
  end

  defp ensure_workspace(name) do
    case Ezagent.Workspace.create(name, %{}) do
      {:ok, _pid} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp add_workspace_member(name, uri) do
    # Direct store write (read-modify-write to preserve existing members)
    # — avoids the full add_member dispatch chain (cap issuance needs the
    # admin Kind, which is not part of the fixture).
    existing =
      case Ezagent.Workspace.Store.get_by_name(name) do
        %{members: members} when is_list(members) -> members
        _ -> []
      end

    {:ok, _} = Ezagent.Workspace.Store.update_members(name, Enum.uniq([uri | existing]))
    :ok
  end
end
