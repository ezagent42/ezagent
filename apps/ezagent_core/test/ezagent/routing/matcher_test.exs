defmodule Ezagent.Routing.MatcherTest do
  use ExUnit.Case, async: true
  alias Ezagent.Routing.Matcher
  alias Ezagent.Message

  defp msg(opts \\ []) do
    sender = Keyword.get(opts, :sender, URI.new!("entity://system/user/admin"))
    mentions = Keyword.get(opts, :mentions, [])
    legend_triggers = Keyword.get(opts, :legend_triggers, [])
    text = Keyword.get(opts, :text, "hello world")

    Message.new(sender, %{text: text, attachments: []},
      mentions: mentions,
      legend_triggers: legend_triggers
    )
  end

  describe "mention/1" do
    test "matches when URI present in mentions" do
      target = URI.new!("entity://team-alpha/agent/test_cc-builder")
      m = msg(mentions: [target])

      assert Matcher.match?(Matcher.mention(target), m)
      assert Matcher.match?(Matcher.mention("entity://team-alpha/agent/test_cc-builder"), m)
    end

    test "no match when mentions empty" do
      refute Matcher.match?(Matcher.mention("entity://team-alpha/agent/test_cc-builder"), msg())
    end

    test "no match for different URI" do
      m = msg(mentions: [URI.new!("entity://team-alpha/agent/test_other")])
      refute Matcher.match?(Matcher.mention("entity://team-alpha/agent/test_cc-builder"), m)
    end

    # team-routing §3.6 (PR-6): a `mention(<token>)` matcher also fires when the
    # token is in the VIRTUAL `legend_triggers` (the symbolic legend-name path —
    # a CJK / non-URI name can't ride `:mentions`).
    test "matches a SYMBOLIC legend name carried in legend_triggers (not :mentions)" do
      m = msg(legend_triggers: ["传话游戏"])
      assert m.mentions == []
      assert Matcher.match?(Matcher.mention("传话游戏"), m)
    end

    test "no match when the legend name is absent from BOTH mentions and legend_triggers" do
      refute Matcher.match?(Matcher.mention("传话游戏"), msg(legend_triggers: ["other"]))
      refute Matcher.match?(Matcher.mention("传话游戏"), msg())
    end
  end

  describe "from/1" do
    test "matches when sender == uri" do
      m = msg(sender: URI.new!("entity://team-alpha/agent/test_cc-builder"))
      assert Matcher.match?(Matcher.from("entity://team-alpha/agent/test_cc-builder"), m)
    end

    test "no match for different sender" do
      refute Matcher.match?(Matcher.from("entity://team-alpha/agent/test_cc-builder"), msg())
    end
  end

  describe "from_role/1" do
    test "matches when the message sender currently holds the role" do
      sender = URI.new!("entity://system/agent/responser")
      m = msg(sender: sender)

      assert Matcher.match?(Matcher.from_role("responser"), m, %{
               members: %{sender => %{role_name: "responser"}}
             })
    end

    test "does not match stale role assignments" do
      sender = URI.new!("entity://system/agent/old-responser")
      m = msg(sender: sender)

      refute Matcher.match?(Matcher.from_role("responser"), m, %{
               members: %{sender => %{role_name: "builder"}}
             })
    end
  end

  describe "text_contains/1" do
    test "matches substring case-sensitive" do
      m = msg(text: "system is URGENT down")
      assert Matcher.match?(Matcher.text_contains("URGENT"), m)
      refute Matcher.match?(Matcher.text_contains("urgent"), m)
    end

    test "handles body with string keys (loaded from store)" do
      # Simulate body returned from Ecto :map column (string keys)
      m = %Message{
        sender: URI.new!("entity://system/user/admin"),
        body: %{"text" => "abc"},
        mentions: [],
        inserted_at: DateTime.utc_now(),
        id: "x"
      }

      assert Matcher.match?(Matcher.text_contains("abc"), m)
    end
  end

  describe "text_matches/1" do
    test "matches Elixir regex" do
      m = msg(text: "deploy to prod")
      assert Matcher.match?(Matcher.text_matches("^deploy"), m)
      refute Matcher.match?(Matcher.text_matches("staging$"), m)
    end

    test "construction fails fast on bad regex" do
      assert_raise MatchError, fn ->
        Matcher.text_matches("[unclosed")
      end
    end
  end

  describe "always/0" do
    test "always matches" do
      assert Matcher.match?(Matcher.always(), msg())
    end
  end

  describe "to_json/1 + from_json/1 round-trip" do
    test "all leaf matchers round-trip cleanly" do
      cases = [
        Matcher.mention("entity://system/user/admin"),
        Matcher.from("entity://team-alpha/agent/test_cc-builder"),
        Matcher.from_role("responser"),
        Matcher.text_contains("hi"),
        Matcher.text_matches("^cmd"),
        Matcher.always()
      ]

      for m <- cases do
        json = Matcher.to_json(m)
        encoded = Jason.encode!(json)
        decoded = Jason.decode!(encoded)
        assert {:ok, ^m} = Matcher.from_json(decoded)
      end
    end

    test "from_json rejects bad regex with friendly error" do
      bad = %{"type" => "text_matches", "arg" => "[unclosed"}
      assert {:error, {:invalid_regex, _}} = Matcher.from_json(bad)
    end

    test "from_json rejects unknown matcher type" do
      assert {:error, {:invalid_matcher_json, _}} =
               Matcher.from_json(%{"type" => "exotic", "arg" => "x"})
    end
  end
end
