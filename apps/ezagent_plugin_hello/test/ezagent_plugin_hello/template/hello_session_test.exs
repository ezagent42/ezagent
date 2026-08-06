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
    test "freezes provider intent only for profile-bearing LLM flavors" do
      for flavor <- EzagentPluginHello.App.llm_flavors() do
        expected =
          if flavor in ["curl", "cc-headless-custom"],
            do: %{provider: "deepseek"},
            else: %{provider: nil}

        assert EzagentPluginHello.App.llm_provider_config(flavor) == expected
      end
    end

    test "uses the selected reusable agent provider profile" do
      assert %{provider: "kimi"} = EzagentPluginHello.App.llm_provider_config("curl", "kimi")

      assert %{provider: "moonshot"} =
               EzagentPluginHello.App.llm_provider_config("cc-headless-custom", "moonshot")
    end

    test "requires an explicit reusable LLM selection" do
      workspace_uri =
        Ezagent.URI.workspace("hello-tmpl-selection-#{System.unique_integer([:positive])}")

      for template <- [
            %{"class" => "session.hello", "session_name" => "main"},
            %{"class" => "session.hello", "session_name" => "main", "llm_flavor" => "py"}
          ] do
        assert {:error, :llm_agent_required} =
                 HelloSession.instantiate("session.hello", template, workspace_uri)
      end
    end

    test "workspace class creation rejects an omitted reusable LLM" do
      ws = "hello-workspace-create-#{System.unique_integer([:positive])}"
      {:ok, _} = Workspace.create(ws, %{})
      workspace_uri = Ezagent.URI.workspace(ws)
      caller = Ezagent.Entity.User.admin_uri()
      short_name = "async-team-#{System.unique_integer([:positive])}"

      assert {:error, :llm_agent_required} =
               Ezagent.ActionSet.Workspace.handle_create_session(
                 %{short_name: short_name, template_name: "hello"},
                 %{self_uri: workspace_uri, caller: caller}
               )
    end

    test "initial install repairs a missing owner Page capability" do
      suffix = System.unique_integer([:positive])
      ws = "hello-page-install-#{suffix}"
      {:ok, _} = Workspace.create(ws, %{})
      workspace_uri = Ezagent.URI.workspace(ws)
      owner = Ezagent.URI.new!("entity://#{ws}/user/owner")
      {:ok, _} = Ezagent.Users.create(owner, "pw-not-secret", [])
      {:ok, _pid} = Ezagent.SpawnRegistry.spawn(owner)

      reusable_llm = seed_reusable_py_agent(ws, workspace_uri, owner, cold: false)

      template = %{
        "class" => "session.hello",
        "session_name" => "main",
        "llm_flavor" => "py",
        "llm_agent_uri" => URI.to_string(reusable_llm)
      }

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

      state =
        ConversationData.state_for(session_uri, %{
          caller_uri: owner,
          workspace_uri: workspace_uri,
          sessions: []
        })

      assert state["active_view"] == "conversation"
    end

    test "installed hello Page remains applicable while the session is cold" do
      suffix = System.unique_integer([:positive])
      ws = "hello-page-cold-#{suffix}"
      {:ok, _} = Workspace.create(ws, %{})
      workspace_uri = Ezagent.URI.workspace(ws)
      caller = Ezagent.URI.new!("entity://#{ws}/user/owner")
      {:ok, _} = Ezagent.Users.create(caller, "pw-not-secret", [])
      {:ok, _pid} = Ezagent.SpawnRegistry.spawn(caller)
      reusable_llm = seed_reusable_py_agent(ws, workspace_uri, caller, cold: false)

      template = %{
        "class" => "session.hello",
        "session_name" => "main",
        "llm_flavor" => "py",
        "llm_agent_uri" => URI.to_string(reusable_llm)
      }

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

      assert Ezagent.UI.SessionViewRegistry.external_render?(EzagentPluginHello.PageView)

      views = ConversationData.session_views(session_uri, caller)
      assert Enum.any?(views, &(&1["id"] == "hello_page" and &1["mode"] == "external"))

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

    test "flavor-only templates do not create a fresh LLM" do
      workspace_uri =
        Ezagent.URI.workspace("hello-tmpl-flavor-#{System.unique_integer([:positive])}")

      assert {:error, :llm_agent_required} =
               HelloSession.instantiate(
                 "session.hello",
                 %{
                   "class" => "session.hello",
                   "session_name" => "main",
                   "llm_flavor" => "cc-headless"
                 },
                 workspace_uri
               )
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

    test "socialware installation joins the selected reusable LLM" do
      suffix = System.unique_integer([:positive])
      ws = "hello-tmpl-reuse-install-#{suffix}"
      {:ok, _} = Workspace.create(ws, %{})
      workspace_uri = Ezagent.URI.workspace(ws)
      owner = confirmed_user(ws, "owner")
      reusable_llm = seed_reusable_py_agent(ws, workspace_uri, owner, cold: false)

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

      llm_declaration =
        session_uri
        |> Ezagent.Entity.Session.read_template_working_copy()
        |> Map.fetch!(:member_declarations)
        |> Enum.find(&((Map.get(&1, :role_name) || Map.get(&1, "role_name")) == "llm"))

      assert %{config: %{provider: nil}} = llm_declaration

      assert {:ok, %{satisfied: satisfied, deferred: []}} =
               EzagentDomainInstanceMessage.SessionCreator.install_session_socialware(
                 session_uri,
                 {workspace_uri, owner}
               )

      assert "llm" in satisfied
      assert {:ok, ^reusable_llm} = Members.role_uri(session_uri, "llm")
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

  defp seed_reusable_py_agent(ws, workspace_uri, owner, opts \\ []) do
    agent_uri =
      Ezagent.URI.agent(ws, "reusable-py-#{System.unique_integer([:positive])}")

    state = %{
      sandbox: %{
        state: %{
          config_dir_path: nil,
          template_class: nil,
          recipe: "hello.llm",
          respawn_template_data: %{"flavor" => "py"},
          pty_phase: nil,
          passive: false
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

    if Keyword.get(opts, :cold, true) do
      assert {:ok, pid} = Ezagent.KindRegistry.lookup(agent_uri)
      assert :ok = DynamicSupervisor.terminate_child(Ezagent.Entity.Agent.supervisor(), pid)
      assert eventually(fn -> Ezagent.KindRegistry.lookup(agent_uri) == :error end)

      assert {:ok, _} =
               Ezagent.SnapshotStore.write(agent_uri, state,
                 kind_type: :agent,
                 version: 0,
                 workspace_uri: URI.to_string(workspace_uri)
               )
    else
      assert :ok = Ezagent.Agent.RecipeAttributes.put(agent_uri, "hello.llm")
      assert :ok = Ezagent.AgentFlavorAttributes.put(agent_uri, "py")

      on_exit(fn ->
        case Ezagent.KindRegistry.lookup(agent_uri) do
          {:ok, _pid} -> Ezagent.Kind.terminate(agent_uri)
          :error -> :ok
        end
      end)
    end

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
