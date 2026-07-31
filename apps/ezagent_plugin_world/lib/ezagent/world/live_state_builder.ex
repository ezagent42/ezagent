defmodule Ezagent.World.LiveStateBuilder do
  @moduledoc false

  # Pure view-model construction for `EzagentPluginWorld.WorldLive`: given a
  # resolved route (`Ezagent.World.Routes`), the LiveView socket (READ-ONLY —
  # every function here only inspects `socket.assigns`, never assigns to the
  # socket or otherwise touches the LiveView process) and a layout, builds the
  # `world:state` / `caller_json` payloads pushed to the React island.
  #
  # Extracted from `EzagentPluginWorld.WorldLive` (2026-07-30, PR #1576
  # arch-debt burn-down) to keep the LiveView process-lifecycle module
  # (mount/handle_params/handle_info/handle_event) under the oversized-module
  # gate (it had crossed 1500 LOC). Mirrors the earlier `Ezagent.World.Routes`
  # extraction (pure route resolution split out of WorldLive) — same
  # "cohesive pure-function cluster, thin delegate call sites, no public API
  # change for callers outside WorldLive" shape as the rest of the LOC
  # burn-down campaign in `arch_baseline_manifest.exs`.

  alias Ezagent.World.CommandPaletteData
  alias Ezagent.World.ConversationSessionState

  # Route pages derive synthetic single-slot layouts. The older persisted
  @doc false
  def layout_for_route(%{component: component, title: title}, workspace_uri, _caller_uri) do
    scope_uri =
      if match?(%URI{}, workspace_uri), do: workspace_uri, else: Ezagent.URI.workspace(:system)

    # Display-only scope label for the fixed route layout.
    scope_label = URI.to_string(scope_uri)

    synthetic = %{
      "version" => 1,
      "scope" => scope_label,
      "components" => [
        %{
          "id" => component,
          "type" => component,
          "placement" => %{"x" => 0, "y" => 0, "w" => 12, "h" => 8},
          "props" => %{"title" => title}
        }
      ]
    }

    synthetic
  end

  @doc false
  def state_for_route(
        %{component: "conversation", session_uri: %URI{} = session_uri} = route,
        socket,
        layout
      ) do
    session_uri
    |> ConversationSessionState.state_for(socket)
    |> Map.put("path", route.path)
    |> Map.put("title", route.title)
    |> Map.put("layout", layout)
    |> put_command_palette(socket)
  end

  def state_for_route(%{component: "sessions_table"}, socket, layout) do
    sessions =
      ConversationSessionState.list_sessions(
        socket.assigns.current_workspace_uri,
        socket.assigns.current_entity_uri
      )

    current_session_uri = socket.assigns.current_session_uri || List.first(sessions)

    sessions_state(
      sessions,
      current_session_uri,
      socket.assigns.current_workspace_uri,
      layout,
      Ezagent.World.PresenterCaps.load(socket),
      socket.assigns.current_entity_uri
    )
    |> put_command_palette(socket)
  end

  # Overview 操作员落地页（FP5 S2-a）：KPI 概览 + 快捷入口,数据复用 AdminData
  # （overview 不属 :admin group,故单独子句;nav 高亮仍走 path="/" → Overview）。
  # F3 (read-plane PR-4 rework): operator-plane read — admin-gated like the
  # `:require_admin` live_session (defense-in-depth behind the route gate).
  def state_for_route(%{component: "overview"} = route, socket, layout) do
    if admin_socket?(socket) do
      route
      |> Ezagent.World.AdminData.state_for(%{
        workspace_uri: socket.assigns.current_workspace_uri,
        caller_uri: socket.assigns.current_entity_uri,
        caller_caps: Ezagent.World.PresenterCaps.load(socket)
      })
      |> Map.put("layout", layout)
      |> put_command_palette(socket)
    else
      unauthorized_route_state(route, socket, layout)
    end
  end

  # F3 (read-plane PR-4 rework): the whole `:admin` route group is
  # admin-gated HERE as well as by the `:require_admin` live_session — a
  # non-admin caller gets an explicit unauthorized state, never
  # cross-tenant counts/registries/templates.
  def state_for_route(%{group: :admin} = route, socket, layout) do
    if admin_socket?(socket) do
      route
      |> Ezagent.World.AdminData.state_for(%{
        workspace_uri: socket.assigns.current_workspace_uri,
        caller_uri: socket.assigns.current_entity_uri,
        caller_caps: Ezagent.World.PresenterCaps.load(socket)
      })
      |> Map.put("layout", layout)
      |> put_command_palette(socket)
    else
      unauthorized_route_state(route, socket, layout)
    end
  end

  def state_for_route(route, socket, layout),
    do: state_for_plugin_or_fallback(route, socket, layout)

  # The same operator predicate the `:require_admin` on_mount enforces
  # (bootstrap admin OR a member of the system workspace) — kept as one
  # small check so the route gate and this data-layer gate cannot drift
  # on WHAT counts as an operator.
  @doc false
  def admin_socket?(socket) do
    Map.get(socket.assigns, :is_admin?, false) == true or
      Map.get(socket.assigns, :is_system_member?, false) == true
  end

  # Explicit unauthorized state (Invariant #9 — surfaced, not silently
  # dropped): the route's component shell plus a denial marker, and NO
  # data keys.
  @doc false
  def unauthorized_route_state(route, socket, layout) do
    %{
      "component" => route.component,
      "title" => route.title,
      "path" => route.path,
      "workspace_uri" => encode_uri(socket.assigns.current_workspace_uri),
      "unauthorized" => true,
      "error" => "unauthorized",
      "layout" => layout
    }
    |> put_command_palette(socket)
  end

  # 插件页面经 `PluginPageRegistry` 在运行时查找已验证的 data builder；这避免了
  # 编译期读取 ETS 插件 catalog，也让新增插件页面无需重编译 World。
  @doc false
  def state_for_plugin_or_fallback(%{component: component} = route, socket, layout) do
    case Ezagent.World.PluginPageRegistry.by_key(component) do
      %{data_builder: data_builder} ->
        state =
          apply(data_builder, :state_for, [
            route,
            %{
              workspace_uri: socket.assigns.current_workspace_uri,
              caller_uri: socket.assigns.current_entity_uri,
              caller_caps: Ezagent.World.PresenterCaps.load(socket)
            }
          ])

        state
        |> Map.put("layout", layout)
        |> put_command_palette(socket)

      nil ->
        state_for_non_plugin_route(route, socket, layout)
    end
  end

  def state_for_plugin_or_fallback(route, socket, layout),
    do: state_for_non_plugin_route(route, socket, layout)

  @doc false
  def state_for_non_plugin_route(%{group: :workspace_plugins} = route, socket, layout) do
    route
    |> Ezagent.World.WorkspacePluginData.state_for(%{
      workspace_uri: socket.assigns.current_workspace_uri,
      caller_uri: socket.assigns.current_entity_uri,
      caller_caps: Ezagent.World.PresenterCaps.load(socket)
    })
    |> Map.put("layout", layout)
    |> put_command_palette(socket)
  end

  def state_for_non_plugin_route(route, socket, layout) do
    route
    |> Ezagent.World.IdentityData.state_for(%{
      workspace_uri: socket.assigns.current_workspace_uri,
      caller_uri: socket.assigns.current_entity_uri,
      caller_caps: Ezagent.World.PresenterCaps.load(socket),
      create_error: create_error_for_route(route, socket)
    })
    |> Map.put("layout", layout)
    |> put_command_palette(socket)
  end

  @doc false
  def create_error_for_route(%{component: "agent_new_form"}, socket),
    do: Map.get(socket.assigns, :agent_create_error)

  def create_error_for_route(%{component: "user_new_form"}, socket),
    do: Map.get(socket.assigns, :user_create_error)

  def create_error_for_route(_route, _socket), do: nil

  @doc false
  def sessions_state(sessions, current_session_uri, workspace_uri, layout, _caps, caller) do
    workspace = encode_uri(workspace_uri)
    current_session = encode_uri(current_session_uri)

    %{
      "component" => "sessions_table",
      "current_session_uri" => current_session,
      "workspace_uri" => workspace,
      "layout" => layout,
      "templates" => session_template_names(caller, workspace_uri),
      "socialwares" => Ezagent.World.WorkspacePluginData.socialware_rows(workspace_uri),
      "sessions" => Enum.map(sessions, &ConversationSessionState.session_row/1),
      # F3: explicitly clear any stale create_error — the React island merges
      # world:state ({...current, ...next}) and never remounts, so a previously
      # pushed create_error would otherwise linger as a phantom banner when the
      # operator returns to a healthy sessions page (mirrors agent_new_form's
      # nil-clear in IdentityData.put_create_error/3).
      "create_error" => nil
    }
  end

  @doc false
  def bootstrap_layout(workspace_uri),
    do: layout_for_route(%{component: "sessions_table", title: "Chat"}, workspace_uri, nil)

  # The bounded mount payload for `data-caller` — pushed at `mount/3` before the
  # async `:load_world_state` read completes. `display_name` is resolved HERE
  # (via the same `CallerDisplay.name/1` the post-load `caller_payload/4` uses)
  # rather than stubbed to the raw URI: the React island reads `data-caller`
  # exactly ONCE at mount (`WorldRenderer.mounted()` never re-reads it), so if
  # the stub loses the mount-vs-async race the top-right account menu is stuck
  # rendering the raw `entity://…` URI for the whole session. Resolving here
  # costs one indexed profile PK read (`Profile.get/1` = `Repo.get`), NOT the
  # caps/session/workspace read path this mount defers — first paint is correct.
  @doc false
  def bootstrap_caller_payload(caller, workspace) do
    %{
      "entity_uri" => encode_uri(caller),
      "workspace_uri" => encode_uri(workspace),
      "current_workspace_name" => workspace_name(workspace),
      "display_name" => caller_display_name(caller),
      "is_system_member" => false,
      "workspaces" => []
    }
  end

  @doc false
  def bootstrap_state(workspace, layout) do
    %{
      "component" => "sessions_table",
      "current_session_uri" => nil,
      "workspace_uri" => encode_uri(workspace),
      "layout" => layout,
      "templates" => ["default"],
      "socialwares" => [],
      "sessions" => [],
      "create_error" => nil,
      "cmdk" => %{"open" => false, "query" => "", "results" => []}
    }
  end

  # Resolvable SessionTemplate names for the "New session" picker —
  # delegated to the SINGLE source
  # `Ezagent.World.WorkspacePluginData.session_template_names/2` (which
  # routes the instance enumeration through the caller-authorizing
  # `Ezagent.Session.TemplateReads` chokepoint, read-plane PR-4 rework).
  @doc false
  def session_template_names(caller, %URI{scheme: "workspace"} = workspace_uri) do
    Ezagent.World.WorkspacePluginData.session_template_names(caller, workspace_uri)
  end

  def session_template_names(_caller, _), do: ["default"]

  @doc false
  def put_command_palette(state, socket) do
    Map.put(state, "cmdk", CommandPaletteData.state(socket.assigns, "", false))
  end

  @doc false
  def caller_payload(caller, workspace, caps, system_member?) do
    %{
      "entity_uri" => encode_uri(caller),
      "workspace_uri" => encode_uri(workspace),
      "current_workspace_name" => workspace_name(workspace),
      "display_name" => caller_display_name(caller),
      "is_system_member" => system_member?,
      "workspaces" => workspace_switcher_rows(caller, workspace, caps)
    }
  end

  @doc false
  def workspace_switcher_rows(caller, current_workspace, caps) do
    Ezagent.Workspace.list_workspaces_for(caller, caps)
    |> Enum.map(fn workspace ->
      %{
        "name" => workspace.name,
        "uri" => encode_uri(workspace.uri),
        "current" => same_uri?(workspace.uri, current_workspace),
        "switch_path" => "/workspaces/switch",
        "detail_path" => "/workspaces/#{URI.encode_www_form(workspace.name)}"
      }
    end)
  end

  @doc false
  def workspace_name(%URI{scheme: "workspace"} = workspace_uri),
    do: Ezagent.URI.name!(workspace_uri)

  def workspace_name(_), do: nil

  @doc false
  def encode_uri(%URI{} = uri), do: URI.to_string(uri)
  def encode_uri(_), do: nil

  @doc false
  def caller_display_name(uri), do: Ezagent.World.CallerDisplay.name(uri)

  defp same_uri?(%URI{} = left, %URI{} = right), do: URI.to_string(left) == URI.to_string(right)
  defp same_uri?(_, _), do: false
end
