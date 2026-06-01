defmodule EzagentPluginLiveview.AdminLive do
  @moduledoc """
  /sessions LiveView — Session Activity coordinator.

  ## Phase 8b — Session view-mode (replaces v1 three-column inline layout)

  Per `docs/superpowers/specs/2026-05-20-phase-8b-session-lv-redesign.zh_cn.md`:

  - Main Window hosts `EzagentPluginLiveview.Admin.SessionEditor`, a
    header (session selector + view-switcher + setting dropdown) /
    `:main_view` slot (the active `Ezagent.UI.SessionView` render) /
    composer (inline `@` autocomplete + file upload + send).
  - View-switcher options come from
    `Ezagent.UI.SessionViewRegistry.applicable_views(@current_session_uri)`.
    Plugins register views (conversation, pty, ...) in their own
    `Application.start/2`.
  - IDE Shell Right Sidebar still hosts `MemberPanel`. cc-agent rows
    get a 🖥️ button — click fires `switch_to_pty_for_agent`, the
    handler sets `current_view = :pty` + `active_pty_agent_uri`.
  - The Phase 4a `debug_panel` (Echo / Manual Dispatch / Audit) has
    moved to `/admin/logs` (ObservabilityLive). admin_live no longer
    renders it; the related handlers (`echo_test`, `manual_dispatch`)
    are gone from this module.

  ## Owned state (assigns)

  - `:current_session_uri` — which session is in view
  - `:current_view` — `:conversation` | `:pty` (default `:conversation`)
  - `:active_pty_agent_uri` — string, set when `current_view = :pty`
  - `:applicable_views` — derived from SessionViewRegistry on session change
  - `:session_members`, `:member_options`, `:invite_options`,
    `:invite_open` — Members panel + Invite modal + composer
  - `:feishu_chat_ids` — for setting dropdown
  - `:debug_open` — Debug events panel toggle (setting dropdown)
  - `:compose_form`, `:new_session_form` — input + create
  """

  use Phoenix.LiveView
  import Phoenix.Component
  # i18n (Allen 2026-05-22): runtime backend reference — EzagentWeb.Gettext
  # lives in the host app; no compile-time dep on :ezagent_web.
  use Gettext, backend: EzagentPluginLiveview.Gettext
  # PR-N2 codex r1 — Logger required for the :slice_changed
  # handler's debug log; module-level require is more idiomatic
  # than an in-function require.
  require Logger

  alias EzagentPluginLiveview.Admin.{
    Compose,
    EventFormat,
    Invite,
    MemberPanel,
    OrchestratorRestart,
    RehydrateFlash,
    RoutingRules,
    SessionContext,
    SessionEditor
  }

  # RFC #402 (Allen 2026-05-26) — OrchestratorHealthCard moved out of
  # the `Admin.*` namespace and into `Session.*` because the
  # orchestrator is 1:1 bound to its session (not an admin-only
  # concept). The session owner — not "anyone with admin caps" —
  # holds restart authority.
  alias EzagentPluginLiveview.Session.OrchestratorHealthCard
  alias EzagentPluginLiveview.Views.ConversationView
  alias EzagentDomainUi.WorkspaceShell
  alias EzagentDomainUi.Pty.TerminalSeam
  alias EzagentPluginLiveview.AppShell
  alias Ezagent.UI.SessionViewRegistry

  # Task #55 round-2 codex CRIT-2 (2026-05-27) — main session URI is
  # NOT a module constant anymore; it's derived from the operator's
  # `current_workspace_uri` at mount time. Pre-fix the LV hardcoded
  # `session://default/system/main` for every tenant, so a non-admin
  # operator's main session view defaulted to the system workspace.
  # `default_main_session_uri/1` is the inverse — given the operator's
  # workspace, return the canonical main session URI for it.
  @message_limit 50

  @impl true
  def mount(_params, _session, socket) do
    # Reassert view registrations on mount; tests can reset the shared
    # SessionViewRegistry ETS table.
    :ok = SessionViewRegistry.init()
    :ok = SessionViewRegistry.register(ConversationView)
    :ok = SessionViewRegistry.register(EzagentDomainSocialware.PageView)
    :ok = SessionViewRegistry.register(EzagentDomainUi.Pty.TerminalView)
    :ok = SessionViewRegistry.register(EzagentDomainUi.Routing.RoutingView)
    :ok = SessionViewRegistry.register(EzagentDomainUi.ExternalMirror.View)

    # Ensure the workspace-scoped main session exists before the view
    # loads messages and member context.
    main_session_uri =
      SessionContext.default_main_session_uri(socket.assigns[:current_workspace_uri])

    {current_session_uri, socket} = ensure_main_session(main_session_uri, socket)

    caller_uri = socket.assigns.current_entity_uri

    if connected?(socket) do
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.Audit.stream_topic())
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, SessionContext.bridge_topic_safely())
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.CCEvents.topic())

      # Subscribe to the operator notification and slice-change streams.
      if caller_uri do
        Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.Notifications.topic(caller_uri))
        :ok = Ezagent.Notifications.subscribe_slice_change(caller_uri)
      end

      # Subscribe only to sessions in the caller's current workspace.
      for session_uri <- SessionContext.list_sessions_for(socket.assigns[:current_workspace_uri]) do
        Phoenix.PubSub.subscribe(
          EzagentCore.PubSub,
          SessionContext.session_events_topic(session_uri)
        )
      end
    end

    caller_caps = Ezagent.Identity.list_caps_for(caller_uri)

    initial_messages = SessionContext.load_session_messages(current_session_uri)

    socket =
      socket
      |> stream(:messages, initial_messages)
      |> assign(:oldest_cursor, SessionContext.oldest_cursor(initial_messages))
      |> assign(:messages_empty?, initial_messages == [])
      |> assign(:caller_uri, caller_uri)
      |> assign(:caller_caps, caller_caps)
      |> assign(:caller_uri_str, URI.to_string(caller_uri))
      # Preserve any rehydrate flash set before the main assign pipeline.
      |> assign_new(:flash_error, fn -> nil end)
      |> assign(:current_session_uri, current_session_uri)
      |> assign(
        :sessions,
        SessionContext.list_sessions_for(socket.assigns[:current_workspace_uri])
      )
      |> SessionContext.maybe_self_join(current_session_uri)
      |> assign(:orchestrator_health, nil)
      |> assign(:orchestrator_can_restart?, false)
      |> assign(:orchestrator_flash_error, nil)
      |> SessionContext.assign_session_context(current_session_uri)
      |> assign(:current_view, :conversation)
      |> assign(:active_pty_agent_uri, nil)
      |> assign(:cc_events, [])
      |> assign(:debug_open, false)
      |> assign(:invite_open, false)
      |> assign(:compose_form, to_form(%{"text" => ""}, as: "chat"))
      |> assign(
        :new_session_form,
        to_form(%{"short_name" => "", "template_class" => ""}, as: "new_session")
      )
      |> allow_upload(:attachments,
        accept: :any,
        max_entries: 5,
        max_file_size: 10 * 1024 * 1024
      )

    {:ok, socket}
  end

  # V1 UI PR-2 (SPEC §2.2 target-URL contract) — `?session=<encoded>`.
  #
  # A CmdK session result navigates to `/sessions?session=<url-encoded
  # session URI>` (SPEC §2.2). Before PR-2, session-switching was ONLY
  # a `phx-click` event ("switch_session") with no URL form — so a
  # CmdK session result had nowhere to land. This `handle_params/3`
  # clause reads the query param, decodes it, and selects that session
  # via the SAME `select_session/2` helper the `phx-click` handler
  # uses, so the two paths cannot drift.
  #
  # No `session` param (the normal /sessions visit, and live-nav back
  # to /sessions without it) is a no-op — the LV keeps its current
  # session.
  @impl true
  def handle_params(%{"session" => encoded}, _uri, socket) when is_binary(encoded) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # with try/rescue keeping the "Bad session URI" flash for malformed
    # query params.
    try do
      case Ezagent.URI.new!(URI.decode_www_form(encoded)) do
        %URI{scheme: "session"} = session_uri ->
          {:noreply, SessionContext.select_session(socket, session_uri)}

        _ ->
          {:noreply,
           assign(socket, :flash_error, gettext("Bad session URI: %{uri}", uri: encoded))}
      end
    rescue
      ArgumentError ->
        {:noreply, assign(socket, :flash_error, gettext("Bad session URI: %{uri}", uri: encoded))}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # --- Stream / membership / audit handlers -----------------------------

  @impl true
  def handle_info({:audit_event, _event}, socket) do
    # Audit stream moved to /admin/logs (ObservabilityLive). Drop here
    # so the subscription on Audit.stream_topic doesn't leak.
    {:noreply, socket}
  end

  def handle_info({:cc_event, event}, socket) do
    {:noreply, assign(socket, :cc_events, [event | socket.assigns.cc_events] |> Enum.take(20))}
  end

  def handle_info({:cc_connected, _bridge_id, _entry}, socket) do
    {:noreply, SessionContext.refresh_views_and_members(socket)}
  end

  def handle_info({:cc_disconnected, _bridge_id}, socket) do
    {:noreply, SessionContext.refresh_views_and_members(socket)}
  end

  def handle_info({:member_joined, _uri}, socket),
    do: {:noreply, SessionContext.refresh_views_and_members(socket)}

  def handle_info({:member_left, _uri}, socket),
    do: {:noreply, SessionContext.refresh_views_and_members(socket)}

  def handle_info({:member_offline, _uri, _at}, socket),
    do:
      {:noreply,
       SessionContext.assign_session_context(socket, socket.assigns.current_session_uri)}

  def handle_info({:chat_message, source_session_uri, %Ezagent.Message{} = msg}, socket) do
    cond do
      # Task #55 round-2 codex MEDIUM (2026-05-27) — workspace guard.
      # Reject any foreign-workspace event that slips through (e.g. from
      # an old subscription on a session that's since been moved, or a
      # transitional period where mount-time list_sessions_for/1 hasn't
      # caught up to the latest workspace switch). Belt-and-suspenders
      # over the mount-time subscription filter.
      not EventFormat.session_in_caller_workspace?(source_session_uri, socket) ->
        {:noreply, socket}

      URI.to_string(source_session_uri) == URI.to_string(socket.assigns.current_session_uri) ->
        {:noreply,
         socket
         |> assign(:messages_empty?, false)
         |> stream_insert(:messages, SessionContext.message_to_row(msg), at: -1)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:chat_message, %Ezagent.Message{} = _msg}, socket) do
    # Task #55 round-2 codex r2 review MEDIUM follow-up — the legacy
    # 2-tuple lacks a source-session URI, so we cannot route it to the
    # right operator. Pre-fix this clause blindly inserted into the
    # current stream, leaking any foreign-session message that
    # happened to ride the 2-tuple shape. Post-fix: drop silently.
    #
    # Producers emitting `{:chat_message, msg}` are transitional and
    # will be migrated to `{:chat_message, source_session_uri, msg}`
    # (see PR-N3/N4 plan). Until then, the safe default is "no insert"
    # — workspace-filtered subscriptions (mount loop) already mean
    # this clause should never fire for sessions the operator is
    # entitled to see; the legacy producer call sites that still emit
    # the 2-tuple are the ones we can't structurally trust.
    {:noreply, socket}
  end

  # Refresh the member panel when presence changes.
  def handle_info({:member_presence, _session_uri, _user_uri, %{online?: _}}, socket) do
    {:noreply, SessionContext.assign_session_context(socket, socket.assigns.current_session_uri)}
  end

  # Read-marker updates are accepted so the LV never crashes on the event.
  def handle_info({:read_marker_updated, _session, _user, _meta}, socket) do
    {:noreply, socket}
  end

  # Bridge plugin-defined notification maps to a best-effort flash summary.
  def handle_info({:notification, _user_uri, payload}, socket) do
    {:noreply, put_flash(socket, :info, EventFormat.format_notification(payload))}
  end

  # Slice-change envelopes are security-minimal; re-fetch only for an
  # authorized event URI and bound formatting time to keep the LV responsive.
  def handle_info({:slice_changed, %{} = event}, socket) do
    if EventFormat.event_uri_authorized?(event, socket) do
      flash = EventFormat.format_slice_change_bounded(event, 250)
      {:noreply, put_flash(socket, :info, flash)}
    else
      :telemetry.execute(
        [:ezagent, :liveview, :slice_changed, :uri_rejected],
        %{count: 1},
        %{event_uri: Map.get(event, :uri), caller_uri: socket.assigns[:caller_uri]}
      )

      {:noreply, socket}
    end
  end

  # Task #55 round-2 codex MEDIUM — workspace guard for inbound session
  # events. Returns true when the caller's `current_workspace_uri`
  # equals the target session's workspace OR the caller holds
  # cross-workspace authority (same predicate `select_session/2`'s
  # gate uses, kept in sync).
  # Incoming-event presentation (slice-change / notification flash +
  # caller-workspace / event-URI auth predicates) lives in
  # `EzagentPluginLiveview.Admin.EventFormat` (#25 Phase-3 PR-3Q).

  # --- User actions -----------------------------------------------------

  @impl true
  def handle_event("validate_compose", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    Compose.cancel_upload(socket, ref)
  end

  def handle_event("chat_compose", params, socket) do
    case params do
      %{"chat" => %{"text" => text}} when is_binary(text) ->
        Compose.submit(socket, text)

      _ ->
        Compose.missing(socket)
    end
  end

  # Fire-and-forget display marker from the viewport hook.
  def handle_event("mark_displayed", %{"msg_id" => msg_id}, socket)
      when is_binary(msg_id) and msg_id != "" do
    session_uri = socket.assigns.current_session_uri
    viewer_uri = socket.assigns.current_entity_uri

    _ = Ezagent.Chat.ReadMarker.mark(session_uri, viewer_uri, msg_id, :displayed)

    {:noreply, socket}
  end

  def handle_event("mark_displayed", _params, socket), do: {:noreply, socket}

  def handle_event("switch_session", %{"session_uri" => session_uri_str}, socket) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # with try/rescue keeping the malformed-URI error flash.
    case (try do
            {:ok, Ezagent.URI.new!(session_uri_str)}
          rescue
            ArgumentError -> :error
          end) do
      {:ok, new_uri} ->
        {:noreply, SessionContext.select_session(socket, new_uri)}

      _ ->
        {:noreply,
         assign(socket, :flash_error, gettext("Bad session URI: %{uri}", uri: session_uri_str))}
    end
  end

  # Create sessions in the operator's current workspace; template_class is required.
  def handle_event(
        "create_session",
        %{"new_session" => %{"short_name" => name, "template_class" => class}},
        socket
      )
      when is_binary(name) and name != "" and is_binary(class) and class != "" do
    case Ezagent.Workspace.create_session(
           socket.assigns.current_workspace_uri,
           %{short_name: String.trim(name), template_name: class},
           %{caller: socket.assigns.caller_uri, caps: socket.assigns.caller_caps}
         ) do
      {:ok, %{session_uri: session_uri} = result} ->
        meta = SessionContext.session_create_meta(result)

        if connected?(socket) do
          Phoenix.PubSub.subscribe(
            EzagentCore.PubSub,
            SessionContext.session_events_topic(session_uri)
          )
        end

        {:noreply,
         socket
         |> assign(
           :sessions,
           SessionContext.list_sessions_for(socket.assigns[:current_workspace_uri])
         )
         |> assign(
           :new_session_form,
           to_form(%{"short_name" => "", "template_class" => ""}, as: "new_session")
         )
         |> assign(:flash_error, OrchestratorRestart.flash_text(meta))}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext("Create failed: %{reason}", reason: inspect(reason))
         )}
    end
  end

  # SPEC `2026-05-26-session-create-orchestrator-unified` Gap A —
  # rehydrate path's status is debug-level (operator's on admin page
  # already; OrchestratorHealthCard surfaces it visually).

  def handle_event(
        "create_session",
        %{"new_session" => %{"short_name" => name}},
        socket
      )
      when is_binary(name) and name != "" do
    # SPEC #366 — explicit failure when the operator left the
    # template dropdown empty. We deliberately do NOT pick a default
    # here.
    {:noreply,
     assign(
       socket,
       :flash_error,
       gettext("Pick a template before creating the session.")
     )}
  end

  def handle_event("create_session", _params, socket) do
    {:noreply, assign(socket, :flash_error, gettext("Session name is required."))}
  end

  # Phase 8b §3 stage c — view switcher (Chat / Terminal buttons in
  # SessionEditor header). `view` is the SessionView id atom encoded
  # as a string in the phx-value attribute; convert via
  # String.to_existing_atom to keep the atom table bounded.
  #
  # V1 UI fix (Allen 2026-05-21): also recompute `:view_module` from
  # the new `:current_view`. Without this update, `render_active_view`
  # keeps using the previously-resolved module (set in
  # `assign_session_context`) and the view-switch silently no-ops
  # visually even though `:current_view` flips correctly.
  def handle_event("switch_view", %{"view" => view_str}, socket) do
    case SessionContext.safe_view_id(view_str) do
      {:ok, id} ->
        socket =
          socket
          |> assign(:current_view, id)
          |> assign(
            :view_module,
            SessionContext.view_module_for(socket.assigns.applicable_views, id)
          )
          |> maybe_restream_messages_on_view_switch(id)

        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  # 2026-06-01 (loom view 暴露的存量 bug):切到 Chat 之外的视图
  # (:loom iframe / :routing / :external_mirror / :pty)时,
  # session_editor 的 main_view slot 会把 ConversationView 整个从 DOM 拿掉。
  # 切回 :conversation 时 stream 容器重新挂载,但 Phoenix.LiveView 的 stream
  # 不会自动 replay 之前发过的 items —— 用户看到空白聊天,只能刷新。
  #
  # 修法:切回 :conversation 时重新从 MessageStore 拉一遍最近消息 +
  # `stream(..., reset: true)`。等价于"重新打开这个 session"的状态恢复。
  # 切到非 :conversation 视图不动 stream,免无谓 DB 读。
  defp maybe_restream_messages_on_view_switch(socket, :conversation) do
    messages = SessionContext.load_session_messages(socket.assigns.current_session_uri)

    socket
    |> assign(:oldest_cursor, SessionContext.oldest_cursor(messages))
    |> assign(:messages_empty?, messages == [])
    |> stream(:messages, messages, reset: true)
  end

  defp maybe_restream_messages_on_view_switch(socket, _other), do: socket

  # Phase 8b §3 stage g — clicking the 🖥️ button in MemberPanel
  # switches the main view to :pty and binds xterm to the chosen agent.
  #
  # V1 UI fix (Allen 2026-05-21): also recompute `:view_module` so the
  # terminal icon in the Members panel actually navigates to the PTY
  # view. Same bug shape as `switch_view` above — assigning only
  # `:current_view` flips state but `render_active_view` reads
  # `@view_module` (the cached module from `assign_session_context`)
  # so the view never updates.
  def handle_event("switch_to_pty_for_agent", %{"agent" => agent_uri_str}, socket) do
    {:noreply,
     socket
     |> assign(:current_view, :pty)
     |> assign(
       :view_module,
       SessionContext.view_module_for(socket.assigns.applicable_views, :pty)
     )
     |> assign(:active_pty_agent_uri, agent_uri_str)}
  end

  # V1 UI SPEC §2C.3 — MemberPanel's Invite modal open/close.
  def handle_event("open_invite_modal", _params, socket), do: Invite.open(socket)

  def handle_event("close_invite_modal", _params, socket), do: Invite.close(socket)

  # V1 UI SPEC §2C.4 (Codex adversarial review rev-4 fix) — the
  # dedicated Invite handler. It REPLACES the deleted `add_floating_agent`
  # `:cast` path, which discarded the dispatch result and silently
  # dropped `:unauthorized` / `:cross_workspace_denied` / missing-target
  # failures (violates Decision #134, the no-silent-drop invariant for
  # user-facing surfaces).
  #
  # Flow:
  #   1. Revalidate the submitted `member_uri` via the SHARED validator
  #      `Ezagent.UI.UriOptions.valid_for?/4` — the picker's hidden
  #      input is untrusted user-controlled DOM, and the ignored
  #      subtree can hold a stale selection after a workspace switch
  #      (SPEC §1.6). A failed check → flash, NO dispatch.
  #   2. Dispatch `chat.join` as `:call` (NOT `:cast`) so the result
  #      comes back — `join`'s `@interface` declares `modes: [:call,
  #      :cast]`, so `:call` is a valid transport choice (invariant 7).
  #   3. Decompose the `:call` result and surface every failure mode
  #      as a distinct flash.
  #   4. Refresh the members list ONLY on confirmed `:ok`.
  def handle_event("invite_member", params, socket) do
    case params do
      %{"member_uri" => uri_str} when is_binary(uri_str) and uri_str != "" ->
        Invite.submit(socket, uri_str)

      _ ->
        Invite.missing(socket)
    end
  end

  # 2026-05-26 — Restart orchestrator from the per-session health card.
  #
  # Dispatches `template://agent/<ws>/cc-orchestrator?action=template.instantiate`
  # with `instance_name: <derived>`. CapBAC step 5.5 enforces the
  # caller's `Behavior.Template :instantiate` cap on the orchestrator
  # template URI; on denial we surface a distinct flash through
  # `orchestrator_flash_error` (the card has its own slot, separate
  # from MemberPanel's flash_error).
  #
  # The submitted `uri` parameter (the orchestrator URI) is revalidated
  # against the freshly-computed `orchestrator_health` to defeat any
  # tampered DOM that would dispatch against a different agent — we
  # only ever instantiate the orchestrator template for the current
  # session.
  def handle_event("restart_orchestrator", %{"uri" => submitted_uri_str}, socket)
      when is_binary(submitted_uri_str) do
    health = socket.assigns.orchestrator_health
    session_uri = socket.assigns.current_session_uri

    cond do
      is_nil(health) ->
        {:noreply,
         assign(
           socket,
           :orchestrator_flash_error,
           gettext("No orchestrator for this session (workspace binding missing).")
         )}

      URI.to_string(health.uri) != String.trim(submitted_uri_str) ->
        # DOM tamper or stale submission. Refuse — the only URI the
        # operator should ever submit is the current session's
        # orchestrator URI.
        {:noreply,
         assign(
           socket,
           :orchestrator_flash_error,
           gettext("Refused — submitted URI does not match this session's orchestrator.")
         )}

      true ->
        # RFC #402 (Allen 2026-05-26) — restart is authorized by the
        # caller holding `Ezagent.Behavior.OrchestratorAdmin :restart`
        # on this session (`SessionContext.caller_can_restart_orchestrator?/2` —
        # computed in `assign_session_context/2`). Re-check here as the
        # chokepoint: a DOM tamper bypassing the
        # `:if={@orchestrator_can_restart?}` render guard MUST still land
        # in :unauthorized.
        #
        # 2026-05-31 orchestrator-startup-atomicity §6 — once the cap
        # check passes, the restart REPAIRS via
        # `EzagentDomainInstanceMessage.repair_orchestrator/2` (re-materialize OTU +
        # §5 atomic gate). The owner/lineage/`spawned_by` resolution that
        # the old `template.instantiate` dispatch needed is now internal
        # to `repair_orchestrator` (it reads `Session.owner/1`), so the LV
        # no longer computes the dispatch target / instance-name /
        # spawned_by here.
        if not SessionContext.caller_can_restart_orchestrator?(socket, session_uri) do
          {:noreply,
           assign(
             socket,
             :orchestrator_flash_error,
             gettext("Unauthorized — only the session owner may restart the orchestrator.")
           )}
        else
          OrchestratorRestart.restart(socket, health, session_uri)
        end
    end
  end

  def handle_event("restart_orchestrator", _params, socket) do
    {:noreply,
     assign(
       socket,
       :orchestrator_flash_error,
       gettext("Restart refused — missing orchestrator URI.")
     )}
  end

  # Phase 8b §1.6 — Debug events toggle in setting dropdown.
  def handle_event("toggle_debug_panel", _params, socket) do
    {:noreply, assign(socket, :debug_open, not socket.assigns.debug_open)}
  end

  # PR-EM-6: the `unbind_feishu_chat` handler was retired along with
  # `EzagentPluginFeishu.SessionBinding`. Per-session chat unbind now
  # flows through the generic admin LV at
  # `/admin/sessions/:id/external_mirror` (PR-EM-4), which uses
  # `Ezagent.ExternalMirror.unbind/4`. No template in this LV bound
  # `unbind_feishu_chat`; the handler was already unreachable from
  # the UI as of PR-EM-4. The `feishu_chat_ids` assign (read-only
  # display) is now backed by `EzagentPluginFeishu.InboundChatLookup`.

  # PTY input dispatch — when PtyView is active, xterm pushes pty_input.
  # Routed through the shared `EzagentDomainUi.Pty.TerminalSeam` (the
  # ONE seam reused by TerminalLive + AgentDetailLive) so the dispatch
  # + error-message plumbing isn't reimplemented per surface.
  def handle_event("pty_input", %{"bytes" => bytes}, socket) when is_binary(bytes) do
    case socket.assigns.active_pty_agent_uri do
      nil ->
        {:noreply, socket}

      agent_uri_str ->
        # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
        # with try/rescue (malformed agent URI silently noop, preserves
        # original case-fallthrough semantics).
        case (try do
                {:ok, Ezagent.URI.new!(agent_uri_str)}
              rescue
                ArgumentError -> :error
              end) do
          {:ok, agent_uri} ->
            case TerminalSeam.dispatch_input(agent_uri, bytes, ctx(socket)) do
              :ok ->
                {:noreply, socket}

              {:error, reason} ->
                {:noreply, assign(socket, :flash_error, TerminalSeam.input_error_message(reason))}
            end

          _ ->
            {:noreply, socket}
        end
    end
  end

  def handle_event("pty_resize", _params, socket), do: {:noreply, socket}

  # V1 Allen #2 — RoutingView event handlers.
  #
  # Toggle a session-scoped rule's enabled flag. Dispatches via SPEC v2
  # §5.7 to the Session Kind's Routing Behavior at
  # `<session_uri>?action=routing.{disable_rule,enable_rule}`. The
  # Session Kind is the scope-owning Kind for session-scoped rules.
  def handle_event(event, params, socket)
      when event in ["routing_rule_toggle", "routing_rule_add_session"] do
    RoutingRules.handle_event(event, params, socket)
  end

  # Phase 5 PR 5 — paginate history backwards. Kept here so all
  # handle_event/3 clauses group contiguously (clause-grouping warning).
  def handle_event("load_older_messages", _params, socket) do
    case socket.assigns.oldest_cursor do
      nil ->
        {:noreply, socket}

      %DateTime{} = cursor ->
        older =
          socket.assigns.current_session_uri
          |> Ezagent.MessageStore.older_than(cursor, @message_limit)
          |> Enum.reverse()
          |> SessionContext.messages_to_rows()

        socket =
          Enum.reduce(older, socket, fn row, acc ->
            stream_insert(acc, :messages, row, at: 0)
          end)

        {:noreply, assign(socket, :oldest_cursor, SessionContext.oldest_cursor(older) || cursor)}
    end
  end

  # Surface failed orchestrator creation while suppressing plain sessions.
  # Orchestrator restart action + flash text live in
  # `EzagentPluginLiveview.Admin.OrchestratorRestart` (#25 Phase-3 PR-3Q).

  # --- Render -----------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:status, fn ->
        %{
          session_uri: assigns.current_session_uri,
          agents_alive: SessionContext.count_alive_agents(),
          bridges: SessionContext.count_connected_bridges(),
          debug_events: length(assigns.cc_events),
          version: SessionContext.ezagent_version()
        }
      end)
      |> assign_new(:view_render_fn, fn -> resolve_view_render(assigns) end)
      # Phase 8c PR-F + Bug 3 (Allen 2026-05-26): top-left
      # `ezagent / <workspace>` label.
      #
      # `workspace_name` is set centrally by
      # `EzagentWeb.LiveAuth.on_mount(:require_entity)` from the
      # session-cookie-bound `:current_workspace_uri` slot — the SoT
      # for "which workspace is the user operating in" (written by
      # `WorkspaceSwitchController` + login). The
      # `assign_new` is a belt-and-suspenders fallback for test
      # paths that mount this LV outside the `:require_entity`
      # live_session.
      #
      # Previous bug: this assign called `workspace_name_for(current_session_uri)`
      # which reads the workspace bound to the in-view session
      # (always `session://default/system/main` → "system"), so a
      # successful `POST /workspaces/switch` (which updates the
      # session cookie) did not update the label — the switch
      # LOOKED broken even when it succeeded.
      |> assign_new(:workspace_name, fn ->
        SessionContext.workspace_name_from_uri(assigns[:current_workspace_uri])
      end)
      # PR-M (Allen 2026-05-20): `workspaces` + `is_admin?` are now
      # set centrally by `EzagentWeb.LiveAuth.on_mount(:require_entity)`,
      # which fires before this render. `assign_new` is kept as belt-
      # and-suspenders for any test path that mounts this LV outside
      # the `:require_entity` live_session.
      |> assign_new(:is_admin?, fn ->
        Ezagent.Identity.admin?(assigns.caller_uri_str)
      end)
      # Phase 9 PR-8 (SPEC v3 §13.3) — `is_system_member?` is normally
      # set by `EzagentWeb.LiveAuth.on_mount(:require_entity)`; this
      # belt-and-suspenders fallback catches any test path that mounts
      # this LV outside the `:require_entity` live_session.
      |> assign_new(:is_system_member?, fn ->
        try do
          caller_workspace =
            assigns.caller_uri_str
            |> Ezagent.URI.new!()
            |> Ezagent.URI.entity_workspace_uri()

          Ezagent.URI.name?(caller_workspace, :system)
        rescue
          _ -> false
        end
      end)
      # V1 UI PR-2 (SPEC §2.2) — `cmdk_nav_routes` is normally set by
      # `EzagentWeb.LiveAuth.on_mount(:cmdk_nav)`. Belt-and-suspenders
      # empty default for test paths that mount this LV outside the
      # `:require_entity` live_session.
      |> assign_new(:cmdk_nav_routes, fn -> [] end)
      # SPEC #366 (Allen 2026-05-26) — eliminate silent `"default"`
      # template-class fallback in session creation. The new-session
      # form needs an explicit dropdown sourced from the current
      # workspace's `session_templates` map. Recomputed on every
      # render (cheap — one Store.get_by_name) so newly-added
      # templates are immediately pickable without an LV remount.
      |> assign(:template_class_options, SessionContext.template_class_options_for(assigns))

    ~H"""
    <AppShell.app_shell
      perspective={:workspace}
      current_entity_uri={@caller_uri_str}
      current_workspace_uri={@current_workspace_uri}
      workspace_name={@workspace_name}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      workspaces={@workspaces}
      cmdk_nav_routes={@cmdk_nav_routes}
    >
      <:body>
        <WorkspaceShell.workspace_shell
          current_entity_uri={@caller_uri_str}
          current_path="/sessions"
          status={@status}
        >
          <:main_window>
            <SessionEditor.session_editor
              current_session_uri={@current_session_uri}
              sessions={@sessions}
              applicable_views={@applicable_views}
              current_view={@current_view}
              new_session_form={@new_session_form}
              template_class_options={@template_class_options}
              compose_form={@compose_form}
              member_options={@member_options}
              session_info={@session_info}
              feishu_chat_ids={@feishu_chat_ids}
              debug_open={@debug_open}
              uploads={@uploads}
              flash_error={@flash_error}
            >
              <:main_view>
                <.render_active_view
                  view_module={@view_module}
                  messages_stream={@streams.messages}
                  oldest_cursor={@oldest_cursor}
                  active_pty_agent_uri={@active_pty_agent_uri}
                  empty_state?={@messages_empty?}
                  session_uri={@current_session_uri}
                  session_routing_rules={@session_routing_rules}
                  entity_options={@routing_entity_options}
                  receiver_options={@routing_receiver_options}
                  session_bindings={@session_bindings}
                />
              </:main_view>
            </SessionEditor.session_editor>

            <section
              :if={@debug_open}
              class="border-t border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-950 max-h-48 overflow-y-auto p-3"
            >
              <h3 class="text-[10px] uppercase tracking-wide text-zinc-500 mb-1">
                {gettext("Debug events (last 20)")}
              </h3>
              <p
                :if={@cc_events == []}
                class="text-[11px] text-zinc-500 dark:text-zinc-400 italic py-2"
              >
                {gettext("No debug events yet. CC hook errors + dispatch events will appear here.")}
              </p>
              <ul :if={@cc_events != []} class="space-y-1 text-[11px]">
                <li :for={ev <- @cc_events} class="flex gap-2">
                  <span class={[
                    "px-1 rounded font-semibold",
                    ev.level == "error" &&
                      "bg-rose-100 dark:bg-rose-900 text-rose-700 dark:text-rose-300",
                    ev.level == "warning" &&
                      "bg-amber-100 dark:bg-amber-900 text-amber-700 dark:text-amber-300",
                    ev.level not in ["error", "warning"] &&
                      "bg-zinc-200 dark:bg-zinc-800 text-zinc-700 dark:text-zinc-300"
                  ]}>
                    {ev.level}
                  </span>
                  <span class="font-mono text-[10px] text-zinc-500">{ev.bridge_id}</span>
                  <span class="flex-1">{ev.text}</span>
                </li>
              </ul>
            </section>
          </:main_window>

          <:right_sidebar>
            <%!-- Per-session orchestrator INSTANCE health (2026-05-26).
                  Renders only when the session is workspace-bound — pre-
                  bind sessions (e.g. ad-hoc test fixtures) hide the card
                  rather than show a misleading state. --%>
            <OrchestratorHealthCard.orchestrator_health_card
              :if={@orchestrator_health}
              health={@orchestrator_health}
              can_restart?={@orchestrator_can_restart?}
              flash_error={@orchestrator_flash_error}
            />
            <MemberPanel.member_panel
              members={@session_members}
              display_map={@display_map}
              invite_open={@invite_open}
              invite_options={@invite_options}
              flash_error={@flash_error}
            />
          </:right_sidebar>
        </WorkspaceShell.workspace_shell>
      </:body>
    </AppShell.app_shell>
    """
  end

  # Helper component: render whichever SessionView is active. We pull
  # the module out of assigns and call its `render/1` with the assigns
  # the view declares it needs.
  attr(:view_module, :atom, required: true)
  attr(:messages_stream, :any, required: true)
  attr(:oldest_cursor, :any, default: nil)
  attr(:active_pty_agent_uri, :any, default: nil)
  attr(:empty_state?, :boolean, default: false)
  # V1 Allen #2 — RoutingView reads these.
  attr(:session_uri, :any, default: nil)
  attr(:session_routing_rules, :list, default: [])
  # V1 UI PR-1 — RoutingView's uri_picker option lists.
  attr(:entity_options, :list, default: [])
  attr(:receiver_options, :list, default: [])
  # 2026-05-25 — ExternalMirror Bindings SessionView reads this.
  attr(:session_bindings, :list, default: [])

  defp render_active_view(assigns) do
    case assigns.view_module do
      mod when is_atom(mod) and not is_nil(mod) ->
        mod.render(assigns)

      _ ->
        # Fallback — should not happen because mount/3 always seeds
        # :current_view = :conversation and ConversationView is
        # registered by EzagentPluginLiveview.Application.start/2.
        ConversationView.render(assigns)
    end
  end

  # Compute the active view module from assigns. The render fn returns
  # the module so `render/1` can avoid recomputing per-render.
  defp resolve_view_render(%{current_view: view_id}) do
    case SessionViewRegistry.lookup(view_id) do
      {:ok, mod} -> mod
      :error -> ConversationView
    end
  end

  defp resolve_view_render(_), do: ConversationView

  # --- Helpers ----------------------------------------------------------

  @doc false
  @spec parse_mentions(String.t(), [map()]) :: [URI.t()]
  def parse_mentions(text, members \\ []),
    do: SessionContext.parse_mentions(text, members)

  @doc false
  @spec parse_mentions(String.t(), [map()], map()) :: {[URI.t()], [String.t()]}
  def parse_mentions(text, members, legends),
    do: SessionContext.parse_mentions(text, members, legends)

  @doc false
  def assign_rehydrate_flash(socket, meta),
    do: RehydrateFlash.assign(socket, meta)

  defp ensure_main_session(%URI{} = uri, socket) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, _pid} ->
        {uri, socket}

      :error ->
        creator = Map.get(socket.assigns, :current_entity_uri) || Ezagent.Entity.User.admin_uri()
        session_workspace_uri = Ezagent.Capability.workspace_of(uri)

        case Ezagent.Workspace.create_session(
               session_workspace_uri,
               %{short_name: "main", template_name: "default"},
               %{
                 caller: creator,
                 caps: Map.get(socket.assigns, :caller_caps, MapSet.new())
               }
             ) do
          {:ok, result} ->
            meta = SessionContext.session_create_meta(result)
            SessionContext.log_orchestrator_status_on_rehydrate(uri, meta)
            {uri, RehydrateFlash.assign(socket, meta)}

          {:error, reason} ->
            Logger.warning("AdminLive.ensure_main_session failed: #{inspect(reason)}")

            {uri,
             assign(
               socket,
               :flash_error,
               gettext("Main session rehydrate failed: %{reason}", reason: inspect(reason))
             )}
        end
    end
  end

  defp ctx(socket) do
    %{
      caller: socket.assigns.caller_uri,
      caps: socket.assigns.caller_caps,
      reply: :ignore
    }
  end

  # Bug 3 (Allen 2026-05-26) — top-left `ezagent / <name>` label
  # data source. Reads the host of the user's session-cookie-bound
  # `:current_workspace_uri` (written by `WorkspaceSwitchController`
  # for system-member context swaps + by `SessionPrincipal.put/3`
  # at login). This is the SoT for "which workspace is the user
  # operating in" and is the assign IdeShell ultimately wants to
  # render in the dropdown trigger.
  #
  # Replaces the previous `workspace_name_for/1` helper that looked
  # up the workspace bound to `current_session_uri` (which is
  # hardcoded to `session://default/system/main` and thus did not
  # follow workspace switches). `EzagentWeb.LiveAuth` sets this
  # assign centrally for every `:require_entity` LV; this local
  # helper is the belt-and-suspenders fallback for test paths that
  # mount the LV outside that live_session.
  # Phase 8c PR-L → PR-M (Allen 2026-05-20): the private
  # `list_known_workspaces/0` helper that used to live here is now
  # `EzagentWeb.LiveAuth.list_known_workspaces/0` (centralized so
  # every LV in `:require_entity` sees `@workspaces`, not just admin_live).
end
