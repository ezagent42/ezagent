defmodule EzagentPluginHello.Template.HelloSessionTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Workspace
  alias EzagentPluginHello.Application, as: HelloApp
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
    test "stands up a creatable hello app: session + joined orchestrator member" do
      ws = "hello-tmpl-#{System.unique_integer([:positive])}"
      {:ok, _} = Workspace.create(ws, %{})
      workspace_uri = Ezagent.URI.workspace(ws)
      tmpl = %{"class" => "session.hello", "session_name" => "main"}

      assert {:ok, [session_uri], %{fresh?: true, vertical: :hello}} =
               HelloSession.instantiate("session.hello", tmpl, workspace_uri)

      assert session_uri == Ezagent.URI.session(ws, :hello, "main")

      # The invisible ORCHESTRATOR front desk joins as a member. `instantiate`
      # DEFERS its create off the workspace process (avoids a :calling_self
      # deadlock), so it appears asynchronously — poll for it. The builder/concierge
      # are NOT created eagerly (the orchestrator spawns them on demand), so they are
      # absent at create.
      orch_uri = Ezagent.URI.entity(ws, :agent, "orch_main")

      assert eventually(fn -> match?({:ok, _}, Ezagent.KindRegistry.lookup(orch_uri)) end),
             "the orchestrator should become live"

      assert eventually(fn ->
               match?(
                 %{^orch_uri => %{role_name: "orchestrator"}},
                 Ezagent.Orchestrator.Tools.read_members(session_uri)
               )
             end),
             "the orchestrator should join as a member"

      # The orchestrator holds no within-session orchestrator cap (it is a plain
      # router member, not a session orchestrator).
      {:ok, %{caps: caps}} = Ezagent.Kind.get_slice(orch_uri, :identity)

      assert {:error, :unauthorized} =
               Ezagent.Orchestrator.Tools.preflight_within_session_cap(caps, session_uri)

      # Builder/concierge are lazy — not members (the orchestrator drives their work
      # via admin-authority TurnDriver; they are never chat members).
      refute Map.has_key?(
               Ezagent.Orchestrator.Tools.read_members(session_uri),
               Ezagent.URI.entity(ws, :agent, "hello_main")
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
  end

  # Retry `fun` until it returns truthy or the budget runs out (the orchestrator is
  # created asynchronously by `instantiate`). DataCase runs async:false in SHARED
  # sandbox mode, so the deferred Task shares this test's DB connection.
  defp eventually(fun, retries \\ 40, delay \\ 25) do
    cond do
      fun.() ->
        true

      retries <= 0 ->
        false

      true ->
        Process.sleep(delay)
        eventually(fun, retries - 1, delay)
    end
  end
end
