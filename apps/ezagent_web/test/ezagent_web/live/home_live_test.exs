defmodule EzagentWeb.HomeLiveTest do
  use EzagentWeb.ConnCase

  import Phoenix.LiveViewTest

  defp create_session_via_workspace(short_name, creator_uri, opts) do
    template_name = Keyword.fetch!(opts, :template_name)

    workspace_uri =
      Keyword.get(opts, :workspace_uri, Ezagent.Capability.workspace_of(creator_uri))

    ensure_workspace_seeded!(workspace_uri)
    target = Ezagent.URI.with_action(workspace_uri, :workspace, :create_session)
    admin = Ezagent.Entity.User.admin_uri()
    {:ok, create_cap} = Ezagent.Cap.issue_for_action({:admin, admin}, creator_uri, target)

    with {:ok, result} <-
           Ezagent.Workspace.create_session(
             workspace_uri,
             %{short_name: short_name, template_name: template_name},
             %{
               caller: creator_uri,
               authenticated_principal: creator_uri,
               caps: MapSet.new([create_cap])
             }
           ) do
      {:ok, result.session_uri, %{}}
    end
  end

  test "GET / unauthenticated redirects to /login", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/login"}}} = live(conn, ~p"/")
  end

  describe "GET / with invalid identity input" do
    test "fails closed for a malformed URI", %{conn: conn} do
      assert_invalid_identity_redirect(conn, "not-a-uri", "malformed-cookie")
    end

    test "fails closed for a non-entity URI", %{conn: conn} do
      assert_invalid_identity_redirect(conn, "workspace://system", "non-entity-cookie")
    end

    test "fails closed for an entity URI whose principal no longer exists", %{conn: conn} do
      missing_uri = "entity://auth-fail/user/missing-principal"
      assert Ezagent.Users.get_by_uri(missing_uri) == nil

      assert_invalid_identity_redirect(conn, missing_uri, "missing-principal")
    end
  end

  test "GET / with session AND existing sessions redirects to /sessions", %{conn: conn} do
    # Create a session through the real workspace path so the authenticated
    # admin holds the born-signed owner member-cap. A merely live global boot
    # session is no longer sufficient: unified authorization intentionally
    # hides sessions for which the caller has no current entitlement.
    {:ok, _session_uri, %{}} =
      create_session_via_workspace(
        "home-existing-#{System.unique_integer([:positive])}",
        Ezagent.Entity.User.admin_uri(),
        template_name: "default"
      )

    conn =
      conn
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => "entity://system/user/admin"
      })

    assert {:error, {:live_redirect, %{to: "/sessions"}}} = live(conn, ~p"/")
  end

  # W0 tenant-isolation regression. The landing判据 must be scoped to the
  # CALLER's workspace, not the global registry. Here tenant-`w0iso`'s
  # workspace owns ZERO sessions while the boot-seeded
  # `session://system/default/main` lives in the DISTINCT `system`
  # workspace. A tenant-`w0iso` operator must land on the WIZARD — never be
  # bounced to `/sessions` (which would both mis-land them AND leak the
  # existence of another tenant's session).
  #
  # On the OLD global `list_sessions/0` code this test FAILS: the system
  # seed makes the global list non-empty → `{:error, {:live_redirect, ...}}`
  # → the `{:ok, _lv, html}` match raises.
  test "GET / scopes the landing judgment to the caller's workspace (no cross-tenant leak)",
       %{conn: conn} do
    caller_uri = URI.new!("entity://w0iso/user/alice")
    assert {:ok, _user} = Ezagent.Users.create_read_only(caller_uri)

    # Precondition: some OTHER tenant (system) has a live session.
    assert Enum.any?(EzagentDomainInstanceMessage.list_sessions(), fn uri ->
             match?(%URI{scheme: "session", host: "system"}, uri)
           end)

    # …but the caller's own workspace (tenant `w0iso`) has none.
    assert [] =
             EzagentDomainInstanceMessage.list_sessions(URI.new!("workspace://w0iso"))

    conn =
      conn
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(caller_uri)
      })

    # No redirect → wizard rendered inline (a redirect would return
    # `{:error, {:live_redirect, ...}}` and fail this match).
    {:ok, lv, _html} = live(conn, ~p"/")
    assert has_element?(lv, "#first-session-wizard")
    assert has_element?(lv, "#hello-wizard-title")
  end

  # W0 — the landing scope PREFERS the session's selected
  # `current_workspace_uri` over the entity's home workspace, so a system
  # member who context-switched into an empty tenant lands on the wizard
  # (matching what `/sessions` renders — §6.5/§13.2) even though their home
  # `system` workspace owns the boot-seeded `main`.
  test "GET / prefers the selected current_workspace_uri over the entity home workspace",
       %{conn: conn} do
    # Home workspace (system) HAS a session…
    assert Enum.any?(EzagentDomainInstanceMessage.list_sessions(), fn uri ->
             match?(%URI{scheme: "session", host: "system"}, uri)
           end)

    # …but the SELECTED workspace (w0iso) has none.
    assert [] = EzagentDomainInstanceMessage.list_sessions(URI.new!("workspace://w0iso"))

    conn =
      conn
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => "entity://system/user/admin",
        "current_workspace_uri" => "workspace://w0iso"
      })

    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ "first-session-wizard"
  end

  # W0 — a malformed/non-workspace selected slot must not crash the mount;
  # it falls back to the entity's home workspace (fail-safe). Here the
  # fallback (system) has the boot-seeded session → redirect.
  test "GET / tolerates a malformed current_workspace_uri (falls back to entity home)",
       %{conn: conn} do
    short_name = "malformed-fallback-#{System.unique_integer([:positive])}"

    assert {:ok, fallback_session, %{}} =
             create_session_via_workspace(short_name, Ezagent.Entity.User.admin_uri(),
               template_name: "default"
             )

    on_exit(fn -> Ezagent.Kind.terminate(fallback_session) end)

    conn =
      conn
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => "entity://system/user/admin",
        "current_workspace_uri" => "@@not-a-uri@@"
      })

    assert {:error, {:live_redirect, %{to: "/sessions"}}} = live(conn, ~p"/")
  end

  describe "wizard (no sessions)" do
    setup do
      workspace_name = "home-wizard-#{System.unique_integer([:positive])}"
      workspace_uri = Ezagent.URI.workspace(workspace_name)
      ensure_workspace_seeded!(workspace_uri)

      assert :ok =
               Ezagent.UI.SessionViewRegistry.register(EzagentPluginHello.PageView)

      case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
        :ok -> :ok
        {:error, {:already_registered, _attribute}} -> :ok
      end

      Enum.each(EzagentPluginHello.Application.roles(), fn recipe ->
        assert {:ok, _recipe} = Ezagent.Agent.RecipeRegistry.seed_role_if_absent(recipe)
      end)

      assert {:ok, %{name: "hello"}} =
               Ezagent.Socialware.ManifestSeed.import_package(
                 File.read!(Ezagent.Socialware.Demo.Hello.manifest_path())
               )

      on_exit(fn -> _ = Ezagent.Kind.terminate(workspace_uri) end)

      %{workspace_uri: workspace_uri}
    end

    # Use a private workspace so "empty" means no live OR durable sessions
    # without tearing down the shared system fixture.
    test "renders the wizard when no sessions exist", %{conn: conn, workspace_uri: workspace_uri} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{
          "current_entity_uri" => "entity://system/user/admin",
          "current_workspace_uri" => URI.to_string(workspace_uri)
        })

      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "#first-session-wizard")
      assert has_element?(lv, "#wizard_short_name[value='main']")
      assert has_element?(lv, "#wizard_llm_flavor")
      assert has_element?(lv, "#wizard_llm_agent_uri")
      assert has_element?(lv, "#hello-llm-empty")
      assert has_element?(lv, "#first-session-submit[disabled]")
    end

    test "changing flavor filters the dependent reusable-agent selector", %{
      conn: conn,
      workspace_uri: workspace_uri
    } do
      eligible = seed_reusable_py_agent(workspace_uri, Ezagent.Entity.User.admin_uri())

      wrong_recipe =
        seed_reusable_py_agent(
          workspace_uri,
          Ezagent.Entity.User.admin_uri(),
          recipe: "other.recipe"
        )

      conn =
        conn
        |> Plug.Test.init_test_session(%{
          "current_entity_uri" => "entity://system/user/admin",
          "current_workspace_uri" => URI.to_string(workspace_uri)
        })

      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> form("#first-session-wizard", %{
        "wizard" => %{
          "short_name" => "main",
          "llm_flavor" => "py"
        }
      })
      |> render_change()

      assert has_element?(
               lv,
               "#wizard_llm_agent_uri option[value='#{URI.to_string(eligible)}']"
             )

      refute has_element?(
               lv,
               "#wizard_llm_agent_uri option[value='#{URI.to_string(wrong_recipe)}']"
             )

      refute has_element?(lv, "#hello-llm-empty")
      assert has_element?(lv, "#first-session-submit[disabled]")
    end

    test "submitting the wizard creates Hello with the selected reusable LLM", %{
      conn: conn,
      workspace_uri: workspace_uri
    } do
      short_name = "wizard-submit-#{System.unique_integer([:positive])}"
      creator = seed_workspace_user(workspace_uri)
      selected = seed_reusable_py_agent(workspace_uri, creator)
      agents_before = Ezagent.Entity.Agent.list_in_workspace(workspace_uri)

      conn =
        conn
        |> Plug.Test.init_test_session(%{
          "current_entity_uri" => URI.to_string(creator),
          "current_workspace_uri" => URI.to_string(workspace_uri)
        })

      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> form("#first-session-wizard", %{
        "wizard" => %{
          "short_name" => short_name,
          "llm_flavor" => "py"
        }
      })
      |> render_change()

      lv
      |> form("#first-session-wizard", %{
        "wizard" => %{
          "short_name" => short_name,
          "llm_flavor" => "py",
          "llm_agent_uri" => URI.to_string(selected)
        }
      })
      |> render_change()

      refute has_element?(lv, "#first-session-submit[disabled]")

      lv
      |> form("#first-session-wizard", %{
        "wizard" => %{
          "short_name" => short_name,
          "llm_flavor" => "py",
          "llm_agent_uri" => URI.to_string(selected)
        }
      })
      |> render_submit()

      assert_redirect(lv, "/sessions")

      session_uri =
        Ezagent.URI.session(
          Ezagent.URI.workspace_name!(workspace_uri),
          :hello,
          short_name
        )

      on_exit(fn -> _ = Ezagent.Kind.terminate(session_uri) end)
      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(session_uri)
      assert {:ok, ^workspace_uri} = Ezagent.WorkspaceRegistry.lookup(session_uri)

      llm_declaration =
        session_uri
        |> Ezagent.Entity.Session.read_template_working_copy()
        |> Map.fetch!(:member_declarations)
        |> Enum.find(&(&1.role_name == "llm"))

      assert %{
               flavor: "py",
               install_mode: :reuse,
               reuse_agent_uri: ^selected
             } = llm_declaration

      assert Ezagent.Entity.Agent.list_in_workspace(workspace_uri) == agents_before
    end
  end

  defp ensure_workspace_seeded!(%URI{scheme: "workspace", host: name})
       when is_binary(name) and name != "" do
    case Ezagent.Workspace.Store.get_by_name(name) do
      nil ->
        case Ezagent.Workspace.create(name, %{}) do
          {:ok, _pid} -> :ok
          {:error, :workspace_exists} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "failed to seed workspace #{name}: #{inspect(reason)}"
        end

      _ ->
        :ok
    end
  end

  defp assert_invalid_identity_redirect(conn, identity, session_name) do
    workspace_uri = URI.new!("workspace://auth-fail")
    sessions_before = EzagentDomainInstanceMessage.list_sessions(workspace_uri)

    conn =
      Plug.Test.init_test_session(conn, %{
        "current_entity_uri" => identity,
        "current_workspace_uri" => URI.to_string(workspace_uri)
      })

    trace_session_creation_calls(fn ->
      assert {:error, {:live_redirect, %{to: "/login"}}} = live(conn, ~p"/")
    end)

    assert EzagentDomainInstanceMessage.list_sessions(workspace_uri) == sessions_before

    assert :error =
             Ezagent.KindRegistry.lookup(URI.new!("session://auth-fail/default/#{session_name}"))
  end

  defp seed_reusable_py_agent(workspace_uri, owner, opts \\ []) do
    workspace_name = Ezagent.URI.workspace_name!(workspace_uri)
    suffix = System.unique_integer([:positive])
    agent_uri = Ezagent.URI.agent(workspace_name, "home-reusable-py-#{suffix}")
    recipe = Keyword.get(opts, :recipe, "hello.llm")

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

    assert :ok = Ezagent.Agent.RecipeAttributes.put(agent_uri, recipe)
    assert :ok = Ezagent.AgentFlavorAttributes.put(agent_uri, "py")

    assert {:ok, pid} = Ezagent.KindRegistry.lookup(agent_uri)
    assert :ok = DynamicSupervisor.terminate_child(Ezagent.Entity.Agent.supervisor(), pid)
    assert eventually(fn -> Ezagent.KindRegistry.lookup(agent_uri) == :error end)

    assert {:ok, _snapshot} =
             Ezagent.SnapshotStore.write(
               agent_uri,
               %{
                 sandbox: %{
                   state: %{
                     config_dir_path: nil,
                     template_class: nil,
                     recipe: recipe,
                     respawn_template_data: %{"flavor" => "py"},
                     pty_phase: nil,
                     passive: false
                   }
                 }
               },
               kind_type: :agent,
               version: 0,
               workspace_uri: URI.to_string(workspace_uri)
             )

    on_exit(fn ->
      case Ezagent.KindRegistry.lookup(agent_uri) do
        {:ok, _pid} -> Ezagent.Kind.terminate(agent_uri)
        :error -> :ok
      end
    end)

    agent_uri
  end

  defp seed_workspace_user(workspace_uri) do
    workspace_name = Ezagent.URI.workspace_name!(workspace_uri)

    user_uri =
      Ezagent.URI.user(
        workspace_name,
        "home-owner-#{System.unique_integer([:positive])}"
      )

    assert {:ok, _user} = Ezagent.Users.create(user_uri, "test-password", [])
    assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(user_uri)
    assert :ok = Ezagent.Workspace.add_member(workspace_name, user_uri)

    on_exit(fn ->
      case Ezagent.KindRegistry.lookup(user_uri) do
        {:ok, _pid} -> Ezagent.Kind.terminate(user_uri)
        :error -> :ok
      end
    end)

    user_uri
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp trace_session_creation_calls(fun) do
    mfa = {Ezagent.Workspace, :create_session, 3}
    :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    try do
      fun.()
      refute_receive {:trace, _pid, :call, {Ezagent.Workspace, :create_session, _args}}, 50
    after
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern(mfa, false, [:local])
    end
  end
end
