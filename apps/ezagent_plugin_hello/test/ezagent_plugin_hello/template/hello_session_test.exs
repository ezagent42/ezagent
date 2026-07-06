defmodule EzagentPluginHello.Template.HelloSessionTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Workspace
  alias EzagentPluginHello.Application, as: HelloApp
  alias EzagentPluginHello.Members
  alias EzagentPluginHello.Template.HelloSession

  setup do
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
    test "stands up a creatable hello app: session + materialized Definition.roles team" do
      ws = "hello-tmpl-#{System.unique_integer([:positive])}"
      {:ok, _} = Workspace.create(ws, %{})
      workspace_uri = Ezagent.URI.workspace(ws)
      tmpl = %{"class" => "session.hello", "session_name" => "main"}

      assert {:ok, [session_uri], %{fresh?: true, vertical: :hello}} =
               HelloSession.instantiate("session.hello", tmpl, workspace_uri)

      assert session_uri == Ezagent.URI.session(ws, :hello, "main")

      # The DECLARED team (orchestrator + builder + concierge) is materialized from
      # `Definition.roles` — each joins as a member with its `role_name` facet at a
      # PLANNED (UUID) URI (the `orch_`/`hello_`/`concierge_` convention is retired,
      # so members are resolved by role, not name). Materialization is synchronous
      # (no deadlock materializing inside the workspace process — the standard
      # socialware create path does the same), so the team is present on return.
      assert {:ok, orch_uri} = Members.role_uri(session_uri, "orchestrator")
      assert {:ok, _builder_uri} = Members.role_uri(session_uri, "builder")
      assert {:ok, _concierge_uri} = Members.role_uri(session_uri, "concierge")

      assert match?({:ok, _}, Ezagent.KindRegistry.lookup(orch_uri)),
             "the orchestrator should be live"

      assert %{^orch_uri => %{role_name: "orchestrator"}} =
               Ezagent.Orchestrator.Tools.read_members(session_uri)

      # The orchestrator holds no within-session orchestrator cap (it is a plain
      # router member, not a session orchestrator).
      {:ok, %{caps: caps}} = Ezagent.Kind.get_slice(orch_uri, :identity)

      assert {:error, :unauthorized} =
               Ezagent.Orchestrator.Tools.preflight_within_session_cap(caps, session_uri)

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
  end
end
