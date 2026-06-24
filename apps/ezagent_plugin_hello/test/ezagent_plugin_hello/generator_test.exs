defmodule EzagentPluginHello.GeneratorTest do
  use ExUnit.Case, async: true

  alias EzagentPluginHello.Generator

  # Contract note (#956): fan-out (the complex path) is DISABLED for the shadcn
  # era — `classify_plan/1` always returns `{:simple}` — and `parse_plan/1` now
  # returns a `{plan, scope}` tuple (the planner reply still carries the edit
  # SCOPE: body / shell / both). These tests pin that contract; the "complex plan
  # still degrades to simple" cases are the regression guard against anyone
  # re-enabling fan-out without re-wiring the worker prompt.
  describe "parse_plan/1 — planner reply → {plan, scope}" do
    test "a well-formed complex plan still degrades to {:simple} (fan-out disabled)" do
      content = ~s({"mode":"complex","title":"Bean & Leaf","sections":[
        {"brief":"a hero with the shop name"},
        {"brief":"two cards: Espresso and Pour-over"}
      ]})

      assert {{:simple}, :body} = Generator.parse_plan(content)
    end

    test "a ```json-fenced complex reply also degrades to {:simple}" do
      content =
        "Plan:\n```json\n{\"mode\":\"complex\",\"sections\":[{\"brief\":\"a\"},{\"brief\":\"b\"}]}\n```"

      assert {{:simple}, :body} = Generator.parse_plan(content)
    end

    test "mode simple → {:simple}" do
      assert {{:simple}, :body} = Generator.parse_plan(~s({"mode":"simple"}))
    end

    test "scope is read from the planner reply's \"scope\" field" do
      assert {{:simple}, :shell} = Generator.parse_plan(~s({"mode":"simple","scope":"shell"}))
      assert {{:simple}, :both} = Generator.parse_plan(~s({"mode":"complex","scope":"both"}))
      # An unknown / missing scope defaults to :body.
      assert {{:simple}, :body} = Generator.parse_plan(~s({"mode":"simple","scope":"weird"}))
      assert {{:simple}, :body} = Generator.parse_plan(~s({"mode":"simple"}))
    end

    test "garbage / non-JSON / non-string → {:simple}, :body (degrade, never crash)" do
      assert {{:simple}, :body} = Generator.parse_plan("not json")
      assert {{:simple}, :body} = Generator.parse_plan(~s({"mode":"weird"}))
      assert {{:simple}, :body} = Generator.parse_plan(nil)
      assert {{:simple}, :body} = Generator.parse_plan(%{})
    end
  end
end
