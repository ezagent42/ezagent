defmodule EzagentPluginHello.RouterTest do
  @moduledoc """
  The `hello.orchestrator` routing policy — identity-first (the page-edit security
  boundary) + intent interpretation. Both are pure and tested here without the LLM;
  the owner→LLM branch is exercised end-to-end elsewhere.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Agent.RecipeRegistry
  alias EzagentPluginHello.{App, Generator, Members, Router}
  alias EzagentPluginHello.Application, as: HelloApp

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
      # The guard resolves the orchestrator + managed members by `role_name` from
      # the LIVE session, so it needs a materialized hello app (the team comes from
      # `Definition.roles`). Reseed the recipes (boot's write is outside this
      # DataCase sandbox) and stand up a real app.
      {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)

      Enum.each(HelloApp.roles(), fn recipe ->
        {:ok, _} = RecipeRegistry.seed_role_if_absent(recipe)
      end)

      ws = "hello-router-#{System.unique_integer([:positive])}"
      {:ok, _ws_pid} = Workspace.create(ws, %{})
      {:ok, session, orchestrator} = App.ensure_app(ws, "guard-demo")

      %{session: session, orchestrator: orchestrator}
    end

    test "ignores the orchestrator's own outbound", ctx do
      refute Router.should_route?(ctx.session, ctx.orchestrator)
    end

    test "ignores its own builder member", %{session: session} do
      assert {:ok, builder} = Members.role_uri(session, "builder")
      refute Router.should_route?(session, builder)
    end

    test "ignores its own concierge member", %{session: session} do
      assert {:ok, concierge} = Members.role_uri(session, "concierge")
      refute Router.should_route?(session, concierge)
    end

    test "routes a user message", %{session: session} do
      user = Ezagent.URI.user("system", "admin")
      assert Router.should_route?(session, user)
    end

    test "routes an EXTERNAL agent message (multi-agent, not human-only)", %{session: session} do
      external = Ezagent.URI.entity("system", :agent, "some-other-agent")
      assert Router.should_route?(session, external)
    end
  end
end
