defmodule Ezagent.World.AgentActions do
  @moduledoc """
  Socket-side agent dispatch handlers for the world plugin.

  Mirrors `Ezagent.World.ConversationActions`: `WorldLive` keeps thin
  `handle_event` clauses for the `agents.*` family and delegates here, so
  the shell module stays under its LOC cap as the agent-console surface grows.

  Handles:
  - `agents.create`         — create a new agent in the current workspace
  - `agents.delete`         — delete an agent after checking live-session bindings
  - `agents.config.update`  — apply a delta to an agent's config layer
  - `agents.config.delete_path` — delete a path inside a config layer
  - `agents.config.repoint` — repoint the config object a layer/key pair references
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, push_navigate: 2]

  alias Ezagent.Invocation

  @doc """
  Route a `world:dispatch` agent action to its handler.
  """
  @spec handle_dispatch(Phoenix.LiveView.Socket.t(), String.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_dispatch(socket, "agents.create", %{"agent" => agent_params}) do
    dispatch_agent_create(socket, agent_params)
  end

  def handle_dispatch(socket, "agents.delete", %{"agent_uri" => agent_uri_str}) do
    dispatch_agent_delete(socket, agent_uri_str)
  end

  def handle_dispatch(socket, "agents.config.update", args) when is_map(args) do
    dispatch_config_update(socket, args)
  end

  def handle_dispatch(socket, "agents.config.delete_path", args) when is_map(args) do
    dispatch_config_delete_path(socket, args)
  end

  def handle_dispatch(socket, "agents.config.repoint", args) when is_map(args) do
    dispatch_config_repoint(socket, args)
  end

  def handle_dispatch(socket, _action, _args) do
    {:noreply, assign(socket, :last_dispatch_status, "error:unsupported_action")}
  end

  # ── Agent create ─────────────────────────────────────────────────────────────

  defp dispatch_agent_create(socket, params) when is_map(params) do
    workspace_uri = socket.assigns.current_workspace_uri
    caller = socket.assigns.current_entity_uri
    caller_ctx = %{caller: caller, caps: Map.get(socket.assigns, :current_caps, MapSet.new())}

    flavor = params |> Map.get("flavor", "") |> to_string() |> String.trim()
    name = params |> Map.get("name", "") |> to_string() |> String.trim()
    cwd = params |> Map.get("cwd", "") |> to_string() |> String.trim()
    caps_str = params |> Map.get("caps", "") |> to_string() |> String.trim()
    with_pty? = Map.get(params, "with_pty") in [true, "true", "on"]
    # M4: extra flavor-specific config fields from the create form
    config_fields =
      case Map.get(params, "config_fields") do
        fields when is_map(fields) -> fields
        _ -> %{}
      end

    with %URI{scheme: "workspace"} <- workspace_uri,
         {:ok, caps} <- Ezagent.Capability.Parser.parse(caps_str, caller),
         {:ok, %{agent_uri: agent_uri}} <-
           Ezagent.Workspace.create_agent(
             workspace_uri,
             %{flavor: flavor, name: name, cwd: cwd, with_pty: with_pty?}
             |> Map.merge(config_fields),
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
    # Resolve the route from the single source (Routes.route_for) so the title/
    # path can't silently drift from routes.ex if it ever changes there.
    route = Ezagent.World.Routes.route_for(%{}, "/identities/agents/new")
    layout = socket.assigns.world_state["layout"]
    socket = assign(socket, :agent_create_error, reason)
    state = state_for_route(route, socket, layout)

    socket
    |> assign(:world_state, state)
    |> assign(:world_state_json, Jason.encode!(state))
    |> assign(:last_dispatch_status, "error:#{reason_to_string(reason)}")
    |> push_event("world:state", state)
  end

  # ── Agent delete ─────────────────────────────────────────────────────────────

  defp dispatch_agent_delete(socket, agent_uri_str) when is_binary(agent_uri_str) do
    caller = socket.assigns.current_entity_uri
    caps = Map.get(socket.assigns, :current_caps, MapSet.new())

    with {:ok, agent_uri} <- parse_agent_uri(agent_uri_str),
         # AUTHZ GATE (must run BEFORE the live-sessions preflight below).
         # `agent_live_sessions/1` resolves the workspace from the PASSED URI and
         # lists there with no caller check, so a forged / cross-workspace agent
         # URI would otherwise leak another tenant's session names + count through
         # the `{:agent_bound_to_live_session, sessions}` error banner.
         #
         # Authorize through the ONLY sanctioned surface read path,
         # `Ezagent.Domain.Agent.read_config/3` (SPEC unified-non-activating-
         # agent-read §2/§11): it is NON-ACTIVATING (no cold-start; the
         # `no_surface_read_dispatch` gate forbids the surface from calling the
         # `Agent.Config.read_cascade` facade directly) and applies the SAME
         # instance-scoped `cap(:agent, Manage, :any)` gate as the authoritative
         # `manage.delete` dispatch, via the SAME TWO-ROUTE authz (inline
         # `ctx.caps` OR the caller's slice/snapshot caps) through the sanctioned
         # `caps_authorize?/2` chokepoint — so a legitimate owner whose manage-cap
         # is slice-backed (not inline) still passes, exactly as the delete does.
         # A caller lacking THIS agent's manage-cap — a forged URI, a
         # cross-workspace URI, or a same-workspace non-owner (including a holder
         # of a DIFFERENT agent's manage-cap) — fails closed with
         # `{:error, :unauthorized}` (or `:cross_workspace_denied`/`:invalid_agent_uri`),
         # learning nothing about what exists. Anyone entitled to delete is equally
         # entitled to this read, so it never blocks a legitimate delete.
         {:ok, _cascade} <-
           Ezagent.Domain.Agent.read_config(agent_uri, %{caller: caller, caps: caps}),
         {:ok, []} <- EzagentDomainInstanceMessage.agent_live_sessions(agent_uri),
         target = Ezagent.URI.with_action(agent_uri, :manage, :delete),
         {:ok, {:ok, :deleted}} <-
           Invocation.dispatch(%Invocation{
             target: target,
             mode: :call,
             args: %{},
             ctx: %{caller: caller, caps: caps, reply: {:caller_inbox, self()}},
             origin: :authenticated_external
           }) do
      {:noreply,
       socket
       |> assign(:last_dispatch_status, "ok")
       |> push_navigate(to: "/identities/agents")}
    else
      {:ok, sessions} when is_list(sessions) ->
        {:noreply,
         push_agent_action_error(socket, agent_uri_str, {:agent_bound_to_live_session, sessions})}

      :error ->
        {:noreply, push_agent_action_error(socket, agent_uri_str, :invalid_agent_uri)}

      {:error, reason} ->
        {:noreply, push_agent_action_error(socket, agent_uri_str, reason)}
    end
  end

  defp dispatch_agent_delete(socket, _),
    do: {:noreply, push_agent_action_error(socket, nil, :invalid_agent)}

  # No silent drop: rebuild the route state with an operator-facing error via the
  # SAME `world:state` channel the route uses (mirrors push_agent_create_error).
  #
  # F4: the delete button lives on the agent DETAIL page, so a delete error must
  # land on the detail route the operator is actually viewing — rebuilding the
  # agents-LIST route put the banner in a component the user had navigated away
  # from (invisible). Rebuild the detail route when we have a valid agent URI;
  # fall back to the list route only when the URI itself is unparseable.
  defp push_agent_action_error(socket, agent_uri_str, reason) do
    route = action_error_route(agent_uri_str)
    layout = socket.assigns.world_state["layout"]
    state = state_for_route(route, socket, layout)
    state = Map.put(state, "action_error", action_error_message(reason))

    socket
    |> assign(:world_state, state)
    |> assign(:world_state_json, Jason.encode!(state))
    |> assign(:last_dispatch_status, "error:#{reason_to_string(reason)}")
    |> push_event("world:state", state)
  end

  defp action_error_route(agent_uri_str) when is_binary(agent_uri_str) do
    case parse_agent_uri(agent_uri_str) do
      {:ok, _agent_uri} ->
        encoded = URI.encode_www_form(agent_uri_str)
        Ezagent.World.Routes.route_for(%{"uri" => encoded}, "/identities/agents/#{encoded}")

      :error ->
        Ezagent.World.Routes.route_for(%{}, "/identities/agents")
    end
  end

  defp action_error_route(_), do: Ezagent.World.Routes.route_for(%{}, "/identities/agents")

  defp action_error_message({:agent_bound_to_live_session, sessions}) when is_list(sessions),
    do:
      "该 agent 正在 #{length(sessions)} 个对话中（#{Enum.map_join(sessions, "、", &short_session_name/1)}），先从这些对话移出再删除"

  defp action_error_message(:agent_bound_to_live_session),
    do: "该 agent 正在某个对话中，先把它从对话移出再删除"

  defp action_error_message(:invalid_agent_uri), do: "无效的 agent URI"
  defp action_error_message(:invalid_agent), do: "无效的请求参数"
  defp action_error_message(:unauthorized), do: "没有删除权限（需要 manage 权限）"
  defp action_error_message(:cross_workspace_denied), do: "跨工作区操作被拒绝"
  defp action_error_message(reason), do: "删除失败：#{reason_to_string(reason)}"

  # ── Config mutation dispatches (C3) ─────────────────────────────────────────
  # All three helpers follow the same shape:
  # 1. Parse the agent_uri from args.
  # 2. Extract caller + caps from the operator's socket assigns.
  # 3. Call the Agent.Config API (never ConfigStore/ConfigEvolve directly — P14).
  # 4. On success: re-build the agent_config route state and push "world:state"
  #    (per spec: re-read after mutation, not an in-form echo).
  # 5. On error: push_config_error/2 (no silent drop — Invariant #9).

  defp dispatch_config_update(socket, args) when is_map(args) do
    caller = socket.assigns.current_entity_uri
    caps = Map.get(socket.assigns, :current_caps, MapSet.new())

    agent_uri_str = Map.get(args, "agent_uri")
    key = Map.get(args, "key")
    patch = Map.get(args, "patch")
    layer = Map.get(args, "layer", "user")

    with {:ok, agent_uri} <- parse_agent_uri(agent_uri_str),
         {:ok, _result} <-
           Ezagent.Agent.Config.apply_delta(agent_uri, caller, caps, %{
             layer: layer,
             key: key,
             patch: patch
           }) do
      {:noreply, push_config_state(socket, agent_uri)}
    else
      :error -> {:noreply, push_config_error(socket, :invalid_agent_uri)}
      {:error, reason} -> {:noreply, push_config_error(socket, reason)}
    end
  end

  defp dispatch_config_delete_path(socket, args) when is_map(args) do
    caller = socket.assigns.current_entity_uri
    caps = Map.get(socket.assigns, :current_caps, MapSet.new())

    agent_uri_str = Map.get(args, "agent_uri")
    key = Map.get(args, "key")
    path = Map.get(args, "path")
    layer = Map.get(args, "layer", "user")

    with {:ok, agent_uri} <- parse_agent_uri(agent_uri_str),
         {:ok, _result} <-
           Ezagent.Agent.Config.delete_path(agent_uri, caller, caps, %{
             layer: layer,
             key: key,
             path: path
           }) do
      {:noreply, push_config_state(socket, agent_uri)}
    else
      :error -> {:noreply, push_config_error(socket, :invalid_agent_uri)}
      {:error, reason} -> {:noreply, push_config_error(socket, reason)}
    end
  end

  defp dispatch_config_repoint(socket, args) when is_map(args) do
    caller = socket.assigns.current_entity_uri
    caps = Map.get(socket.assigns, :current_caps, MapSet.new())

    agent_uri_str = Map.get(args, "agent_uri")
    key = Map.get(args, "key")
    config_id = Map.get(args, "config_id")
    layer = Map.get(args, "layer", "user")

    with {:ok, agent_uri} <- parse_agent_uri(agent_uri_str),
         {:ok, _result} <-
           Ezagent.Agent.Config.repoint(agent_uri, caller, caps, %{
             layer: layer,
             key: key,
             config_id: config_id
           }) do
      {:noreply, push_config_state(socket, agent_uri)}
    else
      :error -> {:noreply, push_config_error(socket, :invalid_agent_uri)}
      {:error, reason} -> {:noreply, push_config_error(socket, reason)}
    end
  end

  # After a successful config mutation: re-build the agent_config route state and
  # push it through "world:state" so the React island reflects the authoritative
  # persisted value (not an in-form echo). The route is rebuilt fresh from routes.ex
  # so the title/path stay consistent with how `handle_params` would build it.
  defp push_config_state(socket, %URI{} = agent_uri) do
    agent_uri_str = URI.to_string(agent_uri)
    encoded = URI.encode_www_form(agent_uri_str)

    route =
      Ezagent.World.Routes.route_for(
        %{"uri" => encoded},
        "/identities/agents/#{encoded}/config"
      )

    layout = socket.assigns.world_state["layout"]
    state = state_for_route(route, socket, layout)

    socket
    |> assign(:world_state, state)
    |> assign(:world_state_json, Jason.encode!(state))
    |> assign(:last_dispatch_status, "ok")
    |> push_event("world:state", state)
  end

  # No silent drop: rebuild the agent_config route state with an operator-facing
  # error via the SAME `world:state` channel the route uses (mirrors push_agent_action_error/2).
  # The error key is "config_error" so the React config page component can surface it
  # without conflicting with the agents-list "action_error".
  defp push_config_error(socket, reason) do
    state = Map.put(socket.assigns.world_state, "config_error", config_error_message(reason))

    socket
    |> assign(:world_state, state)
    |> assign(:world_state_json, Jason.encode!(state))
    |> assign(:last_dispatch_status, "error:#{reason_to_string(reason)}")
    |> push_event("world:state", state)
  end

  defp config_error_message(:unauthorized), do: "没有修改权限（需要 manage 权限）"
  defp config_error_message(:agent_not_found), do: "Agent 不存在"
  defp config_error_message(:invalid_uri), do: "无效的 URI"
  defp config_error_message(:invalid_agent_uri), do: "无效的 agent URI"
  defp config_error_message(:invalid_layer), do: "无效的配置层（layer 必须是 workspace/user/session）"
  defp config_error_message(:invalid_key), do: "无效的配置键（key 不能为空）"
  defp config_error_message(:invalid_patch), do: "无效的 patch（必须是 map 类型）"
  defp config_error_message(:invalid_replace_body), do: "无效的替换内容（replace_body 必须是 map 类型）"
  defp config_error_message(:invalid_path), do: "无效的路径（path 必须是非空字符串列表）"
  defp config_error_message(:path_not_found), do: "路径不存在（字段未找到）"
  defp config_error_message(:config_not_found), do: "配置不存在（该层/键尚无配置对象）"
  defp config_error_message(:cross_tenant_target), do: "跨租户操作被拒绝"
  defp config_error_message(:cross_workspace_denied), do: "跨工作区操作被拒绝"
  defp config_error_message(:subject_not_self), do: "配置目标与调用者不符"
  defp config_error_message(reason), do: "配置操作失败：#{reason_to_string(reason)}"

  # ── Shared private helpers ───────────────────────────────────────────────────
  # These mirror the ConversationActions approach: each sibling action module
  # carries its own private copies of the small helpers it needs, rather than
  # importing from WorldLive (which would couple the two modules). The helpers
  # below are intentionally kept minimal — pure data transforms with no
  # side-effects that could drift between copies.

  # Rebuilds the LiveView route state for the given route + socket + layout.
  # Delegates to the same IdentityData path that WorldLive uses for identity
  # routes (agent_new_form, agents_list, agent_detail, agent_config).
  defp state_for_route(route, socket, layout) do
    route
    |> Ezagent.World.IdentityData.state_for(%{
      workspace_uri: socket.assigns.current_workspace_uri,
      caller_uri: socket.assigns.current_entity_uri,
      caller_caps: Map.get(socket.assigns, :current_caps, MapSet.new()),
      create_error: Map.get(socket.assigns, :agent_create_error)
    })
    |> Map.put("layout", layout)
    |> put_can_manage_layout(socket)
    |> put_command_palette(socket)
  end

  defp put_can_manage_layout(state, socket) do
    workspace_uri = socket.assigns.current_workspace_uri
    caps = Map.get(socket.assigns, :current_caps, MapSet.new())

    Map.put(state, "can_manage_layout", can_manage_layout?(workspace_uri, caps))
  end

  # Only the sessions_table route is user-arrangeable; agent routes are
  # synthetic single-slot layouts where managing layout is a no-op.
  defp can_manage_layout?(_workspace_uri, _caps), do: false

  defp put_command_palette(state, socket) do
    Map.put(
      state,
      "cmdk",
      Ezagent.World.CommandPaletteData.state(socket.assigns, "", false)
    )
  end

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

  defp short_session_name(%URI{} = uri) do
    Ezagent.URI.name!(uri)
  rescue
    _ -> URI.to_string(uri)
  end

  defp short_session_name(str) when is_binary(str) do
    case Ezagent.URI.parse(str) do
      {:ok, uri} -> short_session_name(uri)
      _ -> str
    end
  end

  defp short_session_name(other), do: inspect(other)

  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason), do: inspect(reason)
end
