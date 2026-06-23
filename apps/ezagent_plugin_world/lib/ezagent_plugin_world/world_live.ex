defmodule EzagentPluginWorld.WorldLive do
  @moduledoc """
  LiveView SSR/comms shell for the React-owned `world` app.
  """

  use Phoenix.LiveView

  alias Ezagent.Invocation
  alias Ezagent.World.AdminActions
  alias Ezagent.World.CommandPaletteActions
  alias Ezagent.World.CommandPaletteData
  alias Ezagent.World.ConversationActions
  alias Ezagent.World.WorkspacePluginActions
  alias EzagentPluginWorld.Layouts

  @refresh_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    caller = Map.get(socket.assigns, :current_entity_uri)
    workspace = Map.get(socket.assigns, :current_workspace_uri)
    sessions = list_sessions(workspace)
    current_session_uri = List.first(sessions)

    socket = assign(socket, :subscribed_topics, MapSet.new())

    caller_payload = %{
      "entity_uri" => encode_uri(caller),
      "workspace_uri" => encode_uri(workspace),
      "display_name" => caller_display_name(caller)
    }

    layout = layout_for(workspace)
    if connected?(socket), do: subscribe_global_inbound(caller)

    state =
      sessions_state(
        sessions,
        current_session_uri,
        workspace,
        layout,
        Map.get(socket.assigns, :current_caps, MapSet.new())
      )
      |> put_command_palette(socket)

    if connected?(socket), do: send(self(), :push_world_state)

    {:ok,
     socket
     |> assign(:layout_json, Jason.encode!(layout))
     |> assign(:caller_json, Jason.encode!(caller_payload))
     |> assign(:world_state, state)
     |> assign(:world_state_json, Jason.encode!(state))
     |> assign(:world_component, "sessions_table")
     |> assign(:current_session_uri, current_session_uri)
     |> assign(:current_session_uri_str, encode_uri(current_session_uri))
     |> assign(:last_dispatch_status, "idle")
     |> assign(:world_module_url, world_module_url())
     |> assign(:world_css_url, world_css_url())}
  end

  @impl true
  def handle_params(params, uri, socket) do
    route = Ezagent.World.Routes.route_for(params, uri)
    workspace = socket.assigns.current_workspace_uri
    layout = layout_for_route(route, workspace)
    socket = maybe_set_current_session(socket, route)
    state = state_for_route(route, socket, layout)
    socket = maybe_subscribe_pty(socket, route)

    socket =
      socket
      |> assign(:layout_json, Jason.encode!(layout))
      |> assign(:world_state, state)
      |> assign(:world_state_json, Jason.encode!(state))
      |> assign(:world_component, route.component)

    socket =
      if connected?(socket) do
        push_event(socket, "world:state", state)
      else
        socket
      end

    {:noreply, socket}
  end

  defp maybe_set_current_session(socket, %{component: "conversation", session_uri: %URI{} = uri}) do
    socket
    |> ensure_session_subscribed(uri)
    |> assign(:current_session_uri, uri)
    |> assign(:current_session_uri_str, encode_uri(uri))
    |> ConversationActions.self_join(uri)
    |> ConversationActions.push_members()
  end

  defp maybe_set_current_session(socket, _route), do: socket

  @impl true
  def handle_info(:push_world_state, socket) do
    {:noreply, push_event(socket, "world:state", socket.assigns.world_state)}
  end

  def handle_info({:audit_event, event}, socket),
    do: {:noreply, push_inbound_event(socket, "audit_event", event)}

  def handle_info({:authz_event, result, meta, ts}, socket) do
    {:noreply, push_inbound_event(socket, "authz_event", %{result: result, meta: meta, at: ts})}
  end

  def handle_info({:cc_event, event}, socket),
    do: {:noreply, push_inbound_event(socket, "cc_event", event)}

  def handle_info({:cc_connected, bridge_id, entry}, socket) do
    socket = ConversationActions.push_members(socket)
    {:noreply, push_inbound_event(socket, "cc_connected", %{bridge_id: bridge_id, entry: entry})}
  end

  def handle_info({:cc_disconnected, bridge_id}, socket) do
    socket = ConversationActions.push_members(socket)
    {:noreply, push_inbound_event(socket, "cc_disconnected", %{bridge_id: bridge_id})}
  end

  def handle_info(:refresh, %{assigns: %{world_state: %{"component" => "pty_terminal"}}} = socket) do
    {:noreply, refresh_pty_state(socket)}
  end

  def handle_info(:refresh, socket), do: {:noreply, socket}

  def handle_info({:pty_output, _agent_uri, chunk}, socket) when is_binary(chunk) do
    {:noreply, push_event(socket, "pty_chunk", %{bytes: chunk})}
  end

  def handle_info({:pty_phase, _agent_uri, phase, _meta}, socket)
      when phase in [:starting, :running, :dead] do
    {:noreply, update_pty_state(socket, %{"pty_phase" => Atom.to_string(phase)})}
  end

  def handle_info({:chat_message, %URI{} = source_uri, %Ezagent.Message{} = msg}, socket) do
    if same_uri?(source_uri, socket.assigns[:current_session_uri]) do
      row = Ezagent.World.ConversationData.message_row(msg)
      {:noreply, push_event(socket, "chat:message", %{"message" => row})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:chat_message, %Ezagent.Message{}}, socket), do: {:noreply, socket}

  def handle_info({tag, %URI{}}, socket) when tag in [:member_joined, :member_left] do
    {:noreply, ConversationActions.push_members(socket)}
  end

  def handle_info({:member_offline, %URI{}, _at}, socket),
    do: {:noreply, ConversationActions.push_members(socket)}

  def handle_info({:member_presence, _session_uri, _member_uri, _meta}, socket),
    do: {:noreply, ConversationActions.push_members(socket)}

  def handle_info({:read_marker_updated, session_uri, user_uri, meta}, socket) do
    {:noreply,
     push_inbound_event(socket, "read_marker_updated", %{
       session_uri: session_uri,
       user_uri: user_uri,
       meta: meta
     })}
  end

  def handle_info({:notification, user_uri, payload}, socket) do
    {:noreply,
     push_inbound_event(socket, "notification", %{user_uri: user_uri, payload: payload})}
  end

  def handle_info({:slice_changed, %{} = event}, socket),
    do: {:noreply, push_inbound_event(socket, "slice_changed", event)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "world:dispatch",
        %{"action" => "sessions.join", "args" => %{"session_uri" => session_uri_str}},
        socket
      ) do
    case parse_session_uri(session_uri_str) do
      {:ok, session_uri} ->
        dispatch_session_join(socket, session_uri)

      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_session_uri")}
    end
  end

  def handle_event(
        "world:dispatch",
        %{"action" => "layout.manage", "args" => %{"layout" => layout}},
        socket
      ) do
    dispatch_layout_manage(socket, layout)
  end

  def handle_event(
        "world:dispatch",
        %{"action" => "agents.create", "args" => %{"agent" => agent_params}},
        socket
      ) do
    dispatch_agent_create(socket, agent_params)
  end

  @cmdk_actions ~w(cmdk.open cmdk.close cmdk.query cmdk.select)
  def handle_event("world:dispatch", %{"action" => action, "args" => args}, socket)
      when action in @cmdk_actions and is_map(args) do
    CommandPaletteActions.handle_dispatch(socket, action, args)
  end

  @admin_actions ~w(admin.smtp.save admin.smtp.test admin.smtp.update_recipient)
  def handle_event("world:dispatch", %{"action" => action, "args" => args}, socket)
      when action in @admin_actions and is_map(args) do
    AdminActions.handle_dispatch(socket, action, args)
  end

  @workspace_plugin_actions ~w(profile.display_name.edit profile.display_name.save profile.display_name.cancel feishu.bind feishu.unbind workspace.member.remove workspace.template.save auto_derive.default_source.set auto_derive.credential_grant.revoke)
  def handle_event("world:dispatch", %{"action" => action, "args" => args}, socket)
      when action in @workspace_plugin_actions and is_map(args) do
    WorkspacePluginActions.handle_dispatch(socket, action, args)
  end

  @conversation_actions ~w(chat.send chat.load_older chat.mark_displayed session.switch session.invite session.create session.view.switch session.pty.open session.orchestrator.restart session.routing.add session.routing.toggle)
  def handle_event("world:dispatch", %{"action" => action, "args" => args}, socket)
      when action in @conversation_actions and is_map(args) do
    ConversationActions.handle_dispatch(socket, action, args)
  end

  def handle_event("pty_input", %{"bytes" => bytes}, socket) when is_binary(bytes) do
    case socket.assigns.world_state do
      %{"component" => "pty_terminal", "agent_uri" => agent_uri_str} ->
        with {:ok, agent_uri} <- parse_agent_uri(agent_uri_str),
             :ok <- dispatch_pty_input(socket, agent_uri, bytes) do
          {:noreply, socket}
        else
          {:error, reason} ->
            {:noreply, assign(socket, :last_dispatch_status, "error:#{reason_to_string(reason)}")}

          :error ->
            {:noreply, assign(socket, :last_dispatch_status, "error:invalid_agent_uri")}
        end

      _ ->
        {:noreply, assign(socket, :last_dispatch_status, "error:not_pty_route")}
    end
  end

  def handle_event("pty_resize", _params, socket), do: {:noreply, socket}

  def handle_event("world:dispatch", _params, socket) do
    {:noreply, assign(socket, :last_dispatch_status, "error:unsupported_action")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main id="world-shell" class="min-h-screen">
        <div
          id="world-root"
          phx-hook="WorldRenderer"
          phx-update="ignore"
          data-layout={@layout_json}
          data-caller={@caller_json}
          data-world-state={@world_state_json}
          data-world-component={@world_component}
          data-current-session-uri={@current_session_uri_str}
          data-last-dispatch={@last_dispatch_status}
          data-world-module-url={@world_module_url}
          data-world-css-url={@world_css_url}
          class="min-h-screen"
        >
          <div class="flex min-h-screen items-center justify-center bg-[#f8fafc] px-6">
            <div class="h-10 w-10 rounded-full border border-[#d1d5db] border-t-[#111827] motion-safe:animate-spin">
            </div>
          </div>
        </div>
      </main>
    </Layouts.app>
    """
  end

  defp dispatch_session_join(socket, %URI{} = session_uri) do
    caller = socket.assigns.current_entity_uri
    caps = Map.get(socket.assigns, :current_caps, MapSet.new())

    target = Ezagent.URI.with_action(session_uri, :session, :join)

    result =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: %{member: caller},
        ctx: %{caller: caller, caps: caps, reply: :ignore}
      })

    case result do
      :ok ->
        dispatch_session_join_ok(socket, session_uri)

      {:ok, _payload} ->
        dispatch_session_join_ok(socket, session_uri)

      {:error, reason} ->
        {:noreply, assign(socket, :last_dispatch_status, "error:#{reason_to_string(reason)}")}
    end
  end

  defp dispatch_session_join_ok(socket, %URI{} = session_uri) do
    {:noreply,
     socket
     |> assign(:current_session_uri, session_uri)
     |> assign(:current_session_uri_str, URI.to_string(session_uri))
     |> assign(:last_dispatch_status, "ok")
     |> push_patch(to: "/sessions?session=#{encode_param(session_uri)}")}
  end

  defp dispatch_layout_manage(socket, layout) when is_map(layout) do
    workspace_uri = socket.assigns.current_workspace_uri
    caller = socket.assigns.current_entity_uri
    caps = Map.get(socket.assigns, :current_caps, MapSet.new())

    target = Ezagent.URI.with_action(workspace_uri, :layout, :manage)

    result =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: %{layout: layout},
        ctx: %{caller: caller, caps: caps, reply: {:caller_inbox, self()}}
      })

    case result do
      {:ok, %{layout: saved_layout}} ->
        dispatch_layout_manage_ok(socket, saved_layout)

      {:ok, %{"layout" => saved_layout}} ->
        dispatch_layout_manage_ok(socket, saved_layout)

      {:error, reason} ->
        {:noreply, assign(socket, :last_dispatch_status, "error:#{reason_to_string(reason)}")}
    end
  end

  defp dispatch_layout_manage(socket, _layout) do
    {:noreply, assign(socket, :last_dispatch_status, "error:invalid_layout")}
  end

  defp dispatch_layout_manage_ok(socket, saved_layout) do
    state = Map.put(socket.assigns.world_state, "layout", saved_layout)

    {:noreply,
     socket
     |> assign(:layout_json, Jason.encode!(saved_layout))
     |> assign(:world_state, state)
     |> assign(:world_state_json, Jason.encode!(state))
     |> assign(:last_dispatch_status, "ok")
     |> push_event("world:state", %{"layout" => saved_layout})}
  end

  defp dispatch_agent_create(socket, params) when is_map(params) do
    workspace_uri = socket.assigns.current_workspace_uri
    caller = socket.assigns.current_entity_uri
    caller_ctx = %{caller: caller, caps: Map.get(socket.assigns, :current_caps, MapSet.new())}

    flavor = params |> Map.get("flavor", "") |> to_string() |> String.trim()
    name = params |> Map.get("name", "") |> to_string() |> String.trim()
    cwd = params |> Map.get("cwd", "") |> to_string() |> String.trim()
    caps_str = params |> Map.get("caps", "") |> to_string() |> String.trim()
    with_pty? = Map.get(params, "with_pty") in [true, "true", "on"]

    with %URI{scheme: "workspace"} <- workspace_uri,
         {:ok, caps} <- Ezagent.Capability.Parser.parse(caps_str, caller),
         {:ok, %{agent_uri: agent_uri}} <-
           Ezagent.Workspace.create_agent(
             workspace_uri,
             %{flavor: flavor, name: name, cwd: cwd, with_pty: with_pty?},
             caller_ctx
           ),
         :ok <- Ezagent.Workspace.grant_initial_caps(agent_uri, caps, caller_ctx) do
      encoded = agent_uri |> URI.to_string() |> URI.encode_www_form()

      {:noreply,
       socket
       |> assign(:agent_create_error, nil)
       |> assign(:last_dispatch_status, "ok")
       |> push_navigate(to: "/identities/agents/#{encoded}")}
    else
      {:error, reason} ->
        {:noreply, push_agent_create_error(socket, reason)}

      _ ->
        {:noreply, push_agent_create_error(socket, :invalid_workspace_scope)}
    end
  end

  defp dispatch_agent_create(socket, _params) do
    {:noreply, assign(socket, :last_dispatch_status, "error:invalid_agent")}
  end

  # No silent drop: rebuild the agent_new_form state with the operator-facing
  # message and re-push it through the SAME `world:state` channel the route uses
  # so the React island re-renders the error. The reason is also stashed on the
  # socket so a subsequent `handle_params` re-render (e.g. PTY refresh) keeps the
  # message until the operator navigates away (push_navigate on success clears it).
  defp push_agent_create_error(socket, reason) do
    route = %{component: "agent_new_form", title: "New Agent", path: "/identities/agents/new"}
    layout = socket.assigns.world_state["layout"]
    socket = assign(socket, :agent_create_error, reason)
    state = state_for_route(route, socket, layout)

    socket
    |> assign(:world_state, state)
    |> assign(:world_state_json, Jason.encode!(state))
    |> assign(:last_dispatch_status, "error:#{reason_to_string(reason)}")
    |> push_event("world:state", state)
  end

  defp dispatch_pty_input(socket, %URI{} = agent_uri, bytes) do
    target = Ezagent.URI.with_action(agent_uri, :pty, :write)

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :cast,
           args: %{bytes: bytes},
           ctx: %{
             caller: socket.assigns.current_entity_uri,
             caps: Map.get(socket.assigns, :current_caps, MapSet.new()),
             reply: :ignore
           }
         }) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp world_module_url do
    Application.get_env(:ezagent_plugin_world, :world_module_url, "/assets/world/main.js")
  end

  defp world_css_url do
    Application.get_env(:ezagent_plugin_world, :world_css_url, "/assets/world/world.css")
  end

  defp layout_for(%URI{} = workspace_uri),
    do: Ezagent.World.LayoutManager.read_layout(workspace_uri)

  defp layout_for(_),
    do: Ezagent.World.LayoutManager.default_layout(Ezagent.URI.workspace(:system))

  # The /sessions landing reads its (multi-slot, user-arrangeable) persisted
  # layout; every other route derives a synthetic single-slot layout. BOTH go
  # through `LayoutManager.validate_layout/2` so EVERY route's layout is a
  # registry-validated layout — a route that produces an unregistered slot
  # fails loudly here (and is caught pre-merge by the layout gate) instead of
  # silently falling through to a renderer default.
  defp layout_for_route(%{component: "sessions_table"}, workspace_uri),
    do: layout_for(workspace_uri)

  defp layout_for_route(%{component: component, title: title}, workspace_uri) do
    scope_uri =
      if match?(%URI{}, workspace_uri), do: workspace_uri, else: Ezagent.URI.workspace(:system)

    # Display-only scope label for the synthetic layout (persistence keys off
    # LayoutManager.scope_key/1's stable_key, not this string). Bound to a var so
    # the uri_query scan doesn't read it as an unaudited URI.to_string map key.
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

    case Ezagent.World.LayoutManager.validate_layout(scope_uri, synthetic) do
      {:ok, validated} ->
        validated

      {:error, reason} ->
        raise ArgumentError,
              "world route produced an invalid layout for slot #{inspect(component)}: " <>
                "#{inspect(reason)} — register the slot in Ezagent.World.SlotRegistry"
    end
  end

  defp state_for_route(
         %{component: "conversation", session_uri: %URI{} = session_uri},
         socket,
         layout
       ) do
    session_uri
    |> conversation_state(socket, layout)
    |> put_command_palette(socket)
  end

  defp state_for_route(%{component: "sessions_table"}, socket, layout) do
    sessions =
      socket.assigns.current_workspace_uri
      |> list_sessions()

    current_session_uri = socket.assigns.current_session_uri || List.first(sessions)

    sessions_state(
      sessions,
      current_session_uri,
      socket.assigns.current_workspace_uri,
      layout,
      Map.get(socket.assigns, :current_caps, MapSet.new())
    )
    |> put_command_palette(socket)
  end

  defp state_for_route(%{group: :admin} = route, socket, layout) do
    route
    |> Ezagent.World.AdminData.state_for(%{
      workspace_uri: socket.assigns.current_workspace_uri,
      caller_uri: socket.assigns.current_entity_uri,
      caller_caps: Map.get(socket.assigns, :current_caps, MapSet.new())
    })
    |> Map.put("layout", layout)
    |> put_can_manage_layout(route.component, socket)
    |> put_command_palette(socket)
  end

  defp state_for_route(%{group: :workspace_plugins} = route, socket, layout) do
    route
    |> Ezagent.World.WorkspacePluginData.state_for(%{
      workspace_uri: socket.assigns.current_workspace_uri,
      caller_uri: socket.assigns.current_entity_uri,
      caller_caps: Map.get(socket.assigns, :current_caps, MapSet.new())
    })
    |> Map.put("layout", layout)
    |> put_can_manage_layout(route.component, socket)
    |> put_command_palette(socket)
  end

  defp state_for_route(route, socket, layout) do
    route
    |> Ezagent.World.IdentityData.state_for(%{
      workspace_uri: socket.assigns.current_workspace_uri,
      caller_uri: socket.assigns.current_entity_uri,
      caller_caps: Map.get(socket.assigns, :current_caps, MapSet.new()),
      create_error: Map.get(socket.assigns, :agent_create_error)
    })
    |> Map.put("layout", layout)
    |> put_can_manage_layout(route.component, socket)
    |> put_command_palette(socket)
  end

  defp sessions_state(sessions, current_session_uri, workspace_uri, layout, caps) do
    workspace = encode_uri(workspace_uri)
    current_session = encode_uri(current_session_uri)

    %{
      "component" => "sessions_table",
      "current_session_uri" => current_session,
      "workspace_uri" => workspace,
      "layout" => layout,
      "can_manage_layout" => can_manage_layout?("sessions_table", workspace_uri, caps),
      "sessions" => Enum.map(sessions, &session_row/1)
    }
  end

  defp put_command_palette(state, socket) do
    Map.put(state, "cmdk", CommandPaletteData.state(socket.assigns, "", false))
  end

  defp session_row(%URI{} = session_uri) do
    uri = URI.to_string(session_uri)
    workspace = session_uri |> Ezagent.Capability.workspace_of() |> encode_uri()

    %{
      "uri" => uri,
      "name" => session_uri.path || session_uri.host || uri,
      "workspace_uri" => workspace
    }
  end

  defp list_sessions(%URI{scheme: "workspace"} = workspace_uri) do
    EzagentDomainInstanceMessage.list_sessions(workspace_uri)
  rescue
    _ -> []
  end

  defp list_sessions(_), do: []

  defp subscribe_global_inbound(caller_uri) do
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.Audit.stream_topic())
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.AgentBridge.Registry.legacy_topic())
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.CCEvents.topic())

    if caller_uri do
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.Notifications.topic(caller_uri))
      :ok = Ezagent.Notifications.subscribe_slice_change(caller_uri)
    end
  end

  defp ensure_session_subscribed(socket, %URI{} = session_uri) do
    topic = Ezagent.Behavior.Session.session_events_topic(session_uri)
    subscribed = Map.get(socket.assigns, :subscribed_topics, MapSet.new())

    if connected?(socket) and not MapSet.member?(subscribed, topic) do
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)
      assign(socket, :subscribed_topics, MapSet.put(subscribed, topic))
    else
      socket
    end
  end

  defp conversation_state(%URI{} = session_uri, socket, layout) do
    sessions =
      socket.assigns.current_workspace_uri
      |> list_sessions()
      |> Enum.map(&session_row/1)

    session_uri
    |> Ezagent.World.ConversationData.state_for(%{
      caller_uri: socket.assigns.current_entity_uri,
      workspace_uri: socket.assigns.current_workspace_uri,
      sessions: sessions
    })
    |> Map.put("layout", layout)
    |> put_can_manage_layout("conversation", socket)
  end

  defp encode_param(%URI{} = uri), do: uri |> URI.to_string() |> URI.encode_www_form()

  defp parse_session_uri(value) when is_binary(value) do
    case Ezagent.URI.new!(value) do
      %URI{scheme: "session"} = uri -> {:ok, uri}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp parse_session_uri(_), do: :error

  defp parse_agent_uri(value) when is_binary(value) do
    case Ezagent.URI.new!(value) do
      %URI{scheme: "entity"} = uri ->
        if Ezagent.URI.type?(uri, :agent), do: {:ok, uri}, else: :error

      _ ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  defp parse_agent_uri(_), do: :error

  # Single per-route layout-management policy (the one place that decides).
  # Today only the /sessions landing carries a multi-slot, user-arrangeable
  # layout, so it is the only route where managing the layout is meaningful —
  # and only for a caller holding the workspace-scoped layout `:manage` cap.
  # Every other route is a single synthetic slot; rearranging it is a no-op.
  defp can_manage_layout?("sessions_table", workspace_uri, caps),
    do: layout_manage_affordance?(workspace_uri, caps)

  defp can_manage_layout?(_component, _workspace_uri, _caps), do: false

  defp put_can_manage_layout(state, component, socket) do
    caps = Map.get(socket.assigns, :current_caps, MapSet.new())

    Map.put(
      state,
      "can_manage_layout",
      can_manage_layout?(component, socket.assigns.current_workspace_uri, caps)
    )
  end

  defp layout_manage_affordance?(%URI{} = workspace_uri, caps) do
    Enum.any?(caps, &layout_manage_cap?(&1, workspace_uri))
  end

  defp layout_manage_affordance?(_, _), do: false

  defp layout_manage_cap?(%Ezagent.Capability{} = cap, %URI{} = workspace_uri) do
    cap.kind == :workspace and
      cap.behavior == Ezagent.World.Behavior.Layout and
      Ezagent.Capability.action_of(cap) in [:manage, :any] and
      cap_scope_matches?(cap.instance, Ezagent.URI.instance(workspace_uri)) and
      cap_scope_matches?(cap.workspace_uri, Ezagent.Capability.workspace_of(workspace_uri))
  end

  defp layout_manage_cap?(_, _), do: false

  defp cap_scope_matches?(:any, _needed), do: true
  defp cap_scope_matches?(%URI{} = actual, %URI{} = needed), do: same_uri?(actual, needed)
  defp cap_scope_matches?(actual, needed), do: actual == needed

  defp same_uri?(%URI{} = left, %URI{} = right), do: URI.to_string(left) == URI.to_string(right)
  defp same_uri?(_, _), do: false

  defp maybe_subscribe_pty(socket, %{component: "pty_terminal", entity_uri: %URI{} = agent_uri}) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(
        EzagentCore.PubSub,
        Ezagent.Domain.Pty.Server.output_topic(agent_uri)
      )

      Phoenix.PubSub.subscribe(EzagentCore.PubSub, "pty:phase:" <> URI.to_string(agent_uri))
      :timer.send_interval(@refresh_ms, :refresh)
    end

    socket
  end

  defp maybe_subscribe_pty(socket, _route), do: socket

  defp refresh_pty_state(socket) do
    case socket.assigns.world_state do
      %{"agent_uri" => agent_uri_str} ->
        with {:ok, agent_uri} <- parse_agent_uri(agent_uri_str) do
          update_pty_state(socket, %{
            "agent_status" => jsonable(Ezagent.Domain.Agent.lifecycle_status(agent_uri)),
            "pty_alive" => Ezagent.Domain.Pty.alive?(agent_uri),
            "pty_phase" => pty_phase(agent_uri)
          })
        else
          _ -> socket
        end

      _ ->
        socket
    end
  end

  defp update_pty_state(socket, updates) when is_map(updates) do
    state = Map.merge(socket.assigns.world_state, updates)

    socket
    |> assign(:world_state, state)
    |> assign(:world_state_json, Jason.encode!(state))
    |> push_event("world:state", updates)
  end

  defp push_inbound_event(socket, type, payload) do
    event = %{
      "type" => type,
      "payload" => jsonable(payload),
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    inbound_events =
      [event | Map.get(socket.assigns.world_state, "inbound_events", [])]
      |> Enum.take(20)

    state = Map.put(socket.assigns.world_state, "inbound_events", inbound_events)

    socket
    |> assign(:world_state, state)
    |> assign(:world_state_json, Jason.encode!(state))
    |> push_event("world:inbound", event)
    |> push_event("world:state", %{"inbound_events" => inbound_events})
  end

  defp pty_phase(%URI{} = agent_uri) do
    case Ezagent.Domain.Pty.status(agent_uri) do
      %{phase: phase} when is_atom(phase) -> Atom.to_string(phase)
      %{phase: phase} when is_binary(phase) -> phase
      %{running: true} -> "running"
      _ -> "dead"
    end
  end

  defp jsonable(%URI{} = uri), do: URI.to_string(uri)
  defp jsonable(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp jsonable(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp jsonable(%_struct{} = struct), do: struct |> Map.from_struct() |> jsonable()

  defp jsonable(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), jsonable(value)} end)

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()
  defp jsonable(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp jsonable(pid) when is_pid(pid), do: inspect(pid)
  defp jsonable(port) when is_port(port), do: inspect(port)
  defp jsonable(ref) when is_reference(ref), do: inspect(ref)
  defp jsonable(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp jsonable(nil), do: nil
  defp jsonable(other), do: inspect(other)

  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason), do: inspect(reason)

  defp encode_uri(%URI{} = uri), do: URI.to_string(uri)
  defp encode_uri(_), do: nil

  defp caller_display_name(uri), do: Ezagent.World.CallerDisplay.name(uri)
end
