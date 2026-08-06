defmodule EzagentPluginHello.RouterTest do
  @moduledoc """
  Hello's Session-ingress routing policy. Only the reusable LLM is materialized;
  intent actions execute on the session itself.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Workspace
  alias EzagentPluginHello.{App, Generator, Members, Router}
  alias EzagentPluginHello.Application, as: HelloApp

  describe "classify/3 — identity is the security boundary" do
    test "a non-owner is always routed to the session answer action" do
      session = Ezagent.URI.session("system", :hello, "classify-nonowner")

      assert Router.classify("make the title red", false, session) == :answer
      assert Router.classify("generate a whole new landing page", false, session) == :answer
      assert Router.classify("", false, session) == :answer
    end
  end

  describe "owner?/2" do
    test "treats an unreadable session owner as a visitor" do
      session =
        Ezagent.URI.session(
          "hello-owner-read-#{System.unique_integer([:positive])}",
          :hello,
          "missing"
        )

      refute Router.owner?(session, Ezagent.URI.user("system", "admin"))
    end
  end

  describe "interpret_intent/1 — owner intent parsing" do
    test "KANBAN anywhere delegates to the kanban session action" do
      assert Generator.interpret_intent("KANBAN") == :delegate_to_kanban
      assert Generator.interpret_intent("kanban") == :delegate_to_kanban
      assert Generator.interpret_intent("The answer is KANBAN.") == :delegate_to_kanban
    end

    test "ASK anywhere routes to the session answer action" do
      assert Generator.interpret_intent("ASK") == :answer
      assert Generator.interpret_intent("ask") == :answer
      assert Generator.interpret_intent("The answer is ASK.") == :answer
    end

    test "BUILD / anything-not-ASK routes to the rebuild session action" do
      assert Generator.interpret_intent("BUILD") == :rebuild
      assert Generator.interpret_intent("build") == :rebuild
      assert Generator.interpret_intent("") == :rebuild
      assert Generator.interpret_intent("garbled model output") == :rebuild
    end
  end

  describe "should_route?/2 (loop guard)" do
    setup do
      :ok = EzagentPluginHello.TestCatalog.import!()
      {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
      {:ok, _} = Application.ensure_all_started(:ezagent_plugin_curl_agent)

      Enum.each(HelloApp.roles(), fn recipe ->
        {:ok, _} = RecipeRegistry.seed_role_if_absent(recipe)
      end)

      ws = "hello-router-#{System.unique_integer([:positive])}"
      {:ok, _ws_pid} = Workspace.create(ws, %{})
      {:ok, session, _sender} = App.ensure_app(ws, "guard-demo")

      %{session: session}
    end

    test "ignores messages emitted by the Session itself", %{session: session} do
      refute Router.should_route?(session, session)
    end

    test "allows an external agent while the LLM connection is pending", %{session: session} do
      assert :error = Members.role_uri(session, "llm")

      pending_llm = Ezagent.URI.entity("system", :agent, "pending-llm")
      assert Router.should_route?(session, pending_llm)
    end

    test "routes a user message", %{session: session} do
      assert Router.should_route?(session, Ezagent.URI.user("system", "admin"))
    end

    test "routes an external agent message", %{session: session} do
      external = Ezagent.URI.entity("system", :agent, "some-other-agent")
      assert Router.should_route?(session, external)
    end

    test "routes a user message after the session Kind is rehydrated", %{session: session} do
      :ok = Ezagent.Kind.terminate(session)

      assert Router.should_route?(session, Ezagent.URI.user("system", "admin"))
    end
  end

  describe "should_route?/2 — fails closed when Session membership is unavailable" do
    test "a session URI with no live Kind is not routed" do
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
