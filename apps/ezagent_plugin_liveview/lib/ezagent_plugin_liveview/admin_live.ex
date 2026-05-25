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

  alias EzagentPluginLiveview.Admin.{SessionEditor, MemberPanel}
  alias EzagentPluginLiveview.Views.ConversationView
  alias EzagentDomainUi.WorkspaceShell
  alias EzagentDomainUi.Pty.TerminalSeam
  alias EzagentPluginLiveview.AppShell
  alias Ezagent.UI.SessionViewRegistry

  @main_session_uri URI.new!("session://default/default/main")
  @message_limit 50

  @impl true
  def mount(_params, _session, socket) do
    # Phase 8b — register the default ConversationView lazily here. The
    # liveview plugin is library-only (no Application module — adding
    # one in the umbrella triggered a DB-sandbox boot regression for the
    # rest of the LV test suite). Registration is idempotent so every
    # mount safely no-ops if another LV already registered.
    #
    # Domain.Pty PR-C (2026-05-21) — also re-assert TerminalView (it's
    # primarily registered by `EzagentDomainUi.Application.start/2` at
    # boot, but the SessionView registry's ETS table is shared across
    # tests; `session_view_registry_test.exs` wipes it in `setup`, so
    # this lazy re-registration keeps admin_live tests robust to that
    # pollution).
    :ok = SessionViewRegistry.init()
    :ok = SessionViewRegistry.register(ConversationView)
    :ok = SessionViewRegistry.register(EzagentDomainUi.Pty.TerminalView)
    # V1 Allen #2 (Feishu 2026-05-21) — Routing view as a peer of Chat.
    # Primary registration is in `EzagentDomainUi.Application.start/2`;
    # re-asserting here keeps admin_live tests robust to ETS pollution
    # (same belt-and-suspenders shape as the TerminalView line above).
    :ok = SessionViewRegistry.register(EzagentDomainUi.Routing.RoutingView)

    # Phase 8c follow-up (Allen 2026-05-20) — auto-spawn session://default/default/main
    # if missing. Without this the LV mounts with a hardcoded
    # `current_session_uri` for a session that doesn't exist; the right
    # panel shows "No members — Chat plugin failed to start?" which is
    # misleading copy AND blames the wrong subsystem.
    #
    # Root cause: PR-J removed session://default/default/main from the boot static
    # children (workspace://default seeds it via Workspace.Loader). On
    # cold start before any session-creating action, KindRegistry has
    # no session://main. The wizard at `/` creates one, but the
    # post-login redirect lands on /sessions directly (Phase 8c PR-L:
    # /sessions IS the default landing). So most logins skip the
    # wizard and walk straight into the broken state.
    #
    # Idempotent: ensure_main_session/2 is a no-op when the kind is
    # already alive; only spawns on the cold-start path.
    current_session_uri = ensure_main_session(@main_session_uri, socket)

    caller_uri = socket.assigns.current_entity_uri

    if connected?(socket) do
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.Audit.stream_topic())
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, bridge_topic_safely())
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.CCEvents.topic())

      # Notifier/flash audit 2026-05-24 HIGH-1 — wire AdminLive as the
      # consumer for the current entity's notification stream. Pre-fix:
      # `Notifications.notify/3` broadcast to a topic NO LV subscribed
      # to → dead feature. Post-fix: the active operator's LV
      # subscribes; messages bridge to flash via handle_info below.
      #
      # PR-N2 (SPEC v2 notification architecture, Allen 2026-05-24) —
      # ALSO subscribe to the NEW `:slice_changed` stream
      # (`esr:entity:<uri>:slice_changed`). Both topics carry traffic
      # during the transition window:
      #   • PR-N3 flips the SliceChange auto-hook on so producers
      #     start firing into the new topic
      #   • PR-N4 migrates remaining producer sites
      #   • PR-N5 deletes the legacy subscription + handler clause
      # The `handle_info({:slice_changed, _}, _)` clause below logs
      # the event today; the flash bridge + UI render lands in PR-N3.
      if caller_uri do
        Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.Notifications.topic(caller_uri))
        :ok = Ezagent.Notifications.subscribe_slice_change(caller_uri)
      end

      for session_uri <- EzagentDomainChat.list_sessions() do
        Phoenix.PubSub.subscribe(EzagentCore.PubSub, session_events_topic(session_uri))
        # PR-N2 codex r2 HIGH-1 revert (was r1 MEDIUM-2 add) —
        # this loop briefly also called
        # `Notifications.subscribe_slice_change(session_uri)` so
        # the LV would catch session-scoped slice-change events
        # after PR-N3. Codex r2 correctly observed:
        # `subscribe_slice_change/1` performs NO cap check, so
        # subscribing every logged-in caller to every session's
        # slice stream would leak `old_slice`/`new_slice`/`result`/
        # `caller` content for sessions in workspaces the caller
        # cannot observe (the same /sessions page is mounted for
        # non-admin callers under `:require_entity`, not the admin
        # live_session).
        #
        # The session-URI dual-subscribe genuinely needs cap-gated
        # routing via `Ezagent.NotificationSubscriptions.subscribe/3`
        # (caller + caps + workspace-aware filtering). That's PR-N3/
        # N4 work — see the futures note in the PR-N2 body. Until
        # then, session-scoped UI updates continue to ride the
        # legacy `session_events_topic/1` fan-out unchanged.
      end
    end

    caller_caps =
      if URI.to_string(caller_uri) == URI.to_string(Ezagent.Entity.User.admin_uri()) do
        Ezagent.Entity.User.admin_caps()
      else
        Ezagent.Identity.list_caps_for(caller_uri)
      end

    initial_messages = load_session_messages(current_session_uri)

    socket =
      socket
      |> stream(:messages, initial_messages)
      |> assign(:oldest_cursor, oldest_cursor(initial_messages))
      # Phase 8c PR-B — empty-state flag for ConversationView. Tracks
      # whether any message has been rendered yet so the view can show a
      # dot-grid placeholder instead of a blank white panel.
      |> assign(:messages_empty?, initial_messages == [])
      |> assign(:caller_uri, caller_uri)
      |> assign(:caller_caps, caller_caps)
      |> assign(:caller_uri_str, URI.to_string(caller_uri))
      |> assign(:flash_error, nil)
      |> assign(:current_session_uri, current_session_uri)
      |> assign(:sessions, EzagentDomainChat.list_sessions())
      |> assign_session_context(current_session_uri)
      |> assign(:current_view, :conversation)
      |> assign(:active_pty_agent_uri, nil)
      |> assign(:cc_events, [])
      |> assign(:debug_open, false)
      # V1 UI SPEC §2C.3 — MemberPanel's Invite modal visibility.
      |> assign(:invite_open, false)
      |> assign(:compose_form, to_form(%{"text" => ""}, as: "chat"))
      |> assign(:new_session_form, to_form(%{"short_name" => ""}, as: "new_session"))
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
    case URI.new(URI.decode_www_form(encoded)) do
      {:ok, %URI{scheme: "session"} = session_uri} ->
        {:noreply, select_session(socket, session_uri)}

      _ ->
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
    {:noreply, refresh_views_and_members(socket)}
  end

  def handle_info({:cc_disconnected, _bridge_id}, socket) do
    {:noreply, refresh_views_and_members(socket)}
  end

  def handle_info({:member_joined, _uri}, socket),
    do: {:noreply, refresh_views_and_members(socket)}

  def handle_info({:member_left, _uri}, socket),
    do: {:noreply, refresh_views_and_members(socket)}

  def handle_info({:member_offline, _uri, _at}, socket),
    do: {:noreply, assign_session_context(socket, socket.assigns.current_session_uri)}

  def handle_info({:chat_message, source_session_uri, %Ezagent.Message{} = msg}, socket) do
    if URI.to_string(source_session_uri) == URI.to_string(socket.assigns.current_session_uri) do
      {:noreply,
       socket
       |> assign(:messages_empty?, false)
       |> stream_insert(:messages, message_to_row(msg), at: -1)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:chat_message, %Ezagent.Message{} = msg}, socket) do
    {:noreply,
     socket
     |> assign(:messages_empty?, false)
     |> stream_insert(:messages, message_to_row(msg), at: -1)}
  end

  # PR-4 of Read Receipts rollout — `EzagentDomainChat.PresenceFanout`
  # broadcasts when a session member's Presence changes. Refresh the
  # member panel so online/offline state in the MemberPanel updates
  # live without browser refresh.
  def handle_info({:member_presence, _session_uri, _user_uri, %{online?: _}}, socket) do
    {:noreply, assign_session_context(socket, socket.assigns.current_session_uri)}
  end

  # PR-4 of Read Receipts rollout — `Ezagent.Chat.ReadMarker.mark/4`
  # broadcasts on session events topic when a marker is created/bumped.
  # V1: no UI change — the per-message ✓ / ✓✓ / ✓✓✓ render requires
  # plumbing ReadMarker state into the chat-stream row, which is a
  # bigger refactor. Documented as future work; LV doesn't crash on
  # the event because this handler exists.
  def handle_info({:read_marker_updated, _session, _user, _meta}, socket) do
    {:noreply, socket}
  end

  # `Ezagent.Notifications.notify/3` (PR #276 / PR #281) — the
  # tagged envelope shape. Notifier/flash audit 2026-05-24 HIGH-1
  # fix: bridge the notification to a flash so the operator actually
  # SEES it. Pre-fix this was a silent no-op stub.
  #
  # Payload shape per `notifications.ex:80-110` is plugin-defined
  # (just `is_map(notification)`). We surface a best-effort summary
  # using common keys + fall back to inspecting the map.
  def handle_info({:notification, _user_uri, payload}, socket) do
    {:noreply, put_flash(socket, :info, format_notification(payload))}
  end

  # PR-N3 (SPEC v2 notification architecture, Allen 2026-05-25) —
  # the `:slice_changed` envelope is now produced by the Chat User-
  # branch (chat.ex `:receive` User clause + PR-N1's auto-hook
  # post-commit in `Kind.Server.commit_and_notify/3`). PR-N2 shipped
  # this clause as a logging no-op (deferred-by-design — no producers
  # existed yet); PR-N3 wires the flash bridge so users actually SEE
  # the notification — codex r1 HIGH-1 (correctly) flagged the no-op
  # as a user-visible regression if shipped without this hookup.
  #
  # ## Routing
  #
  # The slice-change event carries (`self_uri`, `kind_module`,
  # `action`, `slice_key`, `old_slice`, `new_slice`, `result`,
  # `caller`, `at`). We pattern-match `:receive` on the User Kind to
  # synthesize a chat-style flash: "<sender>: <preview>". Other
  # slice-change shapes (workspace.add_member, identity.grant_cap —
  # PR-N4 producers) get a generic fallback via
  # `format_slice_change/1`. The previous legacy
  # `{:notification, _, _}` handler stays in place (PR-N2 / N5 sweep)
  # for any unmigrated producer.
  def handle_info({:slice_changed, %{} = event}, socket) do
    {:noreply, put_flash(socket, :info, format_slice_change(event))}
  end

  @doc false
  # Public for unit testing (otherwise `defp`). `Notifications.notify/2`
  # contract shape (apps/ezagent_core/.../notifications.ex):
  #   %{type: atom, body: map, source: module}
  # Prefer `body.text` / `body.summary` (current contract); fall back to
  # top-level `:text` / `:summary` on the OUTER payload for mixed-shape
  # transition stragglers (a producer that's added :body but kept the
  # human text at the top level during incremental migration). Codex r1
  # (PR #320) flagged the pre-fix formatter as rendering cap-grant
  # notifications as raw maps because it only read top-level keys.
  # Codex r2 (PR #320) fixed the fallback ordering — pre-fix the body
  # branch called `format_notification_legacy(body)` instead of falling
  # through to the OUTER payload's top-level keys, so a payload like
  # `%{body: %{x: 1}, summary: "fallback"}` lost the summary.
  def format_notification(%{body: %{} = body} = payload) do
    cond do
      is_binary(body[:text]) -> body[:text]
      is_binary(body["text"]) -> body["text"]
      is_binary(body[:summary]) -> body[:summary]
      is_binary(body["summary"]) -> body["summary"]
      true -> format_notification_legacy(payload)
    end
  end

  def format_notification(%{} = payload), do: format_notification_legacy(payload)
  def format_notification(other), do: "Notification: #{inspect(other)}"

  defp format_notification_legacy(%{} = payload) do
    cond do
      is_binary(payload[:text]) -> payload[:text]
      is_binary(payload["text"]) -> payload["text"]
      is_binary(payload[:summary]) -> payload[:summary]
      is_binary(payload["summary"]) -> payload["summary"]
      true -> "Notification: #{inspect(payload)}"
    end
  end

  defp format_notification_legacy(other), do: "Notification: #{inspect(other)}"

  @doc false
  # Public for unit testing (otherwise `defp`). Formats a SliceChange
  # event (PR-N1 envelope shape — see
  # `apps/ezagent_core/lib/ezagent/slice_change.ex` moduledoc) into a
  # human-readable flash string. Pattern-matches the migrated
  # producer site (Chat User-branch :receive) to produce a chat-style
  # preview; falls back to a generic "<scheme>: <action>" line for
  # PR-N4 producer shapes (workspace member add, identity cap grant)
  # so flashes still surface usefully during the transition.
  #
  # Chat preview lookup goes through `Ezagent.MessageStore.by_id/1` —
  # the message was persisted by `Behavior.Chat.invoke(:send, ...)`
  # before the receive fan-out, so the row is already durable by the
  # time the slice-change event lands. A miss (deleted message,
  # store down) degrades to the generic format.
  def format_slice_change(
        %{
          kind_module: Ezagent.Entity.User,
          action: :receive,
          new_slice: %{last_received: %{message_id: msg_id}}
        } = _event
      )
      when is_binary(msg_id) do
    case Ezagent.MessageStore.by_id(msg_id) do
      {:ok, %Ezagent.Message{sender: sender, body: body}} ->
        "New message from #{URI.to_string(sender)}: #{message_preview(body)}"

      _ ->
        "New chat message (id #{msg_id})"
    end
  end

  def format_slice_change(%{kind_module: kind_module, action: action} = _event) do
    "Update on #{inspect(kind_module)} — #{inspect(action)}"
  end

  def format_slice_change(other), do: "Slice changed: #{inspect(other)}"

  # Best-effort preview from a Message body. Body may be either an
  # atom-keyed map (newly-built) or string-keyed (post-DB roundtrip —
  # the MessageStore ↔ Ecto pair JSON-encodes on write and decodes
  # with string keys on read). Mirrors the dual-shape tolerance in
  # `Behavior.Chat.body_text/1` / `body_attachments/1`.
  defp message_preview(%{text: t}) when is_binary(t), do: truncate_preview(t)
  defp message_preview(%{"text" => t}) when is_binary(t), do: truncate_preview(t)
  defp message_preview(_), do: "(attachment-only message)"

  defp truncate_preview(text) when is_binary(text) do
    case String.length(text) do
      n when n <= 80 -> text
      _ -> String.slice(text, 0, 77) <> "..."
    end
  end

  # --- User actions -----------------------------------------------------

  @impl true
  def handle_event("validate_compose", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

  def handle_event("chat_compose", %{"chat" => %{"text" => text}}, socket)
      when is_binary(text) do
    mentions = parse_mentions(text)

    File.mkdir_p!(Ezagent.Home.path("uploads"))

    # SPEC v3 §3.6 (Phase 9 PR-7) — resource URIs are 3-segment
    # `resource://<type>/<workspace>/<name>`. Use the caller's
    # workspace so the resource belongs to the same tenant as the
    # session that owns it.
    workspace_name =
      case Ezagent.Capability.workspace_of(socket.assigns.current_entity_uri) do
        %URI{host: ws_name} when is_binary(ws_name) -> ws_name
        _ -> "default"
      end

    attachments =
      consume_uploaded_entries(socket, :attachments, fn %{path: tmp_path}, entry ->
        uuid = Ecto.UUID.generate()
        safe_name = sanitize_filename(entry.client_name)
        stored_name = "#{uuid}-#{safe_name}"
        dest = Path.join(Ezagent.Home.path("uploads"), stored_name)
        File.cp!(tmp_path, dest)
        {:ok, URI.parse("resource://uploads/#{workspace_name}/#{stored_name}")}
      end)

    if String.trim(text) == "" and attachments == [] do
      {:noreply,
       assign(
         socket,
         :flash_error,
         gettext("Message text or at least one attachment is required.")
       )}
    else
      send_chat_message(socket, text, attachments, mentions)
    end
  end

  def handle_event("chat_compose", _params, socket) do
    {:noreply,
     assign(
       socket,
       :flash_error,
       gettext("Message text or at least one attachment is required.")
     )}
  end

  # PR-2 of Read Receipts rollout — `ViewportMarkRead` JS hook
  # (IntersectionObserver + 250ms dwell) fires this event when a
  # chat-stream row enters viewport. We mark `:displayed` for the
  # current viewer on the current session. Fire-and-forget; mark
  # failure must not block the LV (the marker is observability,
  # not auth-critical).
  def handle_event("mark_displayed", %{"msg_id" => msg_id}, socket)
      when is_binary(msg_id) and msg_id != "" do
    session_uri = socket.assigns.current_session_uri
    viewer_uri = socket.assigns.current_entity_uri

    _ = Ezagent.Chat.ReadMarker.mark(session_uri, viewer_uri, msg_id, :displayed)

    {:noreply, socket}
  end

  def handle_event("mark_displayed", _params, socket), do: {:noreply, socket}

  def handle_event("switch_session", %{"session_uri" => session_uri_str}, socket) do
    case URI.new(session_uri_str) do
      {:ok, new_uri} ->
        {:noreply, select_session(socket, new_uri)}

      _ ->
        {:noreply,
         assign(socket, :flash_error, gettext("Bad session URI: %{uri}", uri: session_uri_str))}
    end
  end

  def handle_event("create_session", %{"new_session" => %{"short_name" => name}}, socket)
      when is_binary(name) and name != "" do
    case EzagentDomainChat.create_session(String.trim(name), Ezagent.Entity.User.admin_uri()) do
      {:ok, session_uri} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(EzagentCore.PubSub, session_events_topic(session_uri))
          # PR-N2 codex r2 HIGH-1 revert — see the matching comment
          # in `mount/3` for why the per-session slice_change
          # subscription was removed (info-leak via uncap'd
          # `subscribe_slice_change/1`). PR-N3/N4 reintroduces it
          # via `NotificationSubscriptions.subscribe/3` with the
          # caller's caps.
        end

        {:noreply,
         socket
         |> assign(:sessions, EzagentDomainChat.list_sessions())
         |> assign(:new_session_form, to_form(%{"short_name" => ""}, as: "new_session"))
         |> assign(:flash_error, nil)}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext("Create failed: %{reason}", reason: inspect(reason))
         )}
    end
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
    case safe_view_id(view_str) do
      {:ok, id} ->
        {:noreply,
         socket
         |> assign(:current_view, id)
         |> assign(:view_module, view_module_for(socket.assigns.applicable_views, id))}

      :error ->
        {:noreply, socket}
    end
  end

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
     |> assign(:view_module, view_module_for(socket.assigns.applicable_views, :pty))
     |> assign(:active_pty_agent_uri, agent_uri_str)}
  end

  # V1 UI SPEC §2C.3 — MemberPanel's Invite modal open/close.
  def handle_event("open_invite_modal", _params, socket) do
    {:noreply, assign(socket, :invite_open, true)}
  end

  def handle_event("close_invite_modal", _params, socket) do
    {:noreply, assign(socket, :invite_open, false)}
  end

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
  def handle_event("invite_member", %{"member_uri" => uri_str}, socket)
      when is_binary(uri_str) and uri_str != "" do
    trimmed = String.trim(uri_str)
    caller_uri = socket.assigns.current_entity_uri
    session_uri = socket.assigns.current_session_uri
    workspace_uri = invite_workspace_uri(socket)

    cond do
      not match?(%URI{}, caller_uri) ->
        {:noreply, assign(socket, :flash_error, gettext("Not signed in."))}

      # SPEC §1.6 / §2C.4 step 1 — server-side revalidation. The
      # submitted URI must be a well-formed entity URI inside the
      # session's workspace (or the caller holds cross-workspace
      # authority). Reject without dispatching.
      not Ezagent.UI.UriOptions.valid_for?(caller_uri, workspace_uri, trimmed, [:entity]) ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext(
             "Rejected %{uri} — must be an entity URI in this session's workspace (%{workspace}). Pick from the list.",
             uri: inspect(trimmed),
             workspace: URI.to_string(workspace_uri)
           )
         )}

      true ->
        target = URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

        # SPEC §2C.4 step 2 — dispatch as `:call` so the result is
        # observable; `:caller_inbox` is irrelevant for `:call` (the
        # GenServer.call return is the result) — keep `reply: :ignore`.
        result =
          Ezagent.Invocation.dispatch(%Ezagent.Invocation{
            target: target,
            mode: :call,
            args: %{member: Ezagent.URI.parse!(trimmed)},
            ctx: %{
              caller: socket.assigns.caller_uri,
              caps: socket.assigns.caller_caps,
              reply: :ignore
            }
          })

        # SPEC §2C.4 step 3 + 4 — decompose; refresh members only on :ok.
        case result do
          :ok ->
            invite_ok(socket, session_uri)

          {:ok, _members} ->
            invite_ok(socket, session_uri)

          {:error, :unauthorized} ->
            {:noreply,
             assign(
               socket,
               :flash_error,
               gettext("Unauthorized — you may not add members to this session.")
             )}

          {:error, :cross_workspace_denied} ->
            {:noreply,
             assign(
               socket,
               :flash_error,
               gettext(
                 "Cross-workspace denied — this session lives in workspace %{workspace}, different from yours. Ask admin for a cross-workspace cap.",
                 workspace: URI.to_string(workspace_uri)
               )
             )}

          {:error, reason} ->
            {:noreply,
             assign(
               socket,
               :flash_error,
               gettext("Invite failed: %{reason}", reason: inspect(reason))
             )}
        end
    end
  end

  def handle_event("invite_member", _params, socket) do
    {:noreply, assign(socket, :flash_error, gettext("Pick an entity to invite."))}
  end

  # Phase 8b §1.6 — Debug events toggle in setting dropdown.
  def handle_event("toggle_debug_panel", _params, socket) do
    {:noreply, assign(socket, :debug_open, not socket.assigns.debug_open)}
  end

  # Phase 8b §1.6 — Feishu binding unbind action.
  def handle_event("unbind_feishu_chat", %{"chat_id" => chat_id}, socket) do
    _ =
      if Code.ensure_loaded?(EzagentPluginFeishu.SessionBinding) do
        EzagentPluginFeishu.SessionBinding.unbind(chat_id)
      end

    {:noreply, assign_session_context(socket, socket.assigns.current_session_uri)}
  end

  # PTY input dispatch — when PtyView is active, xterm pushes pty_input.
  # Routed through the shared `EzagentDomainUi.Pty.TerminalSeam` (the
  # ONE seam reused by TerminalLive + AgentDetailLive) so the dispatch
  # + error-message plumbing isn't reimplemented per surface.
  def handle_event("pty_input", %{"bytes" => bytes}, socket) when is_binary(bytes) do
    case socket.assigns.active_pty_agent_uri do
      nil ->
        {:noreply, socket}

      agent_uri_str ->
        case URI.new(agent_uri_str) do
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
  def handle_event(
        "routing_rule_toggle",
        %{"id" => id_str, "enabled" => enabled_str, "table" => table_str},
        socket
      ) do
    with {id, ""} <- Integer.parse(id_str),
         {:ok, table} <- safe_table_atom(table_str) do
      action = if enabled_str == "true", do: :disable_rule, else: :enable_rule

      case dispatch_session_routing(socket, action, %{id: id, table: table}) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(
             :session_routing_rules,
             list_session_scoped_rules(socket.assigns.current_session_uri)
           )
           |> assign(:flash_error, nil)}

        {:error, :unauthorized} ->
          {:noreply,
           assign(
             socket,
             :flash_error,
             gettext("Unauthorized — need routing cap on this session.")
           )}

        {:error, :cross_workspace_denied} ->
          {:noreply,
           assign(
             socket,
             :flash_error,
             gettext("Cross-workspace denied — this session lives in a different workspace.")
           )}

        {:error, reason} ->
          {:noreply,
           assign(
             socket,
             :flash_error,
             gettext("Toggle failed: %{reason}", reason: inspect(reason))
           )}
      end
    else
      _ ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext("Bad routing rule id or table: %{id}", id: id_str)
         )}
    end
  end

  # Add a session-scoped rule. The matcher is wrapped with an
  # `:in_session` constraint targeting the current session so the rule
  # only fires for this session (SPEC v2 §5.4).
  def handle_event("routing_rule_add_session", %{"rule" => params}, socket) do
    session_uri = socket.assigns.current_session_uri

    with {:ok, leaf_matcher} <- build_session_form_matcher(params),
         receivers when is_list(receivers) and receivers != [] <-
           parse_session_receivers(Map.get(params, "receivers", "")),
         # SPEC §1.6 — revalidate every uri_picker submission
         # server-side before dispatch. Hidden inputs are untrusted.
         :ok <- revalidate_session_matcher_arg(socket, params),
         :ok <- revalidate_session_receivers(socket, receivers),
         matcher = wrap_in_session(leaf_matcher, session_uri),
         {:ok, _} <-
           dispatch_session_routing(socket, :add_rule, %{
             table: EzagentDomainChat.Routing.MentionRouting,
             matcher_json: Ezagent.Routing.Matcher.to_json(matcher),
             receivers: receivers
           }) do
      {:noreply,
       socket
       |> assign(:session_routing_rules, list_session_scoped_rules(session_uri))
       |> assign(:flash_error, nil)}
    else
      {:error, {:invalid_uri, bad}} ->
        # SPEC §1.6 — a submitted URI failed revalidation. Flash, no
        # dispatch.
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext(
             "Rejected URI %{uri} — not a valid in-workspace entity/session.",
             uri: inspect(bad)
           )
         )}

      {:error, :unauthorized} ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext("Unauthorized — need routing cap on this session.")
         )}

      {:error, :cross_workspace_denied} ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext("Cross-workspace denied — this session lives in a different workspace.")
         )}

      [] ->
        {:noreply,
         assign(socket, :flash_error, gettext("At least one receiver URI is required."))}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext("Add rule failed: %{reason}", reason: inspect(reason))
         )}
    end
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
          |> messages_to_rows()

        socket =
          Enum.reduce(older, socket, fn row, acc ->
            stream_insert(acc, :messages, row, at: 0)
          end)

        {:noreply, assign(socket, :oldest_cursor, oldest_cursor(older) || cursor)}
    end
  end

  defp dispatch_session_routing(socket, action, args) do
    session_uri = socket.assigns.current_session_uri

    target =
      URI.parse(URI.to_string(session_uri) <> "?action=routing." <> Atom.to_string(action))

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: socket.assigns.caller_uri,
        caps: socket.assigns.caller_caps,
        reply: {:caller_inbox, self()}
      }
    })
  end

  # Switch the LV's in-view session to `session_uri`. Shared by the
  # `switch_session` phx-click handler AND the `?session=` query-param
  # `handle_params/3` clause (V1 UI PR-2, SPEC §2.2) so the two entry
  # points stay in lockstep.
  defp select_session(socket, %URI{} = session_uri) do
    new_messages = load_session_messages(session_uri)
    applicable = SessionViewRegistry.applicable_views(session_uri)

    new_view =
      cond do
        Enum.any?(applicable, &(&1.id == socket.assigns.current_view)) ->
          socket.assigns.current_view

        applicable != [] ->
          hd(applicable).id

        true ->
          :conversation
      end

    socket
    |> assign(:current_session_uri, session_uri)
    |> assign_session_context(session_uri)
    |> assign(:current_view, new_view)
    # Reset PTY agent binding — the new session may not have that
    # agent as a member.
    |> assign(:active_pty_agent_uri, nil)
    |> assign(:oldest_cursor, oldest_cursor(new_messages))
    |> assign(:messages_empty?, new_messages == [])
    |> stream(:messages, new_messages, reset: true)
  end

  defp build_session_form_matcher(%{"matcher_type" => "mention", "matcher_arg" => arg})
       when is_binary(arg) and arg != "",
       do: {:ok, Ezagent.Routing.Matcher.mention(arg)}

  defp build_session_form_matcher(%{"matcher_type" => "from", "matcher_arg" => arg})
       when is_binary(arg) and arg != "",
       do: {:ok, Ezagent.Routing.Matcher.from(arg)}

  defp build_session_form_matcher(%{"matcher_type" => "text_contains", "matcher_arg" => arg})
       when is_binary(arg) and arg != "",
       do: {:ok, Ezagent.Routing.Matcher.text_contains(arg)}

  defp build_session_form_matcher(%{"matcher_type" => "always"}),
    do: {:ok, Ezagent.Routing.Matcher.always()}

  defp build_session_form_matcher(_),
    do: {:error, :invalid_matcher_form}

  # V1 UI PR-1 — the receivers field is now a :multi uri_picker, which
  # submits `rule[receivers][]` as a list. The comma-separated string
  # clause is kept for the no-JS dead-render fallback.
  defp parse_session_receivers(list) when is_list(list) do
    list
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_session_receivers(csv) when is_binary(csv) do
    csv
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_session_receivers(_), do: []

  # SPEC §1.6 — server-side revalidation of uri_picker submissions in
  # the session-scoped RoutingView. The picker's hidden inputs are
  # untrusted user-controlled DOM; every submitted URI must pass the
  # SHARED validator `UriOptions.valid_for?/4` before dispatch.
  #
  # Form-mode mention/from matchers carry one entity URI; text_contains
  # / always carry no URI. Receivers carry entity + session URIs.
  defp revalidate_session_matcher_arg(socket, %{
         "matcher_type" => type,
         "matcher_arg" => arg
       })
       when type in ["mention", "from"] and is_binary(arg) and arg != "" do
    revalidate_session_uris(socket, [arg], [:entity])
  end

  defp revalidate_session_matcher_arg(_socket, _params), do: :ok

  defp revalidate_session_uris(socket, uris, kinds) do
    caller_uri = socket.assigns.current_entity_uri
    # Session-scoped rules live in the session's workspace — revalidate
    # against THAT workspace (same scope the picker options were built
    # from), not the caller's current workspace.
    workspace_uri = routing_workspace_uri(socket)

    Enum.reduce_while(uris, :ok, fn uri, :ok ->
      if Ezagent.UI.UriOptions.valid_for?(caller_uri, workspace_uri, uri, kinds) do
        {:cont, :ok}
      else
        {:halt, {:error, {:invalid_uri, uri}}}
      end
    end)
  end

  # Mention-gated-routing (SPEC §3) — a session-scoped rule's receivers
  # accept the magic tokens (`$session_members`, `$session_users`,
  # `$mentions`) alongside concrete in-workspace entity/session URIs.
  # The "All session members (broadcast)" picker option submits
  # `$session_members`; the magic tokens are not URIs so the URI
  # validator would reject them — special-case them here.
  defp revalidate_session_receivers(socket, receivers) do
    Enum.reduce_while(receivers, :ok, fn receiver, :ok ->
      cond do
        Ezagent.Routing.Resolver.magic_token?(receiver) ->
          {:cont, :ok}

        true ->
          case revalidate_session_uris(socket, [receiver], [:entity, :session]) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end
      end
    end)
  end

  # Wrap a leaf matcher with an `:in_session` constraint so the rule
  # only fires for the current session. If the leaf is already an
  # `:in_session` (defensive — form doesn't expose it), pass through.
  defp wrap_in_session({:in_session, _} = m, _session_uri), do: m

  defp wrap_in_session(leaf, %URI{} = session_uri) do
    Ezagent.Routing.Matcher.all_of([
      Ezagent.Routing.Matcher.in_session(session_uri),
      leaf
    ])
  end

  defp safe_table_atom(s) when is_binary(s) do
    {:ok, String.to_existing_atom(s)}
  rescue
    ArgumentError -> {:error, {:unknown_table, s}}
  end

  # --- Render -----------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:status, fn ->
        %{
          session_uri: assigns.current_session_uri,
          agents_alive: count_alive_agents(),
          bridges: count_connected_bridges(),
          debug_events: length(assigns.cc_events),
          version: ezagent_version()
        }
      end)
      |> assign_new(:view_render_fn, fn -> resolve_view_render(assigns) end)
      # Phase 8c PR-F: top-left `ezagent / <workspace>` label +
      # avatar dropdown "Admin" link gate. workspace_name reads the
      # current session's bound workspace (PR-E #2 binds session://default/default/main
      # to workspace://default, so this typically resolves to "default").
      |> assign_new(:workspace_name, fn ->
        workspace_name_for(assigns.current_session_uri)
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
            |> URI.parse()
            |> Ezagent.URI.entity_workspace_uri()

          URI.to_string(caller_workspace) == "workspace://system"
        rescue
          _ -> false
        end
      end)
      # V1 UI PR-2 (SPEC §2.2) — `cmdk_nav_routes` is normally set by
      # `EzagentWeb.LiveAuth.on_mount(:cmdk_nav)`. Belt-and-suspenders
      # empty default for test paths that mount this LV outside the
      # `:require_entity` live_session.
      |> assign_new(:cmdk_nav_routes, fn -> [] end)

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
            <MemberPanel.member_panel
              members={@session_members}
              display_map={@display_map}
              invite_open={@invite_open}
              invite_options={@invite_options}
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

  # Bundle the per-session reads needed by SessionEditor + MemberPanel.
  #
  # Username & Auth UI Task 1 (Phase 8c PR-O) — resolve display names
  # for every URI that will be rendered to a human in one batch query
  # (`Ezagent.EntityPresenter.display_many/1`). The same map covers
  # the Members panel rows, the @mention picker JSON (so users can
  # filter by name), and conversation message senders. Falls back to
  # the URI path segment when no profile exists.
  defp assign_session_context(socket, session_uri) do
    members = read_session_members(session_uri)
    member_uris = Enum.map(members, & &1.uri)

    # V1 UI SPEC §2C.3 — the MemberPanel Invite modal's `uri_picker`
    # options: entities in the session's workspace that are NOT already
    # members. `UriOptions.entities/2` enforces the caller's authority
    # (a non-system caller viewing a session in another workspace gets
    # `[]`). Filtering out current members keeps the picker showing
    # only addable entities (SPEC §2C.3 "entities NOT already in the
    # session").
    invite_options = invite_options_for(socket, session_uri, member_uris)

    # V1 Allen #2 (Feishu 2026-05-21) — sort SessionView tabs in a
    # fixed Chat | Routing | Terminal order. `applicable_views/1`
    # returns alphabetical by id; without this re-sort the tab order
    # would be Chat (`:conversation`) | Terminal (`:pty`) | Routing
    # (`:routing`) which violates Allen's "routing 与 chat 并列" intent.
    applicable =
      session_uri
      |> SessionViewRegistry.applicable_views()
      |> sort_views()

    session_routing_rules = list_session_scoped_rules(session_uri)

    display_map = Ezagent.EntityPresenter.display_many(member_uris)

    member_options =
      member_uris
      |> Enum.sort()
      |> Enum.map(fn uri ->
        %{"uri" => uri, "display_name" => Map.get(display_map, uri, uri)}
      end)

    socket
    |> assign(:session_members, members)
    |> assign(:member_options, member_options)
    |> assign(:invite_options, invite_options)
    |> assign(:display_map, display_map)
    |> assign(:applicable_views, applicable)
    |> assign(:view_module, view_module_for(applicable, current_view_or_default(socket)))
    |> assign(:session_info, build_session_info(session_uri, members))
    |> assign(:feishu_chat_ids, feishu_chat_ids_for(session_uri))
    |> assign(:session_routing_rules, session_routing_rules)
    |> assign_routing_uri_options()
  end

  # V1 UI SPEC §2C.3 — entity option list for the Invite modal's
  # `:single` uri_picker, scoped to the SESSION's workspace and pruned
  # of entities already joined. `UriOptions.entities/2` resolves the
  # caller's authority itself.
  defp invite_options_for(socket, session_uri, member_uris) do
    case Map.get(socket.assigns, :current_entity_uri) do
      %URI{} = caller_uri ->
        joined = MapSet.new(member_uris)

        caller_uri
        |> Ezagent.UI.UriOptions.entities(invite_workspace_uri(socket, session_uri))
        |> Enum.reject(&MapSet.member?(joined, &1.uri))

      _ ->
        []
    end
  end

  # The workspace the Invite picker options + the `chat.join`
  # revalidation belong to — derived from the session URI (a
  # session-scoped action lives in the session's workspace, not
  # necessarily the caller's current workspace). Falls back to the
  # caller's current workspace if the session URI carries no workspace.
  defp invite_workspace_uri(socket) do
    invite_workspace_uri(socket, Map.get(socket.assigns, :current_session_uri))
  end

  defp invite_workspace_uri(socket, %URI{} = session_uri) do
    case Ezagent.Capability.workspace_of(session_uri) do
      %URI{} = ws -> ws
      _ -> socket.assigns.current_workspace_uri
    end
  end

  defp invite_workspace_uri(socket, _), do: socket.assigns.current_workspace_uri

  # V1 UI SPEC §2C.4 step 4 — a confirmed `chat.join` :ok. Refresh the
  # member list (and the derived invite options) + close the modal.
  defp invite_ok(socket, session_uri) do
    {:noreply,
     socket
     |> assign_session_context(session_uri)
     |> assign(:invite_open, false)
     |> assign(:flash_error, nil)}
  end

  # V1 UI PR-1 (SPEC §1.2 / §1.5) — option lists for the RoutingView's
  # uri_picker components. The RoutingView edits SESSION-scoped rules,
  # so its pickers are scoped to the *session's* workspace (not the
  # caller's current workspace). UriOptions still resolves the caller's
  # authority itself: a non-system caller viewing a session in another
  # workspace gets `[]`.
  defp assign_routing_uri_options(socket) do
    caller_uri = socket.assigns.current_entity_uri
    workspace_uri = routing_workspace_uri(socket)

    socket
    |> assign(
      :routing_entity_options,
      Ezagent.UI.UriOptions.entities(caller_uri, workspace_uri)
    )
    |> assign(
      :routing_receiver_options,
      routing_receiver_options(caller_uri, workspace_uri)
    )
  end

  # Receiver picker options for the session-scoped RoutingView:
  # in-workspace entities + sessions, with the first-class "All session
  # members (broadcast)" option prepended (mention-gated-routing
  # SPEC §3). That option's `uri` is the `$session_members` magic
  # token; `revalidate_session_receivers/2` accepts it and
  # `Ezagent.Routing.Resolver` expands it at resolve time.
  defp routing_receiver_options(caller_uri, workspace_uri) do
    broadcast = %{
      uri: Ezagent.Routing.Resolver.session_members_token(),
      label: gettext("All session members (broadcast)"),
      kind: :broadcast,
      flavor: nil
    }

    [broadcast | Ezagent.UI.UriOptions.entities_and_sessions(caller_uri, workspace_uri)]
  end

  # The workspace a session-scoped routing rule + its uri_picker
  # options belong to — derived from the current session URI. Falls
  # back to the caller's current workspace when no session is in view.
  defp routing_workspace_uri(socket) do
    case Map.get(socket.assigns, :current_session_uri) do
      %URI{} = session_uri ->
        case Ezagent.Capability.workspace_of(session_uri) do
          %URI{} = ws -> ws
          _ -> socket.assigns.current_workspace_uri
        end

      _ ->
        socket.assigns.current_workspace_uri
    end
  end

  # V1 Allen #2 — explicit display order for the Session view-switcher.
  # Chat (`:conversation`) first, Routing (`:routing`) middle, Terminal
  # (`:pty`) last. Unknown ids (future plugin views) fall to the end in
  # registration order so adding a new view doesn't silently disappear.
  @view_display_order [:conversation, :routing, :pty]
  defp sort_views(views) do
    Enum.sort_by(views, fn %{id: id} ->
      case Enum.find_index(@view_display_order, &(&1 == id)) do
        nil -> {1, id}
        idx -> {0, idx}
      end
    end)
  end

  defp current_view_or_default(socket) do
    case Map.get(socket.assigns, :current_view) do
      nil -> :conversation
      v -> v
    end
  end

  defp view_module_for(applicable, current_view_id) do
    case Enum.find(applicable, &(&1.id == current_view_id)) do
      %{module: mod} ->
        mod

      nil ->
        case SessionViewRegistry.lookup(:conversation) do
          {:ok, mod} -> mod
          :error -> ConversationView
        end
    end
  end

  defp refresh_views_and_members(socket) do
    assign_session_context(socket, socket.assigns.current_session_uri)
  end

  defp build_session_info(%URI{} = session_uri, members) do
    workspace_str =
      case Ezagent.WorkspaceRegistry.lookup(session_uri) do
        {:ok, ws_uri} -> URI.to_string(ws_uri)
        :error -> nil
      end

    created_at =
      case Ezagent.MessageStore.recent_in_session(session_uri, 1) do
        [%Ezagent.Message{inserted_at: at}] -> at
        _ -> nil
      end

    %{
      member_count: length(members),
      workspace_uri: workspace_str,
      created_at: created_at,
      # G-3 + G-5 stop-gap (audit 2026-05-23) — surface the durable
      # `template_working_copy` slice + the spawn_from_template
      # provenance so operators can answer "what template was this
      # session generated from?" + "which slots are filled / pending?".
      # `nil` for ad-hoc sessions (most sessions, today); a map for
      # Generator-spawned sessions.
      generator: load_generator_info(session_uri)
    }
  end

  # G-3 + G-5 stop-gap — read the `:chat` slice's `template_working_copy`
  # via the existing `Behavior.Chat.template_working_copy/1` helper.
  # Returns nil for:
  #
  #   - Sessions not registered (not yet spawned)
  #   - Sessions with the default (empty) working copy (ad-hoc, NOT
  #     Generator-spawned — `agent_slots` empty AND no
  #     `orchestrator_template_uri`)
  #
  # Returns a map for Generator-spawned sessions:
  #
  #   %{
  #     orchestrator_template_uri: URI.t() | nil,
  #     agent_slots: [{name, source_template_uri, live_worker_uri | nil, gen}],
  #     filled: non_neg_integer,
  #     pending: non_neg_integer,
  #     description: String.t()
  #   }
  defp load_generator_info(%URI{} = session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      :error ->
        nil

      {:ok, pid} ->
        slice =
          try do
            # The Kind.Server state map holds slice data under `:state`
            # (per `Ezagent.Kind.Server` shape — confirmed via
            # :sys.get_state on a live Session pid).
            case :sys.get_state(pid, 500) do
              %{state: %{chat: chat_slice}} -> chat_slice
              _ -> nil
            end
          catch
            :exit, _ -> nil
          end

        if is_map(slice) do
          wc = Ezagent.Behavior.Chat.template_working_copy(slice)

          # Ad-hoc session — no slots + no orchestrator means the session
          # is NOT Generator-spawned. Hide the panel entirely (returns nil).
          if (wc[:agent_slots] || []) == [] and is_nil(wc[:orchestrator_template_uri]) do
            nil
          else
            slots = wc[:agent_slots] || []
            filled = Enum.count(slots, fn {_n, _src, worker, _g} -> not is_nil(worker) end)
            pending = length(slots) - filled

            %{
              orchestrator_template_uri: wc[:orchestrator_template_uri],
              agent_slots: slots,
              filled: filled,
              pending: pending,
              description: wc[:description] || ""
            }
          end
        end
    end
  rescue
    _ -> nil
  end

  # V1 Allen #2 — read rules in chat plugin's routing tables and
  # filter to those scoped to this session via an `:in_session` matcher
  # (directly or inside an and/or/not combinator). SPEC v2 §5.4: a
  # rule is "session-scoped to S" when its matcher narrows by S.
  #
  # The RoutingView shows ONLY this slice; global + workspace rules
  # live on /routing's full editor.
  @routing_tables_for_session [
    EzagentDomainChat.Routing.MentionRouting,
    EzagentDomainChat.Routing.SessionRouting
  ]

  defp list_session_scoped_rules(%URI{} = session_uri) do
    session_str = URI.to_string(session_uri)

    @routing_tables_for_session
    |> Enum.flat_map(fn table ->
      rules = Ezagent.Routing.RuleStore.list(table)

      for row <- rules,
          matcher = parse_matcher(row.matcher_data),
          matcher != :invalid,
          matcher_targets_session?(matcher, session_str) do
        %{
          id: row.id,
          table_name: Atom.to_string(table),
          matcher: matcher,
          matcher_repr: inspect(matcher),
          receivers: row.receivers,
          receivers_repr: Enum.join(row.receivers, ", "),
          source: row.source,
          enabled: row.enabled
        }
      end
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp list_session_scoped_rules(_), do: []

  defp parse_matcher(matcher_data) do
    case Ezagent.Routing.Matcher.from_json(matcher_data) do
      {:ok, m} -> m
      _ -> :invalid
    end
  end

  # `:in_session, "..."` matcher at any depth (and/or/not wrappers).
  defp matcher_targets_session?({:in_session, s}, session_str), do: s == session_str

  defp matcher_targets_session?({:and, items}, s) when is_list(items),
    do: Enum.any?(items, &matcher_targets_session?(&1, s))

  defp matcher_targets_session?({:or, items}, s) when is_list(items),
    do: Enum.any?(items, &matcher_targets_session?(&1, s))

  defp matcher_targets_session?({:not, inner}, s),
    do: matcher_targets_session?(inner, s)

  defp matcher_targets_session?(_, _), do: false

  defp feishu_chat_ids_for(%URI{} = session_uri) do
    if Code.ensure_loaded?(EzagentPluginFeishu.SessionBinding) do
      EzagentPluginFeishu.SessionBinding.chat_ids_for(session_uri)
    else
      []
    end
  end

  # `@<entity://...>` extraction. The autocomplete inserts a trailing
  # space, so `@uri ` is the canonical shape; permissive on EOL.
  defp parse_mentions(text) when is_binary(text) do
    ~r/@(entity:\/\/[^\s]+)/
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.flat_map(fn uri_str ->
      case URI.new(uri_str) do
        {:ok, uri} -> [uri]
        _ -> []
      end
    end)
  end

  defp parse_mentions(_), do: []

  defp safe_view_id(s) when is_binary(s) do
    {:ok, String.to_existing_atom(s)}
  rescue
    ArgumentError -> :error
  end

  defp safe_view_id(_), do: :error

  defp count_alive_agents do
    Ezagent.KindRegistry.list_all()
    |> Enum.count(fn {uri_str, _pid} -> String.starts_with?(uri_str, "entity://agent/") end)
  end

  defp count_connected_bridges do
    if Code.ensure_loaded?(EzagentPluginCc.BridgeRegistry) do
      length(EzagentPluginCc.BridgeRegistry.list_connected())
    else
      0
    end
  end

  defp ezagent_version do
    case Application.spec(:ezagent_core, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end

  defp session_events_topic(%URI{} = uri),
    do: Ezagent.Behavior.Chat.session_events_topic(uri)

  defp load_session_messages(%URI{} = session_uri) do
    session_uri
    |> Ezagent.MessageStore.recent_in_session(@message_limit)
    |> Enum.reverse()
    |> messages_to_rows()
  end

  defp oldest_cursor(rows) do
    case rows do
      [%{at: %DateTime{} = at} | _] -> at
      _ -> nil
    end
  end

  # Phase 8c follow-up (Allen 2026-05-20) — see mount/3 comment.
  #
  # Q: "if main already exists and is persisted but isn't loaded for
  #     some reason, won't create_session overwrite it?"
  # A: No. `create_session/2` → `DynamicSupervisor.start_child(spec)`
  #    → `Kind.Server.init` → `Snapshot.load_or_init/3` which is
  #    rehydrate-aware:
  #      - Session.persistence() == :ephemeral today → fresh
  #        init_slice (no DB touch, nothing to overwrite)
  #      - If/when Session flips to {:snapshot, :on_change}
  #        (Phase 7 PR 46 TODO), load_or_init loads from DB and
  #        merges with fresh init (Snapshot.load_with_fallback, Q5
  #        for newly-added behaviors). Members / monitors /
  #        last_seen come back from the snapshot.
  #    Chat history is independent — it lives in MessageStore (its
  #    own table), unaffected by Session Kind lifecycle.
  #
  # The {:already_started, _pid} branch inside create_session handles
  # the race where the kind is alive in supervisor; it returns :ok
  # without re-initializing state.
  #
  # Returns the URI on success (rehydrate-or-fresh-spawn). Returns
  # the URI even on spawn failure — better to render an obviously-
  # empty state than crash the LV; the spawn failure logs separately.
  defp ensure_main_session(%URI{} = uri, socket) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, _pid} ->
        uri

      :error ->
        creator =
          Map.get(socket.assigns, :current_entity_uri) || Ezagent.Entity.User.admin_uri()

        case EzagentDomainChat.create_session("main", creator) do
          {:ok, _spawned_uri} ->
            uri

          {:error, reason} ->
            require Logger
            Logger.warning("AdminLive.ensure_main_session failed: #{inspect(reason)}")
            uri
        end
    end
  end

  defp read_session_members(%URI{} = session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} ->
        try do
          %{state: %{chat: slice}} = :sys.get_state(pid, 1_000)

          for {uri, %{online: online?}} <- slice.members do
            %{
              uri: URI.to_string(uri),
              online: online?,
              last_seen: Map.get(slice.last_seen, uri)
            }
          end
          |> Enum.sort_by(& &1.uri)
        catch
          _, _ -> []
        end

      :error ->
        []
    end
  end

  defp bridge_topic_safely, do: EzagentPluginCc.BridgeRegistry.topic()

  # Single-message variant — used by handle_info live deliveries
  # where batching is not possible (one message at a time). Pays one
  # DB hit for the sender's display name. Acceptable because chat
  # delivery is human-paced (< 10/s).
  defp message_to_row(%Ezagent.Message{} = msg) do
    sender_str = URI.to_string(msg.sender)

    %{
      id: msg.id,
      sender: sender_str,
      sender_display: Ezagent.EntityPresenter.display(sender_str),
      sender_kind: sender_kind(sender_str),
      text: body_text(msg.body),
      attachments: body_attachments(msg.body),
      at: msg.inserted_at
    }
  end

  # Batch variant — used for initial load + load-older. One
  # display_many/1 query for the whole page, then per-row map lookup.
  defp messages_to_rows(messages) when is_list(messages) do
    sender_uris = Enum.map(messages, fn %Ezagent.Message{sender: s} -> URI.to_string(s) end)
    display_map = Ezagent.EntityPresenter.display_many(sender_uris)

    Enum.map(messages, fn %Ezagent.Message{} = msg ->
      sender_str = URI.to_string(msg.sender)

      %{
        id: msg.id,
        sender: sender_str,
        sender_display: Map.get(display_map, sender_str, sender_str),
        sender_kind: sender_kind(sender_str),
        text: body_text(msg.body),
        attachments: body_attachments(msg.body),
        at: msg.inserted_at
      }
    end)
  end

  defp sender_kind(uri_str) do
    cond do
      String.starts_with?(uri_str, "entity://user/") -> :user
      String.starts_with?(uri_str, "entity://agent/") -> :agent
      true -> :other
    end
  end

  defp body_text(%{text: t}) when is_binary(t), do: t
  defp body_text(%{"text" => t}) when is_binary(t), do: t
  defp body_text(_), do: ""

  defp body_attachments(%{attachments: list}) when is_list(list),
    do: Enum.map(list, &att_to_link/1)

  defp body_attachments(%{"attachments" => list}) when is_list(list),
    do: Enum.map(list, &att_to_link/1)

  defp body_attachments(_), do: []

  defp att_to_link(%URI{scheme: "resource", host: "uploads", path: "/" <> filename}),
    do: {display_name(filename), "/admin/uploads/#{filename}"}

  defp att_to_link(%URI{} = uri),
    do: {URI.to_string(uri), URI.to_string(uri)}

  defp att_to_link(s) when is_binary(s) do
    case URI.parse(s) do
      %URI{} = uri -> att_to_link(uri)
      _ -> {s, s}
    end
  end

  defp display_name(<<_uuid::binary-size(36), "-", rest::binary>>), do: rest
  defp display_name(other), do: other

  defp ctx(socket) do
    %{
      caller: socket.assigns.caller_uri,
      caps: socket.assigns.caller_caps,
      reply: :ignore
    }
  end

  defp sanitize_filename(name) when is_binary(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[^\w\.\-]+/, "_")
    |> String.slice(0, 200)
    |> case do
      "" -> "file"
      s -> s
    end
  end

  defp sanitize_filename(_), do: "file"

  defp send_chat_message(socket, text, attachments, mentions) do
    msg =
      Ezagent.Message.new(
        socket.assigns.caller_uri,
        %{text: text, attachments: attachments},
        mentions: mentions
      )

    target = URI.new!("#{URI.to_string(socket.assigns.current_session_uri)}?action=chat.send")

    inv = %Ezagent.Invocation{
      target: target,
      mode: :cast,
      args: %{message: msg},
      ctx: ctx(socket)
    }

    case Ezagent.Invocation.dispatch(inv) do
      :ok ->
        clear_compose(socket)

      {:ok, _} ->
        clear_compose(socket)

      {:error, reason} ->
        {:noreply, assign(socket, :flash_error, friendly_error(gettext("Send"), reason))}
    end
  end

  defp clear_compose(socket) do
    # Phase 8c follow-up (Allen 2026-05-20) — Phoenix's DOM patcher
    # leaves phx-hook-owned inputs alone, so the form-state reset
    # below doesn't clear the browser DOM. Push an LV event the
    # MentionAutocomplete hook listens for to do the actual clear.
    {:noreply,
     socket
     |> assign(:flash_error, nil)
     |> assign(:compose_form, to_form(%{"text" => ""}, as: "chat"))
     |> Phoenix.LiveView.push_event("clear_compose", %{})}
  end

  defp friendly_error(_action, :unauthorized) do
    gettext("You don't have permission for this action. Contact admin for cap grant.")
  end

  # Phase 9 PR-4 (SPEC v3 §5) — distinct from :unauthorized so users
  # see "wrong workspace" vs "missing cap" as separate failure modes
  # (invariant 9).
  defp friendly_error(_action, :cross_workspace_denied) do
    gettext(
      "Cross-workspace denied — your workspace differs from the target's workspace. Contact admin for a cross-workspace cap."
    )
  end

  defp friendly_error(action, reason),
    do: gettext("%{action} failed: %{reason}", action: action, reason: inspect(reason))

  # Phase 8c PR-F: look up the workspace name bound to the current
  # session. Returns the URI host (e.g. "default" for workspace://default)
  # or nil if the session isn't bound to any workspace. Used for the
  # top-left `ezagent / <name>` label.
  defp workspace_name_for(nil), do: nil

  defp workspace_name_for(session_uri) do
    case Ezagent.WorkspaceRegistry.lookup(session_uri) do
      {:ok, %URI{host: name}} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  # Phase 8c PR-L → PR-M (Allen 2026-05-20): the private
  # `list_known_workspaces/0` helper that used to live here is now
  # `EzagentWeb.LiveAuth.list_known_workspaces/0` (centralized so
  # every LV in `:require_entity` sees `@workspaces`, not just admin_live).
end
