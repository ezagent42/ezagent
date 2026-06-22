defmodule EzagentPluginHello.GeneratorTest do
  use ExUnit.Case, async: true

  alias EzagentPluginHello.Generator

  describe "parse_plan/1 — planner reply → {:simple} | {:complex, ...}" do
    test "a well-formed complex plan with ≥2 briefs fans out, with deterministic ids" do
      content = ~s({"mode":"complex","title":"Bean & Leaf","sections":[
        {"brief":"a hero with the shop name"},
        {"brief":"two cards: Espresso and Pour-over"}
      ]})

      assert {:complex, %{title: "Bean & Leaf", sections: sections}} =
               Generator.parse_plan(content)

      assert sections == [
               %{id: "s0", brief: "a hero with the shop name"},
               %{id: "s1", brief: "two cards: Espresso and Pour-over"}
             ]
    end

    test "ids are assigned by us (s0..sN), never taken from the LLM" do
      content =
        ~s({"mode":"complex","sections":[{"id":"DROP TABLE","brief":"x"},{"brief":"y"}]})

      assert {:complex, %{sections: [%{id: "s0"}, %{id: "s1"}]}} = Generator.parse_plan(content)
    end

    test "falls back to a section's title when it has no brief" do
      content = ~s({"mode":"complex","sections":[{"title":"Hero"},{"title":"Footer"}]})

      assert {:complex, %{sections: [%{brief: "Hero"}, %{brief: "Footer"}]}} =
               Generator.parse_plan(content)
    end

    test "hard floor: a complex plan with <2 usable briefs degrades to simple" do
      assert {:simple} =
               Generator.parse_plan(~s({"mode":"complex","sections":[{"brief":"only one"}]}))

      assert {:simple} = Generator.parse_plan(~s({"mode":"complex","sections":[]}))

      assert {:simple} =
               Generator.parse_plan(~s({"mode":"complex","sections":[{"brief":""},{"x":1}]}))
    end

    test "mode simple → simple" do
      assert {:simple} = Generator.parse_plan(~s({"mode":"simple"}))
    end

    test "parses a ```json-fenced reply (LLMs wrap output)" do
      content =
        "Plan:\n```json\n{\"mode\":\"complex\",\"sections\":[{\"brief\":\"a\"},{\"brief\":\"b\"}]}\n```"

      assert {:complex, %{sections: [%{id: "s0"}, %{id: "s1"}]}} = Generator.parse_plan(content)
    end

    test "garbage / non-JSON / non-string → simple (degrade, never crash)" do
      assert {:simple} = Generator.parse_plan("not json")
      assert {:simple} = Generator.parse_plan(~s({"mode":"weird"}))
      assert {:simple} = Generator.parse_plan(nil)
      assert {:simple} = Generator.parse_plan(%{})
    end
  end
end
