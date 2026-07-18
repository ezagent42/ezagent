defmodule EzagentWeb.WorldAgentConsoleRoutesTest do
  @moduledoc """
  Route-level coverage for the shipped Agent Console surfaces.

  These tests mount the real World LiveView routes and assert the React island
  receives the expected `data-world-state` contract. Lower-level IdentityData
  and AgentActions tests cover the read/action seams; this file protects the
  route wiring around those seams.
  """

  use EzagentWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Ezagent.Entity.User
  alias Ezagent.Workspace

  @fs_types_table :ezagent_resource_fs_types
  @world_layouts "world-layouts"

  setup do
    ensure_world_layouts_registered!()
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    prior_home = System.get_env("EZAGENT_HOME")

    home =
      Path.join(
        System.tmp_dir!(),
        "ezagent_world_agent_routes_#{System.unique_integer([:positive])}"
      )

    System.put_env("EZAGENT_HOME", home)

    ws_name = "agent-routes-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    on_exit(fn ->
      if prior_home,
        do: System.put_env("EZAGENT_HOME", prior_home),
        else: System.delete_env("EZAGENT_HOME")

      File.rm_rf!(home)
    end)

    {:ok, workspace_uri: workspace_uri}
  end

  test "agents list route mounts agents_table state for the current workspace",
       %{conn: conn, workspace_uri: workspace_uri} do
    agent_uri = create_curl_agent!(workspace_uri)
    agent_uri_str = URI.to_string(agent_uri)

    {:ok, view, html} = live(admin_conn(conn, workspace_uri), "/identities/agents")

    assert has_element?(view, "#world-root[data-world-component='agents_table']")

    state = world_state(html)
    assert state["component"] == "agents_table"
    assert state["workspace_uri"] == URI.to_string(workspace_uri)
    assert ["agents_table"] = state["layout"]["components"] |> Enum.map(& &1["type"])
    assert "curl" in state["agent_flavors"]
    assert Enum.any?(state["agents"], &(&1["uri"] == agent_uri_str))
  end

  test "new-agent route exposes dynamic flavor schemas and cwd policy",
       %{conn: conn, workspace_uri: workspace_uri} do
    {:ok, view, html} = live(admin_conn(conn, workspace_uri), "/identities/agents/new")

    assert has_element?(view, "#world-root[data-world-component='agent_new_form']")

    state = world_state(html)
    assert state["component"] == "agent_new_form"
    assert state["preview_uri"] == "<agent-uri>"
    assert state["create_error"] == nil
    assert "curl" in state["flavors"]
    assert "py" in state["script_required_flavors"]
    assert is_list(state["allowed_project_cwd_roots"])

    curl_schema_keys =
      state
      |> get_in(["config_schemas", "curl"])
      |> Enum.map(& &1["key"])

    assert "model" in curl_schema_keys
    assert "provider" in curl_schema_keys
    assert "api_url" in curl_schema_keys
  end

  test "agent detail and config routes expose shipped Agent Console state",
       %{conn: conn, workspace_uri: workspace_uri} do
    agent_uri = create_curl_agent!(workspace_uri)
    agent_uri_str = URI.to_string(agent_uri)
    encoded = URI.encode_www_form(agent_uri_str)

    {:ok, detail_view, detail_html} =
      live(admin_conn(conn, workspace_uri), "/identities/agents/#{encoded}")

    assert has_element?(detail_view, "#world-root[data-world-component='agent_detail']")

    detail_state = world_state(detail_html)
    assert detail_state["component"] == "agent_detail"
    assert detail_state["agent_uri"] == agent_uri_str
    assert detail_state["flavor"] == "curl"
    assert detail_state["config_path"] == "/identities/agents/#{encoded}/config"
    assert is_list(detail_state["granted_caps"])

    config_field_keys = Enum.map(detail_state["config_fields"], & &1["key"])
    assert "model" in config_field_keys
    assert "provider" in config_field_keys
    assert "api_url" in config_field_keys

    {:ok, config_view, config_html} =
      live(admin_conn(conn, workspace_uri), "/identities/agents/#{encoded}/config")

    assert has_element?(config_view, "#world-root[data-world-component='agent_config']")

    config_state = world_state(config_html)
    assert config_state["component"] == "agent_config"
    assert config_state["agent_uri"] == agent_uri_str
    assert is_list(config_state["config_schema"])
    refute Map.has_key?(config_state, "config_error")
  end

  test "delete-bound-agent failure stays on the detail route with action_error",
       %{conn: conn, workspace_uri: workspace_uri} do
    agent_uri = create_curl_agent!(workspace_uri)
    agent_uri_str = URI.to_string(agent_uri)
    encoded = URI.encode_www_form(agent_uri_str)
    session_uri = spawn_session_for_workspace!(workspace_uri)
    join_member!(session_uri, agent_uri)

    {:ok, view, _html} = live(admin_conn(conn, workspace_uri), "/identities/agents/#{encoded}")

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "agents.delete",
        "args" => %{"agent_uri" => agent_uri_str}
      })

    assert has_element?(view, "#world-root[data-world-component='agent_detail']")
    assert html =~ ~s(data-last-dispatch="error:{:agent_bound_to_live_session,)

    state = world_state(html)
    assert state["component"] == "agent_detail"
    assert state["path"] == "/identities/agents/#{encoded}"
    assert state["agent_uri"] == agent_uri_str
    assert state["action_error"] =~ "该 agent 正在 1 个对话中"
  end

  defp create_curl_agent!(%URI{} = workspace_uri) do
    name = "route-curl-#{System.unique_integer([:positive])}"
    admin = User.admin_uri()
    target = Ezagent.URI.with_action(workspace_uri, :workspace, :create_agent)
    {:ok, create_cap} = Ezagent.Cap.issue_for_action({:admin, admin}, admin, target)

    assert {:ok, %{agent_uri: agent_uri}} =
             Workspace.create_agent(
               workspace_uri,
               %{flavor: "curl", name: name, cwd: "", with_pty: false},
               %{caller: admin, caps: MapSet.new([create_cap])}
             )

    grant_admin_agent_read_caps!(agent_uri)
    agent_uri
  end

  defp grant_admin_agent_read_caps!(agent_uri) do
    admin = User.admin_uri()

    issued =
      [
        Ezagent.URI.with_action(agent_uri, :identity, :list_caps),
        Ezagent.URI.with_action(agent_uri, :sandbox, :read),
        Ezagent.URI.with_action(agent_uri, :manage, :read_cascade)
      ]
      |> Enum.map(fn target ->
        {:ok, artifact} = Ezagent.Cap.issue_for_action({:admin, admin}, admin, target)
        :ok = Ezagent.Identity.absorb_cap(admin, artifact)
        artifact
      end)

    :ok = Ezagent.Identity.CapAbsorbAwait.await_exact(admin, issued, 5_000)
  end

  defp spawn_session_for_workspace!(%URI{} = workspace_uri) do
    ws_name = Ezagent.URI.name!(workspace_uri)

    session_uri =
      Ezagent.URI.new!(
        "session://#{ws_name}/default/route-test-#{System.unique_integer([:positive])}"
      )

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors(),
        owner_uri: User.admin_uri()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)

    on_exit(fn ->
      case Ezagent.KindRegistry.lookup(session_uri) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, pid)

        :error ->
          :ok
      end
    end)

    session_uri
  end

  defp join_member!(%URI{} = session_uri, %URI{} = agent_uri) do
    admin = User.admin_uri()
    target = Ezagent.URI.with_action(session_uri, :session, :join)
    {:ok, join_cap} = Ezagent.Cap.issue_for_action({:admin, admin}, admin, target)

    result =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{member: agent_uri},
        ctx: %{
          caller: admin,
          caps: MapSet.new([join_cap]),
          reply: :ignore
        }
      })

    assert result == :ok or match?({:ok, _}, result)
    :ok
  end

  defp admin_conn(conn, %URI{} = workspace_uri) do
    conn
    |> Map.put(:host, "world.ezagent.chat")
    |> Plug.Test.init_test_session(%{
      "current_entity_uri" => URI.to_string(User.admin_uri()),
      "current_workspace_uri" => URI.to_string(workspace_uri)
    })
  end

  defp world_state(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#world-root")
    |> LazyHTML.attribute("data-world-state")
    |> List.first()
    |> Jason.decode!()
  end

  defp ensure_world_layouts_registered! do
    if :ets.lookup(@fs_types_table, @world_layouts) == [] do
      {@world_layouts, spec} =
        Enum.find(
          EzagentPluginWorld.Application.resource_types(),
          fn {type, _spec} -> type == @world_layouts end
        )

      :ok = Ezagent.Resource.FsResolver.register_type(@world_layouts, spec)
      on_exit(fn -> Ezagent.Resource.FsResolver.unregister_type(@world_layouts) end)
    end

    :ok
  end
end
