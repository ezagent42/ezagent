defmodule EzagentWeb.WorldHostRoutingTest do
  use EzagentWeb.ConnCase

  import Phoenix.LiveViewTest

  setup do
    prior_world_host_scope =
      Application.get_env(:ezagent_web, :world_host_scope, :__ezagent_missing__)

    prior_home = System.get_env("EZAGENT_HOME")

    home =
      Path.join(System.tmp_dir!(), "ezagent_world_live_#{System.unique_integer([:positive])}")

    System.put_env("EZAGENT_HOME", home)

    on_exit(fn ->
      if prior_home,
        do: System.put_env("EZAGENT_HOME", prior_home),
        else: System.delete_env("EZAGENT_HOME")

      if prior_world_host_scope == :__ezagent_missing__,
        do: Application.delete_env(:ezagent_web, :world_host_scope),
        else: Application.put_env(:ezagent_web, :world_host_scope, prior_world_host_scope)

      File.rm_rf!(home)
    end)

    :ok
  end

  test "world.ezagent.chat root mounts the world React shell", %{conn: conn} do
    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, view, html} = live(conn, "/")

    assert html =~ ~s(id="world-root")
    assert has_element?(view, "#world-root[phx-hook='WorldRenderer'][phx-update='ignore']")
    assert has_element?(view, "#world-root[data-world-component='sessions_table']")
    assert has_element?(view, ~s([data-world-loading="shell-skeleton"]))
    assert has_element?(view, "[data-world-loading-progress]")
    assert has_element?(view, ~s([data-world-loading-panel="sessions"]))
    assert has_element?(view, ~s([data-world-loading-panel="conversation"]))
    assert has_element?(view, ~s([data-world-loading-panel="context"]))
    refute html =~ "motion-safe:animate-spin"
  end

  test "world Chat uses a fixed single-slot layout", %{conn: conn} do
    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, view, _html} = live(conn, "/sessions")
    html = render_async(view, 5_000)

    state = world_state(html)
    assert [component] = state["layout"]["components"]
    assert component["type"] == "sessions_table"
    refute Map.has_key?(state, "can_manage" <> "_layout")
    refute html =~ "layout" <> "_editor"
  end

  test "world shell exposes visible workspaces for the header switcher", %{conn: conn} do
    target = "world-switcher-#{System.unique_integer([:positive])}"
    {:ok, _} = Ezagent.Workspace.Store.create(target, %{})

    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, view, _html} = live(conn, "/sessions")
    # See render_async note above — the caller payload (workspaces list)
    # is populated by the same async load.
    html = render_async(view, 5_000)
    caller = world_caller(html)

    assert caller["workspace_uri"] == "workspace://system"
    assert caller["current_workspace_name"] == "system"

    assert Enum.any?(caller["workspaces"], fn workspace ->
             workspace["name"] == "system" and
               workspace["uri"] == "workspace://system" and
               workspace["current"] == true and
               workspace["switch_path"] == "/workspaces/switch"
           end)

    assert Enum.any?(caller["workspaces"], fn workspace ->
             workspace["name"] == target and
               workspace["uri"] == "workspace://#{target}" and
               workspace["current"] == false and
               workspace["switch_path"] == "/workspaces/switch"
           end)
  end

  test "world sessions_table dispatch joins through Invocation.dispatch", %{conn: conn} do
    caller = "entity://system/user/world_join_#{System.unique_integer([:positive])}"
    caller_uri = Ezagent.URI.new!(caller)
    session_uri = world_session_uri()

    :ok = create_read_only_user(caller_uri, [session_join_cap(caller_uri, session_uri)])

    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => caller,
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, view, _html} = live(conn, "/")

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "sessions.join",
        "args" => %{"session_uri" => URI.to_string(session_uri)}
      })

    assert html =~ ~s(data-last-dispatch="ok")
    assert html =~ ~s(data-current-session-uri="#{URI.to_string(session_uri)}")

    # #1576 regression: the sessions-TABLE row click is client-wired to this
    # exact action (`sessions.join`, `apps/ezagent_plugin_world/assets/src/
    # main.tsx`'s SessionsTable `onJoin`) BECAUSE only this direct-action path
    # (push_patch -> handle_params -> LiveStateBuilder.state_for_route) supplies
    # a "layout" in the pushed world:state. The conversation-group `session.switch`
    # action (ConversationSessionState.switch_session/2, used by the in-conversation
    # session rail's onSessionSwitch) never adds one — the two actions are NOT
    # interchangeable. A prior commit swapped the client's onJoin onto
    # `session.switch`, silently losing the layout and breaking the
    # sessions-table-join E2E contract (world.spec.ts "sessions interaction
    # emits an admitted world:dispatch"). This assertion pins the asymmetry the
    # client depends on so a future accidental swap of these two actions fails
    # here first.
    assert %{"layout" => %{}} = world_state(html)
  end

  test "world sessions_table opens an existing member without preloaded join caps", %{conn: conn} do
    caller = "entity://system/user/world_existing_member_#{System.unique_integer([:positive])}"
    caller_uri = Ezagent.URI.new!(caller)
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    :ok = create_read_only_user(caller_uri, [])
    {:ok, _} = join_member_as_admin(session_uri, caller_uri)

    refute holds_join_cap?(caller_uri, session_uri)

    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => caller,
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, view, _html} = live(conn, "/sessions")

    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{
      "action" => "sessions.join",
      "args" => %{"session_uri" => URI.to_string(session_uri)}
    })

    assert_patch(view, "/sessions?session=#{encoded}")
    assert has_element?(view, "#world-root[data-world-component='conversation']")
  end

  test "world sessions_table opens an existing member whose principal is cold", %{conn: conn} do
    caller =
      "entity://system/user/world_cold_existing_member_#{System.unique_integer([:positive])}"

    caller_uri = Ezagent.URI.new!(caller)
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    on_exit(fn ->
      _ = Ezagent.LocalRuntime.ensure_live(session_uri)
      _ = Ezagent.Entity.spawn_principal(caller_uri)
    end)

    :ok = create_read_only_user(caller_uri, [])
    {:ok, _} = join_member_as_admin(session_uri, caller_uri)
    wait_until(fn -> holds_member_cap?(caller_uri, session_uri) end)
    :ok = Ezagent.Kind.terminate(caller_uri)
    wait_until(fn -> Ezagent.KindRegistry.lookup(caller_uri) == :error end)

    refute holds_join_cap?(caller_uri, session_uri)

    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => caller,
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, view, _html} = live(conn, "/sessions")

    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{
      "action" => "sessions.join",
      "args" => %{"session_uri" => URI.to_string(session_uri)}
    })

    assert_patch(view, "/sessions?session=#{encoded}")
    assert has_element?(view, "#world-root[data-world-component='conversation']")
    assert holds_member_cap?(caller_uri, session_uri)
  end

  test "world sessions_table opens observe-only when caller cannot join", %{conn: conn} do
    caller = "entity://system/user/world_observe_only_#{System.unique_integer([:positive])}"
    caller_uri = Ezagent.URI.new!(caller)
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    :ok = create_read_only_user(caller_uri, [])

    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => caller,
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, view, _html} = live(conn, "/sessions")

    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{
      "action" => "sessions.join",
      "args" => %{"session_uri" => URI.to_string(session_uri)}
    })

    assert_patch(view, "/sessions?session=#{encoded}")
    assert has_element?(view, "#world-root[data-world-component='conversation']")
    refute holds_join_cap?(caller_uri, session_uri)
  end

  test "world conversation deep link rehydrates a cold member session before self-join", %{
    conn: conn
  } do
    caller =
      "entity://system/user/world_cold_deep_link_member_#{System.unique_integer([:positive])}"

    caller_uri = Ezagent.URI.new!(caller)
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    on_exit(fn ->
      _ = Ezagent.LocalRuntime.ensure_live(session_uri)
      _ = Ezagent.Entity.spawn_principal(caller_uri)
    end)

    :ok = create_read_only_user(caller_uri, [])
    {:ok, _} = join_member_as_admin(session_uri, caller_uri)
    wait_until(fn -> holds_member_cap?(caller_uri, session_uri) end)
    :ok = Ezagent.Kind.terminate(session_uri)
    :ok = Ezagent.Kind.terminate(caller_uri)
    wait_until(fn -> Ezagent.KindRegistry.lookup(session_uri) == :error end)
    wait_until(fn -> Ezagent.KindRegistry.lookup(caller_uri) == :error end)

    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => caller,
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, view, _html} = live(conn, "/sessions?session=#{encoded}")
    # The self-join rehydration (spawning the session/caller Kinds and
    # granting the member cap) is a side effect of the async-loaded route
    # state, not the bounded mount fallback. Await it via render_async
    # before asserting the Kinds are live — see render_async note above.
    _html = render_async(view, 5_000)

    assert has_element?(view, "#world-root[data-world-component='conversation']")
    assert {:ok, _pid} = Ezagent.KindRegistry.lookup(session_uri)
    assert {:ok, _pid} = Ezagent.KindRegistry.lookup(caller_uri)
    assert holds_member_cap?(caller_uri, session_uri)
  end

  test "world React island navigation patches without a full page reload", %{conn: conn} do
    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, view, _html} = live(conn, "/sessions")

    view
    |> element("#world-root")
    |> render_hook("world:navigate", %{"to" => "/identities/agents/new"})

    assert_patch(view, "/identities/agents/new")
  end

  test "world.ezagent.chat sessions path stays inside the world scope", %{conn: conn} do
    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, view, html} = live(conn, "/sessions")

    assert html =~ ~s(id="world-root")
    assert has_element?(view, "#world-root[data-world-component='sessions_table']")
  end

  # This is ten LiveView boots plus their authorization/data-load work. Under the
  # umbrella suite the shared sandbox can make the aggregate exceed ExUnit's
  # default 60s even though each route remains bounded and fast in isolation.
  @tag timeout: 180_000
  test "world identities group paths stay inside the world scope", %{conn: conn} do
    agent_uri = "entity://system/agent/world_route_agent"
    encoded_agent = URI.encode_www_form(agent_uri)
    user_uri = "entity://system/user/world_route_user"
    encoded_user = URI.encode_www_form(user_uri)

    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://system"
      })

    paths = [
      {"/identities", "identities"},
      {"/identities/users", "users_table"},
      {"/identities/agents", "agents_table"},
      {"/identities/users/#{encoded_user}/caps", "entity_caps"},
      {"/identities/agents/#{encoded_agent}/caps", "entity_caps"},
      {"/identities/agents/#{encoded_agent}/api-keys", "agent_api_keys"},
      {"/identities/agents/new", "agent_new_form"},
      {"/identities/agents/#{encoded_agent}/extensions", "agent_extensions"},
      {"/identities/agents/#{encoded_agent}/terminal", "pty_terminal"},
      {"/identities/agents/#{encoded_agent}", "agent_detail"}
    ]

    for {path, component} <- paths do
      {:ok, view, html} = live(conn, path)

      assert html =~ ~s(id="world-root")
      assert has_element?(view, "#world-root[data-world-component='#{component}']")
      assert html =~ component
    end
  end

  # kanban-as-role K4 — the router MUST have `live "/plugins/kanban"` +
  # `/plugins/kanban/:uri` or WorldLive never mounts the surface (the e2e bug:
  # the path 404'd to the "此路径无处可去" fallback even though Routes.route_for
  # produced the kanban route). This is a ROUTER-level guard: `live/2` raises if
  # the route is absent — exactly the layer the bug lived in (a route_for unit
  # test stays green without the router line, so it can't catch this).
  test "world kanban plugin paths mount the kanban surface (router live routes)", %{conn: conn} do
    kanban_uri = "entity://system/agent/kanban-mgr-route-test"
    encoded = URI.encode_www_form(kanban_uri)

    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://system"
      })

    paths = [
      {"/plugins/kanban", "kanban"},
      {"/plugins/kanban/#{encoded}", "kanban"}
    ]

    for {path, component} <- paths do
      {:ok, view, html} = live(conn, path)

      assert html =~ ~s(id="world-root")
      assert has_element?(view, "#world-root[data-world-component='#{component}']")
      refute html =~ "此路径无处可去", "#{path} fell through to the no-route fallback"
    end
  end

  test "world admin group paths stay inside the world scope", %{conn: conn} do
    session_uri = URI.to_string(world_session_uri())
    encoded_session = URI.encode_www_form(session_uri)

    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://system"
      })

    paths = [
      {"/admin", "dashboard"},
      {"/admin/logs", "observability"},
      {"/admin/registry", "entity_registry"},
      {"/admin/snapshots", "snapshots"},
      {"/admin/templates", "templates"},
      {"/admin/caps", "caps_admin"},
      {"/admin/audit/authz", "authz_audit"},
      {"/admin/settings", "settings"},
      {"/admin/routing", "routing"},
      {"/admin/sessions/#{encoded_session}/external_mirror", "external_mirror"}
    ]

    for {path, component} <- paths do
      {:ok, view, html} = live(conn, path)

      assert html =~ ~s(id="world-root")
      assert has_element?(view, "#world-root[data-world-component='#{component}']")
      assert html =~ component
    end
  end

  test "nil world host scope serves operator routes on apex without taking apex root",
       %{conn: conn} do
    Application.put_env(:ezagent_web, :world_host_scope, nil)

    admin_conn =
      conn
      |> Map.put(:host, "app.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, view, html} = live(admin_conn, "/admin")

    assert html =~ ~s(id="world-root")
    assert has_element?(view, "#world-root[data-world-component='dashboard']")

    route_info = Phoenix.Router.route_info(EzagentWeb.Router, "GET", "/", "app.ezagent.chat")

    assert route_info.plug == Phoenix.LiveView.Plug
    assert route_info.route == "/"
    assert {EzagentWeb.HomeLive, _action, _opts, _metadata} = route_info.phoenix_live_view
  end

  test "world workspace and plugin group paths stay inside the world scope", %{conn: conn} do
    encoded_session = world_session_uri() |> URI.to_string() |> URI.encode_www_form()

    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://system"
      })

    paths = [
      {"/workspaces", "workspaces_list"},
      {"/workspaces/system", "workspace_detail"},
      {"/plugins", "plugins"},
      {"/plugins/feishu/bindings", "feishu_bindings"},
      {"/plugins/auto/session", "auto_derive"},
      {"/plugins/auto/session/#{encoded_session}", "auto_derive"},
      {"/profile", "profile"}
    ]

    for {path, component} <- paths do
      {:ok, view, html} = live(conn, path)

      assert html =~ ~s(id="world-root")
      assert has_element?(view, "#world-root[data-world-component='#{component}']")
      assert html =~ component
    end
  end

  test "world sessions_table dispatch records join denial", %{conn: conn} do
    caller = "entity://system/user/world_no_caps_#{System.unique_integer([:positive])}"
    caller_uri = Ezagent.URI.new!(caller)
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    :ok = create_read_only_user(caller_uri, [])

    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => caller,
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, view, _html} = live(conn, "/")

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "sessions.join",
        "args" => %{"session_uri" => URI.to_string(session_uri)}
      })

    assert html =~ ~s(data-last-dispatch="error:missing_cap")
    assert_patch(view, "/sessions?session=#{encoded}")
  end

  defp create_read_only_user(uri, caps) do
    result =
      case Ezagent.Users.create_read_only(uri, caps) do
        {:ok, _} -> :ok
        {:error, %Ecto.Changeset{errors: [uri: {"has already been taken", _}]}} -> :ok
      end

    with :ok <- result do
      Ezagent.Entity.spawn_principal(uri)
    end
  end

  defp world_session_uri do
    workspace_uri = Ezagent.URI.workspace(:system)
    admin = Ezagent.Entity.User.admin_uri()
    target = Ezagent.URI.with_action(workspace_uri, :workspace, :create_session)
    {:ok, create_cap} = Ezagent.Cap.issue_for_action({:admin, admin}, admin, target)
    short_name = "world-host-#{System.unique_integer([:positive, :monotonic])}"

    {:ok, %{session_uri: %URI{} = session_uri}} =
      Ezagent.Workspace.create_session(
        workspace_uri,
        %{short_name: short_name, template_name: "default"},
        %{
          caller: admin,
          authenticated_principal: admin,
          caps: MapSet.new([create_cap])
        }
      )

    on_exit(fn ->
      try do
        _ = Ezagent.Kind.terminate(session_uri)
      catch
        _, _ -> :ok
      end
    end)

    session_uri
  end

  defp session_join_cap(caller_uri, session_uri) do
    requested =
      Ezagent.Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :join,
        session_uri,
        Ezagent.URI.workspace(:system)
      )

    {:ok, artifact} =
      Ezagent.Cap.issue({:admin, Ezagent.Entity.User.admin_uri()}, caller_uri, requested)

    artifact
  end

  defp join_member_as_admin(session_uri, member_uri) do
    admin = Ezagent.Entity.User.admin_uri()
    target = Ezagent.URI.with_action(session_uri, :session, :join)
    {:ok, join_cap} = Ezagent.Cap.issue_for_action({:admin, admin}, admin, target)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{member: member_uri},
      ctx: %{
        caller: admin,
        authenticated_principal: admin,
        caps: MapSet.new([join_cap]),
        reply: :ignore
      }
    })
  end

  defp holds_join_cap?(caller_uri, session_uri) do
    Enum.any?(Ezagent.Identity.list_caps_for(caller_uri), fn
      %Ezagent.Capability{} = cap ->
        cap.kind == :session and cap.behavior == Ezagent.ActionSet.Session and
          Ezagent.Capability.action_of(cap) == :join and cap.instance == session_uri

      _ ->
        false
    end)
  end

  defp holds_member_cap?(caller_uri, session_uri) do
    caller_uri
    |> Ezagent.IdentityCaps.load_persisted()
    |> then(&Ezagent.Session.MemberReceive.holds_member_cap_over?(caller_uri, &1, session_uri))
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp world_caller(html) do
    [_, json] = Regex.run(~r/data-caller="([^"]*)"/, html)

    json
    |> html_unescape()
    |> Jason.decode!()
  end

  defp world_state(html) do
    [_, json] = Regex.run(~r/data-world-state="([^"]*)"/, html)

    json
    |> html_unescape()
    |> Jason.decode!()
  end

  defp html_unescape(s) do
    s
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end
end
