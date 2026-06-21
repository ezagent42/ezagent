defmodule EzagentPluginWorld.WorldLive do
  @moduledoc """
  LiveView SSR/comms shell for the React-owned `world` app.
  """

  use Phoenix.LiveView

  alias Ezagent.Invocation
  alias EzagentPluginWorld.Layouts

  @impl true
  def mount(_params, _session, socket) do
    caller = Map.get(socket.assigns, :current_entity_uri)
    workspace = Map.get(socket.assigns, :current_workspace_uri)
    sessions = list_sessions(workspace)
    current_session_uri = List.first(sessions)

    caller_payload = %{
      "entity_uri" => encode_uri(caller),
      "workspace_uri" => encode_uri(workspace)
    }

    layout = layout_for(workspace)
    state = sessions_state(sessions, current_session_uri, workspace, layout, caller)

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
  def handle_info(:push_world_state, socket) do
    {:noreply, push_event(socket, "world:state", socket.assigns.world_state)}
  end

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
    session_uri_str = URI.to_string(session_uri)

    state =
      socket.assigns.world_state
      |> Map.put("current_session_uri", session_uri_str)

    {:noreply,
     socket
     |> assign(:current_session_uri, session_uri)
     |> assign(:current_session_uri_str, session_uri_str)
     |> assign(:world_state, state)
     |> assign(:world_state_json, Jason.encode!(state))
     |> assign(:last_dispatch_status, "ok")
     |> push_event("world:state", state)}
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

  defp sessions_state(sessions, current_session_uri, workspace_uri, layout, caller) do
    workspace = encode_uri(workspace_uri)
    current_session = encode_uri(current_session_uri)

    %{
      "component" => "sessions_table",
      "current_session_uri" => current_session,
      "workspace_uri" => workspace,
      "layout" => layout,
      "can_manage_layout" => default_layout_manager?(workspace_uri, caller),
      "sessions" => Enum.map(sessions, &session_row/1)
    }
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

  defp parse_session_uri(value) when is_binary(value) do
    case Ezagent.URI.new!(value) do
      %URI{scheme: "session"} = uri -> {:ok, uri}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp parse_session_uri(_), do: :error

  defp default_layout_manager?(%URI{} = workspace_uri, %URI{} = caller) do
    same_uri?(workspace_uri, Ezagent.URI.workspace(:system)) and
      URI.to_string(caller) == URI.to_string(Ezagent.Entity.User.admin_uri())
  end

  defp default_layout_manager?(_, _), do: false

  defp same_uri?(%URI{} = left, %URI{} = right), do: URI.to_string(left) == URI.to_string(right)

  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason), do: inspect(reason)

  defp encode_uri(%URI{} = uri), do: URI.to_string(uri)
  defp encode_uri(_), do: nil
end
