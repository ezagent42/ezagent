defmodule EzagentPluginHello.Template.HelloSessionTest do
  use EzagentCore.DataCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Workspace
  alias EzagentPluginHello.Application, as: HelloApp
  alias EzagentPluginHello.Members
  alias EzagentPluginHello.Template.HelloSession
  alias Ezagent.World.ConversationData

  setup do
    :ok = EzagentPluginHello.TestCatalog.import!()
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_curl_agent)
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
    test "workspace class creation asynchronously installs the declared team" do
      ws = "hello-workspace-create-#{System.unique_integer([:positive])}"
      {:ok, _} = Workspace.create(ws, %{})
      workspace_uri = Ezagent.URI.workspace(ws)
      caller = Ezagent.Entity.User.admin_uri()
      short_name = "async-team-#{System.unique_integer([:positive])}"

      assert {:ok, %{session_uri: session_uri}, []} =
               Ezagent.ActionSet.Workspace.handle_create_session(
                 %{short_name: short_name, template_name: "hello"},
                 %{self_uri: workspace_uri, caller: caller}
               )

      assert %{status: status} =
               Ezagent.Session.SocialwareInstallObligations.get_by_session(session_uri)

      assert status in [:pending, :running, :resolved]

      assert eventually(fn ->
               match?(
                 %{status: :resolved},
                 Ezagent.Session.SocialwareInstallObligations.get_by_session(session_uri)
               ) and
                 match?({:ok, %URI{}}, Members.role_uri(session_uri, "front-desk"))
             end)
    end

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
      assert "llm" in declarations
      assert length(declarations) == 2

      # `Workspace.create_session` fires this transaction once the owner-only
      # session is durable; drive it synchronously here.
      assert {:ok, %{satisfied: ["front-desk"], skipped: [], deferred: ["llm"]}} =
               EzagentDomainInstanceMessage.SessionCreator.install_session_socialware(session_uri)

      assert {:ok, orch_uri} = Members.role_uri(session_uri, "front-desk")
      assert :error = Members.role_uri(session_uri, "llm")

      assert [
               %{
                 role_name: "llm",
                 status: :pending_auth,
                 connection: {:api_key, %{provider: "deepseek"}}
               }
             ] = EzagentDomainInstanceMessage.SessionCreator.AgentAdmission.list(session_uri)

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

    test "initial install repairs a missing owner Page capability" do
      suffix = System.unique_integer([:positive])
      ws = "hello-page-install-#{suffix}"
      {:ok, _} = Workspace.create(ws, %{})
      workspace_uri = Ezagent.URI.workspace(ws)
      owner = Ezagent.URI.new!("entity://#{ws}/user/owner")
      {:ok, _} = Ezagent.Users.create(owner, "pw-not-secret", [])
      {:ok, _pid} = Ezagent.SpawnRegistry.spawn(owner)

      template = %{"class" => "session.hello", "session_name" => "main"}

      assert {:ok, [session_uri], %{fresh?: true}} =
               HelloSession.instantiate("session.hello", template, workspace_uri, caller: owner)

      assert :ok =
               EzagentDomainInstanceMessage.SessionCreator.join_session_members(
                 session_uri,
                 [owner]
               )

      owner
      |> Ezagent.Identity.list_caps_for()
      |> Enum.filter(fn cap ->
        cap.behavior == Ezagent.ActionSet.HelloRender and
          cap.action == :hello_render and cap.instance == session_uri
      end)
      |> Enum.each(fn cap -> assert :ok = Ezagent.EntityCaps.revoke(owner, cap) end)

      assert {:ok, members} = Ezagent.Entity.Session.session_member_uris_strict(session_uri)
      assert owner in members
      assert Ezagent.Users.confirmed?(owner)
      assert Ezagent.ActionSet.Session.Membership.current_member_entitled?(session_uri, owner)

      assert {Ezagent.ActionSet.HelloRender, :hello_render} in Ezagent.Socialware.Installation.declared_view_actions(
               session_uri
             )

      refute Ezagent.UI.SessionView.authorize_view(
               EzagentPluginHello.PageView,
               owner,
               session_uri
             )

      assert {:ok, _summary} =
               EzagentDomainInstanceMessage.SessionCreator.install_session_socialware(
                 session_uri,
                 {workspace_uri, owner}
               )

      assert Ezagent.UI.SessionView.authorize_view(
               EzagentPluginHello.PageView,
               owner,
               session_uri
             )

      view_ids =
        session_uri
        |> ConversationData.state_for(%{
          caller_uri: owner,
          workspace_uri: workspace_uri,
          sessions: []
        })
        |> Map.fetch!("views")
        |> Enum.map(& &1["id"])

      assert "hello_page" in view_ids
    end

    test "installed hello Page remains applicable while the session is cold" do
      suffix = System.unique_integer([:positive])
      ws = "hello-page-cold-#{suffix}"
      {:ok, _} = Workspace.create(ws, %{})
      workspace_uri = Ezagent.URI.workspace(ws)
      caller = Ezagent.URI.new!("entity://#{ws}/user/owner")
      {:ok, _} = Ezagent.Users.create(caller, "pw-not-secret", [])
      {:ok, _pid} = Ezagent.SpawnRegistry.spawn(caller)
      template = %{"class" => "session.hello", "session_name" => "main"}

      assert {:ok, [session_uri], %{fresh?: true}} =
               HelloSession.instantiate("session.hello", template, workspace_uri, caller: caller)

      assert :ok =
               EzagentDomainInstanceMessage.SessionCreator.join_session_members(
                 session_uri,
                 [caller]
               )

      assert {:ok, _summary} =
               EzagentDomainInstanceMessage.SessionCreator.install_session_socialware(
                 session_uri,
                 {workspace_uri, caller}
               )

      assert EzagentPluginHello.PageView.applies_to?(session_uri)
      assert {:ok, session_pid} = Ezagent.KindRegistry.lookup(session_uri)

      assert :ok =
               DynamicSupervisor.terminate_child(
                 Ezagent.Entity.Session.supervisor(),
                 session_pid
               )

      refute match?({:ok, _}, Ezagent.Kind.read(session_uri, :surface, spawn: :never))

      assert EzagentPluginHello.PageView.applies_to?(session_uri),
             "an installed Page must not disappear merely because its session is cold"

      assert Enum.any?(
               Ezagent.UI.SessionViewRegistry.applicable_views(session_uri, caller),
               &(&1.id == :hello_page)
             )

      _rendered =
        render_component(&EzagentPluginHello.PageView.render/1, session_uri: session_uri)

      assert {:ok, surface} = Ezagent.Kind.read(session_uri, :surface, spawn: :never)
      assert is_map(surface)
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

    test "flavor overrides preserve admission without carrying Curl provider metadata" do
      ws = "hello-tmpl-flavor-#{System.unique_integer([:positive])}"
      {:ok, _} = Workspace.create(ws, %{})
      workspace_uri = Ezagent.URI.workspace(ws)

      Enum.each(["cc-headless", "codex"], fn flavor ->
        tmpl = %{
          "class" => "session.hello",
          "session_name" => "main-#{flavor}",
          "llm_flavor" => flavor
        }

        assert {:ok, [session_uri], _} =
                 HelloSession.instantiate("session.hello", tmpl, workspace_uri)

        declarations =
          session_uri
          |> Ezagent.Entity.Session.read_template_working_copy()
          |> Map.get(:member_declarations, [])

        llm =
          Enum.find(declarations, fn role ->
            (Map.get(role, :role_name) || Map.get(role, "role_name")) == "llm"
          end)

        assert %{role_name: "llm", flavor: ^flavor, credential_admission: :before_session_join} =
                 llm

        refute Map.has_key?(llm, :provider)
        assert %{"provider" => "deepseek"} = llm.config
      end)
    end

    test "preflights a selected reusable LLM and freezes the reuse role slot" do
      suffix = System.unique_integer([:positive])
      ws = "hello-tmpl-reuse-#{suffix}"
      {:ok, _} = Workspace.create(ws, %{})
      workspace_uri = Ezagent.URI.workspace(ws)
      owner = confirmed_user(ws, "owner")
      reusable_llm = seed_reusable_py_agent(ws, workspace_uri, owner)

      template = %{
        "class" => "session.hello",
        "session_name" => "main",
        "llm_flavor" => "py",
        "llm_agent_uri" => URI.to_string(reusable_llm)
      }

      assert {:ok, [session_uri], %{fresh?: true}} =
               HelloSession.instantiate(
                 "session.hello",
                 template,
                 workspace_uri,
                 caller: owner
               )

      working_copy = Ezagent.Entity.Session.read_template_working_copy(session_uri)

      llm =
        working_copy
        |> Map.fetch!(:member_declarations)
        |> Enum.find(&(&1.role_name == "llm"))

      assert %{
               role_name: "llm",
               flavor: "py",
               install_mode: :reuse,
               reuse_agent_uri: ^reusable_llm
             } = llm

      assert {:ok, manifest_content} =
               Ezagent.Entity.Session.Orchestrator.read_template_content(
                 working_copy.session_template_uri
               )

      refute contains_uri?(manifest_content, reusable_llm),
             "the selected agent URI is per-session install data, not manifest data"
    end

    test "rejects a stale selected LLM before persisting the Hello app" do
      suffix = System.unique_integer([:positive])
      ws = "hello-tmpl-stale-reuse-#{suffix}"
      {:ok, _} = Workspace.create(ws, %{})
      workspace_uri = Ezagent.URI.workspace(ws)
      owner = confirmed_user(ws, "owner")
      stale = Ezagent.URI.agent(ws, "stale-llm")
      session_uri = Ezagent.URI.session(ws, :hello, "main")

      template = %{
        "class" => "session.hello",
        "session_name" => "main",
        "llm_flavor" => "py",
        "llm_agent_uri" => URI.to_string(stale)
      }

      assert {:error, {:invalid_reusable_llm_agent, :not_found}} =
               HelloSession.instantiate(
                 "session.hello",
                 template,
                 workspace_uri,
                 caller: owner
               )

      assert {:error, :not_found} = Ezagent.SnapshotStore.latest(session_uri)
      assert :error = Ezagent.KindRegistry.lookup(session_uri)
    end
  end

  defp seed_reusable_py_agent(ws, workspace_uri, owner) do
    agent_uri =
      Ezagent.URI.agent(ws, "reusable-py-#{System.unique_integer([:positive])}")

    state = %{
      sandbox: %{
        state: %{
          recipe: "hello.llm",
          respawn_template_data: %{"flavor" => "py"}
        }
      }
    }

    assert {:ok, _pid} =
             Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
               uri: agent_uri,
               behaviors: Ezagent.Entity.Agent.base_behaviors(),
               initial_caps: MapSet.new()
             })

    assert :ok = Ezagent.WorkspaceRegistry.bind(agent_uri, workspace_uri)

    cap =
      Ezagent.CreatorGrant.manage_cap(
        :agent,
        agent_uri,
        workspace_uri,
        owner
      )

    assert :ok =
             Ezagent.Identity.Grant.grant_cap_via_router(
               owner,
               cap,
               {:admin, Ezagent.Entity.User.admin_uri()},
               :sync
             )

    assert {:ok, pid} = Ezagent.KindRegistry.lookup(agent_uri)
    assert :ok = DynamicSupervisor.terminate_child(Ezagent.Entity.Agent.supervisor(), pid)
    assert eventually(fn -> Ezagent.KindRegistry.lookup(agent_uri) == :error end)

    assert {:ok, _} =
             Ezagent.SnapshotStore.write(agent_uri, state,
               kind_type: :agent,
               workspace_uri: URI.to_string(workspace_uri)
             )

    agent_uri
  end

  defp confirmed_user(ws, prefix) do
    uri =
      Ezagent.URI.new!("entity://#{ws}/user/#{prefix}-#{System.unique_integer([:positive])}")

    {:ok, _} = Ezagent.Users.create(uri, "pw-not-secret", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp contains_uri?(%URI{} = value, target),
    do: Ezagent.URI.stable_key(value) == Ezagent.URI.stable_key(target)

  defp contains_uri?(value, target) when is_binary(value),
    do: value == URI.to_string(target)

  defp contains_uri?(value, target) when is_map(value),
    do:
      Enum.any?(value, fn {key, nested} ->
        contains_uri?(key, target) or contains_uri?(nested, target)
      end)

  defp contains_uri?(value, target) when is_list(value),
    do: Enum.any?(value, &contains_uri?(&1, target))

  defp contains_uri?(_value, _target), do: false

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
