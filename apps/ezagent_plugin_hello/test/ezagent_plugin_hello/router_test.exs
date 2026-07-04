defmodule EzagentPluginHello.RouterTest do
  @moduledoc """
  The `hello.orchestrator` routing policy — identity-first (the page-edit security
  boundary) + intent interpretation. Both are pure and tested here without the LLM;
  the owner→LLM branch is exercised end-to-end elsewhere.
  """
  use ExUnit.Case, async: true

  alias EzagentPluginHello.{Generator, Router}

  describe "decide/2 — identity is the security boundary" do
    test "a NON-owner is ALWAYS routed to the concierge, whatever they type" do
      # The page-edit boundary: even an explicit build request from a non-owner
      # must NOT reach the builder. No LLM is consulted for non-owners.
      assert Router.decide(false, "make the title red") == :concierge
      assert Router.decide(false, "generate a whole new landing page") == :concierge
      assert Router.decide(false, "") == :concierge
    end
  end

  describe "interpret_intent/1 — owner intent parsing (pure)" do
    test "ASK anywhere → concierge" do
      assert Generator.interpret_intent("ASK") == :concierge
      assert Generator.interpret_intent("ask") == :concierge
      assert Generator.interpret_intent("The answer is ASK.") == :concierge
    end

    test "BUILD / anything-not-ASK → builder (fail-open to build)" do
      assert Generator.interpret_intent("BUILD") == :builder
      assert Generator.interpret_intent("build") == :builder
      assert Generator.interpret_intent("") == :builder
      assert Generator.interpret_intent("garbled model output") == :builder
    end
  end
end
