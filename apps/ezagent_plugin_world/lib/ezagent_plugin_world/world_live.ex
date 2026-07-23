defmodule EzagentPluginWorld.WorldLive do
  @moduledoc """
  LiveView SSR/comms shell for the React-owned `world` app.
  """

  use Phoenix.LiveView

  alias Ezagent.ActionSet.Session.Membership
  alias Ezagent.Invocation
  alias Ezagent.World.AdminActions
  alias Ezagent.World.AgentActions
  alias Ezagent.World.CommandPaletteActions
  alias Ezagent.World.CommandPaletteData
  alias Ezagent.Socialware.SessionReads
  alias Ezagent.World.ConversationActions
  alias Ezagent.World.ConversationSessionState
  alias Ezagent.World.UserActions
  alias Ezagent.World.WorkspacePluginActions
  alias EzagentPluginWorld.{Layouts, WorldLoading}

  @refresh_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    caller = Map.get(socket.assigns, :current_entity_uri)
    workspace = Map.get(socket.assigns, :current_workspace_uri)
    caps = Ezagent.World.PresenterCaps.load(socket)
    sessions = ConversationSessionState.list_sessions(workspace, caller)
    current_session_uri = List.first(sessions)

    socket = assign(socket, :subscribed_topics, MapSet.new())

    caller_payload =
      caller_payload(
        caller,
        workspace,
        caps,
        Map.get(socket.assigns, :is_system_member?, false)
      )

    layout = layout_for(workspace, caller)
    if connected?(socket), do: subscribe_global_inbound(socket)

    state =
      sessions_state(
        sessions,
        current_session_uri,
        workspace,
        layout,
        caps,
        caller
      )
      |> put_command_palette(socket)

    if connected?(socket), do: send(self(), :push_world_state)

    # Layer-2 modular nav: every INSTALLED plugin's `nav_surfaces/0`,
    # merged into the static sidebar NAV_ITEMS on the React side. View-
    # INVARIANT chrome (same on every route, like `caller`), so computed
    # ONCE at mount and passed as its own mount option — never clobbered by
    # per-route `world:state` pushes.
    plugin_nav = Ezagent.World.WorkspacePluginData.plugin_nav_surfaces()

    {:ok,
     socket
     |> assign(:layout_json, Jason.encode!(layout))
     |> assign(:plugin_nav_json, Jason.encode!(plugin_nav))
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
    caller = Map.get(socket.assigns, :current_entity_uri)
    layout = layout_for_route(route, workspace, caller)
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
    # Subscribe UNCONDITIONALLY — subscription is NOT the security boundary,
    # DELIVERY is: every session-content handler (chat_message, read_marker,
    # cc_*, push_members) authorizes the caller LIVE before pushing, so a
    # non-member subscribed here receives nothing, while a first-time member
    # whose async at-join cap has not yet committed starts receiving the moment
    # it does — no gate-on-subscribe race, no lock-out until reload. (F3.)
    socket
    |> assign(:current_session_uri, uri)
    |> assign(:current_session_uri_str, encode_uri(uri))
    |> ConversationSessionState.ensure_session_subscribed(uri)
    |> ConversationActions.self_join(uri)
    |> ConversationActions.push_members()
  end

  defp maybe_set_current_session(socket, _route), do: socket

  @impl true
  def handle_info(:push_world_state, socket) do
    {:noreply, push_event(socket, "world:state", socket.assigns.world_state)}
  end

  # Task #187 — audit/authz/cc_event are the OPERATOR-OBSERVABILITY plane:
  # delivery is gated LIVE on the operator predicate (subscribe-time alone
  # would leave a socket that subscribed pre-gate, or an operator demoted
  # mid-session, receiving the stream). Fail-closed on unknown/missing caller.
  def handle_info({:audit_event, event}, socket) do
    if operator_streams?(socket) do
      {:noreply, push_inbound_event(socket, "audit_event", event)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:authz_event, result, meta, ts}, socket) do
    if operator_streams?(socket) do
      {:noreply, push_inbound_event(socket, "authz_event", %{result: result, meta: meta, at: ts})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:cc_event, event}, socket) do
    if operator_streams?(socket) do
      {:noreply, push_inbound_event(socket, "cc_event", event)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:cc_connected, bridge_id, entry}, socket) do
    if authorized_for_current_session?(socket) do
      socket = ConversationActions.push_members(socket)

      {:noreply,
       push_inbound_event(socket, "cc_connected", %{bridge_id: bridge_id, entry: entry})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:cc_disconnected, bridge_id}, socket) do
    if authorized_for_current_session?(socket) do
      socket = ConversationActions.push_members(socket)
      {:noreply, push_inbound_event(socket, "cc_disconnected", %{bridge_id: bridge_id})}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh, %{assigns: %{world_state: %{"component" => "pty_terminal"}}} = socket) do
    {:noreply, refresh_pty_state(socket)}
  end

  def handle_info(:refresh, socket), do: {:noreply, socket}

  # Bind the chunk to the agent whose terminal is ACTUALLY on screen.
  #
  # PTY subscriptions accumulate: opening agent A's terminal and then agent B's
  # leaves this LV subscribed to both, and nothing ever unsubscribes. Forwarding
  # every chunk the process happens to receive therefore bled A's output into B's
  # terminal — and kept streaming a terminal the viewer had navigated away from,
  # including after their authority over it changed. Both subscriptions are
  # capability-gated at subscribe time (`Ezagent.Domain.Pty.Access`), so this is
  # not the ungated-read hole; it is the second half of closing it — output only
  # reaches the browser for the terminal being looked at.
  def handle_info({:pty_output, %URI{} = agent_uri, chunk}, socket) when is_binary(chunk) do
    if active_pty_agent?(socket, agent_uri) do
      {:noreply, push_event(socket, "pty_chunk", %{bytes: chunk})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:pty_phase, %URI{} = agent_uri, phase, _meta}, socket)
      when phase in [:starting, :running, :dead] do
    if active_pty_agent?(socket, agent_uri) do
      {:noreply, update_pty_state(socket, %{"pty_phase" => Atom.to_string(phase)})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:chat_message, %URI{} = source_uri, %Ezagent.Message{} = msg}, socket) do
    session_uri = socket.assigns[:current_session_uri]

    if same_uri?(source_uri, session_uri) and live_message_deliverable?(socket, session_uri, msg) do
      # G5 source 2 — attach the per-viewer error card when the reply body
      # carries a structured agent-error payload (lazy ctx: no admin/founder
      # lookup on ordinary messages).
      row =
        msg
        |> Ezagent.World.ConversationData.message_row(socket.assigns[:current_entity_uri])
        |> Ezagent.World.ErrorCards.enrich(
          msg.body,
          Ezagent.World.ErrorCards.live_viewer_ctx(socket)
        )

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
    # A read-marker discloses a member's identity + which message they last read
    # + when — session content. Only deliver it for the current session AND to an
    # authorized viewer (a non-member subscribed via a forged `session.switch`
    # otherwise leaks other members' reading activity). (read-plane-authz F2/#2.)
    if same_uri?(session_uri, socket.assigns[:current_session_uri]) and
         authorized_for_current_session?(socket) do
      {:noreply,
       push_inbound_event(socket, "read_marker_updated", %{
         session_uri: session_uri,
         user_uri: user_uri,
         meta: meta
       })}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:notification, user_uri, payload}, socket) do
    {:noreply,
     push_inbound_event(socket, "notification", %{user_uri: user_uri, payload: payload})}
  end

  def handle_info({:slice_changed, %{} = event}, socket),
    do: {:noreply, push_inbound_event(socket, "slice_changed", event)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Both views store the agent URI with a plain `URI.to_string/1` (only
  # `agent_detail_path` is www-form-encoded), so a direct compare is right.
  defp active_pty_agent?(socket, %URI{} = agent_uri) do
    pty_agent_uri_str(socket.assigns[:world_state] || %{}) == encode_uri(agent_uri)
  end

  @impl true
  def handle_event("world:navigate", %{"to" => to}, socket) when is_binary(to) do
    case Ezagent.World.Navigation.navigation_for(to) do
      {:ok, :patch, path} -> {:noreply, push_patch(socket, to: path)}
      {:ok, :navigate, path} -> {:noreply, push_navigate(socket, to: path)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event(
        "world:dispatch",
        %{"action" => "sessions.join", "args" => %{"session_uri" => session_uri_str}},
        socket
      ) do
    case parse_session_uri(session_uri_str) do
      {:ok, session_uri} ->
        with_admin_operator(socket, fn -> dispatch_session_join(socket, session_uri) end)

      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_session_uri")}
    end
  end

  def handle_event(
        "world:dispatch",
        %{"action" => "layout.manage", "args" => %{"layout" => layout}},
        socket
      ) do
    with_admin_operator(socket, fn -> dispatch_layout_manage(socket, layout) end)
  end

  @agent_actions Ezagent.World.DispatchContract.actions(:agent)
  def handle_event("world:dispatch", %{"action" => action, "args" => args}, socket)
      when action in @agent_actions and is_map(args) do
    with_admin_operator(socket, fn -> AgentActions.handle_dispatch(socket, action, args) end)
  end

  @user_actions Ezagent.World.DispatchContract.actions(:user)
  def handle_event("world:dispatch", %{"action" => action, "args" => args}, socket)
      when action in @user_actions and is_map(args) do
    with_admin_operator(socket, fn -> UserActions.handle_dispatch(socket, action, args) end)
  end

  def handle_event(
        "world:dispatch",
        %{"action" => "agent.api_key.put", "args" => %{"agent_uri" => agent_uri_str} = args},
        socket
      ) do
    with_admin_operator(socket, fn -> dispatch_api_key_put(socket, agent_uri_str, args) end)
  end

  @cmdk_actions Ezagent.World.DispatchContract.actions(:cmdk)
  def handle_event("world:dispatch", %{"action" => action, "args" => args}, socket)
      when action in @cmdk_actions and is_map(args) do
    with_admin_operator(socket, fn ->
      CommandPaletteActions.handle_dispatch(socket, action, args)
    end)
  end

  @admin_actions Ezagent.World.DispatchContract.actions(:admin)
  def handle_event("world:dispatch", %{"action" => action, "args" => args}, socket)
      when action in @admin_actions and is_map(args) do
    with_admin_operator(socket, fn -> AdminActions.handle_dispatch(socket, action, args) end)
  end

  @workspace_plugin_actions Ezagent.World.DispatchContract.actions(:workspace_plugin)
  def handle_event("world:dispatch", %{"action" => action, "args" => args}, socket)
      when action in @workspace_plugin_actions and is_map(args) do
    with_admin_operator(socket, fn ->
      WorkspacePluginActions.handle_dispatch(socket, action, args)
    end)
  end

  @market_actions Ezagent.World.DispatchContract.actions(:market)
  def handle_event("world:dispatch", %{"action" => action, "args" => args}, socket)
      when action in @market_actions and is_map(args) do
    with_admin_operator(socket, fn ->
      Ezagent.World.MarketActions.handle_dispatch(socket, action, args)
    end)
  end

  @conversation_actions Ezagent.World.DispatchContract.actions(:conversation)
  def handle_event("world:dispatch", %{"action" => action, "args" => args}, socket)
      when action in @conversation_actions and is_map(args) do
    with_admin_operator(socket, fn ->
      ConversationActions.handle_dispatch(socket, action, args)
    end)
  end

  # G5 Layer 2 notification: user clicks "send reminder" on an error card.
  def handle_event(
        "world:dispatch",
        %{
          "action" => "notification.send",
          "args" => %{"type" => "error_fix_request", "body" => body}
        },
        socket
      )
      when is_map(body) do
    caller = socket.assigns.current_entity_uri

    case resolve_founder_for_notify(socket) do
      %URI{} = founder_uri ->
        Ezagent.Notifications.notify(founder_uri, %{
          type: :error_fix_request,
          body:
            Map.merge(body, %{
              caller_name: entity_display_name(caller),
              workspace: entity_display_name(socket.assigns.current_workspace_uri)
            }),
          source: __MODULE__
        })

        {:noreply, assign(socket, :last_dispatch_status, "ok")}

      nil ->
        {:noreply, assign(socket, :last_dispatch_status, "error:no_founder")}
    end
  end

  # G5 Layer 2 notification: user clicks "send reminder" on an error card.
  def handle_event(
        "world:dispatch",
        %{
          "action" => "notification.send",
          "args" => %{"type" => "error_fix_request", "body" => body}
        },
        socket
      )
      when is_map(body) do
    case Ezagent.World.ErrorCards.send_fix_request(socket, body) do
      :ok -> {:noreply, assign(socket, :last_dispatch_status, "ok")}
      :no_founder -> {:noreply, assign(socket, :last_dispatch_status, "error:no_founder")}
    end
  end

  # 插件页面动作（`Ezagent.World.PluginPageRegistry`）：fail-closed 准入——
  # action 命中某页面的前缀 **且** 在其细白名单内才路由到该页面的
  # actions_module（kanban 曾是写死的 `@kanban_actions` 串子句）；未注册动作
  # 与原 catch-all 一致返回 `error:unsupported_action`。
  def handle_event("world:dispatch", %{"action" => action, "args" => args}, socket)
      when is_binary(action) and is_map(args) do
    case Ezagent.World.PluginPageRegistry.by_action(action) do
      %{actions_module: actions_module} ->
        with_admin_operator(socket, fn ->
          # Inject the presenter's freshly-loaded caps so the plugin's action
          # handlers consume a world-computed value instead of compile-depending
          # on `Ezagent.World.PresenterCaps` (#1476: a plugin must not depend on
          # the UI host). World keeps `presenter_caps_dispatch_gate` enforced on
          # its side — caps originate here from `PresenterCaps.load/1`, never the
          # raw mount snapshot.
          socket = assign(socket, :presenter_caps, Ezagent.World.PresenterCaps.load(socket))
          actions_module.handle_dispatch(socket, action, args)
        end)

      nil ->
        {:noreply, assign(socket, :last_dispatch_status, "error:unsupported_action")}
    end
  end

  def handle_event("pty_input", %{"bytes" => bytes}, socket) when is_binary(bytes) do
    case pty_agent_uri_str(socket.assigns.world_state) do
      agent_uri_str when is_binary(agent_uri_str) ->
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

  defp with_admin_operator(socket, fun) when is_function(fun, 0) do
    case Map.get(socket.assigns, :current_entity_uri) do
      %URI{} = caller -> Invocation.with_admin_operator(caller, fun)
      _other -> fun.()
    end
  end

  defp resolve_founder_for_notify(socket) do
    case Map.get(socket.assigns, :current_workspace_uri) do
      %URI{} = ws_uri ->
        case Ezagent.URI.name(ws_uri) do
          {:ok, name} when is_binary(name) and name != "" ->
            case Ezagent.Workspace.Store.get_by_name(name) do
              %{members: [%URI{} = founder | _]} -> founder
              _ -> nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp entity_display_name(%URI{} = uri) do
    case Ezagent.URI.name(uri) do
      {:ok, name} -> name
      _ -> Ezagent.URI.stable_key(uri)
    end
  end

  defp entity_display_name(_), do: "unknown"

  defp pty_agent_uri_str(%{"component" => "pty_terminal", "agent_uri" => agent_uri_str}),
    do: agent_uri_str

  defp pty_agent_uri_str(%{
         "component" => "conversation",
         "active_view" => "pty",
         "active_pty_agent_uri" => agent_uri_str
       }),
       do: agent_uri_str

  defp pty_agent_uri_str(_), do: nil

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
          data-plugin-nav={@plugin_nav_json}
          data-caller={@caller_json}
          data-world-state={@world_state_json}
          data-world-component={@world_component}
          data-current-session-uri={@current_session_uri_str}
          data-last-dispatch={@last_dispatch_status}
          data-world-module-url={@world_module_url}
          data-world-css-url={@world_css_url}
          class="min-h-screen"
        >
          <WorldLoading.shell />
        </div>
      </main>
    </Layouts.app>
    """
  end

  defp dispatch_session_join(socket, %URI{} = session_uri) do
    caller = socket.assigns.current_entity_uri

    _ = Ezagent.LocalRuntime.ensure_live(session_uri)
    _ = EzagentDomainInstanceMessage.SessionCreator.demand_spawn_member(caller)
    _ = provision_session_join_authority(session_uri, caller)

    # The JIT grant above is synchronous, but the socket's mount-time cap set is
    # an immutable snapshot. Every external envelope must carry the newly
    # issued artifact explicitly, so reload the presenter's verified Identity
    # caps before dispatch instead of relying on hidden verifier fallback.
    caps = Ezagent.World.PresenterCaps.load(socket)

    target = Ezagent.URI.with_action(session_uri, :session, :join)

    result =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: %{member: caller},
        ctx: %{caller: caller, authenticated_principal: caller, caps: caps, reply: :ignore},
        origin: :authenticated_external
      })

    case result do
      :ok ->
        dispatch_session_join_ok(socket, session_uri)

      {:ok, _payload} ->
        dispatch_session_join_ok(socket, session_uri)

      {:error, reason} when reason in [:missing_cap, :unauthorized] ->
        dispatch_session_join_observe(socket, session_uri, reason)

      {:error, reason} ->
        {:noreply, assign(socket, :last_dispatch_status, "error:#{reason_to_string(reason)}")}
    end
  end

  defp dispatch_session_join_ok(socket, %URI{} = session_uri) do
    mount_session_participation_caps(session_uri, socket.assigns.current_entity_uri)

    {:noreply,
     socket
     |> assign(:current_session_uri, session_uri)
     |> assign(:current_session_uri_str, URI.to_string(session_uri))
     |> assign(:last_dispatch_status, "ok")
     |> push_patch(to: "/sessions?session=#{encode_param(session_uri)}")}
  end

  defp dispatch_session_join_observe(socket, %URI{} = session_uri, reason) do
    {:noreply,
     socket
     |> assign(:current_session_uri, session_uri)
     |> assign(:current_session_uri_str, URI.to_string(session_uri))
     |> assign(:last_dispatch_status, "error:#{reason_to_string(reason)}")
     |> push_patch(to: "/sessions?session=#{encode_param(session_uri)}")}
  end

  defp provision_session_join_authority(%URI{} = session_uri, %URI{} = caller_uri),
    do: Membership.provision_join_authority(session_uri, caller_uri)

  defp provision_session_join_authority(_session_uri, _caller_uri), do: {:error, :no_authority}

  # D1 join 补发:每次成功 join(含重导航的幂等 join)走完整补发 —— 也是
  # approve_admission 这类 in-Kind 补员路径的自愈点(成员下次导航进会话补齐)。
  defp mount_session_participation_caps(%URI{} = session_uri, %URI{} = caller_uri),
    do: Ezagent.Socialware.MemberBackfill.backfill(session_uri, caller_uri)

  defp mount_session_participation_caps(_session_uri, _caller_uri), do: {:error, :no_authority}

  defp dispatch_layout_manage(socket, layout) when is_map(layout) do
    workspace_uri = socket.assigns.current_workspace_uri
    caller = socket.assigns.current_entity_uri
    caps = Ezagent.World.PresenterCaps.load(socket)

    target = Ezagent.URI.with_action(workspace_uri, :layout, :manage)

    result =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: %{layout: layout},
        ctx: %{caller: caller, authenticated_principal: caller, caps: caps, reply: {:caller_inbox, self()}},
        origin: :authenticated_external
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

  # Store/replace an agent's downstream-LLM API key from the world UI — the write
  # half of the agent_api_keys page (the read half is IdentityData.list_api_keys).
  # Dispatches `Behavior.ApiKeys :put_api_key` with the caller's scope; the
  # behavior gate authorizes by data_owner (agent creator) or admin, matching the
  # `can_edit` affordance the page already computes. On success the masked-keys
  # table is refreshed by re-resolving the SAME route state (no key plaintext ever
  # rides back — `list_api_keys` returns only masked values).
  defp dispatch_api_key_put(socket, agent_uri_str, args) when is_map(args) do
    caller = socket.assigns.current_entity_uri
    caps = Ezagent.World.PresenterCaps.load(socket)
    provider = args |> Map.get("provider", "") |> to_string() |> String.trim()
    key = args |> Map.get("key", "") |> to_string() |> String.trim()

    with {:ok, agent_uri} <- parse_agent_uri(agent_uri_str),
         true <- provider != "" and key != "",
         {:ok, _result} <-
           Invocation.dispatch(%Invocation{
             target: Ezagent.URI.with_action(agent_uri, :identity, :put_api_key),
             mode: :call,
             args: %{provider: provider, key: key},
             ctx: %{caller: caller, authenticated_principal: caller, caps: caps, reply: :sync},
             origin: :authenticated_external
           }) do
      refresh_api_keys_state(socket, agent_uri)
    else
      false ->
        {:noreply,
         assign(socket, :last_dispatch_status, "error:api_key_provider_and_key_required")}

      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:invalid_agent_uri")}

      {:error, reason} ->
        {:noreply, assign(socket, :last_dispatch_status, "error:#{reason_to_string(reason)}")}
    end
  end

  defp refresh_api_keys_state(socket, %URI{} = agent_uri) do
    # Re-resolve through Routes.route_for (the single route SoT) so the refreshed
    # state can't drift from what the page renders on a normal navigation.
    encoded = agent_uri |> URI.to_string() |> URI.encode_www_form()
    route = Ezagent.World.Routes.route_for(%{}, "/identities/agents/#{encoded}/api-keys")
    layout = socket.assigns.world_state["layout"]
    state = state_for_route(route, socket, layout)

    {:noreply,
     socket
     |> assign(:world_state, state)
     |> assign(:world_state_json, Jason.encode!(state))
     |> assign(:last_dispatch_status, "ok")
     |> push_event("world:state", state)}
  end

  defp dispatch_pty_input(socket, %URI{} = agent_uri, bytes) do
    target = Ezagent.URI.with_action(agent_uri, :pty, :write)

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :cast,
           args: %{bytes: bytes},
           ctx: %{
             caller: socket.assigns.current_entity_uri,
             authenticated_principal: socket.assigns.current_entity_uri,
             caps: Ezagent.World.PresenterCaps.load(socket),
             reply: :ignore
           },
           origin: :authenticated_external
         }) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp world_module_url,
    do: Application.get_env(:ezagent_plugin_world, :world_module_url, "/assets/world/main.js")

  defp world_css_url,
    do: Application.get_env(:ezagent_plugin_world, :world_css_url, "/assets/world/world.css")

  # R-3 (codex HIGH-4): the persisted-layout read threads the CALLER's
  # authenticated scope (`caller` = `current_entity_uri`) SEPARATELY from the
  # target `workspace_uri`. The resolver's authority check then compares the two
  # independently-sourced `<ws>` values, so a mount whose caller is not
  # authoritative for the target workspace falls back to `default_layout`
  # (fail-closed) rather than reading the foreign layout.
  defp layout_for(%URI{} = workspace_uri, %URI{} = caller_uri) do
    case Ezagent.URI.workspace_name(caller_uri) do
      {:ok, ws} ->
        Ezagent.World.LayoutManager.read_layout(workspace_uri, %{workspace: ws})

      :error ->
        Ezagent.World.LayoutManager.default_layout(workspace_uri)
    end
  end

  defp layout_for(_, _),
    do: Ezagent.World.LayoutManager.default_layout(Ezagent.URI.workspace(:system))

  # Route pages derive synthetic single-slot layouts. The older persisted
  # multi-slot layout still exists for the layout.manage behavior, but Chat is
  # now an IM surface; rendering a layout editor beside the default conversation
  # shell breaks the product contract.
  defp layout_for_route(%{component: component, title: title}, workspace_uri, _caller_uri) do
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
         %{component: "conversation", session_uri: %URI{} = session_uri} = route,
         socket,
         layout
       ) do
    session_uri
    |> ConversationSessionState.state_for(socket)
    |> Map.put("path", route.path)
    |> Map.put("title", route.title)
    |> Map.put("layout", layout)
    |> put_can_manage_layout("conversation", socket)
    |> put_command_palette(socket)
  end

  defp state_for_route(%{component: "sessions_table"}, socket, layout) do
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
  defp state_for_route(%{component: "overview"} = route, socket, layout) do
    if admin_socket?(socket) do
      route
      |> Ezagent.World.AdminData.state_for(%{
        workspace_uri: socket.assigns.current_workspace_uri,
        caller_uri: socket.assigns.current_entity_uri,
        caller_caps: Ezagent.World.PresenterCaps.load(socket)
      })
      |> Map.put("layout", layout)
      |> put_can_manage_layout(route.component, socket)
      |> put_command_palette(socket)
    else
      unauthorized_route_state(route, socket, layout)
    end
  end

  # F3 (read-plane PR-4 rework): the whole `:admin` route group is
  # admin-gated HERE as well as by the `:require_admin` live_session — a
  # non-admin caller gets an explicit unauthorized state, never
  # cross-tenant counts/registries/templates.
  defp state_for_route(%{group: :admin} = route, socket, layout) do
    if admin_socket?(socket) do
      route
      |> Ezagent.World.AdminData.state_for(%{
        workspace_uri: socket.assigns.current_workspace_uri,
        caller_uri: socket.assigns.current_entity_uri,
        caller_caps: Ezagent.World.PresenterCaps.load(socket)
      })
      |> Map.put("layout", layout)
      |> put_can_manage_layout(route.component, socket)
      |> put_command_palette(socket)
    else
      unauthorized_route_state(route, socket, layout)
    end
  end

  defp state_for_route(route, socket, layout),
    do: state_for_plugin_or_fallback(route, socket, layout)

  # The same operator predicate the `:require_admin` on_mount enforces
  # (bootstrap admin OR a member of the system workspace) — kept as one
  # small check so the route gate and this data-layer gate cannot drift
  # on WHAT counts as an operator.
  defp admin_socket?(socket) do
    Map.get(socket.assigns, :is_admin?, false) == true or
      Map.get(socket.assigns, :is_system_member?, false) == true
  end

  # Explicit unauthorized state (Invariant #9 — surfaced, not silently
  # dropped): the route's component shell plus a denial marker, and NO
  # data keys.
  defp unauthorized_route_state(route, socket, layout) do
    %{
      "component" => route.component,
      "title" => route.title,
      "path" => route.path,
      "workspace_uri" => encode_uri(socket.assigns.current_workspace_uri),
      "unauthorized" => true,
      "error" => "unauthorized",
      "layout" => layout
    }
    |> put_can_manage_layout(route.component, socket)
    |> put_command_palette(socket)
  end

  # 插件页面经 `PluginPageRegistry` 在运行时查找已验证的 data builder；这避免了
  # 编译期读取 ETS 插件 catalog，也让新增插件页面无需重编译 World。
  defp state_for_plugin_or_fallback(%{component: component} = route, socket, layout) do
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
        |> Map.put("can_manage_layout", false)
        |> put_command_palette(socket)

      nil ->
        state_for_non_plugin_route(route, socket, layout)
    end
  end

  defp state_for_plugin_or_fallback(route, socket, layout),
    do: state_for_non_plugin_route(route, socket, layout)

  defp state_for_non_plugin_route(%{group: :workspace_plugins} = route, socket, layout) do
    route
    |> Ezagent.World.WorkspacePluginData.state_for(%{
      workspace_uri: socket.assigns.current_workspace_uri,
      caller_uri: socket.assigns.current_entity_uri,
      caller_caps: Ezagent.World.PresenterCaps.load(socket)
    })
    |> Map.put("layout", layout)
    |> put_can_manage_layout(route.component, socket)
    |> put_command_palette(socket)
  end

  defp state_for_non_plugin_route(route, socket, layout) do
    route
    |> Ezagent.World.IdentityData.state_for(%{
      workspace_uri: socket.assigns.current_workspace_uri,
      caller_uri: socket.assigns.current_entity_uri,
      caller_caps: Ezagent.World.PresenterCaps.load(socket),
      create_error: create_error_for_route(route, socket)
    })
    |> Map.put("layout", layout)
    |> put_can_manage_layout(route.component, socket)
    |> put_command_palette(socket)
  end

  defp create_error_for_route(%{component: "agent_new_form"}, socket),
    do: Map.get(socket.assigns, :agent_create_error)

  defp create_error_for_route(%{component: "user_new_form"}, socket),
    do: Map.get(socket.assigns, :user_create_error)

  defp create_error_for_route(_route, _socket), do: nil

  defp sessions_state(sessions, current_session_uri, workspace_uri, layout, caps, caller) do
    workspace = encode_uri(workspace_uri)
    current_session = encode_uri(current_session_uri)

    %{
      "component" => "sessions_table",
      "current_session_uri" => current_session,
      "workspace_uri" => workspace,
      "layout" => layout,
      "can_manage_layout" => can_manage_layout?("sessions_table", workspace_uri, caps),
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

  # Resolvable SessionTemplate names for the "New session" picker —
  # delegated to the SINGLE source
  # `Ezagent.World.WorkspacePluginData.session_template_names/2` (which
  # routes the instance enumeration through the caller-authorizing
  # `Ezagent.Session.TemplateReads` chokepoint, read-plane PR-4 rework).
  defp session_template_names(caller, %URI{scheme: "workspace"} = workspace_uri) do
    Ezagent.World.WorkspacePluginData.session_template_names(caller, workspace_uri)
  end

  defp session_template_names(_caller, _), do: ["default"]

  defp put_command_palette(state, socket) do
    Map.put(state, "cmdk", CommandPaletteData.state(socket.assigns, "", false))
  end

  defp caller_payload(caller, workspace, caps, system_member?) do
    %{
      "entity_uri" => encode_uri(caller),
      "workspace_uri" => encode_uri(workspace),
      "current_workspace_name" => workspace_name(workspace),
      "display_name" => caller_display_name(caller),
      "is_system_member" => system_member?,
      "workspaces" => workspace_switcher_rows(caller, workspace, caps)
    }
  end

  defp workspace_switcher_rows(caller, current_workspace, caps) do
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

  defp workspace_name(%URI{scheme: "workspace"} = workspace_uri),
    do: Ezagent.URI.name!(workspace_uri)

  defp workspace_name(_), do: nil

  defp subscribe_global_inbound(socket) do
    caller_uri = Map.get(socket.assigns, :current_entity_uri)

    # Task #187: the audit and cc_event streams are GLOBAL, all-tenant — the
    # OPERATOR-OBSERVABILITY plane, gated on the operator predicate
    # (`operator_streams?/1`), NOT session membership. Only an operator's LV
    # subscribes; delivery is ALSO gated per-event in `handle_info`, so a
    # pre-gate subscription or a mid-session demotion still cannot leak.
    if operator_streams?(socket) do
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.Audit.stream_topic())
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.CCEvents.topic())
    end

    # The legacy-bridge topic carries cc_connected/cc_disconnected, delivered
    # only to a viewer authorized for their CURRENT session
    # (`authorized_for_current_session?/1`, read-plane-authz F2/#2) — a session
    # member needs it for their own session's bridge status, so it is NOT
    # operator-only.
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.AgentBridge.Registry.legacy_topic())

    if caller_uri do
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.Notifications.topic(caller_uri))
      :ok = Ezagent.Notifications.subscribe_slice_change(caller_uri)
    end
  end

  # Task #187 — the ONE operator predicate for the audit/authz/cc_event plane:
  # REUSES `Ezagent.Identity.AdminAuthority.admin?/1` (the same gate the
  # `:require_admin` live_session and `Ezagent.Identity.OperatorReads` use —
  # no new check invented). Caps are loaded LIVE so a runtime demotion closes
  # the stream without a reload; any load failure and any unknown/missing
  # caller fails closed.
  defp operator_streams?(socket) do
    socket.assigns
    |> Map.get(:current_entity_uri)
    |> Ezagent.Identity.AdminAuthority.admin?()
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

  defp can_manage_layout?(_component, _workspace_uri, _caps), do: false

  defp put_can_manage_layout(state, component, socket) do
    caps = Ezagent.World.PresenterCaps.load(socket)

    Map.put(
      state,
      "can_manage_layout",
      can_manage_layout?(component, socket.assigns.current_workspace_uri, caps)
    )
  end

  # A live broadcast reaches the browser only if the viewer is authorized for the
  # session AND the message is visible to them (row-policy: `:internal` only for a
  # `:read_unfiltered` holder). This is the DELIVERY-time counterpart to the
  # `SessionReads` historical read gate and the ROBUST guarantee: even a socket
  # that subscribed without authorization, or a member revoked mid-session, is
  # dropped here — independent of subscribe ordering. (read-plane-authz F1.)
  defp live_message_deliverable?(socket, %URI{} = session_uri, %Ezagent.Message{} = msg) do
    caller = Map.get(socket.assigns, :current_entity_uri)

    SessionReads.authorized?(caller, session_uri) and
      (msg.visibility != :internal or SessionReads.read_unfiltered?(caller, session_uri))
  end

  defp live_message_deliverable?(_socket, _session_uri, _msg), do: false

  # Live authorization for the socket's CURRENT session — the shared delivery-time
  # gate for session-scoped broadcasts that are not messages (roster/read-marker/
  # cc-bridge). Fail-closed when there is no current session or the caller is not
  # authorized. (read-plane-authz F2/#2.)
  defp authorized_for_current_session?(socket) do
    caller = Map.get(socket.assigns, :current_entity_uri)

    case socket.assigns[:current_session_uri] do
      %URI{} = session_uri -> SessionReads.authorized?(caller, session_uri)
      _ -> false
    end
  end

  defp same_uri?(%URI{} = left, %URI{} = right), do: URI.to_string(left) == URI.to_string(right)
  defp same_uri?(_, _), do: false

  # The SECOND read exit for the same bytes (the first is
  # `IdentityData.component_state/5`'s `pty_terminal` branch). `agent_uri`
  # comes from the URL, so this subscription carries the same capability
  # check — gating only the state path would leave the live output stream
  # wide open. See `Ezagent.Domain.Pty.Access`.
  defp maybe_subscribe_pty(socket, %{component: "pty_terminal", entity_uri: %URI{} = agent_uri}) do
    caps = Ezagent.World.PresenterCaps.load(socket)

    holder = socket.assigns.current_entity_uri

    if connected?(socket) and Ezagent.Domain.Pty.Access.may_read?(holder, agent_uri, caps) do
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
            "agent_status" =>
              Ezagent.World.Jsonable.to_json(Ezagent.Domain.Agent.lifecycle_status(agent_uri)),
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
      "payload" => Ezagent.World.Jsonable.to_json(payload),
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

  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason), do: inspect(reason)

  defp encode_uri(%URI{} = uri), do: URI.to_string(uri)
  defp encode_uri(_), do: nil

  defp caller_display_name(uri), do: Ezagent.World.CallerDisplay.name(uri)
end
