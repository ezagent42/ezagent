defmodule EzagentPluginContent.SoulRendererTest do
  use ExUnit.Case, async: true

  alias EzagentPluginContent.SoulRenderer

  describe "render/2 with binary template" do
    test "replaces {{a.b}} using a flattened slot map" do
      assert SoulRenderer.render("Hello {{a.b}}!", %{"a.b" => "World"}) == "Hello World!"
    end

    test "whitespace tolerated: {{ a.b }} also replaced" do
      assert SoulRenderer.render("Hello {{ a.b }}!", %{"a.b" => "World"}) == "Hello World!"
    end

    test "missing key keeps the literal {{a.b}} in output" do
      assert SoulRenderer.render("Hello {{missing.key}}!", %{}) == "Hello {{missing.key}}!"
    end

    test "non-string slot values are to_string-ed (integer)" do
      assert SoulRenderer.render("Count: {{n}}", %{"n" => 2}) == "Count: 2"
    end

    test "replaces multiple distinct placeholders" do
      result = SoulRenderer.render("{{a}} and {{b}}", %{"a" => "X", "b" => "Y"})
      assert result == "X and Y"
    end

    test "partial match: some keys present, some missing" do
      result = SoulRenderer.render("{{present}} {{absent}}", %{"present" => "here"})
      assert result == "here {{absent}}"
    end
  end

  describe "render/2 with list of layers" do
    test "joins rendered layers with double newline" do
      layers = ["Layer {{n}}", "Done"]
      result = SoulRenderer.render(layers, %{"n" => "1"})
      assert result == "Layer 1\n\nDone"
    end

    test "each layer gets placeholders replaced independently" do
      layers = ["{{a}}", "{{b}}"]
      result = SoulRenderer.render(layers, %{"a" => "A", "b" => "B"})
      assert result == "A\n\nB"
    end

    test "empty list of layers returns empty string" do
      assert SoulRenderer.render([], %{"a" => "X"}) == ""
    end
  end

  describe "flatten/1" do
    test "flattens nested map to dotted keys" do
      input = %{"a" => %{"b" => 1}}
      assert SoulRenderer.flatten(input) == %{"a.b" => 1}
    end

    test "atom keys are stringified" do
      input = %{a: %{b: "v"}}
      assert SoulRenderer.flatten(input) == %{"a.b" => "v"}
    end

    test "mixed atom and string keys" do
      input = %{a: %{"b" => 99}}
      assert SoulRenderer.flatten(input) == %{"a.b" => 99}
    end

    test "flat map stays flat" do
      input = %{"x" => 1, "y" => 2}
      assert SoulRenderer.flatten(input) == %{"x" => 1, "y" => 2}
    end

    test "deeply nested three levels" do
      input = %{"a" => %{"b" => %{"c" => "deep"}}}
      assert SoulRenderer.flatten(input) == %{"a.b.c" => "deep"}
    end

    test "empty map returns empty map" do
      assert SoulRenderer.flatten(%{}) == %{}
    end
  end
end
