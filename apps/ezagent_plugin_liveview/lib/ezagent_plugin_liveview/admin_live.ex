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

  defp default_main_session_uri(%URI{scheme: "workspace", host: ws}) when is_binary(ws) and ws != "",
    do: Ezagent.URI.new!("session://default/#{ws}/main")

  defp default_main_session_uri(_),
    # Early-mount / test paths with no workspace assigned — fall back
    # to the system workspace's main. LiveAuth populates the assign
    # for every `:require_entity` mount in production, so this branch
    # fires only when the LV is mounted outside that live_session.
    do: Ezagent.URI.new!("session://default/system/main")

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
    # 2026-05-25 — ExternalMirror Bindings SessionView. Same belt-and-
    # suspenders re-registration so admin_live tests stay robust to
    # session_view_registry_test.exs's setup wipe.
    :ok = SessionViewRegistry.register(EzagentDomainUi.ExternalMirror.View)

    # Phase 8c follow-up (Allen 2026-05-20) — auto-spawn session://default/system/main
    # if missing. Without this the LV mounts with a hardcoded
    # `current_session_uri` for a session that doesn't exist; the right
    # panel shows "No members — Chat plugin failed to start?" which is
    # misleading copy AND blames the wrong subsystem.
    #
    # Root cause: PR-J removed session://default/system/main from the boot static
    # children (the wizard creates it via Workspace.Loader on first login).
    # On
    # cold start before any session-creating action, KindRegistry has
    # no session://main. The wizard at `/` creates one, but the
    # post-login redirect lands on /sessions directly (Phase 8c PR-L:
    # /sessions IS the default landing). So most logins skip the
    # wizard and walk straight into the broken state.
    #
    # Idempotent: ensure_main_session/2 is a no-op when the kind is
    # already alive; only spawns on the cold-start path.
    #
    # codex PR #408 review MED-1 — ensure_main_session/2 now returns
    # `{uri, socket}` so the orchestrator-status meta (pending/failed)
    # can surface through the admin error banner. The unchanged path
    # (kind alive) returns the unchanged socket.
    #
    # Task #55 codex r2 CRIT-2 — derive main session URI from the
    # operator's `current_workspace_uri`. Pre-fix every tenant landed
    # on `session://default/system/main` (the admin's workspace's
    # session). Post-fix a `team-alpha` operator lands on
    # `session://default/team-alpha/main`.
    main_session_uri = default_main_session_uri(socket.assigns[:current_workspace_uri])
    {current_session_uri, socket} = ensure_main_session(main_session_uri, socket)

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

      # Task #55 round-2 codex MEDIUM (2026-05-27) — subscribe ONLY to
      # sessions in the caller's current workspace. Pre-fix the LV
      # subscribed to every session's event topic regardless of tenant,
      # so foreign-workspace session events were delivered into this
      # process (rendered-list filter caught most leaks, but membership
      # events flowing through `refresh_views_and_members/1` and the
      # `{:chat_message, source_session_uri, msg}` path still touched
      # the LV inbox).
      for session_uri <- list_sessions_for(socket.assigns[:current_workspace_uri]) do
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

    # SPEC caps-cleanup-v1 §4.4 — admin's caps live in slice (seeded
    # via `Ezagent.SystemPrincipal` at boot); no special branch needed.
    caller_caps = Ezagent.Identity.list_caps_for(caller_uri)

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
      # codex PR #408 review round-2 MED-1 — use `assign_new/3` so the
      # rehydrate-orchestrator-status flash that `ensure_main_session/2`
      # may have set BEFORE we reach this line (line ~114) is preserved
      # rather than wiped to nil. Fresh mounts (no rehydrate flash) get
      # the default nil via the lazy fn; rehydrate paths keep their
      # `:pending` / `:failed` text for the operator to see.
      |> assign_new(:flash_error, fn -> nil end)
      |> assign(:current_session_uri, current_session_uri)
      # Task #55 (Allen 2026-05-27) — filter sessions by the operator's
      # current workspace. Pre-fix every LV mount displayed sessions
      # from every workspace (cross-workspace display leak).
      # Round-2 codex r2 MED follow-up: `list_sessions_for/1` now
      # falls back to `[]` when `current_workspace_uri` is nil (LV
      # mounted outside `:require_entity` LiveAuth path) — deny by
      # absence rather than show-everything default.
      #
      # 2026-06-02 — use the visibility-filtered list so removed
      # templates' ghost sessions don't show in the dropdown. See
      # `list_visible_sessions_for/1` for rationale (root cause:
      # lazy-spawn-from-snapshot revives killed sessions on any
      # in-flight dispatch).
      |> assign(:sessions, list_visible_sessions_for(socket.assigns[:current_workspace_uri]))
      # Session auto-join (Allen 2026-05-26 — PR #374) — every
      # navigation to a session auto-dispatches `chat.join` for the
      # caller, so the MemberPanel renders the user WITHOUT requiring
      # a manual Invite. `maybe_self_join/2` is idempotent (chat.join
      # short-circuits on already-member); failures (no caps /
      # cross-workspace / target missing) surface as a flash via the
      # same decomposition the Invite handler uses —
      # `feedback_let_it_crash_no_workarounds` forbids silent default-join.
      |> maybe_self_join(current_session_uri)
      # Per-session orchestrator INSTANCE health (2026-05-26 — PR #376).
      # Defaults to nil/false; `assign_session_context/2` overwrites
      # with the real classification + cap-gate result. Set BEFORE
      # `assign_session_context/2` so that helper's assigns win.
      |> assign(:orchestrator_health, nil)
      |> assign(:orchestrator_can_restart?, false)
      |> assign(:orchestrator_flash_error, nil)
      |> assign_session_context(current_session_uri)
      |> assign(:current_view, :conversation)
      |> assign(:active_pty_agent_uri, nil)
      |> assign(:cc_events, [])
      |> assign(:debug_open, false)
      # V1 UI SPEC §2C.3 — MemberPanel's Invite modal visibility.
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
          {:noreply, select_session(socket, session_uri)}

        _ ->
          {:noreply, assign(socket, :flash_error, gettext("Bad session URI: %{uri}", uri: encoded))}
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
    cond do
      # Task #55 round-2 codex MEDIUM (2026-05-27) — workspace guard.
      # Reject any foreign-workspace event that slips through (e.g. from
      # an old subscription on a session that's since been moved, or a
      # transitional period where mount-time list_sessions_for/1 hasn't
      # caught up to the latest workspace switch). Belt-and-suspenders
      # over the mount-time subscription filter.
      not session_in_caller_workspace?(source_session_uri, socket) ->
        {:noreply, socket}

      URI.to_string(source_session_uri) == URI.to_string(socket.assigns.current_session_uri) ->
        {:noreply,
         socket
         |> assign(:messages_empty?, false)
         |> stream_insert(:messages, message_to_row(msg), at: -1)}

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

  # Task #55 round-2 codex MEDIUM — workspace guard for inbound session
  # events. Returns true when the caller's `current_workspace_uri`
  # equals the target session's workspace OR the caller holds
  # cross-workspace authority (same predicate `select_session/2`'s
  # gate uses, kept in sync).
  defp session_in_caller_workspace?(%URI{} = session_uri, socket) do
    authorize_session_view(socket, session_uri) == :ok
  end

  defp session_in_caller_workspace?(_, _), do: false

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
  # ## Envelope shape (PR-N3 codex r2 HIGH-1, Allen 2026-05-25)
  #
  # The broadcast envelope is security-minimal: `uri / slice_key /
  # cursor / event_at / result_summary` only. Slice content
  # (`new_slice` / `old_slice` / `result`) is NOT in the envelope —
  # pre-fix it leaked plaintext slice fields (e.g.
  # `Ezagent.Behavior.ApiKeys.put_api_key`'s plaintext key) to any
  # same-VM subscriber of the public-derivable topic. Codex r2 (PR
  # #328) flagged this; the invariant test
  # `slice_change_event_carries_no_slice_content_test.exs` locks
  # the new shape in.
  #
  # ## Routing
  #
  # To synthesize the chat flash, `format_slice_change/1` re-fetches
  # the affected entity's slice via `Ezagent.Kind.get_slice/2`. This
  # runs in the LV process (the admin's session); the LV mount only
  # subscribes the caller to its OWN `caller_uri` topic, so the
  # re-fetch is on the caller's own slice. Future per-session
  # subscriptions (PR-N3/N4 with NotificationSubscriptions) get the
  # same default-secure shape — the event doesn't leak, the re-fetch
  # is the subscriber's own cap concern.
  def handle_info({:slice_changed, %{} = event}, socket) do
    # PR-N3 r4 codex r4 MEDIUM (Allen 2026-05-25) — verify the
    # event's `:uri` matches a URI this LV legitimately subscribes
    # to before doing any slice re-fetch. The LV subscribes the
    # caller's own topic ONLY (`mount/3` line ~124); a wrong-topic
    # broadcast or buggy producer that sent a foreign URI on this
    # topic would otherwise cause us to read the OTHER entity's
    # chat slice and render its preview. Default-deny: anything
    # not on the allowlist degrades to a no-op (telemetry only).
    if event_uri_authorized?(event, socket) do
      # PR-N3 r4 codex r4 HIGH-1 (Allen 2026-05-25) — bounded-
      # blocking format. `format_slice_change/1`'s chat branch
      # calls `Kind.get_slice/2` (a synchronous `GenServer.call`
      # with default 5s timeout) followed by a `MessageStore`
      # lookup. Under burst (busy Kind, wedged Repo) this would
      # block the LV mailbox for up to 5s × N events, stalling
      # renders/clicks/uploads. The fix: cap the resolution time
      # at 250ms via `Task.async` + `Task.yield`. If resolution
      # doesn't return in time, shut the task down and degrade
      # to the generic flash — the flash ALWAYS fires; what
      # degrades under load is the preview fidelity, never the
      # responsiveness.
      flash = format_slice_change_bounded(event, 250)
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

  # PR-N3 r4 codex r4 MEDIUM — the allowlist. Today AdminLive
  # subscribes exactly one topic (the caller's own); future
  # multi-subscription (per-session inbox, plugin-owned entities)
  # extends this to `socket.assigns[:subscribed_uris]` MapSet.
  # Until then, the caller URI IS the allowlist.
  defp event_uri_authorized?(%{uri: %URI{} = event_uri}, %{assigns: assigns}) do
    case assigns[:caller_uri] do
      %URI{} = caller_uri -> URI.to_string(event_uri) == URI.to_string(caller_uri)
      _ -> false
    end
  end

  defp event_uri_authorized?(_, _), do: false

  # PR-N3 r4 codex r4 HIGH-1 — bounded-blocking wrapper around
  # `format_slice_change/1`. Spawn a short-lived Task to do the
  # actual `Kind.get_slice` + `MessageStore` lookup; yield up to
  # `timeout_ms`; on timeout, shut the task down and return the
  # generic fallback. The LV mailbox never blocks longer than
  # `timeout_ms` regardless of producer/Repo health.
  #
  # Why not `Task.Supervisor.async_nolink`: AdminLive doesn't own
  # a TaskSupervisor (would require app-level wiring + per-plugin
  # boilerplate). `Task.async` + `Task.shutdown` is sufficient
  # for a fire-and-forget format with no parent-trapping semantics
  # — the task is linked but if it crashes inside the format
  # function (e.g. malformed slice), we want the LV to know via
  # the `{ref, result}` message OR the `:DOWN` after shutdown.
  # `Task.shutdown(task, :brutal_kill)` cleans up cleanly.
  defp format_slice_change_bounded(event, timeout_ms) do
    task = Task.async(fn -> format_slice_change(event) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, flash} when is_binary(flash) ->
        flash

      _ ->
        # Timeout or crash. Generic fallback — the flash still
        # fires, just without the message preview.
        case Map.get(event, :uri) do
          %URI{} = uri -> "Update on #{URI.to_string(uri)}"
          _ -> "Update received"
        end
    end
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
  # event (PR-N3 codex r2 HIGH-1 security-minimal shape — see
  # `apps/ezagent_core/lib/ezagent/slice_change.ex` moduledoc) into a
  # human-readable flash string.
  #
  # The envelope carries `uri / slice_key / cursor / event_at /
  # result_summary` only — to render anything richer we re-fetch
  # the affected entity's slice via `Ezagent.Kind.get_slice/2`.
  # That call goes to the live Kind GenServer; the read is in-VM and
  # synchronous. A failed fetch (Kind not alive, etc.) degrades to a
  # generic "Update on <uri>" line so the flash always surfaces.
  #
  # For chat (`slice_key == :chat`) we look up the event's `:cursor`
  # in the slice's cursor-indexed `:recent_messages` ring (PR-N3 r4
  # codex r3 HIGH-1 race fix). Pre-r4 we read `:last_received` (a
  # single pointer) which raced under burst: 3 events arriving
  # faster than the LV mailbox drained all read the latest pointer,
  # rendering 3 identical flashes and losing 2 distinct
  # notifications. Now: receive envelope cursor C → re-fetch slice →
  # `List.keyfind(ring, C, 0)` returns the `{C, msg_id}` tuple for
  # THIS event regardless of how many later events have committed,
  # so each flash renders its correct message.
  #
  # Fallback chain:
  # 1. Ring has cursor C → load + render that msg_id
  # 2. Ring missing C (older than @recent_messages_ring_depth, slice
  #    not loaded yet, or pre-PR-N3-r4 snapshot without the field) →
  #    fall back to `:last_received.message_id` for the LATEST event
  #    only (preserves the pre-r4 behavior — single-event case still
  #    renders correctly; burst case degrades to "1 of N correct,
  #    N-1 generic" which is strictly better than r3's "0 of N
  #    correct, N identical")
  # 3. Slice unreadable / no chat data → generic "New chat update"
  #    line (the bridge ALWAYS fires a flash; the worst case is
  #    losing the sender + preview, never losing the flash itself)
  #
  # Other slice keys (`:identity` / `:workspace` / etc — PR-N4
  # producers) get the generic fallback until bespoke formatters land.
  def format_slice_change(%{uri: %URI{} = uri, slice_key: :chat, cursor: cursor} = _event)
      when is_integer(cursor) do
    case Ezagent.Kind.get_slice(uri, :chat) do
      {:ok, %{} = slice} ->
        case chat_msg_id_for_cursor(slice, cursor) do
          {:ok, msg_id} -> chat_flash_for(msg_id)
          :not_found -> "New chat update on #{URI.to_string(uri)}"
        end

      _ ->
        "New chat update on #{URI.to_string(uri)}"
    end
  end

  # Legacy / synthesised event without a cursor (pre-PR-N3-r4 test
  # fixtures + the `:not_a_map` / other-shape paths). Keep the old
  # `:last_received` resolution so existing tests + any unmigrated
  # producer surface a flash.
  def format_slice_change(%{uri: %URI{} = uri, slice_key: :chat} = _event) do
    case Ezagent.Kind.get_slice(uri, :chat) do
      {:ok, %{last_received: %{message_id: msg_id}}} when is_binary(msg_id) ->
        chat_flash_for(msg_id)

      _ ->
        "New chat update on #{URI.to_string(uri)}"
    end
  end

  def format_slice_change(%{uri: %URI{} = uri, slice_key: slice_key} = _event)
      when is_atom(slice_key) do
    "Update on #{URI.to_string(uri)} (#{slice_key})"
  end

  def format_slice_change(other), do: "Slice changed: #{inspect(other)}"

  # PR-N3 r4 (Allen 2026-05-25) — look up the msg_id for a given
  # broadcast envelope cursor in the slice's `:recent_messages` ring.
  # Each ring entry is `{cursor, msg_id}` (newest first); cursors
  # match `SliceChange` broadcast envelope cursors exactly. Returns
  # `:not_found` for cursors older than the ring's bound, missing
  # ring (pre-PR-N3-r4 snapshot), or non-binary msg_id (defensive).
  defp chat_msg_id_for_cursor(slice, cursor) when is_map(slice) and is_integer(cursor) do
    ring = Map.get(slice, :recent_messages, [])

    case List.keyfind(ring, cursor, 0) do
      {^cursor, msg_id} when is_binary(msg_id) -> {:ok, msg_id}
      _ -> :not_found
    end
  end

  # Build the chat-style flash from a persisted message id. Splitting
  # this out makes the `:chat` clause a single match-and-render so the
  # re-fetch failure path stays readable.
  defp chat_flash_for(msg_id) when is_binary(msg_id) do
    case Ezagent.MessageStore.by_id(msg_id) do
      {:ok, %Ezagent.Message{sender: sender, body: body}} ->
        "New message from #{URI.to_string(sender)}: #{message_preview(body)}"

      _ ->
        "New chat message (id #{msg_id})"
    end
  end

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
    {mentions, legend_triggers} =
      parse_mentions(
        text,
        socket.assigns[:member_options] || [],
        socket.assigns[:session_legends] || %{}
      )

    File.mkdir_p!(Ezagent.Home.path("uploads"))

    # SPEC v3 §3.6 (Phase 9 PR-7) — resource URIs are 3-segment
    # `resource://<type>/<workspace>/<name>`. Use the caller's
    # workspace so the resource belongs to the same tenant as the
    # session that owns it.
    #
    # SPEC #324 rev 3 / PR #362 (Allen 2026-05-26): NO silent default
    # workspace fallback. If the authenticated caller has no derivable
    # workspace, raise — uploading to a phantom `resource://uploads/
    # default/...` would silently orphan the file from any real tenant.
    workspace_name =
      case Ezagent.Capability.workspace_of(socket.assigns.current_entity_uri) do
        %URI{host: ws_name} when is_binary(ws_name) ->
          ws_name

        other ->
          raise ArgumentError,
                "current_entity_uri does not yield a workspace URI with a binary host " <>
                  "— got #{inspect(other)} for current_entity_uri=" <>
                  "#{inspect(socket.assigns.current_entity_uri)}. Per SPEC #324 rev 3 / " <>
                  "PR #362, there is NO silent default workspace fallback; the " <>
                  "authenticated caller must carry a workspace structurally."
      end

    attachments =
      consume_uploaded_entries(socket, :attachments, fn %{path: tmp_path}, entry ->
        uuid = Ecto.UUID.generate()
        safe_name = sanitize_filename(entry.client_name)
        stored_name = "#{uuid}-#{safe_name}"
        dest = Path.join(Ezagent.Home.path("uploads"), stored_name)
        File.cp!(tmp_path, dest)
        {:ok, Ezagent.URI.new!("resource://uploads/#{workspace_name}/#{stored_name}")}
      end)

    if String.trim(text) == "" and attachments == [] do
      {:noreply,
       assign(
         socket,
         :flash_error,
         gettext("Message text or at least one attachment is required.")
       )}
    else
      send_chat_message(socket, text, attachments, mentions, legend_triggers)
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
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # with try/rescue keeping the malformed-URI error flash.
    case (try do
            {:ok, Ezagent.URI.new!(session_uri_str)}
          rescue
            ArgumentError -> :error
          end) do
      {:ok, new_uri} ->
        {:noreply, select_session(socket, new_uri)}

      _ ->
        {:noreply,
         assign(socket, :flash_error, gettext("Bad session URI: %{uri}", uri: session_uri_str))}
    end
  end

  # SPEC #366 (Allen 2026-05-26) — `template_class` is now a required
  # form field (rendered as a dropdown). The previous silent
  # `"default"` fallback in `EzagentDomainChat.create_session/3` was
  # removed; this LV handler refuses the submit when the operator
  # didn't pick a class.
  #
  # Codex PR #369 r1 HIGH — pass `socket.assigns.caller_uri` (the
  # authenticated entity URI from LiveAuth) AND an explicit
  # `:workspace_uri` so the session is created in the operator's
  # current workspace, not whatever workspace admin happens to belong
  # to. The previous `User.admin_uri()` argument silently dropped the
  # tenant operator into `workspace://system` and joined `admin`
  # instead of the actual caller.
  def handle_event(
        "create_session",
        %{"new_session" => %{"short_name" => name, "template_class" => class}},
        socket
      )
      when is_binary(name) and name != "" and is_binary(class) and class != "" do
    case EzagentDomainChat.create_session(
           String.trim(name),
           socket.assigns.caller_uri,
           template_name: class,
           workspace_uri: socket.assigns.current_workspace_uri
         ) do
      {:ok, session_uri, meta} ->
        # SPEC `2026-05-26-session-create-orchestrator-unified` Gap A +
        # Invariant #9 — render the orchestrator status from the meta
        # map. Silently discarding the meta would be an Invariant #9
        # violation: a `:pending` / `:failed` orchestrator would be
        # invisible to the operator at the moment of creation.
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
         # Task #55 — workspace-scoped session list (see mount/3).
         # 2026-06-02 — ghost-session filter; see mount/3 comment.
         |> assign(:sessions, list_visible_sessions_for(socket.assigns[:current_workspace_uri]))
         |> assign(
           :new_session_form,
           to_form(%{"short_name" => "", "template_class" => ""}, as: "new_session")
         )
         |> assign(:flash_error, orchestrator_flash_text(meta))}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext("Create failed: %{reason}", reason: inspect(reason))
         )}
    end
  end

  # SPEC `2026-05-26-session-create-orchestrator-unified` Gap A — produce
  # a `flash_error` text for the orchestrator-status field of
  # `EzagentDomainChat.create_session/3`'s meta map. `:ready` → nil
  # (suppress the existing error banner — happy path); `:pending` /
  # `:failed` → human-readable text that surfaces the partial-success
  # to the operator. The `flash_error` assign re-uses the LV's existing
  # admin-error banner; a future PR can split this into its own slot.
  # 2026-05-31 orchestrator-startup-atomicity §8 — the orchestrator status
  # is now a 2-STATE model: `:ready | :failed`. `:pending` is GONE (the
  # atomic gate either succeeds or fails-loud → rollback within the 30s
  # window; there is no half-started "pending" surface). `:degraded` is no
  # longer a separate STATE either — it is `:ready` + a degraded warning
  # carried in `orchestrator_error` (`{:role_degraded, _}`), so the happy
  # `:ready` arm suppresses the banner and the role-degraded notification
  # flows through the owner inbox (Invariant #9), not the create flash.
  defp orchestrator_flash_text(meta) when is_map(meta) do
    case Map.get(meta, :orchestrator_status) do
      :ready ->
        nil

      :failed ->
        reason = Map.get(meta, :orchestrator_error)

        # `:no_orchestrator` (plain session) is NOT an error — suppress.
        if reason == :no_orchestrator do
          nil
        else
          gettext("Orchestrator failed: %{reason}; click Restart to retry.",
            reason: inspect(reason)
          )
        end

      _ ->
        nil
    end
  end

  defp orchestrator_flash_text(_), do: nil

  # SPEC `2026-05-26-session-create-orchestrator-unified` Gap A —
  # rehydrate path's status is debug-level (operator's on admin page
  # already; OrchestratorHealthCard surfaces it visually).
  defp log_orchestrator_status_on_rehydrate(session_uri, meta) when is_map(meta) do
    case Map.get(meta, :orchestrator_status) do
      :ready ->
        :ok

      status ->
        require Logger

        Logger.info(
          "AdminLive.ensure_main_session rehydrate: orchestrator " <>
            "status=#{inspect(status)} for #{URI.to_string(session_uri)} " <>
            "(error=#{inspect(Map.get(meta, :orchestrator_error))})"
        )
    end
  end

  defp log_orchestrator_status_on_rehydrate(_, _), do: :ok

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
    case safe_view_id(view_str) do
      {:ok, id} ->
        socket =
          socket
          |> assign(:current_view, id)
          |> assign(:view_module, view_module_for(socket.assigns.applicable_views, id))
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
    messages = load_session_messages(socket.assigns.current_session_uri)

    socket
    |> assign(:oldest_cursor, oldest_cursor(messages))
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
        target = Ezagent.URI.with_action(session_uri, :chat, :join)

        # SPEC §2C.4 step 2 — dispatch as `:call` so the result is
        # observable; `:caller_inbox` is irrelevant for `:call` (the
        # GenServer.call return is the result) — keep `reply: :ignore`.
        result =
          Ezagent.Invocation.dispatch(%Ezagent.Invocation{
            target: target,
            mode: :call,
            args: %{member: Ezagent.URI.new!(trimmed)},
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
        # on this session (`caller_can_restart_orchestrator?/2` —
        # computed in `assign_session_context/2`). Re-check here as the
        # chokepoint: a DOM tamper bypassing the
        # `:if={@orchestrator_can_restart?}` render guard MUST still land
        # in :unauthorized.
        #
        # 2026-05-31 orchestrator-startup-atomicity §6 — once the cap
        # check passes, the restart REPAIRS via
        # `EzagentDomainChat.repair_orchestrator/2` (re-materialize OTU +
        # §5 atomic gate). The owner/lineage/`spawned_by` resolution that
        # the old `template.instantiate` dispatch needed is now internal
        # to `repair_orchestrator` (it reads `Session.owner/1`), so the LV
        # no longer computes the dispatch target / instance-name /
        # spawned_by here.
        if not caller_can_restart_orchestrator?(socket, session_uri) do
          {:noreply,
           assign(
             socket,
             :orchestrator_flash_error,
             gettext("Unauthorized — only the session owner may restart the orchestrator.")
           )}
        else
          do_restart_orchestrator(socket, health, session_uri)
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

  defp do_restart_orchestrator(socket, health, session_uri) do
    # 2026-05-31 orchestrator-startup-atomicity §6 — Restart is now a
    # REPAIR. The old path dispatched `template.instantiate` + respawned
    # the PTY but NEVER set `orchestrator_template_uri` (OTU), so it could
    # not fix the nil-OTU sessions (`main`, `orch-feishu-7429`) that were
    # the whole reason for the SPEC. `EzagentDomainChat.repair_orchestrator/2`
    # RE-MATERIALIZES the OTU from the session's template THEN runs the §5
    # atomic readiness gate (cap grants + MCP registration + member join).
    # The OrchestratorAdmin :restart cap was already checked in the
    # `handle_event` clause above.
    result = EzagentDomainChat.repair_orchestrator(session_uri, health.workspace_uri)

    case result do
      {:ok, ^session_uri, _meta} ->
        # Re-classify; success path lands `:alive` (or a new `:crashed`
        # if the fresh worker died immediately — itself a useful signal).
        {:noreply,
         socket
         |> assign_session_context(session_uri)
         |> assign(:orchestrator_flash_error, nil)}

      {:error, :unauthorized} ->
        {:noreply,
         assign(
           socket,
           :orchestrator_flash_error,
           gettext("Unauthorized — you may not restart this orchestrator.")
         )}

      {:error, :cross_workspace_denied} ->
        {:noreply,
         assign(
           socket,
           :orchestrator_flash_error,
           gettext(
             "Cross-workspace denied — orchestrator lives in workspace %{workspace}.",
             workspace: URI.to_string(health.workspace_uri)
           )
         )}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :orchestrator_flash_error,
           gettext("Restart failed: %{reason}", reason: inspect(reason))
         )}
    end
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
      Ezagent.URI.new!(URI.to_string(session_uri) <> "?action=routing." <> Atom.to_string(action))

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
  #
  # Task #55 round-2 codex CRIT-2 (2026-05-27) — workspace gate. Pre-fix
  # any caller could deep-link `?session=<foreign-workspace-session>`
  # and the LV called `load_session_messages/1` before any cap check,
  # exposing messages from sessions in workspaces the caller doesn't
  # belong to. Post-fix `select_session/2` refuses any session whose
  # workspace differs from the caller's current workspace UNLESS the
  # caller holds structural cross-workspace authority (system workspace
  # member or `workspace_uri: :any` cap).
  defp select_session(socket, %URI{} = session_uri) do
    case authorize_session_view(socket, session_uri) do
      :ok ->
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
        # Session auto-join (Allen 2026-05-26) — every session switch is a
        # navigation event for membership purposes (the new session may be
        # a freshly-spawned one we've never joined). `maybe_self_join/2`
        # is idempotent so re-selecting a session we're already in is a
        # no-op.
        |> maybe_self_join(session_uri)
        |> assign_session_context(session_uri)
        |> assign(:current_view, new_view)
        # Reset PTY agent binding — the new session may not have that
        # agent as a member.
        |> assign(:active_pty_agent_uri, nil)
        |> assign(:oldest_cursor, oldest_cursor(new_messages))
        |> assign(:messages_empty?, new_messages == [])
        |> stream(:messages, new_messages, reset: true)

      {:error, :cross_workspace_denied} ->
        # Refuse the session-switch + surface a flash. Caller's
        # `current_session_uri` is unchanged — the LV stays on whatever
        # session it was already viewing (typically the workspace's
        # main session from mount).
        assign(
          socket,
          :flash_error,
          gettext(
            "Cross-workspace denied — that session belongs to a different workspace."
          )
        )
    end
  end

  # Task #55 round-2 codex CRIT-2 — workspace gate. Allowed when ANY of:
  #
  #   1. Target session's workspace == caller's current workspace.
  #   2. Caller's current workspace is `workspace://system` (system
  #      members hold structural cross-workspace authority per SPEC v3
  #      §13.1).
  #   3. Caller holds a `workspace_uri: :any` cap (cross-workspace cap
  #      via `Ezagent.Capability.cross_workspace?/2`) — the same
  #      predicate dispatch step 5.6 uses to override workspace
  #      isolation.
  #
  # `:cross_workspace_denied` is the same error atom dispatch returns
  # so observability (telemetry / log surface) stays uniform.
  defp authorize_session_view(socket, %URI{} = session_uri) do
    caller_workspace = socket.assigns[:current_workspace_uri]
    target_workspace = Ezagent.Capability.workspace_of(session_uri)
    caller_uri = socket.assigns[:caller_uri]
    caller_caps = socket.assigns[:caller_caps] || []

    cond do
      # `:any` (system targets, e.g. cross-cutting sessions) — never
      # workspace-bound. Allowed.
      target_workspace == :any ->
        :ok

      # Same workspace — happy path.
      match?(%URI{}, caller_workspace) and match?(%URI{}, target_workspace) and
          URI.to_string(caller_workspace) == URI.to_string(target_workspace) ->
        :ok

      # System workspace member OR explicit cross-workspace cap.
      caller_holds_cross_workspace_authority?(caller_uri, caller_caps) ->
        :ok

      true ->
        {:error, :cross_workspace_denied}
    end
  end

  defp caller_holds_cross_workspace_authority?(nil, _caps), do: false

  defp caller_holds_cross_workspace_authority?(%URI{} = caller_uri, caps) do
    caps_list =
      cond do
        is_list(caps) -> caps
        is_struct(caps, MapSet) -> MapSet.to_list(caps)
        true -> List.wrap(caps)
      end

    Enum.any?(caps_list, &Ezagent.Capability.cross_workspace?(&1, caller_uri))
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
        workspace_name_from_uri(assigns[:current_workspace_uri])
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
      # SPEC #366 (Allen 2026-05-26) — eliminate silent `"default"`
      # template-class fallback in session creation. The new-session
      # form needs an explicit dropdown sourced from the current
      # workspace's `session_templates` map. Recomputed on every
      # render (cheap — one Store.get_by_name) so newly-added
      # templates are immediately pickable without an LV remount.
      |> assign(:template_class_options, template_class_options_for(assigns))

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

  # Bundle the per-session reads needed by SessionEditor + MemberPanel.
  #
  # Username & Auth UI Task 1 (Phase 8c PR-O) — resolve display names
  # for every URI that will be rendered to a human in one batch query
  # (`Ezagent.EntityPresenter.display_many/1`). The same map covers
  # the Members panel rows, the @mention picker JSON (so users can
  # filter by name), and conversation message senders. Falls back to
  # the URI path segment when no profile exists.
  # Session auto-join (Allen 2026-05-26) — dispatch `chat.join` for the
  # caller on every session navigation so the MemberPanel renders them
  # automatically.
  #
  # Cap correctness: a user navigating to a session in their own
  # workspace holds the `cap(:session, :any, :any, workspace_uri:
  # their_ws)` cap from `User.default_caps/1`, which step 5.5 matches
  # against `chat.join`. A user without that cap (e.g. unauthenticated
  # mount, anon session, cross-workspace navigation without an explicit
  # cross-workspace cap) gets `{:error, :unauthorized}` back — we
  # surface it as a flash via `flash_error` so the operator SEES the
  # gap instead of silently rendering an empty member panel.
  #
  # Idempotency: `Behavior.Chat.invoke(:join)` short-circuits on
  # already-online + monitor-alive (see `chat.ex` Allen 2026-05-26
  # idempotency comment). LV remounts + repeated `select_session`
  # calls don't stack monitors or notifications.
  #
  # Codex r1 MEDIUM-4 (2026-05-26): MUST gate on `connected?(socket)`.
  # Phoenix LiveView mounts twice — once for the disconnected dead-
  # render (synchronous HTTP), once for the live socket post-handshake.
  # Pre-fix this dispatched `chat.join` TWICE per page load AND ran a
  # session mutation during the HTTP render path. Post-fix the join
  # happens only on the live socket — the dead render still gets the
  # accurate MemberPanel via `assign_session_context/2`'s
  # `read_session_members/1` (which reads the live slice the previous
  # mount populated). `select_session/2` (the phx-click + handle_params
  # paths) always runs in the live socket so the guard is a no-op there.
  #
  # Not-signed-in / no-creds: skip the dispatch entirely. The session
  # may legitimately be one the visitor only has read authority on
  # (admin observing); the Invite path remains available for the
  # creator to add them later.
  defp maybe_self_join(socket, %URI{} = session_uri) do
    if not connected?(socket) do
      # Dead-render pass — skip. The live mount runs `maybe_self_join`
      # again right after the socket connects.
      socket
    else
      do_maybe_self_join(socket, session_uri)
    end
  end

  defp do_maybe_self_join(socket, %URI{} = session_uri) do
    caller_uri = Map.get(socket.assigns, :caller_uri) || socket.assigns[:current_entity_uri]
    caller_caps = Map.get(socket.assigns, :caller_caps)

    case caller_uri do
      %URI{} = caller_uri when not is_nil(caller_caps) ->
        target = Ezagent.URI.with_action(session_uri, :chat, :join)

        result =
          Ezagent.Invocation.dispatch(%Ezagent.Invocation{
            target: target,
            mode: :call,
            args: %{member: caller_uri},
            ctx: %{
              caller: caller_uri,
              caps: caller_caps,
              reply: :ignore
            }
          })

        case result do
          :ok ->
            socket

          {:ok, _} ->
            socket

          {:error, :unauthorized} ->
            # Let-it-crash spec — DO NOT silently auto-join (would
            # require widening the principal to system-internal,
            # which would defeat the per-session cap model). Surface
            # the gap so the operator can act (request a cap from
            # the session owner, or accept that they can read but
            # not participate). `feedback_let_it_crash_no_workarounds`.
            assign(
              socket,
              :flash_error,
              gettext(
                "No chat.join cap on %{session} — ask the session owner to invite you, or you can only observe.",
                session: URI.to_string(session_uri)
              )
            )

          {:error, :cross_workspace_denied} ->
            assign(
              socket,
              :flash_error,
              gettext(
                "Session %{session} is in another workspace — auto-join skipped.",
                session: URI.to_string(session_uri)
              )
            )

          {:error, {:member_not_registered, _}} ->
            # Caller's own Kind isn't alive yet (rare race during
            # login → /sessions navigation before identity boot
            # completes). Spawning a User Kind is the identity
            # domain's job; we don't reach across.
            require Logger

            Logger.warning(
              "AdminLive.maybe_self_join: caller Kind not registered " <>
                "for #{URI.to_string(caller_uri)} on #{URI.to_string(session_uri)} — " <>
                "skipping auto-join (next remount will retry)."
            )

            socket

          {:error, reason} ->
            # Unexpected — log + render. The session is still usable
            # in observe-mode; we don't crash the LV mount because
            # of a transient dispatch failure.
            require Logger

            Logger.warning(
              "AdminLive.maybe_self_join: chat.join failed for " <>
                "#{URI.to_string(caller_uri)} on #{URI.to_string(session_uri)}: " <>
                inspect(reason)
            )

            socket
        end

      _ ->
        # Anonymous / not-signed-in / no caps assigned yet — skip.
        socket
    end
  end

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

    # 2026-05-25 — per-session ExternalMirror bindings list, surfaced by
    # `EzagentDomainUi.ExternalMirror.View`. Read via the dispatched
    # `list_bindings` action so CapBAC step 5.5 enforces Cap 1; a
    # caller without the cap gets [] (the view renders the empty state
    # AND a navigate link to the per-session admin LV).
    session_bindings = list_session_bindings(socket, session_uri)

    display_map = Ezagent.EntityPresenter.display_many(member_uris)

    member_options =
      member_uris
      |> Enum.sort()
      |> Enum.map(fn uri ->
        %{"uri" => uri, "display_name" => Map.get(display_map, uri, uri)}
      end)

    {orchestrator_health, can_restart?} = compute_orchestrator_health(socket, session_uri)

    # team-routing-unification §3.6 (PR-6) — the session legend registry, so
    # the chat composer's `parse_mentions/3` can resolve a `@legend` to its
    # symbolic token (precedence over the URI/bare-member path).
    session_legends = read_session_legends(session_uri)

    socket
    |> assign(:session_members, members)
    |> assign(:member_options, member_options)
    |> assign(:session_legends, session_legends)
    |> assign(:invite_options, invite_options)
    |> assign(:display_map, display_map)
    |> assign(:applicable_views, applicable)
    |> assign(:view_module, view_module_for(applicable, current_view_or_default(socket)))
    |> assign(:session_info, build_session_info(session_uri, members))
    |> assign(:feishu_chat_ids, feishu_chat_ids_for(session_uri))
    |> assign(:session_routing_rules, session_routing_rules)
    |> assign(:session_bindings, session_bindings)
    |> assign(:orchestrator_health, orchestrator_health)
    |> assign(:orchestrator_can_restart?, can_restart?)
    |> assign(:orchestrator_flash_error, nil)
    |> assign_routing_uri_options()
  end

  # Compute orchestrator-instance health for the current session +
  # whether the caller holds a cap that would let the Restart action
  # through. Returns `{nil, false}` for sessions with no workspace
  # binding (the card hides itself in that case — see render/1).
  #
  # The can_restart? guard is purely a UI affordance — CapBAC step 5.5
  # still gates the dispatch. We don't want operators to see a Restart
  # button that always returns :unauthorized.
  defp compute_orchestrator_health(socket, %URI{} = session_uri) do
    case Ezagent.Orchestrator.Health.classify(session_uri) do
      {:ok, health} ->
        can_restart? =
          health.status == :crashed and
            caller_can_restart_orchestrator?(socket, session_uri)

        {health, can_restart?}

      {:error, :session_not_workspace_bound} ->
        # Session not bound to a workspace yet — the orchestrator URI is
        # not derivable. Hide the card.
        {nil, false}
    end
  end

  defp compute_orchestrator_health(_socket, _), do: {nil, false}

  # RFC #402 (Allen 2026-05-26) — restart authority is bound to the
  # session OWNER, not generic template-instantiate.
  #
  # The caller may restart iff they hold the
  # `Ezagent.Behavior.OrchestratorAdmin :restart` cap on this session's
  # URI. That cap is granted to:
  #
  #   * the session owner (`slice.chat.owner_uri`) — by
  #     `Session.spawn_from_template/2 → grant_owner_orchestrator_admin_cap/3`
  #     at session-create time, and
  #   * the bootstrap admin — via its all-caps `:any/:any/:any/:any`
  #     grant which matches every needed cap.
  #
  # Pre-RFC the gate was `cap(:any, Behavior.Template, :instantiate)`
  # on the cc-orchestrator template URI — that gave EVERY workspace-
  # template-instantiate holder restart authority on every session in
  # the workspace, decoupled from session ownership. The new gate is
  # narrower (session-instance scoped) AND broader (orchestrator
  # template caps no longer needed for the common owner path).
  defp caller_can_restart_orchestrator?(socket, %URI{} = session_uri) do
    caps = Map.get(socket.assigns, :caller_caps, MapSet.new())

    needed = %{
      kind: :session,
      behavior: Ezagent.Behavior.OrchestratorAdmin,
      # SPEC 2026-05-27 capability-action-axis — OrchestratorAdmin
      # actions/0 == [:restart].
      action: :restart,
      instance: session_uri,
      workspace_uri:
        case Ezagent.Capability.workspace_of(session_uri) do
          %URI{} = ws -> ws
          :any -> :any
        end
    }

    Enum.any?(caps, &Ezagent.Capability.matches?(&1, needed))
  end

  defp caller_can_restart_orchestrator?(_socket, _), do: false

  # ExternalMirror bindings for a session, via the dispatched
  # `list_bindings` facade so the CapBAC gate runs. Read failures (no
  # Cap 1 / not_ready / cross_workspace_denied / no_such_actor) are
  # absorbed to [] — the view renders the empty state, which already
  # explains how to proceed (navigate to the per-session admin LV).
  defp list_session_bindings(socket, %URI{} = session_uri) do
    ctx = %{
      caller: Map.get(socket.assigns, :caller_uri) || socket.assigns.current_entity_uri,
      caps: Map.get(socket.assigns, :caller_caps, MapSet.new()),
      reply: :ignore
    }

    case Ezagent.ExternalMirror.list_bindings(session_uri, ctx) do
      {:ok, bindings} -> bindings
      _ -> []
    end
  rescue
    # ExternalMirror facade missing / DB down / etc. — view falls
    # through to empty state.
    _ -> []
  end

  defp list_session_bindings(_socket, _), do: []

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
  # Chat (`:conversation`) first, Routing (`:routing`) second,
  # ExternalMirror Bindings (`:external_mirror`) third, Terminal
  # (`:pty`) last. Unknown ids (future plugin views) fall to the end in
  # registration order so adding a new view doesn't silently disappear.
  # 2026-05-25 — `:external_mirror` slot added between routing + pty
  # per Allen's "Routing-rules + ExternalMirror-bindings tabs" intent.
  @view_display_order [:conversation, :routing, :external_mirror, :pty]
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

      {:ok, _pid} ->
        # Read the chat slice through the T3-normalized accessor — post-
        # lifecycle the on-process slice is two-container, so a raw
        # `%{state: %{chat: chat_slice}}` match would hand
        # `template_working_copy/1` the `%{state: …, transients: …}`
        # wrapper instead of the flat chat slice. (post-lifecycle
        # remediation.)
        slice =
          case Ezagent.Kind.get_slice(session_uri, :chat) do
            {:ok, chat_slice} when is_map(chat_slice) -> chat_slice
            _ -> nil
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
  # NOTE (2026-05-25): SessionRouting was removed; the Feishu chat ↔
  # session bridge it once held now lives in `external_mirror_bindings`
  # (PR-EM-3 #317). MentionRouting remains the sole routing-rule table.
  @routing_tables_for_session [
    EzagentDomainChat.Routing.MentionRouting
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
    # PR-EM-6: reads `external_mirror_bindings` filtered to
    # adapter_id="feishu", replacing the retired
    # `EzagentPluginFeishu.SessionBinding.chat_ids_for/1`.
    if Code.ensure_loaded?(EzagentPluginFeishu.InboundChatLookup) do
      EzagentPluginFeishu.InboundChatLookup.chat_ids_for(session_uri)
    else
      []
    end
  end

  # `@<entity://...>` extraction. The autocomplete inserts a trailing
  # space, so `@uri ` is the canonical shape; permissive on EOL.
  #
  # Bare-name fallback (Allen 2026-05-26 regression fix) — also scan
  # `@<word>` and resolve against the in-session `member_options` (the
  # autocomplete data source). Resolves by `display_name` first, then
  # by URI path segment (the EntityPresenter fallback). This makes a
  # typed `@cc_e2e_final` (no autocomplete expansion) actually mention
  # the cc agent. Without this, the Phase 8b mention-parser
  # (URI-only) interacted with the 2026-05-22 mention-gated dispatch
  # (`$mentions` token in the system_default rule) such that a
  # non-expanded `@name` silently sent a message that NEVER reached
  # the named agent — Allen perceived this as the cc-agent auto-spawn
  # regression, but the spawn path is healthy: PtyServer spawns
  # claude, claude opens the WS bridge, the bridge just never receives
  # a `to_claude` push because the agent isn't in the recipient set.
  #
  # `members` is a list of `%{"uri" => uri_str, "display_name" =>
  # name}` maps (from `member_options` in socket assigns). An empty
  # list disables the bare-name fallback — URI form still works.
  # Exposed (`@doc false`) for regression-test coverage of the bare-name
  # fallback. Test:
  # `apps/ezagent_plugin_liveview/test/admin_live_mention_parse_test.exs`.
  @doc false
  @spec parse_mentions(String.t(), [map()]) :: [URI.t()]
  def parse_mentions(text, members \\ [])

  def parse_mentions(text, members) when is_binary(text) and is_list(members) do
    uri_form = parse_uri_mentions(text)
    bare_form = parse_bare_mentions(text, members)

    (uri_form ++ bare_form)
    |> Enum.uniq_by(&URI.to_string/1)
  end

  def parse_mentions(_, _), do: []

  # team-routing-unification §3.6 (PR-6) — legend-aware mention parsing.
  # Consults the session legend registry BEFORE the URI/bare-member path and
  # returns a `{mentions :: [URI.t()], legend_triggers :: [String.t()]}` pair:
  #
  #   * a typed `@<name>` that IS a registered legend is intercepted and
  #     surfaced as a SYMBOLIC legend NAME in `legend_triggers` — NOT
  #     pre-canonicalized to concrete URIs. The send path
  #     (`Behavior.Chat.handle_send`) fires the legend's bound rule-set ENTRY
  #     rule through the NORMAL Resolver expansion (matching
  #     `mention(<legend_name>)` against the virtual `Message.legend_triggers`),
  #     carrying the entry's `prompt_template_ref` AND expanding magic receivers.
  #     The legend NAME never lands in `:mentions` (not URI-castable).
  #
  #   * concrete `@`-mentions resolve from the text with the legend `@<name>`
  #     tokens STRIPPED FIRST (codex 2026-06-01 MED #4). The previous code
  #     parsed the FULL text and only rejected resolved URIs whose path SEGMENT
  #     equaled the legend token — so a member whose mutable `display_name`
  #     equaled the legend (but whose URI segment differed) still leaked the
  #     message. Stripping the token text before bare/URI parsing closes that
  #     by construction: the legend token never reaches the member resolver on
  #     EITHER the segment or the display-name axis.
  #
  # `legends` is the session legend registry (`name => entry`); `%{}` yields
  # `{parse_mentions(text, members), []}`.
  @doc false
  @spec parse_mentions(String.t(), [map()], map()) :: {[URI.t()], [String.t()]}
  def parse_mentions(text, members, legends)
      when is_binary(text) and is_list(members) and is_map(legends) do
    if map_size(legends) == 0 do
      {parse_mentions(text, members), []}
    else
      legend_names =
        legend_mention_tokens(text)
        |> Enum.filter(fn name ->
          match?({:legend, _}, Ezagent.Routing.Legend.mention_token(legends, name))
        end)

      # Strip the legend `@<token>` occurrences from the text BEFORE concrete
      # URI/bare resolution, so a legend token can NEVER also resolve to a
      # member (segment OR display-name axis) — the legend's entry rule wins.
      stripped_text = strip_legend_tokens(text, legend_names)

      mentions = parse_mentions(stripped_text, members)

      {mentions, legend_names}
    end
  end

  def parse_mentions(_, _, _), do: {[], []}

  # Remove every `@<token>` occurrence for the given legend names from the text
  # (left-boundary aware), so concrete-mention parsing never sees them. The
  # surrounding text (and any non-legend `@`-mentions) is preserved.
  defp strip_legend_tokens(text, []), do: text

  defp strip_legend_tokens(text, legend_names) do
    Enum.reduce(legend_names, text, fn name, acc ->
      # Escape the legend name (CJK / dotted / hyphenated) for literal match;
      # same left-boundary rule as the parsers so `foo@legend` isn't touched.
      re = ~r/(?<![\p{L}\p{N}_])@#{Regex.escape(name)}/u
      Regex.replace(re, acc, "")
    end)
  end

  # Unicode-aware `@<token>` scan used ONLY for legend detection (the legend
  # name may be CJK — e.g. `@传话游戏` — which the ASCII URI/bare regexes don't
  # capture). Mirrors the bare-mention boundary rule (no letter/number/_ before
  # `@`).
  defp legend_mention_tokens(text) do
    ~r/(?<![\p{L}\p{N}_])@([\p{L}\p{N}][\p{L}\p{N}._-]*)/u
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp parse_uri_mentions(text) do
    ~r/@(entity:\/\/[^\s]+)/
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.flat_map(fn uri_str ->
      # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
      # with try/rescue keeping the silent-drop semantics for malformed
      # @-mentions in user-typed chat text.
      try do
        [Ezagent.URI.new!(uri_str)]
      rescue
        ArgumentError -> []
      end
    end)
  end

  # Match `@<word>` where <word> is NOT a URI (URI form is `@entity://...`
  # which contains `:` — exclude those tokens). Resolve <word> against
  # session members by URI path segment first (immutable), then by
  # `display_name` (mutable — operators can rename profiles).
  # Unresolvable bare names are silently dropped (parser tolerance —
  # the user might just be using `@` for emphasis on a non-member name).
  #
  # Unicode-aware boundary (codex 2026-05-26 MEDIUM): the previous
  # `(?<![\w])` blocked Latin email-like `foo@x` but did NOT block
  # CJK / Hangul like `中文@x` or `한글@x` because PCRE `\w` is ASCII
  # by default. The `\p{L}\p{N}_` class covers every Unicode letter +
  # digit + underscore, so a CJK character immediately before `@`
  # correctly blocks the mention match. The `u` regex modifier puts
  # the regex into Unicode mode end-to-end.
  defp parse_bare_mentions(text, members) when members != [] do
    ~r/(?<![\p{L}\p{N}_])@([A-Za-z0-9][A-Za-z0-9._-]*)/u
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.flat_map(fn name -> resolve_member_name(name, members) end)
  end

  defp parse_bare_mentions(_, _), do: []

  # Resolve a bare `@name` against the in-session member list. Two
  # match axes:
  #
  # 1. URI path segment (immutable, derived from the entity URI).
  # 2. `display_name` (mutable — operators rename profiles).
  #
  # Codex 2026-05-26 MEDIUM — display_name COLLISIONS could let an
  # in-session entity capture a mention intended for another member
  # (e.g. an agent and a user both named "admin"). Strategy:
  #
  #   a. Prefer URI-segment matches over display-name matches (the
  #      URI segment is the autocomplete-canonical name; display
  #      names are the changeable layer above it).
  #   b. If MULTIPLE distinct URIs match on the chosen axis → drop
  #      the mention entirely (ambiguous; force the operator to use
  #      autocomplete URI form for disambiguation). Silent drop is
  #      consistent with the unresolvable-name behavior — better to
  #      surface NO mention than the wrong one.
  defp resolve_member_name(name, members) do
    by_segment = match_members(members, &(uri_path_segment(Map.get(&1, "uri")) == name))

    candidates =
      if by_segment != [] do
        by_segment
      else
        match_members(members, &(Map.get(&1, "display_name") == name))
      end

    case unique_uris(candidates) do
      [uri_str] ->
        # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
        # with try/rescue keeping the silent-drop fallback for malformed
        # member URIs (corrupted Workspace.Store row, etc.).
        try do
          [Ezagent.URI.new!(uri_str)]
        rescue
          ArgumentError -> []
        end

      _ ->
        # Either no match (unresolvable) OR ambiguous (>1 distinct
        # URI). Both are silent drops — the operator can use
        # autocomplete to insert the unambiguous `@entity://...` form.
        []
    end
  end

  defp match_members(members, pred) do
    Enum.filter(members, fn
      m when is_map(m) -> pred.(m)
      _ -> false
    end)
  end

  defp unique_uris(members) do
    members
    |> Enum.map(&Map.get(&1, "uri"))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp uri_path_segment(uri_str) when is_binary(uri_str) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # with try/rescue (display fallback to nil for malformed input).
    try do
      case Ezagent.URI.new!(uri_str) do
        %URI{path: "/" <> rest} when rest != "" ->
          # entity URIs are `/<workspace>/<name>`; bare display is last segment.
          case String.split(rest, "/", parts: 2) do
            [_ws, name] -> name
            [name] -> name
          end

        _ ->
          nil
      end
    rescue
      ArgumentError -> nil
    end
  end

  defp uri_path_segment(_), do: nil

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

  # Task #55 round-2 codex r2 review MED follow-up — workspace-scoped
  # session list for the LV sidebar / `/admin/sessions` / mount
  # subscription loop. When `current_workspace_uri` is missing
  # (mount outside the `:require_entity` live_session), return
  # an EMPTY list rather than every workspace's sessions. Pre-fix
  # the fallback returned `EzagentDomainChat.list_sessions/0` (all
  # workspaces), so an LV mounted outside LiveAuth would subscribe
  # to every session's event topic. The structural default must
  # be "deny by absence" — if we don't know the operator's
  # workspace, we cannot scope a subscription, so we subscribe to
  # nothing.
  defp list_sessions_for(%URI{scheme: "workspace"} = workspace_uri),
    do: EzagentDomainChat.list_sessions(workspace_uri)

  defp list_sessions_for(_), do: []

  # 2026-06-02 — ghost-session filter.
  #
  # User repro: "Remove a loom session template via /workspaces/<ws>; the
  # session still appears in the /sessions left-top dropdown." Root cause:
  # `list_sessions_for/1` returns whatever's currently in `KindRegistry`
  # under the session:// scheme, and **multiple paths re-spawn a session
  # whose snapshot is still on disk**:
  #
  #   • `Invocation.attempt_lazy_spawn_and_redispatch` — any in-flight
  #     dispatch to the dead URI triggers `StateRebuilder.snapshot_exists?`
  #     → `SpawnRegistry.spawn` → Kind back in registry.
  #   • An open loom iframe (`/loom/<ws>/<sid>`) keeps POSTing
  #     `chat.send` after the operator removed the template.
  #   • Feishu webhook arrivals for the mirrored chat_id.
  #
  # `LoomSession.cleanup/3` does terminate + snapshot delete, but it's
  # fire-and-forget and any of the above paths can revive between
  # cleanup completing and the operator reloading `/sessions`.
  #
  # Rather than try to plug every revival path (impossible: any external
  # MCP / webhook / iframe arriving from outside our control can revive),
  # the durable rule is: **a session is visible iff some current workspace
  # template declares it**. Removing the template makes the session
  # invisible to the operator regardless of whether a ghost Kind happens
  # to be alive in memory.
  #
  # Subscribe loop (mount/3 line ~174) deliberately still uses the
  # unfiltered `list_sessions_for/1` so the LV inbox stays scoped to
  # the workspace (Task #55 invariant). Only the **dropdown assign**
  # uses this filtered version.
  defp list_visible_sessions_for(%URI{scheme: "workspace", host: ws_name} = workspace_uri) do
    declared = declared_session_uri_strs(ws_name)

    workspace_uri
    |> list_sessions_for()
    |> Enum.filter(fn uri ->
      URI.to_string(uri) in declared or well_known_session?(uri)
    end)
  end

  defp list_visible_sessions_for(_), do: []

  # Walk `workspace.session_templates` and, for each recipe, ask its
  # Template Class "what session URIs would you spawn?" via the
  # optional duck-typed `session_uris_for_recipe/3` callback. Classes
  # that don't own session URIs (e.g. `cc.agent`, which owns agent
  # URIs) don't implement it and contribute nothing.
  defp declared_session_uri_strs(ws_name) when is_binary(ws_name) do
    case Ezagent.Workspace.Store.get_by_name(ws_name) do
      %{session_templates: tmpls} when is_map(tmpls) ->
        ws_uri =
          try do
            Ezagent.URI.new!("workspace://#{ws_name}")
          rescue
            _ -> nil
          end

        if ws_uri do
          Enum.flat_map(tmpls, &declared_for_one(&1, ws_uri))
        else
          []
        end

      _ ->
        []
    end
  end

  defp declared_session_uri_strs(_), do: []

  defp declared_for_one({tmpl_name, recipe}, ws_uri)
       when is_binary(tmpl_name) and is_map(recipe) do
    with class_name when is_binary(class_name) <- Map.get(recipe, "class"),
         {:ok, mod} <- Ezagent.TemplateRegistry.lookup(class_name),
         true <- function_exported?(mod, :session_uris_for_recipe, 3) do
      try do
        mod.session_uris_for_recipe(tmpl_name, recipe, ws_uri)
        |> Enum.map(&URI.to_string/1)
      rescue
        _ -> []
      catch
        _, _ -> []
      end
    else
      _ -> []
    end
  end

  defp declared_for_one(_, _), do: []

  # The default boot-time session(s) — never template-declared but the
  # operator MUST always see them. Currently only the canonical
  # `session://default/<ws>/main` (login-wizard / mix seeds). Add more
  # well-knowns here if/when other plugins seed boot sessions outside
  # the template path.
  defp well_known_session?(%URI{scheme: "session", host: "default", path: "/" <> rest}) do
    case String.split(rest, "/") do
      [_ws, "main"] -> true
      _ -> false
    end
  end

  # 2026-06-05 — loom 发布物/分享 fork 出的 preview session(`pub_<hex>`)是临时直接
  # instantiate 的,没注册进 workspace.session_templates,默认被 declared 过滤掉。
  # 显式放出来,让操作员在 /sessions 下拉能看到这些会话。
  defp well_known_session?(%URI{scheme: "session", host: "loom", path: "/" <> rest}) do
    case String.split(rest, "/") do
      [_ws, name] -> String.starts_with?(name, "pub_")
      _ -> false
    end
  end

  defp well_known_session?(_), do: false

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
        {uri, socket}

      :error ->
        creator =
          Map.get(socket.assigns, :current_entity_uri) || Ezagent.Entity.User.admin_uri()

        # SPEC #366 (Allen 2026-05-26) — explicit template_name. This
        # rehydrate path preserves the legacy `session://default/<ws>/main`
        # URI shape that tests + persisted state assume; literal
        # `"default"` is the bootstrap namespace segment, NOT a
        # TemplateRegistry-registered class.
        #
        # SPEC `2026-05-26-session-create-orchestrator-unified` Gap A —
        # `create_session/3` now returns a 3-tuple.
        #
        # codex PR #408 review MED-1 — surface :pending / :failed meta
        # through the admin error banner (mirrors the create_session
        # handler at line ~709 + restart handler at line ~2511). Pre-fix
        # the meta was log-only; an operator who landed on the admin
        # page right after a failed orchestrator-spawn rehydrate had
        # zero visibility into the failure.
        # Task #55: the main session must be created in the workspace the
        # operator is VIEWING (the workspace segment of `uri`), not the
        # creator's own workspace. A system-member admin viewing
        # `team-alpha` ensures `session://default/team-alpha/main`;
        # without the explicit `workspace_uri`, `create_session/3` derives
        # the workspace structurally from the creator (admin → `system`)
        # and the team-alpha session is never spawned — so a routing
        # dispatch to `current_session_uri` hits `:no_such_actor`. (post-
        # lifecycle remediation.)
        session_workspace_uri = Ezagent.Capability.workspace_of(uri)

        case EzagentDomainChat.create_session("main", creator,
               template_name: "default",
               workspace_uri: session_workspace_uri
             ) do
          {:ok, _spawned_uri, meta} ->
            log_orchestrator_status_on_rehydrate(uri, meta)
            {uri, assign_rehydrate_flash(socket, meta)}

          {:error, reason} ->
            require Logger
            Logger.warning("AdminLive.ensure_main_session failed: #{inspect(reason)}")

            {uri,
             assign(
               socket,
               :flash_error,
               gettext("Main session rehydrate failed: %{reason}",
                 reason: inspect(reason)
               )
             )}
        end
    end
  end

  # codex PR #408 review MED-1 — translate the orchestrator-status meta
  # into a LV flash assign. 2026-05-31 orchestrator-startup-atomicity §8 —
  # the status is now a 2-STATE model: `:ready | :failed`. `:ready` → no
  # change (the `:no_orchestrator` plain-session case is `:failed` with a
  # benign reason, suppressed); `:failed` → error-style text. `:pending`
  # is GONE (the atomic gate succeeds or fails-loud within 30s; no
  # half-started surface).
  #
  # Public-for-test via `@doc false` so unit tests can exercise the
  # branches without booting the full LV (the rehydrate path's first-mount
  # window is a flaky setup to drive otherwise).
  @doc false
  def assign_rehydrate_flash(socket, meta) when is_map(meta) do
    case Map.get(meta, :orchestrator_status) do
      :ready ->
        socket

      :failed ->
        reason = Map.get(meta, :orchestrator_error)

        if reason == :no_orchestrator do
          socket
        else
          assign(
            socket,
            :flash_error,
            gettext(
              "Orchestrator failed during main-session rehydrate: %{reason}; click Restart to retry.",
              reason: inspect(reason)
            )
          )
        end

      _ ->
        socket
    end
  end

  def assign_rehydrate_flash(socket, _), do: socket

  defp read_session_members(%URI{} = session_uri) do
    # Read the chat slice through the T3-normalized accessor
    # (`Kind.get_slice/2`), NOT a raw `:sys.get_state` + manual
    # destructure. Post-lifecycle the on-process slice is two-container
    # (`%{state: …, transients: …}`); `get_slice/2` flattens it to the
    # developer view so `members`/`last_seen` are read off the right
    # level. The old `%{state: %{chat: slice}}` match handed back the
    # two-container wrapper, so `slice.members` raised → caught → []
    # (members table silently empty). (post-lifecycle remediation.)
    case Ezagent.Kind.get_slice(session_uri, :chat) do
      {:ok, %{members: members} = slice} when is_map(members) ->
        last_seen = Map.get(slice, :last_seen, %{})

        for {uri, %{online: online?}} <- members do
          %{
            uri: URI.to_string(uri),
            online: online?,
            last_seen: Map.get(last_seen, uri)
          }
        end
        |> Enum.sort_by(& &1.uri)

      _ ->
        []
    end
  end

  # team-routing-unification §3.6 (PR-6) — read the session-scoped legend
  # registry off the `:chat` slice via the T3-normalized accessor (same path
  # as `read_session_members/1`). Returns `%{}` when the session has none /
  # isn't live; `Ezagent.Behavior.Chat.legends_of/1` defaults the legacy
  # (key-absent) shape.
  defp read_session_legends(%URI{} = session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :chat) do
      {:ok, slice} when is_map(slice) -> Ezagent.Behavior.Chat.legends_of(slice)
      _ -> %{}
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

  # `resource://uploads/<workspace>/<stored_name>` — extract just the
  # stored_name segment for the download URL. The on-disk file is named
  # `<stored_name>` (no workspace prefix); the workspace is metadata
  # in the URI for tenant-scoping the resource namespace.
  #
  # 2026-05-25: URL changed from `/admin/uploads/:filename` to
  # `/files/:filename` (PR #305 r4 HIGH — uploads-route scope fix).
  # The old URL was both misleading (looked admin-gated but wasn't)
  # AND broken (the multi-segment path bypassed the single-segment
  # `:filename` route param; this `Path.basename` strips the
  # workspace prefix to match the actual on-disk filename + the
  # new route's single-segment shape).
  defp att_to_link(%URI{scheme: "resource", host: "uploads", path: "/" <> rest}) do
    stored_name = Path.basename(rest)
    {display_name(stored_name), "/files/#{stored_name}"}
  end

  defp att_to_link(%URI{} = uri),
    do: {URI.to_string(uri), URI.to_string(uri)}

  defp att_to_link(s) when is_binary(s) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # with try/rescue keeping the `{s, s}` display-string fallback.
    try do
      att_to_link(Ezagent.URI.new!(s))
    rescue
      ArgumentError -> {s, s}
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

  defp send_chat_message(socket, text, attachments, mentions, legend_triggers) do
    msg =
      Ezagent.Message.new(
        socket.assigns.caller_uri,
        %{text: text, attachments: attachments},
        mentions: mentions,
        legend_triggers: legend_triggers
      )

    target = Ezagent.URI.with_action(socket.assigns.current_session_uri, :chat, :send)

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
  defp workspace_name_from_uri(nil), do: nil
  defp workspace_name_from_uri(%URI{host: name}) when is_binary(name) and name != "", do: name

  defp workspace_name_from_uri(uri_str) when is_binary(uri_str) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # with try/rescue (display fallback to nil for malformed input).
    try do
      case Ezagent.URI.new!(uri_str) do
        %URI{host: name} when is_binary(name) and name != "" -> name
        _ -> nil
      end
    rescue
      ArgumentError -> nil
    end
  end

  defp workspace_name_from_uri(_), do: nil

  # SPEC #366 (Allen 2026-05-26) — read the current workspace's
  # `session_templates` map and project to the new-session form's
  # `<select>` options.
  #
  # Returns `[String.t()]` — the workspace's session-template instance
  # names sorted lexically (NOT registered template-class names from
  # `Ezagent.TemplateRegistry`; see the codex r1 note in the
  # `session_editor.ex` template-class dropdown for the semantic
  # split). Each key becomes the URI's class segment via
  # `create_session/3`'s `:template_name` option.
  #
  # Empty list = workspace has zero declared templates → the dropdown
  # renders an empty-state with a deep-link to /admin/templates.
  # (LOW limitation: `/admin/templates` is `:require_admin`; non-admin
  # operators see the link but can't follow it. Tracked for a later
  # PR that exposes a tenant-scoped templates UI.)
  #
  # Defensive against early-mount paths where `:current_workspace_uri`
  # hasn't been assigned yet (test fixtures, error paths) — returns
  # `[]` rather than crashing.
  defp template_class_options_for(assigns) do
    case Map.get(assigns, :current_workspace_uri) do
      %URI{scheme: "workspace", host: ws_name} when is_binary(ws_name) and ws_name != "" ->
        case Ezagent.Workspace.Store.get_by_name(ws_name) do
          %{session_templates: tmpls} when is_map(tmpls) ->
            tmpls |> Map.keys() |> Enum.sort()

          _ ->
            []
        end

      _ ->
        []
    end
  end

  # Phase 8c PR-L → PR-M (Allen 2026-05-20): the private
  # `list_known_workspaces/0` helper that used to live here is now
  # `EzagentWeb.LiveAuth.list_known_workspaces/0` (centralized so
  # every LV in `:require_entity` sees `@workspaces`, not just admin_live).
end
