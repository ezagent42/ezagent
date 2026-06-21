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

  # NOTE: `build_message/3,4` and `message_row/1` tests live in
  # `EzagentWeb.WorldConversationTest` (a sandbox-backed `ConnCase`), NOT here:
  # they resolve entity display names / download tokens through the Repo, so they
  # need Ecto-sandbox ownership. This module stays `async: true` + DB-free
  # (pure `parse_mentions`), which is exactly why the parse tests are fast here.
end
