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

  describe "classify/3 — identity is the security boundary" do
    test "a NON-owner is ALWAYS routed to the concierge, whatever they type" do
      session = Ezagent.URI.session("system", :hello, "classify-nonowner")

      assert Router.classify("make the title red", false, session) == :concierge
      assert Router.classify("generate a whole new landing page", false, session) == :concierge
      assert Router.classify("", false, session) == :concierge
    end
  end

  describe "interpret_intent/1 — owner intent parsing (pure)" do
    test "KANBAN anywhere → dispatcher" do
      assert Generator.interpret_intent("KANBAN") == :dispatcher
      assert Generator.interpret_intent("kanban") == :dispatcher
      assert Generator.interpret_intent("The answer is KANBAN.") == :dispatcher
    end

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
      :ok = EzagentPluginHello.TestCatalog.import!()
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

    test "front-desk own outbound IS routable by should_route? (Agent.Receive self-drop guards it)",
         ctx do
      assert Router.should_route?(ctx.session, ctx.orchestrator)
    end

    test "ignores its own builder member", %{session: session} do
      assert {:ok, builder} = Members.role_uri(session, "builder")
      refute Router.should_route?(session, builder)
    end

    test "ignores its own concierge member", %{session: session} do
      assert {:ok, concierge} = Members.role_uri(session, "concierge")
      refute Router.should_route?(session, concierge)
    end

    test "ignores its own dispatcher member", %{session: session} do
      assert {:ok, dispatcher} = Members.role_uri(session, "dispatcher")
      refute Router.should_route?(session, dispatcher)
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

  describe "should_route?/2 — fails CLOSED when the members slice is unreadable" do
    test "a session URI with no live Kind (members slice unreadable) is NOT routed" do
      # No `App.ensure_app` call for this session — no live Kind is spawned at
      # this URI, so `Ezagent.Kind.get_slice/2` returns `{:error, :not_found}`.
      # Loop-safety cannot be guaranteed without knowing our own members, so the
      # guard must fail CLOSED (refuse to route) rather than fail OPEN (which
      # would let an unbounded loop through if the read miss ever coincided with
      # a live orchestrator sending its own builder/concierge output back in).
      ghost_session =
        Ezagent.URI.session(
          "hello-router-ghost-#{System.unique_integer([:positive])}",
          :hello,
          "no-such-session"
        )

      user = Ezagent.URI.user("system", "admin")
      external = Ezagent.URI.entity("system", :agent, "some-other-agent")

      refute Router.should_route?(ghost_session, user)
      refute Router.should_route?(ghost_session, external)
    end
  end
end
