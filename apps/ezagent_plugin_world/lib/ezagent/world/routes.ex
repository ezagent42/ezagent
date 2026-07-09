defmodule Ezagent.World.Routes do
  @moduledoc """
  Pure URL → world route resolution for `EzagentPluginWorld.WorldLive`.

  `route_for/2` maps a browser path (+ query params) to the route map the React
  shell renders (`%{component, title, path, ...}`). Extracted from `WorldLive`
  (it held no socket state) to keep the LiveView module under the oversized
  arch-cap — same split pg applied to `Ezagent.World.CallerDisplay`. All helpers
  are pure; the URI-parsing ones tolerate malformed input by returning `nil`.
  """

  @doc """
  Resolve the route map for a browser request from `params` + the request `uri`.
  Unknown paths fall back to the sessions table.
  """
  @spec route_for(map(), String.t() | nil) :: map()
  def route_for(params, uri) do
    path = browser_path(uri)

    cond do
      path in ["/", "/sessions"] ->
        case conversation_session_param(params) do
          %URI{} = session_uri ->
            %{
              component: "conversation",
              title: "Chat",
              path: path,
              session_uri: session_uri
            }

          nil ->
            %{component: "sessions_table", title: "Chat", path: path}
        end

      # `/overview` — the operator Overview surface (KPI overview + quick entries +
      # continuable sessions), reachable via the "Overview" nav item. NON-default
      # by design: the `/` landing intentionally stays Chat/Sessions. Whether
      # Overview should become the post-login first screen is a deferred host-model
      # decision (main-host `/` is HomeLive → redirect-loop risk; see the
      # 2026-07-02 return doc "Deferred: first-screen landing"). Not wired to `/`.
      path == "/overview" ->
        %{component: "overview", title: "Overview", path: path}

      path == "/identities" ->
        %{
          component: "identities",
          title: "Identities",
          path: path,
          filter: Map.get(params, "filter", "all")
        }

      path == "/identities/users" ->
        %{component: "users_table", title: "Users", path: path}

      path == "/identities/users/new" ->
        %{component: "user_new_form", title: "New User", path: path}

      path == "/identities/agents" ->
        %{
          component: "agents_table",
          title: "Agents",
          path: path,
          filter: "agents"
        }

      path == "/identities/agents/new" ->
        %{component: "agent_new_form", title: "New Agent", path: path}

      path == "/workspaces" ->
        %{
          group: :workspace_plugins,
          component: "workspaces_list",
          title: "Workspaces",
          path: path
        }

      match = Regex.run(~r{\A/workspaces/([^/]+)/templates/new\z}, path) ->
        [_full, encoded] = match

        %{
          group: :workspace_plugins,
          component: "workspace_template_new",
          title: "New Template",
          path: path,
          name: URI.decode_www_form(encoded)
        }

      match = Regex.run(~r{\A/workspaces/([^/]+)\z}, path) ->
        [_full, encoded] = match

        %{
          group: :workspace_plugins,
          component: "workspace_detail",
          title: "Workspace Detail",
          path: path,
          name: URI.decode_www_form(encoded)
        }

      path == "/plugins" ->
        %{group: :workspace_plugins, component: "plugins", title: "Plugins", path: path}

      path == "/plugins/kb" ->
        %{
          group: :workspace_plugins,
          component: "plugins",
          title: "Knowledge Base",
          path: path,
          focus_slug: "kb"
        }

      path == "/plugins/feishu/bindings" ->
        %{
          group: :workspace_plugins,
          component: "feishu_bindings",
          title: "Feishu Bindings",
          path: path
        }

      # kanban 操作面（kanban-as-role K4）：列表页 + 单个 kanban 详情页。
      # entity_uri = 一个 kanban-manager agent 的 `entity://<ws>/agent/<id>`。
      match = Regex.run(~r{\A/plugins/kanban/([^/]+)\z}, path) ->
        [_full, encoded] = match

        %{
          group: :workspace_plugins,
          component: "kanban",
          title: "看板",
          path: path,
          entity_uri: parse_any_uri(encoded)
        }

      path == "/plugins/kanban" ->
        %{
          group: :workspace_plugins,
          component: "kanban",
          title: "看板",
          path: path,
          entity_uri: nil
        }

      match = Regex.run(~r{\A/plugins/auto/([^/]+)/([^/]+)\z}, path) ->
        [_full, kind, encoded] = match

        %{
          group: :workspace_plugins,
          component: "auto_derive",
          title: "Auto Derive",
          path: path,
          kind: parse_existing_kind(kind),
          entity_uri: parse_any_uri(encoded)
        }

      match = Regex.run(~r{\A/plugins/auto/([^/]+)\z}, path) ->
        [_full, kind] = match

        %{
          group: :workspace_plugins,
          component: "auto_derive",
          title: "Auto Derive",
          path: path,
          kind: parse_existing_kind(kind),
          entity_uri: nil
        }

      path == "/profile" ->
        %{group: :workspace_plugins, component: "profile", title: "Profile", path: path}

      path == "/admin" ->
        %{group: :admin, component: "dashboard", title: "Admin Dashboard", path: path}

      path == "/admin/logs" ->
        %{group: :admin, component: "observability", title: "Observability", path: path}

      path == "/admin/registry" ->
        %{group: :admin, component: "entity_registry", title: "Entity Registry", path: path}

      path == "/admin/snapshots" ->
        %{group: :admin, component: "snapshots", title: "Snapshots", path: path}

      path == "/admin/templates" ->
        %{group: :admin, component: "templates", title: "Templates", path: path}

      path == "/admin/caps" ->
        %{group: :admin, component: "caps_admin", title: "Capabilities", path: path}

      path == "/admin/audit/authz" ->
        %{group: :admin, component: "authz_audit", title: "Authz Audit", path: path}

      path == "/admin/settings" ->
        %{group: :admin, component: "settings", title: "Settings", path: path}

      path == "/admin/routing" ->
        %{group: :admin, component: "routing", title: "Routing", path: path}

      match = Regex.run(~r{\A/admin/sessions/([^/]+)/external_mirror\z}, path) ->
        [_full, encoded] = match

        %{
          group: :admin,
          component: "external_mirror",
          title: "External Mirror",
          path: path,
          session_uri: parse_session_uri_param(encoded)
        }

      match = Regex.run(~r{\A/identities/(users|agents)/([^/]+)/caps\z}, path) ->
        [_full, _kind, encoded] = match

        %{
          component: "entity_caps",
          title: "Entity Caps",
          path: path,
          entity_uri: parse_entity_uri(encoded)
        }

      match = Regex.run(~r{\A/identities/users/([^/]+)\z}, path) ->
        [_full, encoded] = match

        %{
          component: "user_detail",
          title: "User Detail",
          path: path,
          entity_uri: parse_entity_uri(encoded)
        }

      match = Regex.run(~r{\A/identities/agents/([^/]+)/api-keys\z}, path) ->
        [_full, encoded] = match

        %{
          component: "agent_api_keys",
          title: "Agent API Keys",
          path: path,
          entity_uri: parse_entity_uri(encoded)
        }

      match = Regex.run(~r{\A/identities/agents/([^/]+)/config\z}, path) ->
        [_full, encoded] = match

        %{
          component: "agent_config",
          title: "Agent Config",
          path: path,
          entity_uri: parse_entity_uri(encoded)
        }

      match = Regex.run(~r{\A/identities/agents/([^/]+)/extensions\z}, path) ->
        [_full, encoded] = match

        %{
          component: "agent_extensions",
          title: "Agent Extensions",
          path: path,
          entity_uri: parse_entity_uri(encoded)
        }

      match = Regex.run(~r{\A/identities/agents/([^/]+)/terminal\z}, path) ->
        [_full, encoded] = match

        %{
          component: "pty_terminal",
          title: "Terminal",
          path: path,
          entity_uri: parse_entity_uri(encoded)
        }

      match = Regex.run(~r{\A/identities/agents/([^/]+)\z}, path) ->
        [_full, encoded] = match

        %{
          component: "agent_detail",
          title: "Agent Detail",
          path: path,
          entity_uri: parse_entity_uri(encoded)
        }

      true ->
        %{component: "sessions_table", title: "Chat", path: path}
    end
  end

  defp browser_path(uri) when is_binary(uri) do
    path =
      uri
      |> String.replace(~r{\Ahttps?://[^/]+}, "")
      |> String.split(["?", "#"], parts: 2)
      |> List.first()

    if path in [nil, ""], do: "/", else: path
  end

  defp browser_path(_), do: "/"

  defp conversation_session_param(params) when is_map(params) do
    case Map.get(params, "session") do
      encoded when is_binary(encoded) -> parse_session_uri_param(encoded)
      _ -> nil
    end
  end

  defp conversation_session_param(_), do: nil

  defp parse_session_uri_param(encoded) when is_binary(encoded) do
    decoded = URI.decode_www_form(encoded)

    case Ezagent.URI.new!(decoded) do
      %URI{scheme: "session"} = uri -> uri
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp parse_session_uri_param(_), do: nil

  defp parse_entity_uri(encoded) when is_binary(encoded) do
    decoded = URI.decode_www_form(encoded)

    case Ezagent.URI.new!(decoded) do
      %URI{scheme: "entity"} = uri -> uri
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp parse_entity_uri(_), do: nil

  defp parse_any_uri(encoded) when is_binary(encoded) do
    encoded
    |> URI.decode_www_form()
    |> Ezagent.URI.new!()
  rescue
    ArgumentError -> nil
  end

  defp parse_any_uri(_), do: nil

  defp parse_existing_kind(kind) when is_binary(kind) do
    String.to_existing_atom(kind)
  rescue
    ArgumentError -> nil
  end

  defp parse_existing_kind(_), do: nil
end
