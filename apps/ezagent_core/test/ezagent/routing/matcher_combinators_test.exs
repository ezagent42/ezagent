defmodule Ezagent.Routing.MatcherCombinatorsTest do
  use ExUnit.Case, async: true

  alias Ezagent.Routing.Matcher

  defp msg(text \\ "hello", mentions \\ [], sender \\ "entity://system/user/admin") do
    %Ezagent.Message{
      id: "test",
      sender: Ezagent.URI.new!(sender),
      body: %{text: text, attachments: []},
      mentions: Enum.map(mentions, &URI.parse/1),
      ref_id: nil,
      inserted_at: ~U[2026-05-16 00:00:00.000000Z]
    }
  end

  describe "all_of/1 + match?/2" do
    test "true when every leaf matches" do
      m =
        Matcher.all_of([
          Matcher.mention("entity://team-alpha/agent/test_x"),
          Matcher.text_contains("hi")
        ])

      assert Matcher.match?(m, msg("hi all", ["entity://team-alpha/agent/test_x"]))
    end

    test "false when any leaf fails" do
      m =
        Matcher.all_of([
          Matcher.mention("entity://team-alpha/agent/test_x"),
          Matcher.text_contains("never")
        ])

      refute Matcher.match?(m, msg("hi", ["entity://team-alpha/agent/test_x"]))
    end

    test "empty list is vacuously true" do
      assert Matcher.match?(Matcher.all_of([]), msg())
    end
  end

  describe "any_of/1 + match?/2" do
    test "true when at least one leaf matches" do
      m =
        Matcher.any_of([
          Matcher.from("entity://system/user/admin"),
          Matcher.text_contains("never")
        ])

      assert Matcher.match?(m, msg("hi", [], "entity://system/user/admin"))
    end

    test "false when no leaf matches" do
      m =
        Matcher.any_of([
          Matcher.text_contains("never"),
          Matcher.from("entity://team-alpha/user/other")
        ])

      refute Matcher.match?(m, msg("hi", [], "entity://system/user/admin"))
    end

    test "empty list is vacuously false" do
      refute Matcher.match?(Matcher.any_of([]), msg())
    end
  end

  describe "negate/1 + match?/2" do
    test "flips leaf result" do
      assert Matcher.match?(Matcher.negate(Matcher.text_contains("never")), msg("hi"))
      refute Matcher.match?(Matcher.negate(Matcher.text_contains("hi")), msg("hi"))
    end

    test "double negation cancels" do
      assert Matcher.match?(
               Matcher.negate(Matcher.negate(Matcher.text_contains("hi"))),
               msg("hi")
             )
    end
  end

  describe "nested combinators" do
    test "and(or(mention X, mention Y), not from Z)" do
      m =
        Matcher.all_of([
          Matcher.any_of([
            Matcher.mention("entity://team-alpha/agent/test_x"),
            Matcher.mention("entity://team-alpha/agent/test_y")
          ]),
          Matcher.negate(Matcher.from("entity://team-alpha/user/blocked"))
        ])

      assert Matcher.match?(
               m,
               msg("hi", ["entity://team-alpha/agent/test_y"], "entity://system/user/admin")
             )

      refute Matcher.match?(
               m,
               msg("hi", ["entity://team-alpha/agent/test_y"], "entity://team-alpha/user/blocked")
             )

      refute Matcher.match?(
               m,
               msg("hi", ["entity://team-alpha/agent/test_z"], "entity://system/user/admin")
             )
    end
  end

  describe "JSON serde for combinators" do
    test "and round-trip" do
      m =
        Matcher.all_of([
          Matcher.mention("entity://team-alpha/agent/test_x"),
          Matcher.from("entity://system/user/admin")
        ])

      assert {:ok, ^m} = m |> Matcher.to_json() |> Matcher.from_json()
    end

    test "or round-trip" do
      m = Matcher.any_of([Matcher.text_contains("urgent"), Matcher.always()])
      assert {:ok, ^m} = m |> Matcher.to_json() |> Matcher.from_json()
    end

    test "not round-trip" do
      m = Matcher.negate(Matcher.from("entity://team-alpha/user/blocked"))
      assert {:ok, ^m} = m |> Matcher.to_json() |> Matcher.from_json()
    end

    test "deeply nested round-trip" do
      m =
        Matcher.all_of([
          Matcher.any_of([
            Matcher.mention("entity://team-alpha/agent/test_x"),
            Matcher.mention("entity://team-alpha/agent/test_y")
          ]),
          Matcher.negate(Matcher.from("entity://team-alpha/user/blocked")),
          Matcher.text_matches("^/help")
        ])

      assert {:ok, ^m} = m |> Matcher.to_json() |> Matcher.from_json()
    end
  end

  describe "backward compat" do
    test "existing leaf-only JSON still decodes" do
      assert {:ok, {:mention, "entity://system/user/admin"}} =
               Matcher.from_json(%{"type" => "mention", "arg" => "entity://system/user/admin"})
    end
  end
end
