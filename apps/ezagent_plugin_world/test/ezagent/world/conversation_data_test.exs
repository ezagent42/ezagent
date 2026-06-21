defmodule Ezagent.World.ConversationDataTest do
  @moduledoc """
  PR-2a — @mention parse is the load-bearing piece: the domain's recipient
  resolver consumes `msg.mentions`, so a wrong parse silently routes a mention
  nowhere (the exact divergence class this migration's ratchet is blind to).
  These pin world's parse to the same URIs the LiveView parser produced.
  """
  use ExUnit.Case, async: true

  alias Ezagent.World.ConversationData

  defp members do
    [
      %{"uri" => "entity://system/agent/codex-1", "display_name" => "Codex One"},
      %{"uri" => "entity://system/user/admin", "display_name" => "Admin"},
      %{"uri" => "entity://system/user/alice", "display_name" => "Alice"},
      %{"uri" => "entity://system/user/bob", "display_name" => "Alice"}
    ]
  end

  defp parsed(text), do: text |> ConversationData.parse_mentions(members()) |> Enum.map(&URI.to_string/1)

  test "explicit @entity:// URI mention resolves" do
    assert parsed("hey @entity://system/agent/codex-1 look") == ["entity://system/agent/codex-1"]
  end

  test "bare @name resolves by URI path segment" do
    assert parsed("ping @codex-1 now") == ["entity://system/agent/codex-1"]
  end

  test "bare @name resolves by unique display name" do
    assert parsed("hi @Admin") == ["entity://system/user/admin"]
  end

  test "ambiguous display name resolves to nothing (no guess)" do
    # Two members share display "Alice" and neither path segment is "Alice".
    assert parsed("yo @Alice") == []
  end

  test "unknown @name resolves to nothing" do
    assert parsed("@nobody here") == []
  end

  test "multiple + duplicate mentions dedupe, preserving distinct recipients" do
    assert parsed("@codex-1 @Admin @codex-1") == [
             "entity://system/agent/codex-1",
             "entity://system/user/admin"
           ]
  end

  test "no @ token yields no mentions" do
    assert parsed("plain message, email a@b.test is not a mention-at-start") == []
  end

  test "build_message embeds parsed mentions so the domain routes them" do
    # build_message reads members from the session slice; with no live session
    # the slice is empty, so only an explicit @entity:// URI (which needs no
    # member list) survives — proving the mentions reach msg.mentions.
    sender = Ezagent.URI.new!("entity://system/user/admin")
    session = Ezagent.URI.new!("session://system/default/none-#{System.unique_integer([:positive])}")
    msg = ConversationData.build_message(sender, "ping @entity://system/agent/codex-1", session)

    assert Enum.map(msg.mentions, &URI.to_string/1) == ["entity://system/agent/codex-1"]
  end
end
