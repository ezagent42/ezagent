defmodule Ezagent.World.UserActions do
  @moduledoc """
  Socket-side user-management dispatch handlers for the world identities surface.

  Create/reset-password go through the existing dispatch-backed domain paths.
  Profile edits and soft-disable/enable use the `Users` / `Entity.Profile`
  facades because no dedicated Behavior exists yet; those mutations are gated
  here by admin authority and always re-read state after write.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, push_navigate: 2]

  alias Ezagent.Entity.Profile
  alias Ezagent.Invocation
  alias Ezagent.Users

  @doc "Route a `world:dispatch` user action to its handler."
  @spec handle_dispatch(Phoenix.LiveView.Socket.t(), String.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_dispatch(socket, "users.create", %{"user" => user_params})
      when is_map(user_params) do
    dispatch_user_create(socket, user_params)
  end

  def handle_dispatch(socket, "users.profile.save", args) when is_map(args) do
    dispatch_profile_save(socket, args)
  end

  def handle_dispatch(socket, "users.password.set", args) when is_map(args) do
    dispatch_password_set(socket, args)
  end

  def handle_dispatch(socket, "users.disable", args) when is_map(args) do
    dispatch_disable(socket, args)
  end

  def handle_dispatch(socket, "users.enable", args) when is_map(args) do
    dispatch_enable(socket, args)
  end

  def handle_dispatch(socket, _action, _args) do
    {:noreply, assign(socket, :last_dispatch_status, "error:unsupported_action")}
  end

  defp dispatch_user_create(socket, params) do
    workspace_uri = socket.assigns.current_workspace_uri
    caller = socket.assigns.current_entity_uri
    caps = Map.get(socket.assigns, :current_caps, MapSet.new())
    caller_ctx = %{caller: caller, caps: caps}

    with %URI{scheme: "workspace"} <- workspace_uri,
         {:ok, name} <- required_string(params, "name", :name_required),
         :ok <- validate_name(name),
         {:ok, password} <- required_string(params, "password", :password_required),
         {:ok, user_uri} <- build_user_uri(workspace_uri, name),
         user_uri_str = URI.to_string(user_uri),
         {:ok, %{user_uri: ^user_uri_str}} <-
           Ezagent.Workspace.create_user(
             workspace_uri,
             %{user_uri: user_uri_str, password: password, caps: ""},
             caller_ctx
           ),
         :ok <- upsert_profile(user_uri, params) do
      encoded = URI.encode_www_form(user_uri_str)

      {:noreply,
       socket
       |> assign(:user_create_error, nil)
       |> assign(:last_dispatch_status, "ok")
       |> push_navigate(to: "/identities/users/#{encoded}")}
    else
      {:error, reason} ->
        {:noreply, push_user_create_error(socket, reason)}

      _ ->
        {:noreply, push_user_create_error(socket, :invalid_workspace_scope)}
    end
  end

  defp dispatch_profile_save(socket, args) do
    user_uri_str = Map.get(args, "user_uri")

    with :ok <- require_admin(socket),
         {:ok, user_uri} <- parse_user_uri(user_uri_str),
         :ok <- ensure_user_exists(user_uri),
         :ok <- upsert_profile(user_uri, args) do
      {:noreply, push_user_state(socket, user_uri)}
    else
      :error -> {:noreply, push_user_action_error(socket, user_uri_str, :invalid_user_uri)}
      {:error, reason} -> {:noreply, push_user_action_error(socket, user_uri_str, reason)}
    end
  end

  defp dispatch_password_set(socket, args) do
    user_uri_str = Map.get(args, "user_uri")
    password = Map.get(args, "password")
    caller = socket.assigns.current_entity_uri
    caps = Map.get(socket.assigns, :current_caps, MapSet.new())

    with :ok <- require_admin(socket),
         {:ok, user_uri} <- parse_user_uri(user_uri_str),
         :ok <- ensure_user_exists(user_uri),
         {:ok, password} <- required_value(password, :password_required),
         {:ok, %{password_set: true}} <-
           Invocation.dispatch(%Invocation{
             target: Ezagent.URI.with_action(user_uri, :user_credentials, :set_password),
             mode: :call,
             args: %{password: password},
             ctx: %{caller: caller, caps: caps, reply: {:caller_inbox, self()}},
             origin: :authenticated_external
           }) do
      {:noreply, push_user_state(socket, user_uri)}
    else
      :error -> {:noreply, push_user_action_error(socket, user_uri_str, :invalid_user_uri)}
      {:error, reason} -> {:noreply, push_user_action_error(socket, user_uri_str, reason)}
    end
  end

  defp dispatch_disable(socket, args) do
    user_uri_str = Map.get(args, "user_uri")
    reason = Map.get(args, "reason")
    caller = socket.assigns.current_entity_uri

    with :ok <- require_admin(socket),
         {:ok, user_uri} <- parse_user_uri(user_uri_str),
         :ok <- ensure_not_self(caller, user_uri),
         :ok <- ensure_user_exists(user_uri),
         {:ok, _user} <- Users.disable(user_uri, caller, reason) do
      {:noreply, push_user_state(socket, user_uri)}
    else
      :error -> {:noreply, push_user_action_error(socket, user_uri_str, :invalid_user_uri)}
      {:error, reason} -> {:noreply, push_user_action_error(socket, user_uri_str, reason)}
    end
  end

  defp dispatch_enable(socket, args) do
    user_uri_str = Map.get(args, "user_uri")

    with :ok <- require_admin(socket),
         {:ok, user_uri} <- parse_user_uri(user_uri_str),
         :ok <- ensure_user_exists(user_uri),
         {:ok, _user} <- Users.enable(user_uri) do
      {:noreply, push_user_state(socket, user_uri)}
    else
      :error -> {:noreply, push_user_action_error(socket, user_uri_str, :invalid_user_uri)}
      {:error, reason} -> {:noreply, push_user_action_error(socket, user_uri_str, reason)}
    end
  end

  defp push_user_create_error(socket, reason) do
    route = Ezagent.World.Routes.route_for(%{}, "/identities/users/new")
    layout = socket.assigns.world_state["layout"]
    socket = assign(socket, :user_create_error, reason)
    state = state_for_route(route, socket, layout, reason)

    socket
    |> assign(:world_state, state)
    |> assign(:world_state_json, Jason.encode!(state))
    |> assign(:last_dispatch_status, "error:#{reason_to_string(reason)}")
    |> push_event("world:state", state)
  end

  defp push_user_state(socket, %URI{} = user_uri) do
    user_uri_str = URI.to_string(user_uri)
    encoded = URI.encode_www_form(user_uri_str)
    route = Ezagent.World.Routes.route_for(%{"uri" => encoded}, "/identities/users/#{encoded}")
    layout = socket.assigns.world_state["layout"]
    state = state_for_route(route, socket, layout, nil)

    socket
    |> assign(:world_state, state)
    |> assign(:world_state_json, Jason.encode!(state))
    |> assign(:last_dispatch_status, "ok")
    |> push_event("world:state", state)
  end

  defp push_user_action_error(socket, user_uri_str, reason) do
    route = action_error_route(user_uri_str)
    layout = socket.assigns.world_state["layout"]
    state = state_for_route(route, socket, layout, nil)
    state = Map.put(state, "action_error", Ezagent.World.UserData.error_message(reason))

    socket
    |> assign(:world_state, state)
    |> assign(:world_state_json, Jason.encode!(state))
    |> assign(:last_dispatch_status, "error:#{reason_to_string(reason)}")
    |> push_event("world:state", state)
  end

  defp state_for_route(route, socket, layout, create_error) do
    route
    |> Ezagent.World.IdentityData.state_for(%{
      workspace_uri: socket.assigns.current_workspace_uri,
      caller_uri: socket.assigns.current_entity_uri,
      caller_caps: Map.get(socket.assigns, :current_caps, MapSet.new()),
      create_error: create_error
    })
    |> Map.put("layout", layout)
    |> Map.put("can_manage_layout", false)
    |> put_command_palette(socket)
  end

  defp put_command_palette(state, socket) do
    Map.put(state, "cmdk", Ezagent.World.CommandPaletteData.state(socket.assigns, "", false))
  end

  defp action_error_route(user_uri_str) when is_binary(user_uri_str) do
    case parse_user_uri(user_uri_str) do
      {:ok, _user_uri} ->
        encoded = URI.encode_www_form(user_uri_str)
        Ezagent.World.Routes.route_for(%{"uri" => encoded}, "/identities/users/#{encoded}")

      :error ->
        Ezagent.World.Routes.route_for(%{}, "/identities/users")
    end
  end

  defp action_error_route(_), do: Ezagent.World.Routes.route_for(%{}, "/identities/users")

  defp required_string(params, key, reason) do
    params
    |> Map.get(key)
    |> required_value(reason)
  end

  defp required_value(value, reason) do
    value = value |> to_string() |> String.trim()

    if value == "", do: {:error, reason}, else: {:ok, value}
  end

  defp validate_name(name) do
    if Regex.match?(~r/\A[a-z][a-z0-9_-]*\z/, name) do
      :ok
    else
      {:error, {:bad_name, name}}
    end
  end

  defp build_user_uri(%URI{scheme: "workspace"} = workspace_uri, name) do
    case Ezagent.URI.name(workspace_uri) do
      {:ok, workspace_name} -> {:ok, Ezagent.URI.user(workspace_name, name)}
      :error -> {:error, {:bad_workspace_uri, workspace_uri}}
    end
  rescue
    ArgumentError -> {:error, {:bad_name, name}}
  end

  defp upsert_profile(%URI{} = user_uri, attrs) when is_map(attrs) do
    display_name =
      attrs
      |> Map.get("display_name", "")
      |> to_string()
      |> String.trim()
      |> fallback_display_name(user_uri, Map.get(attrs, "email"))

    email =
      case Map.get(attrs, "email") do
        value when is_binary(value) -> String.trim(value)
        _ -> ""
      end

    case Profile.upsert(%{
           entity_uri: user_uri,
           display_name: display_name,
           email: if(email == "", do: nil, else: email)
         }) do
      {:ok, _profile} -> :ok
      {:error, reason} -> {:error, {:profile_failed, reason}}
    end
  end

  defp fallback_display_name("", user_uri, email) do
    cond do
      is_binary(email) and String.trim(email) != "" ->
        email |> String.trim() |> String.split("@", parts: 2) |> List.first()

      true ->
        case Ezagent.URI.name(user_uri) do
          {:ok, name} -> name
          :error -> URI.to_string(user_uri)
        end
    end
  end

  defp fallback_display_name(display_name, _user_uri, _email), do: display_name

  defp parse_user_uri(value) when is_binary(value) do
    case Ezagent.URI.new!(value) do
      %URI{scheme: "entity"} = uri ->
        if Ezagent.URI.type?(uri, :user), do: {:ok, uri}, else: :error

      _ ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  defp parse_user_uri(_), do: :error

  defp ensure_user_exists(%URI{} = user_uri) do
    if Users.get_by_uri(user_uri), do: :ok, else: {:error, :user_not_found}
  end

  defp ensure_not_self(%URI{} = caller, %URI{} = user_uri) do
    if Ezagent.URI.stable_key(caller) == Ezagent.URI.stable_key(user_uri) do
      {:error, :self_disable_denied}
    else
      :ok
    end
  end

  defp ensure_not_self(_caller, _user_uri), do: :ok

  defp require_admin(socket) do
    caller = socket.assigns.current_entity_uri
    caps = Map.get(socket.assigns, :current_caps, MapSet.new())

    if Ezagent.Identity.AdminAuthority.admin?(caller, caps),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason), do: inspect(reason)
end
