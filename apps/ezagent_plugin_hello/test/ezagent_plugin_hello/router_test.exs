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

  describe "should_route?/2 (loop + multi-agent guard)" do
    setup do
      session = Ezagent.URI.session("system", :hello, "guard-demo")
      %{session: session}
    end

    test "ignores the orchestrator's own outbound", %{session: session} do
      self_uri = EzagentPluginHello.App.orchestrator_uri(session)
      refute EzagentPluginHello.Router.should_route?(session, self_uri)
    end

    test "ignores its own builder member", %{session: session} do
      refute EzagentPluginHello.Router.should_route?(
               session,
               EzagentPluginHello.App.builder_uri(session)
             )
    end

    test "ignores its own concierge member", %{session: session} do
      refute EzagentPluginHello.Router.should_route?(
               session,
               EzagentPluginHello.App.concierge_uri(session)
             )
    end

    test "routes a user message", %{session: session} do
      user = Ezagent.URI.user("system", "admin")
      assert EzagentPluginHello.Router.should_route?(session, user)
    end

    test "routes an EXTERNAL agent message (multi-agent, not human-only)", %{session: session} do
      external = Ezagent.URI.entity("system", :agent, "some-other-agent")
      assert EzagentPluginHello.Router.should_route?(session, external)
    end
  end
end
