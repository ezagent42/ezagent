defmodule Ezagent.World.ConversationActions do
  @moduledoc """
  Socket-side conversation dispatch handlers for the world plugin
  (LV→world parity migration PR-1).

  Mirrors the LiveView plugin's `Admin.Compose` pattern: `WorldLive` keeps
  thin `handle_event` clauses and delegates the bodies here, so the shell
  module stays modular as later PRs add more conversation surface. Pure data
  shaping lives in `Ezagent.World.ConversationData`; this module owns the
  `Ezagent.Invocation.dispatch/1` calls + `push_event`/`assign` plumbing and
  returns `{:noreply, socket}` tuples ready to hand back from `WorldLive`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, connected?: 1, push_patch: 2]

  require Logger

  alias Ezagent.ActionSet.Session.Membership
  alias Ezagent.Invocation
  alias Ezagent.Socialware.SessionReads
  alias Ezagent.World.ConversationData
  alias Ezagent.World.ConversationRoutingForm
  alias EzagentDomainInstanceMessage.Routing.MentionRouting

  @doc """
  Route a `world:dispatch` conversation action to its handler (the dispatcher
  `WorldLive` delegates ALL conversation actions here, so the LiveView shell
  stays a thin host as the conversation surface grows). Each clause parses the
  `session_uri` arg then calls the matching action; an unknown action or a
  malformed session URI yields an error status. Read-only actions
  (`chat.load_older`/`chat.mark_displayed`) silently no-op on a bad URI.
  """
  @spec handle_dispatch(Phoenix.LiveView.Socket.t(), String.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_dispatch(socket, "chat.send", %{"session_uri" => sid, "text" => text} = args)
      when is_binary(text) do
    grants = Map.get(args, "grants", [])
    with_session(socket, sid, &send_message(socket, &1, text, grants))
  end

  def handle_dispatch(socket, "chat.load_older", %{"session_uri" => sid, "before" => before})
      when is_binary(before) do
    with_session(socket, sid, &load_older(socket, &1, before), on_error: {:noreply, socket})
  end

  def handle_dispatch(socket, "chat.mark_displayed", %{"session_uri" => sid, "msg_id" => mid})
      when is_binary(mid) and mid != "" do
    with_session(socket, sid, &mark_displayed(socket, &1, mid), on_error: {:noreply, socket})
  end

  def handle_dispatch(socket, "session.switch", %{"session_uri" => sid}) do
    with_session(socket, sid, fn uri ->
      Ezagent.World.ConversationSessionState.switch_session(socket, uri)
    end)
  end

  def handle_dispatch(
        socket,
        "session.agent_admission.begin",
        %{"session_uri" => sid, "role_name" => role_name}
      )
      when is_binary(role_name) do
    Ezagent.World.AgentAdmissionActions.begin(socket, sid, role_name)
  end

  def handle_dispatch(
        socket,
        "session.agent_admission.complete",
        %{"session_uri" => sid, "role_name" => role_name, "attempt_id" => attempt_id}
      )
      when is_binary(role_name) and is_binary(attempt_id) do
    Ezagent.World.AgentAdmissionActions.complete(socket, sid, role_name, attempt_id)
  end

  def handle_dispatch(
        socket,
        "session.agent_admission.cancel",
        %{"session_uri" => sid, "role_name" => role_name, "attempt_id" => attempt_id}
      )
      when is_binary(role_name) and is_binary(attempt_id) do
    Ezagent.World.AgentAdmissionActions.cancel(socket, sid, role_name, attempt_id)
  end

  def handle_dispatch(socket, "session.invite", %{"session_uri" => sid, "member" => member})
      when is_binary(member) do
    with_session(socket, sid, &invite_member(socket, &1, member))
  end

  def handle_dispatch(
        socket,
        "session.remove_participant",
        %{"session_uri" => sid, "participant" => participant}
      )
      when is_binary(participant) do
    with_session(socket, sid, &remove_participant(socket, &1, participant))
  end

  def handle_dispatch(
        socket,
        "session.socialware.uninstall",
        %{"session_uri" => sid, "ref" => ref}
      )
      when is_binary(ref) do
    with_session(socket, sid, fn session_uri ->
      uninstall_socialware(socket, session_uri, ref)
    end)
  end

  def handle_dispatch(
        socket,
        "session.assign_role",
        %{"session_uri" => sid, "member" => member, "role_name" => role_name}
      )
      when is_binary(member) and is_binary(role_name) do
    with_session(socket, sid, &assign_role(socket, &1, member, role_name))
  end

  def handle_dispatch(socket, "session.create", %{"short_name" => short_name} = args)
      when is_binary(short_name) do
    create_session(
      socket,
      short_name,
      Map.get(args, "template_name", "default"),
      Map.get(args, "socialware_ref"),
      socialware_revision(args),
      socialware_install_config(args)
    )
  end

  def handle_dispatch(socket, "session.fork_config", %{"session_uri" => sid} = args) do
    with_session(socket, sid, &Ezagent.World.SessionForkAction.fork_config(socket, &1, args))
  end

  def handle_dispatch(socket, "session.publish_template", %{"session_uri" => sid, "name" => name})
      when is_binary(name) do
    with_session(socket, sid, &publish_template(socket, &1, name))
  end

  def handle_dispatch(socket, "session.view.switch", %{"session_uri" => sid, "view" => view})
      when is_binary(view) do
    with_session(socket, sid, &switch_view(socket, &1, view))
  end

  def handle_dispatch(socket, "session.pty.open", %{"session_uri" => sid, "agent" => agent})
      when is_binary(agent) do
    Ezagent.World.AgentAdmissionActions.open_pty(socket, sid, agent)
  end

  def handle_dispatch(socket, "session.orchestrator.restart", %{"session_uri" => sid}) do
    with_session(socket, sid, &restart_orchestrator(socket, &1))
  end

  def handle_dispatch(socket, "turn.claim", %{"session_uri" => sid, "turn_id" => turn_id})
      when is_binary(turn_id) do
    with_session(socket, sid, &dispatch_turn_claim(socket, &1, turn_id))
  end

  def handle_dispatch(socket, "turn.settle", %{"session_uri" => sid, "turn_id" => turn_id})
      when is_binary(turn_id) do
    with_session(
      socket,
      sid,
      &dispatch_session_action(socket, &1, :turn, :settle, %{turn_id: turn_id})
    )
  end

  def handle_dispatch(socket, "surface.approve", %{"session_uri" => sid, "version" => version}) do
    with_session(socket, sid, &dispatch_surface_approve(socket, &1, version))
  end

  def handle_dispatch(socket, "supervisor.verdict", %{"session_uri" => sid} = args) do
    with_session(socket, sid, &dispatch_supervisor_verdict(socket, &1, args))
  end

  def handle_dispatch(socket, "session.routing.add", %{"session_uri" => sid, "rule" => rule})
      when is_map(rule) do
    with_session(socket, sid, &add_routing_rule(socket, &1, rule))
  end

  def handle_dispatch(socket, "session.routing.toggle", %{"session_uri" => sid} = args) do
    with_session(socket, sid, &toggle_routing_rule(socket, &1, args))
  end

  def handle_dispatch(socket, _action, _args) do
    {:noreply, assign(socket, :last_dispatch_status, "error:unsupported_action")}
  end

  # Parse the `session_uri` arg, then run `fun` with it. On a malformed URI use
  # `opts[:on_error]` (default: a `bad_session_uri` status).
  defp with_session(socket, sid, fun, opts \\ []) do
    case Ezagent.URI.new!(sid) do
      %URI{scheme: "session"} = uri -> fun.(uri)
      _ -> on_session_error(socket, opts)
    end
  rescue
    ArgumentError -> on_session_error(socket, opts)
  end

  defp on_session_error(socket, opts) do
    Keyword.get(
      opts,
      :on_error,
      {:noreply, assign(socket, :last_dispatch_status, "error:bad_session_uri")}
    )
  end

  # Max attachments per message — server-enforced here (never trusts the client),
  # mirroring the LV `max_entries`. codex PR-2b #4.
  @max_attachments 5
  # Upload-grant TTL (1h) — bounds how long a minted `:attach` grant is replayable.
  @grant_max_age 3_600
  @grant_salt "world_attach"

  @doc """
  Send a chat message into a session via the `:session :send` dispatch
  (`:cast`, mirroring `Admin.Compose.submit/2`). The cast'd message returns
  to the sender through the inbound bridge, so no optimistic insert is done.
  Empty/whitespace text is refused without a dispatch. `grants` are signed
  upload tokens verified before their URIs are attached (PR-2b).
  """
  @spec send_message(Phoenix.LiveView.Socket.t(), URI.t(), String.t(), [String.t()]) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def send_message(socket, session_uri, text, grants \\ [])

  def send_message(socket, %URI{} = session_uri, text, grants)
      when is_binary(text) and is_list(grants) do
    caller = socket.assigns.current_entity_uri
    caps = Ezagent.World.PresenterCaps.load(socket)
    attachments = verify_grants(socket, grants, caller, session_uri)

    if String.trim(text) == "" and attachments == [] do
      {:noreply, assign(socket, :last_dispatch_status, "error:empty_message")}
    else
      # A session can be cold after the asynchronous Hello socialware install
      # (or after a service restart). Reuse the authenticated self-join path to
      # hydrate it before dispatching, rather than sending to a dead actor.
      socket = self_join(socket, session_uri)
      msg = ConversationData.build_message(caller, text, session_uri, attachments)
      target = Ezagent.URI.with_action(session_uri, :session, :send)

      result =
        Invocation.dispatch(%Invocation{
          target: target,
          mode: :cast,
          args: %{message: msg},
          ctx: %{caller: caller, authenticated_principal: caller, caps: caps, reply: :ignore},
          origin: :authenticated_external
        })

      case result do
        :ok ->
          {:noreply, assign(socket, :last_dispatch_status, "ok")}

        {:ok, _} ->
          {:noreply, assign(socket, :last_dispatch_status, "ok")}

        {:error, reason} ->
          {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
      end
    end
  end

  @doc """
  Page history backwards and push the older rows to the island for prepend.

  The `caller` (the viewing entity) is threaded so the pagination read is
  authorized at the `SessionReads` chokepoint — previously this paged the store
  with NO authorization, so a non-member could deep-link and scroll back through
  a conversation they were never in. A non-member now gets an empty page.
  """
  @spec load_older(Phoenix.LiveView.Socket.t(), URI.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def load_older(socket, %URI{} = session_uri, before) when is_binary(before) do
    {older, next_cursor} =
      ConversationData.load_older(
        session_uri,
        Map.get(socket.assigns, :current_entity_uri),
        before,
        # Lazy per-viewer error-card ctx (G5 source 2) — only resolved when a
        # paged message actually carries a structured agent-error payload.
        Ezagent.World.ErrorCards.live_viewer_ctx(socket)
      )

    {:noreply,
     push_event(socket, "chat:older", %{"messages" => older, "oldest_cursor" => next_cursor})}
  end

  @doc """
  Fire-and-forget read marker (parity: `mark_displayed`). Best-effort — never
  surfaces an error to the user.
  """
  @spec mark_displayed(Phoenix.LiveView.Socket.t(), URI.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def mark_displayed(socket, %URI{} = session_uri, msg_id)
      when is_binary(msg_id) and msg_id != "" do
    _ =
      Ezagent.Session.ReadMarker.mark(
        session_uri,
        socket.assigns.current_entity_uri,
        msg_id,
        :displayed
      )

    {:noreply, socket}
  end

  @doc """
  Create a new session in the caller's current workspace via
  `Ezagent.Workspace.create_session/3`, then open its `?session=` deep-link.
  """
  @spec create_session(
          Phoenix.LiveView.Socket.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          Ezagent.World.SocialwareInstall.revision() | nil,
          map()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def create_session(
        socket,
        short_name,
        template_name,
        socialware_ref \\ nil,
        revision \\ nil,
        install_config \\ %{}
      )
      when is_binary(short_name) and is_binary(template_name) do
    workspace_uri = socket.assigns.current_workspace_uri
    caller = socket.assigns.current_entity_uri
    # Session names are URI path segments, so collapse whitespace and reject
    # remaining URI-structural chars with a clear error.
    short_name = sanitize_short_name(short_name)
    template_name = String.trim(template_name)

    cond do
      short_name == "" ->
        {:noreply, push_session_create_error(socket, :short_name_required)}

      not uri_safe_short_name?(short_name) ->
        {:noreply, push_session_create_error(socket, :invalid_short_name)}

      template_name == "" ->
        {:noreply, push_session_create_error(socket, :template_required)}

      not match?(%URI{scheme: "workspace"}, workspace_uri) ->
        {:noreply, push_session_create_error(socket, :invalid_workspace)}

      true ->
        case Ezagent.World.SocialwareInstall.prepare_create_template(
               workspace_uri,
               caller,
               template_name,
               socialware_ref,
               revision,
               install_config
             ) do
          {:ok, create_template_name} ->
            do_create_session(socket, workspace_uri, caller, short_name, create_template_name)

          {:error, reason} ->
            {:noreply, push_session_create_error(socket, reason)}
        end
    end
  end

  # Content-hash-addressed install (P1 §O-1) — a catalog install intent may carry
  # the def's EXACT revision identity so the install pins the revision the user
  # saw, not a same-named local def. `socialware_config_id` is the revision
  # resolver key; `socialware_content_hash` (optional) is the env-stable identity
  # cross-checked at resolution. Absent → nil → the legacy bare-name path.
  defp socialware_revision(args) when is_map(args) do
    case Map.get(args, "socialware_config_id") do
      config_id when is_binary(config_id) and config_id != "" ->
        %{config_id: config_id, content_hash: Map.get(args, "socialware_content_hash")}

      _ ->
        nil
    end
  end

  defp socialware_install_config(args) when is_map(args) do
    case Map.get(args, "role_slots") do
      role_slots when is_list(role_slots) -> %{"role_slots" => role_slots}
      _ -> %{}
    end
  end

  defp do_create_session(socket, workspace_uri, caller, short_name, template_name) do
    caller_caps = Ezagent.World.PresenterCaps.load(socket)
    create_session = &Ezagent.Workspace.create_session/3

    create_with_caller_caps = fn target_workspace, args, ctx ->
      create_session.(
        target_workspace,
        args,
        Map.put(ctx, :caps, caller_caps)
      )
    end

    case create_session_result(
           workspace_uri,
           caller,
           short_name,
           template_name,
           create_with_caller_caps
         ) do
      {:ok, %URI{} = session_uri} ->
        # rev6 / #912 — the session returned here is OWNER-ONLY. Its declared team
        # (`Definition.roles`) is materialized by the post-create
        # socialware-install transaction that `Workspace.create_session` fires,
        # NOT inside the create. We deep-link immediately, so a message sent to a
        # declared `fill: :agent` role during that window has no receiver: routing
        # surfaces `[:ezagent, :session, :route_provision, :role_not_installed]`
        # (loud) rather than delivering. TODO(#1294): show an "installing…" state
        # and surface `:role_not_installed` in the UI — a server-side-only log is
        # a silent drop at a user-facing surface (Invariant #9).
        # Session selection stays route-driven: `handle_params/3` is the one
        # canonical producer of the full conversation state. The separate
        # completion event only clears the create form promptly; it does not
        # let a stale client-side session state choose the active conversation.
        # Materialize the URI string in a binding (not inline in the payload map)
        # so the map line stays off the unify-uri-query `uri_string_key` scan —
        # matching the `caller_str`/`session_str` convention in `verify_grants/4`.
        session_uri_str = URI.to_string(session_uri)

        {:noreply,
         socket
         |> assign(:last_dispatch_status, "ok")
         |> push_event("world:session_created", %{"session_uri" => session_uri_str})
         |> push_patch(to: "/sessions?session=#{encode_param(session_uri)}")}

      {:error, reason} ->
        {:noreply, push_session_create_error(socket, reason)}
    end
  end

  # Publish the current session as a reusable SessionTemplate (via the orchestrator
  # `save_template_as` tool, which snapshots the socialware definition + config and
  # — through `capture_seed_surface` — the current page, but NOT the chat history).
  # The template lands in the SESSION's workspace so its socialware definition
  # resolves; it then appears in the New-session Template dropdown.
  @spec publish_template(Phoenix.LiveView.Socket.t(), URI.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  defp publish_template(socket, %URI{} = session_uri, name) do
    caller = socket.assigns.current_entity_uri
    workspace_uri = Ezagent.Capability.workspace_of(session_uri)
    trimmed = String.trim(name)

    cond do
      trimmed == "" ->
        {:noreply,
         socket
         |> assign(:last_dispatch_status, "error:template_name_required")
         |> push_event("world:state", %{"publish_error" => "请填写发布物名称"})}

      not publish_authorized?(caller, session_uri) ->
        # #224 Blocker B (Option B): the world publish borrows the ADMIN operator
        # authority below, so it MUST be gated here by an un-forgeable identity
        # check — only the session OWNER (or system admin) may publish. A
        # non-owner participant is refused BEFORE any operator dispatch, so the
        # operator authority can never be borrowed by a non-owner. No owner cap
        # is granted on this path.
        {:noreply,
         socket
         |> assign(:last_dispatch_status, "error:unauthorized")
         |> push_event("world:state", %{"publish_error" => "只有会话所有者可以发布模板"})}

      true ->
        # #224 Blocker B — RESOLVED via Option B (no owner cap escalation). Route
        # the publish through the SAME admin-operator authority the
        # orchestrator/chat-publish path uses by passing the admin URI as
        # principal. `Ezagent.Session.Config.execute/4`'s `:template_write`
        # admission gate AND the executor's own write-cap check both run
        # `with_admin_operator(admin)` + `operator_dispatch_caps(admin) = ∅`, so
        # the DispatchPolicyAdapter materializes the exact admin action-cap — no
        # owner cap is required or granted for authority. The template still lands
        # in the SESSION's workspace (`derive_context` derives it from
        # `session_uri`, not the principal), and `save_template_as` grants the
        # OWNER (not the admin) the per-template instantiate cap. Owner-gated
        # above. See `Ezagent.World.PublishTemplateOwnerGateTest`.
        case Ezagent.Session.Config.execute(
               "save_template_as",
               %{"new_name" => trimmed},
               Ezagent.Entity.User.admin_uri(),
               session_uri
             ) do
          {:ok, %URI{}} ->
            {:noreply,
             socket
             |> assign(:last_dispatch_status, "ok")
             |> push_world_state(%{
               "publish_notice" => "已发布为模板",
               "templates" =>
                 Ezagent.World.WorkspacePluginData.session_template_names(caller, workspace_uri)
             })}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:last_dispatch_status, "error:#{reason(reason)}")
             |> push_event("world:state", %{"publish_error" => "发布失败：#{reason(reason)}"})}
        end
    end
  end

  # #224 Blocker B (Option B) owner-gate. The world publish runs under the admin
  # operator authority, so it MUST be gated by an identity the caller cannot
  # forge: a publish is authorized iff the caller is the session owner (compared
  # by canonical URI) or the system admin. A nil/anonymous caller is refused —
  # never crashes the handler.
  @spec publish_authorized?(URI.t() | nil, URI.t()) :: boolean()
  defp publish_authorized?(%URI{} = caller, %URI{} = session_uri) do
    session_owner?(caller, session_uri) or Ezagent.Identity.admin?(caller)
  end

  defp publish_authorized?(_caller, _session_uri), do: false

  defp session_owner?(%URI{} = caller, %URI{} = session_uri) do
    case Ezagent.Entity.Session.owner(session_uri) do
      {:ok, %URI{} = owner} ->
        Ezagent.URI.stable_key(owner) == Ezagent.URI.stable_key(caller)

      _ ->
        false
    end
  end

  # No silent drop (Invariant #9): surface a session-create failure on the
  # sessions table via the SAME `world:state` channel the route renders from
  # (the React `SessionsTable` reads `state.create_error` and shows a banner).
  # F3: before this, a create error only set the `data-last-dispatch` attribute
  # and the operator saw nothing. The success path immediately pushes caller-scoped
  # state, which carries no `create_error`, so the banner clears.
  defp push_session_create_error(socket, reason) do
    socket
    |> assign(:last_dispatch_status, "error:#{reason(reason)}")
    |> push_event("world:state", %{"create_error" => session_create_error_message(reason)})
  end

  @doc false
  @spec session_create_error_message(term()) :: String.t()
  def session_create_error_message(:short_name_required), do: "请填写会话名称"
  def session_create_error_message(:template_required), do: "请选择会话模板"
  def session_create_error_message(:invalid_workspace), do: "无效的工作区"

  def session_create_error_message(:invalid_short_name),
    do: "会话名称含无效字符（如 : / ? # @ [ ]），请改用字母、数字、中文或连字符"

  def session_create_error_message({:invalid_template, _}),
    do: "该模板不能从这里直接创建（缺少额外参数）——请改选 default 或该模板自己的入口"

  def session_create_error_message(:unauthorized), do: "没有创建会话的权限"
  def session_create_error_message(:cross_workspace_denied), do: "跨工作区操作被拒绝"

  def session_create_error_message(reason) do
    if unsupported_claude_dev_channels?(reason) do
      "创建会话失败：当前 Claude Code 不支持 cc orchestrator 所需的开发通道参数，请升级 Claude Code 或改用 codex flavor。"
    else
      "创建会话失败：#{reason(reason)}"
    end
  end

  defp unsupported_claude_dev_channels?({:unsupported_claude_dev_channels, _}), do: true

  defp unsupported_claude_dev_channels?(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.any?(&unsupported_claude_dev_channels?/1)
  end

  defp unsupported_claude_dev_channels?(_), do: false

  # Trim + collapse any run of (Unicode) whitespace to a single "-", so a name
  # like "hello world" becomes the URI-safe "hello-world" instead of crashing the
  # `session://<ws>/<template>/<name>` parse. Non-whitespace chars (incl. CJK) are
  # untouched here; `uri_safe_short_name?/1` rejects the few that still break a URI.
  @doc false
  @spec sanitize_short_name(String.t()) :: String.t()
  def sanitize_short_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.replace(~r/\s+/u, "-")
  end

  # A session name is a URI path segment, and `Ezagent.URI.new!` parses STRICTLY —
  # it rejects spaces, CJK, and other non-ASCII / reserved chars (not just the
  # gen-delims). So allow only the URI "unreserved" set `[A-Za-z0-9-._~]`; anything
  # else (incl. CJK) gets a clear :invalid_short_name error instead of a raw
  # ArgumentError crash. (CJK session names would need percent-encoding + a display
  # layer that decodes them — a separate, larger change, not done here.)
  @doc false
  @spec uri_safe_short_name?(String.t()) :: boolean()
  def uri_safe_short_name?(name) when is_binary(name) do
    name != "" and Regex.match?(~r/\A[A-Za-z0-9._~-]+\z/, name)
  end

  @doc false
  @spec create_session_result(
          URI.t(),
          URI.t(),
          String.t(),
          String.t(),
          (URI.t(), map(), map() -> term())
        ) ::
          {:ok, URI.t()} | {:error, term()}
  def create_session_result(workspace_uri, caller, short_name, template_name, create)
      when is_function(create, 3) do
    case create.(
           workspace_uri,
           %{short_name: short_name, template_name: template_name},
           %{caller: caller, authenticated_principal: caller, caps: MapSet.new()}
         ) do
      {:ok, %{session_uri: %URI{} = session_uri}} -> {:ok, session_uri}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_create_session_result, other}}
    end
  rescue
    exception -> {:error, {:create_session_exception, exception}}
  catch
    :exit, reason -> {:error, {:create_session_exit, reason}}
  end

  @doc """
  Switch the active session view. The whitelist is the caller-aware registry set
  (`ConversationData.session_view_ids/2`) — the SAME source that produces the
  visible tabs — so a view a caller can't see is neither a tab nor switchable-to
  (no bypass of the `authorize_view/3` cap gate). An id outside that set is
  rejected with `error:bad_view`.
  """
  @spec switch_view(Phoenix.LiveView.Socket.t(), URI.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def switch_view(socket, %URI{} = session_uri, view) when is_binary(view) do
    caller = socket.assigns.current_entity_uri

    if view in ConversationData.session_view_ids(session_uri, caller) do
      {:noreply, push_world_state(socket, view_switch_updates(socket, session_uri, view))}
    else
      {:noreply, assign(socket, :last_dispatch_status, "error:bad_view")}
    end
  end

  # Switching to the native kanban board tab loads the session's boards
  # (`KanbanData.session_boards/2` — caller-cap filtered, session-workspace
  # scoped) so the rich `<Kanban>` mounts WITH data instead of the plugin-page
  # Miro-config placeholder. With ≥1 board, auto-select the first: merge its full
  # snapshot (kanban_uri + tree + config + miro), then re-assert the session-scoped
  # `instances` list. Zero boards → just the empty `instances` + `active_view`
  # (frontend renders its own empty/config state). fail-safe: any error falls back
  # to a plain active_view switch so the tab never wedges.
  defp view_switch_updates(socket, %URI{} = session_uri, view) do
    case Ezagent.World.PluginPageRegistry.by_session_view(view) do
      %{session_view: %{state_builder: builder}} ->
        case session_view_state(builder, session_uri, session_view_ctx(socket)) do
          {:ok, state} -> Map.put(state, "active_view", view)
          :error -> builtin_view_switch_updates(session_uri, view)
        end

      nil ->
        builtin_view_switch_updates(session_uri, view)
    end
  end

  defp session_view_state(builder, session_uri, ctx) do
    case apply(builder, :session_state_for, [session_uri, ctx]) do
      state when is_map(state) -> {:ok, state}
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp session_view_ctx(socket) do
    %{
      caller_uri: socket.assigns.current_entity_uri,
      caller_caps: Ezagent.World.PresenterCaps.load(socket),
      workspace_uri: socket.assigns.current_workspace_uri
    }
  end

  defp builtin_view_switch_updates(%URI{} = session_uri, "external_mirror") do
    %{
      "active_view" => "external_mirror",
      "bindings" => Ezagent.World.AdminData.external_mirror_bindings_for(session_uri)
    }
  end

  defp builtin_view_switch_updates(_session_uri, view), do: %{"active_view" => view}

  @doc """
  Switch the conversation panel to the PTY view for a member agent.

  This is the ONE path besides `switch_view/3` that sets `active_view`, and it is
  hard-wired to `"pty"` only. That is safe today because the pty view
  (`EzagentDomainUi.Pty.TerminalView`) declares no `view_behavior/0` — it is never
  cap-gated — and the React client only activates ids present in the enumerated
  `views` (falling back otherwise), so no gated view can be exposed through here.
  If pty ever GROWS a `view_behavior`, this must route through
  `ConversationData.session_view_ids/2` like `switch_view/3`
  (`view_cap_gate_regression_test.exs` locks that assumption).
  """
  @spec switch_to_pty(Phoenix.LiveView.Socket.t(), URI.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def switch_to_pty(socket, %URI{} = session_uri, agent_str) when is_binary(agent_str) do
    # `agent_str` is CLIENT input (the `session.pty.open` event's "agent" field),
    # so this is a full PTY read exit — it subscribes to the live output stream
    # and pushes liveness/phase. Without the gate any authenticated user could
    # open any agent's terminal in any workspace from inside a conversation.
    # Same authority as every other exit: the agent's Manage cap.
    caps = Ezagent.World.PresenterCaps.load(socket)
    holder = socket.assigns.current_entity_uri

    case parse_agent_uri(agent_str) do
      {:ok, %URI{} = agent_uri} ->
        if Ezagent.Domain.Pty.Access.may_read?(holder, agent_uri, caps) do
          if pty_target_in_session?(session_uri, agent_uri) do
            # A session can retain an agent membership across a node restart while
            # the agent's subprocess is cold. Opening an authorized terminal is
            # the demand boundary: revive the Agent first so Sandbox.activate/2
            # restores its PTY (or the unauthenticated Codex login PTY) before we
            # subscribe and render the terminal surface.
            case Ezagent.Domain.Agent.ensure_deliverable(agent_uri) do
              {:ok, _status} ->
                subscribe_pty(agent_uri)
                push_pty_view(socket, agent_uri)

              {:error, _reason} ->
                {:noreply, assign(socket, :last_dispatch_status, "error:agent_unavailable")}
            end
          else
            {:noreply,
             assign(socket, :last_dispatch_status, "error:session_pty_target_unrelated")}
          end
        else
          {:noreply, assign(socket, :last_dispatch_status, "error:unauthorized")}
        end

      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_agent_uri")}
    end
  end

  defp pty_target_in_session?(%URI{} = session_uri, %URI{} = agent_uri) do
    agent_uri_str = URI.to_string(agent_uri)

    Enum.any?(Ezagent.Entity.Session.session_member_uris(session_uri), fn member_uri ->
      same_uri?(member_uri, agent_uri)
    end) or
      Enum.any?(
        EzagentDomainInstanceMessage.SessionCreator.AgentAdmission.list(session_uri),
        fn admission ->
          Map.fetch!(admission, :status) in [:authenticating, :materializing] and
            Map.get(admission, :provisional_agent_uri) == agent_uri_str
        end
      )
  end

  defp push_pty_view(socket, %URI{} = agent_uri) do
    {:noreply,
     push_world_state(socket, %{
       "active_view" => "pty",
       "active_pty_agent_uri" => uri_string(agent_uri),
       "agent_uri" => uri_string(agent_uri),
       "agent_detail_path" =>
         "/identities/agents/#{URI.encode_www_form(URI.to_string(agent_uri))}",
       "agent_status" => jsonable(Ezagent.Domain.Agent.lifecycle_status(agent_uri)),
       "pty_alive" => Ezagent.Domain.Pty.alive?(agent_uri),
       "pty_phase" => pty_phase(agent_uri),
       # The process may have emitted its first screen before the browser's
       # PubSub subscription is installed (notably `codex login`).  Replay the
       # bounded server buffer in the state update so mounting the terminal
       # cannot lose that initial output.
       "pty_initial_buffer" => pty_initial_buffer(agent_uri)
     })}
  end

  defp pty_initial_buffer(%URI{} = agent_uri) do
    case Ezagent.Domain.Pty.Server.snapshot_buffer(agent_uri) do
      {:ok, buffer} when is_binary(buffer) -> buffer
      _ -> ""
    end
  rescue
    _ -> ""
  end

  @doc """
  Restart a session orchestrator for an admin caller.

  This avoids caller-side cap enumeration/matching; PR #154 keeps cap checks
  at dispatch chokepoints, and this repair helper is not a dispatch action.
  """
  @spec restart_orchestrator(Phoenix.LiveView.Socket.t(), URI.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def restart_orchestrator(socket, %URI{} = session_uri) do
    if caller_can_restart_orchestrator?(socket, session_uri) do
      workspace_uri = Ezagent.Capability.workspace_of(session_uri)

      case EzagentDomainInstanceMessage.repair_orchestrator(
             session_uri,
             {workspace_uri, socket.assigns.current_entity_uri}
           ) do
        {:ok, ^session_uri, _meta} ->
          {:noreply, assign(socket, :last_dispatch_status, "ok")}

        {:error, reason} ->
          {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
      end
    else
      {:noreply, assign(socket, :last_dispatch_status, "error:unauthorized")}
    end
  end

  @doc "Claim a socialware turn for internal review through the Turn behavior."
  @spec dispatch_turn_claim(Phoenix.LiveView.Socket.t(), URI.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def dispatch_turn_claim(socket, %URI{} = session_uri, turn_id) when is_binary(turn_id) do
    dispatch_session_action(socket, session_uri, :turn, :claim, %{
      turn_id: turn_id,
      by: socket.assigns.current_entity_uri
    })
  end

  @doc "Approve a surface version through the Surface behavior."
  @spec dispatch_surface_approve(Phoenix.LiveView.Socket.t(), URI.t(), term()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def dispatch_surface_approve(socket, %URI{} = session_uri, version) do
    case parse_positive_integer(version) do
      {:ok, version} ->
        dispatch_session_action(socket, session_uri, :surface, :approve, %{version: version})

      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_version")}
    end
  end

  @doc "Submit a B2 supervisor verdict through the session approval workflow."
  @spec dispatch_supervisor_verdict(Phoenix.LiveView.Socket.t(), URI.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def dispatch_supervisor_verdict(socket, %URI{} = session_uri, args) when is_map(args) do
    turn_id = Map.get(args, "turn_id", "")
    verdict = Map.get(args, "verdict", "approve")

    if is_binary(turn_id) and turn_id != "" do
      dispatch_session_action(socket, session_uri, :supervisor_approval, :submit_verdict, %{
        turn_id: turn_id,
        responsibility: Map.get(args, "responsibility", "supervisor"),
        verdict: normalize_verdict_arg(verdict),
        quorum_policy: Map.get(args, "quorum_policy", %{"type" => "any_one"}),
        arbiter: Map.get(args, "arbiter")
      })
    else
      {:noreply, assign(socket, :last_dispatch_status, "error:bad_turn_id")}
    end
  end

  defp dispatch_session_action(socket, %URI{} = session_uri, behavior_prefix, action, args)
       when is_atom(behavior_prefix) and is_atom(action) and is_map(args) do
    caller = socket.assigns.current_entity_uri
    caps = Ezagent.World.PresenterCaps.load(socket)

    result =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.with_action(session_uri, behavior_prefix, action),
        mode: :call,
        args: args,
        ctx: %{
          caller: caller,
          authenticated_principal: caller,
          caps: caps,
          reply: {:caller_inbox, self()}
        },
        origin: :authenticated_external
      })

    case result do
      {:ok, _} ->
        {:noreply, assign(socket, :last_dispatch_status, "ok")}

      :ok ->
        {:noreply, assign(socket, :last_dispatch_status, "ok")}

      {:error, reason} ->
        user_can_fix = Ezagent.Identity.AdminAuthority.admin?(caller, caps)
        fix_owner_name = resolve_founder_name(socket)

        socket
        |> assign(:last_dispatch_status, "error:#{reason(reason)}")
        |> Ezagent.World.ErrorRenderer.push_dispatch_error_card(
          reason,
          user_can_fix: user_can_fix,
          fix_owner_display_name: fix_owner_name
        )
        |> then(&{:noreply, &1})
    end
  end

  defp resolve_founder_name(socket) do
    Ezagent.World.ErrorCards.founder_display_name(Map.get(socket.assigns, :current_workspace_uri))
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_positive_integer(_), do: :error

  defp normalize_verdict_arg(value) when value in ["reject", "rejected"], do: :reject
  defp normalize_verdict_arg(_), do: :approve

  @doc "Add a session-scoped mention-routing rule."
  @spec add_routing_rule(Phoenix.LiveView.Socket.t(), URI.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def add_routing_rule(socket, %URI{} = session_uri, params) when is_map(params) do
    with {:ok, leaf_matcher} <- ConversationRoutingForm.build_matcher(params),
         receivers when is_list(receivers) and receivers != [] <-
           ConversationRoutingForm.parse_receivers(Map.get(params, "receivers", "")),
         :ok <- ConversationRoutingForm.revalidate_matcher_arg(socket, params),
         :ok <- ConversationRoutingForm.revalidate_receivers(socket, receivers),
         matcher = ConversationRoutingForm.wrap_in_session(leaf_matcher, session_uri),
         {:ok, _} <-
           dispatch_session_routing(socket, session_uri, :add_rule, %{
             table: MentionRouting,
             matcher_json: Ezagent.Routing.Matcher.to_json(matcher),
             receivers: receivers
           }) do
      {:noreply,
       socket
       |> assign(:last_dispatch_status, "ok")
       |> push_world_state(%{
         "routing_rules" => ConversationData.list_session_routing_rules(session_uri)
       })}
    else
      [] ->
        {:noreply, assign(socket, :last_dispatch_status, "error:receivers_required")}

      {:error, reason} ->
        {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
    end
  end

  @doc "Enable or disable a session-scoped routing rule."
  @spec toggle_routing_rule(Phoenix.LiveView.Socket.t(), URI.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def toggle_routing_rule(socket, %URI{} = session_uri, args) when is_map(args) do
    with {id, ""} <- Integer.parse(to_string(Map.get(args, "id", ""))),
         {:ok, table} <- safe_table_atom(Map.get(args, "table")),
         action = if(Map.get(args, "enabled") == "true", do: :disable_rule, else: :enable_rule),
         {:ok, _} <-
           dispatch_session_routing(socket, session_uri, action, %{id: id, table: table}) do
      {:noreply,
       socket
       |> assign(:last_dispatch_status, "ok")
       |> push_world_state(%{
         "routing_rules" => ConversationData.list_session_routing_rules(session_uri)
       })}
    else
      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_rule_id")}

      {:error, reason} ->
        {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
    end
  end

  @doc """
  Invite an entity into the in-view session (LV→world parity PR-3b, mirroring
  `Admin.Invite.dispatch_invite/4`). Dispatches `:session :join` with the
  INVITED member; the inviter's own `:join` authority comes from their
  self-join on mount (`self_join/2` provisions an owner-rooted `:join` cap that
  the runtime reads from the live slice). On success, mounts the invited
  member's participation tier (best-effort, no-op for agents) and pushes the
  refreshed member list. A malformed URI or an unauthorized invite degrades to
  an error status — the panel just doesn't gain the member.
  """
  @spec invite_member(Phoenix.LiveView.Socket.t(), URI.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def invite_member(socket, %URI{} = session_uri, member_str) when is_binary(member_str) do
    caller = socket.assigns.current_entity_uri
    caps = Ezagent.World.PresenterCaps.load(socket)

    case parse_member_uri(member_str) do
      {:ok, %URI{} = member_uri} ->
        # `:join` requires a LIVE member Kind (`:member_not_registered` else); a
        # registered-but-cold invitee (e.g. a user who hasn't logged in this
        # boot) is spawned from its snapshot first. Best-effort — a never-created
        # URI stays unspawned and the join below fails closed to an error status.
        _ = EzagentDomainInstanceMessage.SessionCreator.demand_spawn_member(member_uri)

        result =
          Invocation.dispatch(%Invocation{
            target: Ezagent.URI.with_action(session_uri, :session, :join),
            mode: :call,
            args: %{member: member_uri},
            ctx: %{caller: caller, authenticated_principal: caller, caps: caps, reply: :ignore},
            origin: :authenticated_external
          })

        case result do
          r when r == :ok or (is_tuple(r) and elem(r, 0) == :ok) ->
            # D1 join 补发(caller-side):participation tier + view caps +
            # mount operate keys —— 被拉进来的成员零刷新可见 tab + 板钥匙。
            _ = Ezagent.Socialware.MemberBackfill.backfill(session_uri, member_uri)
            {:noreply, push_members(assign(socket, :last_dispatch_status, "ok"))}

          {:error, reason} ->
            {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
        end

      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_member_uri")}
    end
  end

  @doc """
  Remove a participant (user / invited agent) from the in-view session (F7 PR-A,
  the QA-pulled remove control re-instated). Dispatches the isomorphic
  `session.remove_participant` action via the SAME domain entry the CLI uses
  (`Ezagent.Session.Participants.remove_participant/3`), so CLI and UI share one
  path. On success the refreshed member list is pushed; removal also fires the
  `{:member_left}` broadcast that other open views converge on (world_live's
  membership handler refreshes their panels). A malformed URI or an unauthorized
  remove degrades to an error status (the panel keeps the member).

  Owner-gated: the session owner (or the participant itself, for self-leave) is
  authorized; a non-owner non-participant viewer is denied. Removing a
  session-SPAWNED worker returns the PR-B stub error.
  """
  @spec remove_participant(Phoenix.LiveView.Socket.t(), URI.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def remove_participant(socket, %URI{} = session_uri, participant_str)
      when is_binary(participant_str) do
    caller = socket.assigns.current_entity_uri
    caps = Ezagent.World.PresenterCaps.load(socket)

    case parse_member_uri(participant_str) do
      {:ok, %URI{} = participant_uri} ->
        if URI.to_string(participant_uri) == URI.to_string(caller) do
          {:noreply, assign(socket, :last_dispatch_status, "error:self_remove_not_allowed")}
        else
          case Ezagent.Session.Participants.remove_participant(
                 session_uri,
                 participant_uri,
                 %{caller: caller, authenticated_principal: caller, caps: caps}
               ) do
            {:ok, _result} ->
              {:noreply, push_members(assign(socket, :last_dispatch_status, "ok"))}

            {:error, reason} ->
              {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
          end
        end

      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_member_uri")}
    end
  end

  @doc "Uninstall session socialware materialization from the management panel."
  @spec uninstall_socialware(Phoenix.LiveView.Socket.t(), URI.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def uninstall_socialware(socket, %URI{} = session_uri, ref) when is_binary(ref) do
    caller = socket.assigns.current_entity_uri
    actor = caller || Ezagent.Entity.User.admin_uri()
    caps = Ezagent.World.PresenterCaps.load(socket)

    definitions = Ezagent.Socialware.Installation.installed_definitions(session_uri)

    case Enum.find(definitions, fn definition -> definition.name == ref end) do
      nil ->
        {:noreply, assign(socket, :last_dispatch_status, "error:unknown_socialware_install")}

      _definition ->
        with true <- match?(%URI{}, caller),
             :ok <- remove_socialware_members(session_uri, definitions, caller, caps),
             :ok <- Ezagent.ActionSet.Session.RoutingPrune.prune_all_for_session(session_uri),
             :ok <- Ezagent.Socialware.Installation.retract_session_installs(session_uri, actor) do
          socket =
            socket
            |> assign(:last_dispatch_status, "ok")
            |> push_session_management_state(session_uri)

          {:noreply, socket}
        else
          false ->
            {:noreply, assign(socket, :last_dispatch_status, "error:missing_caller")}

          {:error, reason} ->
            {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
        end
    end
  end

  defp remove_socialware_members(%URI{} = session_uri, definitions, %URI{} = caller, caps) do
    role_names =
      definitions
      |> List.wrap()
      |> Enum.flat_map(fn definition -> List.wrap(definition.roles) end)
      |> Enum.map(fn role -> Map.get(role, :role_name) end)
      |> Enum.filter(fn role -> is_binary(role) and String.trim(role) != "" end)
      |> Enum.uniq()

    with {:ok, %{members: members}} when is_map(members) <-
           Ezagent.Kind.read(session_uri, :session, spawn: :never) do
      Enum.reduce_while(role_names, :ok, fn role_name, :ok ->
        case member_for_role(members, role_name) do
          nil ->
            {:cont, :ok}

          %URI{} = member_uri ->
            case Ezagent.Session.Participants.remove_participant(session_uri, member_uri, %{
                   caller: caller,
                   authenticated_principal: caller,
                   caps: caps
                 }) do
              {:ok, _result} -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
        end
      end)
    else
      _ -> :ok
    end
  end

  defp member_for_role(members, role_name) when is_map(members) do
    Enum.find_value(members, fn {uri, meta} ->
      if member_role_name(meta) == role_name, do: uri, else: nil
    end)
  end

  defp member_role_name(meta) when is_map(meta),
    do: Map.get(meta, :role_name) || Map.get(meta, "role_name")

  defp member_role_name(_), do: nil

  defp push_session_management_state(socket, %URI{} = session_uri) do
    caller = socket.assigns.current_entity_uri
    members = ConversationData.member_options(caller, session_uri)
    workspace = socket.assigns.current_workspace_uri

    payload = %{
      "members" => members,
      "human_role_slots" => ConversationData.human_role_slots(session_uri),
      "installed_socialwares" => ConversationData.installed_socialwares(session_uri),
      "routing_rules" => ConversationData.list_session_routing_rules(session_uri),
      "routing_entity_candidates" =>
        ConversationData.routing_entity_candidates(caller, workspace, members),
      "invite_candidates" =>
        ConversationData.invite_candidates(session_uri, caller, workspace, members),
      "views" => ConversationData.session_views(session_uri, caller),
      # Chain C — declared agent role slots that could not be materialized (today
      # only "missing credentials"). Mirrors the existing `human_role_slots`
      # shape: `[%{role_name: "...", reason: :missing_credentials}]`. The UI
      # renders a hint in the socialware section so the user knows WHY a role
      # agent is absent (Invariant #9: a server log alone is a silent drop at a
      # user-facing surface).
      "unfilled_agent_role_slots" =>
        EzagentDomainInstanceMessage.SessionCreator.unfilled_agent_role_slots(session_uri),
      "agent_admissions" => ConversationData.agent_admissions(session_uri),
      "degraded_operates_edges" => Ezagent.Socialware.CompositionCaps.degraded_edges(session_uri)
    }

    if connected?(socket), do: push_event(socket, "world:state", payload), else: socket
  end

  @doc """
  Assign an open socialware human role slot to a user member from the world UI.
  """
  @spec assign_role(Phoenix.LiveView.Socket.t(), URI.t(), String.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def assign_role(socket, %URI{} = session_uri, member_str, role_name)
      when is_binary(member_str) and is_binary(role_name) do
    caller = socket.assigns.current_entity_uri
    caps = Ezagent.World.PresenterCaps.load(socket)

    case parse_member_uri(member_str) do
      {:ok, %URI{} = member_uri} ->
        case Ezagent.Session.RoleAssignments.assign_role(session_uri, member_uri, role_name, %{
               caller: caller,
               authenticated_principal: caller,
               caps: caps
             }) do
          {:ok, _assigned} ->
            {:noreply, push_members(assign(socket, :last_dispatch_status, "ok"))}

          {:error, reason} ->
            {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
        end

      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_member_uri")}
    end
  end

  defp parse_member_uri(str) do
    case Ezagent.URI.parse(String.trim(str)) do
      {:ok, %URI{} = uri} -> {:ok, uri}
      _ -> :error
    end
  end

  @doc """
  Re-read the in-view session's members and push them to the React members
  panel (PR-3a inbound membership/presence handler). No-op off the
  conversation route (no session in view).
  """
  @spec push_members(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def push_members(socket) do
    # `push_event` is a no-op on the dead static render, so guard connected? —
    # the initial member list already rides in `data-world-state`.
    if connected?(socket) do
      case socket.assigns[:current_session_uri] do
        %URI{} = session_uri ->
          caller = Map.get(socket.assigns, :current_entity_uri)

          if SessionReads.authorized?(caller, session_uri) do
            members = ConversationData.member_options(caller, session_uri)

            push_event(socket, "members:update", %{
              "members" => members,
              "human_role_slots" => ConversationData.human_role_slots(session_uri),
              "invite_candidates" =>
                ConversationData.invite_candidates(
                  session_uri,
                  caller,
                  socket.assigns.current_workspace_uri,
                  members
                ),
              "routing_entity_candidates" =>
                ConversationData.routing_entity_candidates(
                  caller,
                  socket.assigns.current_workspace_uri,
                  members
                ),
              "agent_admissions" => ConversationData.agent_admissions(session_uri)
            })
          else
            # Unauthorized viewer (e.g. denied `?session=` deep-link): push NO
            # roster — the whole `members:update` payload (members, role slots,
            # invite/routing candidates) is session content. (read-plane-authz F2.)
            socket
          end

        _ ->
          socket
      end
    else
      socket
    end
  end

  @doc """
  Best-effort self-join of the viewing caller to the in-view conversation,
  ported from the LiveView plugin's `SessionContext.maybe_self_join/2` (the
  parity reference). This is what makes the members panel + @mention dropdown
  populate: the conversation read-path (`ConversationData.member_options/1` →
  `Ezagent.Kind.get_slice/2`) reads LIVE slice state, which is empty for a cold
  session even though membership is PERSISTED. Self-joining on view spawns the
  session from its snapshot (so persisted members appear) and makes the viewer
  present.

  Runs only once the socket is `connected?/1` (never on the dead static render)
  and only once per session (deduped via `:self_joined`, mirroring
  `WorldLive`'s `:subscribed_topics` pattern), so repeated `handle_params`
  (e.g. `chat.load_older`) don't re-dispatch.

  Authorization is owner-rooted: `Membership.provision_join_authority/2` grants a
  per-session `:join` cap JIT (owner / existing member / first-non-anon
  owner-claim → granted; anyone else → denied), then the `:session :join`
  dispatch authorizes at the chokepoint. A denial degrades to "observe" — the
  viewer still sees the conversation, just isn't added as a member.
  """
  @spec self_join(Phoenix.LiveView.Socket.t(), URI.t()) :: Phoenix.LiveView.Socket.t()
  def self_join(socket, %URI{} = session_uri) do
    joined = Map.get(socket.assigns, :self_joined, MapSet.new())

    if connected?(socket) and not MapSet.member?(joined, session_uri) do
      socket
      |> assign(:self_joined, MapSet.put(joined, session_uri))
      |> do_self_join(session_uri)
    else
      socket
    end
  end

  defp do_self_join(socket, %URI{} = session_uri) do
    caller = Map.get(socket.assigns, :current_entity_uri)

    case caller do
      %URI{} = caller_uri ->
        # JIT, owner-rooted per-session :join cap (`:sync` so it lands before the
        # dispatch authorizes via the live slice read).
        _ = Ezagent.LocalRuntime.ensure_live(session_uri)
        _ = EzagentDomainInstanceMessage.SessionCreator.demand_spawn_member(caller_uri)
        _ = Membership.provision_join_authority(session_uri, caller_uri)

        # Reload after the synchronous JIT grant so the external envelope
        # carries the newly issued target-signed artifact.
        caps = Ezagent.World.PresenterCaps.load(socket)

        result =
          Invocation.dispatch(%Invocation{
            target: Ezagent.URI.with_action(session_uri, :session, :join),
            mode: :call,
            args: %{member: caller_uri},
            ctx: %{
              caller: caller_uri,
              authenticated_principal: caller_uri,
              caps: caps,
              reply: :ignore
            },
            origin: :authenticated_external
          })

        case result do
          r when r == :ok or (is_tuple(r) and elem(r, 0) == :ok) ->
            # D1 join 补发(caller-side,parity with Invite.ex / maybe_self_join):
            # participation tier + view caps + mount operate keys。Best-effort,
            # no-op for agents.
            _ = Ezagent.Socialware.MemberBackfill.backfill(session_uri, caller_uri)
            assign(socket, :last_join_status, "ok")

          {:error, reason} ->
            # Degrade to observe — the viewer still reads the conversation.
            Logger.debug(fn ->
              "World.self_join: #{URI.to_string(caller_uri)} could not join " <>
                "#{URI.to_string(session_uri)}: #{inspect(reason)} (observe-only)"
            end)

            assign(socket, :last_join_status, "error:#{reason(reason)}")
        end

      _ ->
        socket
    end
  end

  # Verify upload grants (PR-2b anti-laundering, codex #3). Each grant is a
  # `Phoenix.Token` minted by `WorldUploadsController` after a successful
  # `:session :attach` dispatch, binding `uri ↔ caller ↔ session`. A message may
  # only embed a `resource://…/uploads/…` URI whose grant: (a) verifies (MAC +
  # TTL) against THIS endpoint, and (b) was issued to THIS caller for THIS
  # session. A forged/expired/cross-session grant — or a raw URI with no grant —
  # yields nothing, so a client cannot launder an arbitrary uploads URI into a
  # message. At most `@max_attachments` are accepted (server-enforced count).
  defp verify_grants(socket, grants, %URI{} = caller, %URI{} = session_uri) do
    caller_str = URI.to_string(caller)
    session_str = URI.to_string(session_uri)

    grants
    |> Enum.filter(&is_binary/1)
    |> Enum.take(@max_attachments)
    |> Enum.flat_map(&verify_grant(socket, &1, caller_str, session_str))
  end

  defp verify_grants(_socket, _grants, _caller, _session), do: []

  defp verify_grant(socket, grant, caller_str, session_str) do
    case Phoenix.Token.verify(socket, @grant_salt, grant, max_age: @grant_max_age) do
      {:ok, %{"uri" => uri_str, "caller" => ^caller_str, "session" => ^session_str}} ->
        case Ezagent.URI.parse(uri_str) do
          {:ok, %URI{} = uri} -> [uri]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp push_world_state(socket, updates) when is_map(updates) do
    state = Map.merge(Map.get(socket.assigns, :world_state, %{}), updates)

    socket
    |> assign(:world_state, state)
    |> assign(:world_state_json, Jason.encode!(state))
    |> assign(:last_dispatch_status, "ok")
    |> push_event("world:state", updates)
  end

  @doc false
  @spec parse_agent_uri(String.t()) :: {:ok, URI.t()} | :error
  def parse_agent_uri(value) when is_binary(value) do
    with %URI{scheme: "entity"} = uri <- Ezagent.URI.new!(value),
         true <- Ezagent.URI.type?(uri, :agent) do
      {:ok, uri}
    else
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp subscribe_pty(%URI{} = agent_uri) do
    Phoenix.PubSub.subscribe(
      EzagentCore.PubSub,
      Ezagent.Domain.Pty.Server.output_topic(agent_uri)
    )

    Phoenix.PubSub.subscribe(EzagentCore.PubSub, "pty:phase:" <> URI.to_string(agent_uri))
  end

  defp pty_phase(%URI{} = agent_uri) do
    status = Ezagent.Domain.Pty.status(agent_uri)

    cond do
      is_atom(status[:phase]) -> Atom.to_string(status[:phase])
      is_binary(status[:phase]) -> status[:phase]
      status[:running] == true -> "running"
      true -> "dead"
    end
  end

  defp caller_can_restart_orchestrator?(socket, %URI{}) do
    Ezagent.Identity.admin?(socket.assigns.current_entity_uri)
  end

  defp safe_table_atom(s) when is_binary(s) do
    {:ok, String.to_existing_atom(s)}
  rescue
    ArgumentError -> {:error, {:unknown_table, s}}
  end

  defp safe_table_atom(_), do: {:error, :unknown_table}

  defp dispatch_session_routing(socket, %URI{} = session_uri, action, args) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.with_action(session_uri, :routing, action),
      mode: :call,
      args: args,
      ctx: %{
        caller: socket.assigns.current_entity_uri,
        authenticated_principal: socket.assigns.current_entity_uri,
        caps: MapSet.new(),
        reply: {:caller_inbox, self()}
      },
      origin: :authenticated_external
    })
  end

  defp encode_param(%URI{} = uri), do: uri |> URI.to_string() |> URI.encode_www_form()
  defp uri_string(%URI{} = uri), do: URI.to_string(uri)

  defp same_uri?(%URI{} = left, %URI{} = right),
    do: URI.to_string(left) == URI.to_string(right)

  defp jsonable(value) do
    cond do
      match?(%URI{}, value) ->
        URI.to_string(value)

      match?(%DateTime{}, value) ->
        DateTime.to_iso8601(value)

      match?(%NaiveDateTime{}, value) ->
        NaiveDateTime.to_iso8601(value)

      is_struct(value) ->
        value |> Map.from_struct() |> jsonable()

      is_map(value) ->
        Map.new(value, fn {k, v} -> {to_string(k), jsonable(v)} end)

      is_list(value) ->
        Enum.map(value, &jsonable/1)

      is_binary(value) or is_number(value) ->
        value

      is_atom(value) ->
        Atom.to_string(value)

      true ->
        inspect(value)
    end
  end

  defp reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason(reason), do: inspect(reason)
end
