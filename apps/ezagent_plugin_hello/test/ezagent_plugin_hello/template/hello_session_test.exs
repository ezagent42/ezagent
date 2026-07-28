defmodule EzagentPluginHello.Template.HelloSessionTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Workspace
  alias EzagentPluginHello.Application, as: HelloApp
  alias EzagentPluginHello.Members
  alias EzagentPluginHello.Template.HelloSession

  setup do
    :ok = EzagentPluginHello.TestCatalog.import!()
    # hello's builder/concierge are role × native agents; `App.ensure_app` creates
    # them via the RF-5a role-create path, which resolves the recipe through the
    # "role-as-data" `RecipeRegistry` (ConfigStore-backed). Boot seeds the recipes,
    # but that write is outside this DataCase sandbox transaction — so seed them
    # WITHIN the test (idempotent) so the create path resolves the role. Mirrors
    # `EzagentPluginKanban.E2E.RoleNativeCreateTest`.
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)

    Enum.each(HelloApp.roles(), fn recipe ->
      {:ok, _} = RecipeRegistry.seed_role_if_absent(recipe)
    end)

    :ok
  end

  describe "validate/1" do
    test "accepts a well-formed session.hello template" do
      assert :ok = HelloSession.validate(%{"class" => "session.hello", "session_name" => "main"})
    end

    test "rejects wrong class / missing fields / non-map" do
      assert {:error, {:wrong_class, "session.other"}} =
               HelloSession.validate(%{"class" => "session.other", "session_name" => "x"})

      assert {:error, :missing_class_field} = HelloSession.validate(%{"session_name" => "x"})

      assert {:error, :missing_session_name} =
               HelloSession.validate(%{"class" => "session.hello"})

      assert {:error, :not_a_map} = HelloSession.validate("nope")
    end
  end

  describe "instantiate/3" do
    test "stands up a creatable hello app: session + declared (not spawned) team" do
      ws = "hello-tmpl-#{System.unique_integer([:positive])}"
      {:ok, _} = Workspace.create(ws, %{})
      workspace_uri = Ezagent.URI.workspace(ws)
      tmpl = %{"class" => "session.hello", "session_name" => "main"}

      assert {:ok, [session_uri], %{fresh?: true, vertical: :hello}} =
               HelloSession.instantiate("session.hello", tmpl, workspace_uri)

      assert session_uri == Ezagent.URI.session(ws, :hello, "main")

      # rev6 / #912 — `instantiate/3` runs inside the `workspace.create_session`
      # dispatch, so it creates the session + its config and RECORDS the declared
      # team as `member_declarations`. It spawns nothing. Before this split it
      # materialized four role agents (plus the `requires`-pulled cc orchestrator)
      # right here, which is why `hello` kept timing out at the 5s dispatch budget
      # after `default` had already been decoupled.
      assert :error = Members.role_uri(session_uri, "front-desk")

      declarations =
        session_uri
        |> Ezagent.Entity.Session.read_template_working_copy()
        |> Map.get(:member_declarations, [])
        |> Enum.map(&(Map.get(&1, :role_name) || Map.get(&1, "role_name")))

      assert "front-desk" in declarations
      assert "builder" in declarations
      assert "concierge" in declarations

      # `Workspace.create_session` fires this transaction once the owner-only
      # session is durable; drive it synchronously here.
      assert {:ok, %{satisfied: _, skipped: []}} =
               EzagentDomainInstanceMessage.SessionCreator.install_session_socialware(session_uri)

      assert {:ok, orch_uri} = Members.role_uri(session_uri, "front-desk")
      assert {:ok, _builder_uri} = Members.role_uri(session_uri, "builder")
      assert {:ok, _concierge_uri} = Members.role_uri(session_uri, "concierge")

      assert match?({:ok, _}, Ezagent.KindRegistry.lookup(orch_uri)),
             "the orchestrator should be live"

      assert %{^orch_uri => %{role_name: "front-desk"}} =
               Ezagent.Orchestrator.Tools.read_members(session_uri)

      # The orchestrator holds no within-session orchestrator cap (it is a plain
      # router member, not a session orchestrator).
      {:ok, %{caps: caps}} = Ezagent.Kind.read(orch_uri, :identity, spawn: :never)

      assert {:error, :unauthorized} =
               Ezagent.Orchestrator.Tools.preflight_within_session_cap(
                 orch_uri,
                 caps,
                 session_uri,
                 :any
               )

      # Idempotent: re-instantiating the same app reports not-fresh.
      assert {:ok, [^session_uri], %{fresh?: false}} =
               HelloSession.instantiate("session.hello", tmpl, workspace_uri)
    end

    test "rejects an invalid template" do
      workspace_uri = Ezagent.URI.workspace("hello-tmpl-bad")

      assert {:error, {:wrong_class, _}} =
               HelloSession.instantiate(
                 "session.hello",
                 %{"class" => "x", "session_name" => "y"},
                 workspace_uri
               )

      assert {:error, {:invalid_template, _}} =
               HelloSession.instantiate("session.hello", %{}, workspace_uri)
    end

    test "persists the selected llm flavor on the template role" do
      ws = "hello-tmpl-flavor-#{System.unique_integer([:positive])}"
      {:ok, _} = Workspace.create(ws, %{})
      workspace_uri = Ezagent.URI.workspace(ws)

      tmpl = %{
        "class" => "session.hello",
        "session_name" => "main",
        "llm_flavor" => "cc-headless"
      }

      assert {:ok, [session_uri], _} =
               HelloSession.instantiate("session.hello", tmpl, workspace_uri)

      declarations =
        session_uri
        |> Ezagent.Entity.Session.read_template_working_copy()
        |> Map.get(:member_declarations, [])

      assert %{role_name: "llm", flavor: "cc-headless"} =
               Enum.find(declarations, fn role ->
                 (Map.get(role, :role_name) || Map.get(role, "role_name")) == "llm"
               end)
    end
  end
end
