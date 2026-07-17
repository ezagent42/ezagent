defmodule EzagentWeb.LiveAuth do
  @moduledoc """
  LiveView `on_mount` hook that gates admin LVs on a logged-in entity.

  Plug `RequireEntity` already runs on the HTTP dead-render path
  (`live` macro hits `mount/3` once before the WS upgrade), so for
  initial connects this is a belt-and-suspenders check. But on a
  fresh WS reconnect with an expired/missing session, only the
  on_mount hook protects the LV — without it, an LV's `mount/3`
  would receive `session = %{}` and would historically fall back to
  `Ezagent.Entity.User.admin_uri()` / `admin_caps()` (security bug
  pre-PR #123; `admin_caps/0` deleted in PR-CC-1 — anonymous mounts
  now fall back to `system://lv-anon-mount` with EMPTY caps per
  SPEC caps-cleanup-v1 §4.4).

  ## Wiring

  Mounted via `live_session` block in the router:

      live_session :require_entity, on_mount: {EzagentWeb.LiveAuth, :require_entity} do
        live "/admin", EzagentPluginWorld.WorldLive, :admin
        # ...
      end

  ## Effect

  On successful auth, sets `socket.assigns.current_entity_uri` to a
  `%URI{}`. LVs can read this directly instead of re-parsing from
  the session map (and instead of falling back to admin if it's
  missing — that fallback is now deleted across all 5 LVs).

  On failure (no `current_entity_uri` in session), redirects to
  `/login` and halts mount. Public exposure safe.

  ## PR #142 rename

  Renamed from `:require_user` → `:require_entity` to reflect that
  the gated session may belong to any Entity (a human User OR an
  Agent acting via bearer token).

  ## PR #149 (S-8) hardening

  WS reconnect path now asserts the session URI parses to an
  `entity://` shape with a user or agent type axis. A malformed
  or non-entity URI in the cookie redirects to `/login` instead of
  silently propagating into LV assigns. Same vigilance as PR #123:
  prevent any silent fallback to admin on reconnect.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  @doc """
  LiveView on_mount hook that propagates the per-request Gettext locale
  (set by `EzagentWeb.Plugs.Locale`) into the LiveView's BEAM process.

  Reason: the websocket process is separate from the HTTP request
  process; `Gettext.put_locale/2` is process-dictionary state and does
  NOT propagate across processes. Without this hook, LV templates fall
  back to the Gettext default (English) even when the dead-render was
  translated.

  Attach via `live_session :foo, on_mount: [{EzagentWeb.LiveAuth, :put_locale}, ...]`.
  """
  def on_mount(:put_locale, _params, session, socket) do
    locale = session["locale"] || "en"

    resolved =
      if locale in EzagentWeb.Plugs.Locale.supported_locales() do
        locale
      else
        EzagentWeb.Plugs.Locale.default_locale()
      end

    Gettext.put_locale(EzagentWeb.Gettext, resolved)
    # Tier-2 shared-component backend (`ezagent_domain_ui` shells) — set
    # on the LV process too; `put_locale/2` is per-backend process state.
    Gettext.put_locale(EzagentDomainUi.Gettext, resolved)

    {:cont, assign(socket, :current_locale, Gettext.get_locale(EzagentWeb.Gettext))}
  end

  # V1 UI PR-2 (SPEC §2.2) — `:cmdk_nav` on_mount: assigns
  # `:cmdk_nav_routes` for the CmdK command palette.
  #
  # `EzagentWeb.CommandRoutes.command_routes/0` projects the Phoenix
  # Router into enriched nav routes. The CmdK `CommandSource` (Tier-2)
  # and `CommandPaletteComponent` (Tier-3) live BELOW `ezagent_web` and
  # MUST NOT call `EzagentWeb.Router` directly — so the nav data is
  # computed HERE (the top tier) and flows DOWN through this assign:
  # `ezagent_web` → LV → `CommandPaletteComponent`.
  #
  # Chained from `:require_entity` (below) so every workspace LV
  # inherits `:cmdk_nav_routes` without each LV recomputing it.
  def on_mount(:cmdk_nav, _params, _session, socket) do
    {:cont, assign(socket, :cmdk_nav_routes, EzagentWeb.CommandRoutes.command_routes())}
  end

  # Codex PR #305 round-2 HIGH fix — centralized admin gate.
  # `/admin/*` LVs (ObservabilityLive, SnapshotsLive, EntitiesLive,
  # AdminDashboardLive, AdminTemplatesLive) ALL had the same bug
  # where non-admin authenticated users could deep-link in and
  # enumerate cross-tenant data. Per-LV gates fixed two of them
  # but missed three; codex correctly recommended a centralized
  # `live_session :require_admin` so the next /admin LV inherits
  # the gate automatically.
  #
  # Chains `:require_entity` first (sets `is_admin?` / `is_system_member?`)
  # then halts non-admins with a flash + redirect to `/`.
  def on_mount(:require_admin, params, session, socket) do
    case on_mount(:require_entity, params, session, socket) do
      {:cont, %{assigns: %{is_admin?: true}} = authed_socket} ->
        {:cont, authed_socket}

      {:cont, %{assigns: %{is_system_member?: true}} = authed_socket} ->
        {:cont, authed_socket}

      {:cont, authed_socket} ->
        # Redirect target matches the pre-existing per-LV admin
        # redirects (`AdminCapsLive`, `SettingsLive`, etc) so tests
        # that assert "non-admin → /sessions" keep passing.
        {:halt,
         authed_socket
         |> put_flash(:error, "Admin access required.")
         |> redirect(to: "/sessions")}

      halt ->
        # `:require_entity` already redirected (e.g. no session).
        halt
    end
  end

  def on_mount(:require_entity, params, session, socket) do
    # Locale must be set on the LV process too — chain to :put_locale
    # first so any redirect message (e.g. "Please sign in") + every
    # subsequent render uses the user's chosen locale.
    {:cont, socket} = on_mount(:put_locale, params, session, socket)

    # CmdK nav routes (SPEC §2.2) — assemble in this top tier and flow
    # the data DOWN via an assign. Chaining here keeps it inside the
    # one `:require_entity` hook the router already wires for every
    # workspace LV.
    {:cont, socket} = on_mount(:cmdk_nav, params, session, socket)

    case require_entity_mount(session, socket) do
      {:cont, authed_socket} ->
        # PR-B of Presence rollout (SPEC
        # `docs/superpowers/specs/2026-05-23-presence.md` rev 3 §7) —
        # track presence on the LV socket. Only on the WS connect (skip
        # dead-render: a stateless HTTP request shouldn't register a
        # presence entry). Phoenix.Presence monitors the LV socket pid
        # → auto-untrack on socket exit. Failure must NOT block mount;
        # we log + continue.
        track_presence(authed_socket)

      halt ->
        halt
    end
  end

  defp track_presence(socket) do
    if Phoenix.LiveView.connected?(socket) do
      uri = socket.assigns.current_entity_uri
      transport_id = "liveview:" <> socket.id
      meta = %{transport: :liveview, since: DateTime.utc_now()}

      case Ezagent.Presence.track(uri, transport_id, meta) do
        {:ok, _ref} ->
          :ok

        {:error, reason} ->
          require Logger

          Logger.warning(
            "LiveAuth: Ezagent.Presence.track/3 failed " <>
              "uri=#{URI.to_string(uri)} transport_id=#{transport_id} " <>
              "reason=#{inspect(reason)} — LV will mount but won't appear online"
          )
      end
    end

    {:cont, socket}
  end

  defp require_entity_mount(session, socket) do
    case session["current_entity_uri"] do
      nil ->
        {:halt, redirect(socket, to: "/login")}

      uri_str when is_binary(uri_str) ->
        case parse_entity_uri(uri_str) do
          {:ok, uri} ->
            if user_offboarded?(uri) do
              # Active-session eviction (task #180 Change 3): a user
              # disabled AFTER login is bounced on their next LV mount
              # (connect / navigation / reconnect). Mirrors the HTTP-side
              # `RequireEntity` recheck; scoped to USER URIs so an agent LV
              # (bearer-authed) is never run through the user-table lookup
              # (`Users.disabled?/1` fails closed on unknown).
              {:halt,
               socket
               |> put_flash(:info, "Your access has been revoked. Please sign in again.")
               |> redirect(to: "/login")}
            else
              mount_authed_socket(session, socket, uri)
            end

          :error ->
            # Malformed / non-entity / stale pre-Phase-9 2-segment URI
            # → treat as unauthenticated. The flash informs the user
            # WHY they were bounced — pre-Phase 9 cookies (with bare
            # 2-segment entity URIs) silently expire after the SPEC v3
            # write/read parity fix (V1, Allen 2026-05-21).
            {:halt,
             socket
             |> put_flash(:info, "Your session expired. Please sign in again.")
             |> redirect(to: "/login")}
        end
    end
  end

  defp mount_authed_socket(session, socket, %URI{} = uri) do
    workspace_uri = parse_workspace_uri(session["current_workspace_uri"], uri)
    is_system_member = system_member?(uri)
    caps = load_caps(uri)

    {:cont,
     socket
     |> assign(:current_entity_uri, uri)
     |> assign(:current_workspace_uri, workspace_uri)
     |> assign(:workspace_name, workspace_name_from_uri(workspace_uri))
     |> assign(:is_admin?, admin?(uri))
     |> assign(:is_system_member?, is_system_member)
     |> assign(:current_caps, caps)
     |> assign(:workspaces, list_known_workspaces(uri, caps))}
  end

  # True only when `uri` is a soft-disabled USER (`Users.disabled?/1`). Agent
  # URIs are exempt — they are not `users` rows and `disabled?/1` fails closed on
  # unknown.
  defp user_offboarded?(%URI{} = uri) do
    match?({:ok, "user"}, Ezagent.URI.type(uri)) and Ezagent.Users.disabled?(uri)
  end

  # Phase 9 PR-8 (SPEC v3 §13.3) — `is_system_member?` is the
  # membership-based cross-workspace authority predicate. Used by the
  # workspace dropdown to decide whether non-current workspaces are
  # clickable (system member: yes, regular user: yes but hits the
  # denial page).
  defp system_member?(%URI{} = entity_uri) do
    try do
      caller_workspace = Ezagent.URI.entity_workspace_uri(entity_uri)
      Ezagent.URI.name?(caller_workspace, :system)
    rescue
      _ -> false
    end
  end

  # Phase 9 PR-5 (SPEC v3 §6.3 + §6.5 invariant): assign
  # `:current_workspace_uri` from the session slot
  # `SessionPrincipal.put/2` writes. Defensive fallback derives it
  # from the entity URI when the session slot is missing (pre-PR-5
  # sessions on disk during the rollout). The invariant
  # `current_workspace_uri == entity_workspace_uri(current_entity_uri)`
  # is preserved either way.
  defp parse_workspace_uri(nil, entity_uri), do: Ezagent.URI.entity_workspace_uri(entity_uri)

  defp parse_workspace_uri(ws_str, entity_uri) when is_binary(ws_str) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # with try/rescue. Pre-SPEC code used stdlib `URI.parse/1` which
    # silently produced `%URI{scheme: nil}` for a malformed/stale
    # cookie; downstream `workspace_name_from_uri/1` then degraded to
    # nil. The canonical chokepoint raises ArgumentError on malformed
    # input, so we preserve the original degraded path by falling back
    # to the entity-derived workspace URI (which is always canonical
    # because LiveAuth already validated `current_entity_uri`).
    Ezagent.URI.new!(ws_str)
  rescue
    ArgumentError -> Ezagent.URI.entity_workspace_uri(entity_uri)
  end

  # Bug 3 (Allen 2026-05-26) — derive the display name from the
  # canonical `:current_workspace_uri` so every LV in the
  # `:require_entity` live_session inherits it. Previously only
  # `admin_live` computed `workspace_name` (and it pulled from the
  # session URI's bound workspace, which ignores the cookie's
  # workspace slot — so the IdeShell `ezagent / <name>` trigger
  # didn't update after a successful workspace switch).
  defp workspace_name_from_uri(%URI{} = uri) do
    case Ezagent.URI.workspace_name(uri) do
      {:ok, name} -> name
      :error -> nil
    end
  end

  defp workspace_name_from_uri(_), do: nil

  # Phase 8c follow-up (Allen 2026-05-20) — `is_admin?` was set in
  # admin_live's mount but not propagated to the other 12 LVs that
  # wrap IdeShell. Result: Admin link in avatar dropdown disappeared
  # when navigating to /profile or /settings even for admin users.
  # Setting it here on every LV in the `:require_entity` live_session
  # means avatar_menu reads it uniformly. assign_new in admin_live
  # still works (this fires first, admin_live's assign_new sees a
  # value and is a no-op).
  defp admin?(uri) do
    if Code.ensure_loaded?(Ezagent.Identity) and
         function_exported?(Ezagent.Identity, :admin?, 1) do
      Ezagent.Identity.admin?(uri)
    else
      false
    end
  end

  # PR-M (Allen 2026-05-20) — centralized workspaces assign. Previously
  # only `admin_live.ex` computed `[%{name, uri}]` for the top-left
  # `ezagent / <workspace> ▾` dropdown, so the dropdown appeared on
  # `/sessions` but not on `/identities`, `/routing`, `/plugins`,
  # `/profile`, `/preferences`. Now every LV in `:require_entity`
  # sees `@workspaces`, IdeShell renders the dropdown consistently,
  # and admin_live's private helper becomes redundant (removed in
  # the same PR).
  #
  # Defensive load — DB unavailable at LV-mount (e.g. test sandbox
  # not checked out) returns an empty list. The dropdown's
  # `Manage workspaces…` link is the user's escape hatch when no
  # workspaces are visible.
  #
  # SPEC v2 PR-F (#296 follow-up) — the previous "always include
  # `default`" stub was deleted: PR-C removed the boot-seeded
  # `default` workspace, so injecting a synthetic `default` row
  # would point operators at a non-existent workspace (P2: no
  # silent defaults). Operators land in their email-domain
  # workspace via the onboarding flow (PR-B) and create
  # additional workspaces via the admin drawer.
  defp list_known_workspaces(caller_uri, caps) do
    # SPEC 2026-05-27-workspace-cap-based-visibility — cap-derived
    # per-caller listing. Admin-shortcut callers see all workspaces;
    # other callers see workspaces their caps reach + their
    # memberships. `workspace://system`'s appearance is no longer
    # field-gated — it appears iff the 4-predicate admin shortcut
    # fires (per SPEC §3.4).
    #
    # Defensive fallback returns `[]` if `Ezagent.Workspace` is
    # unavailable at runtime (test boot, partial app start).
    persisted =
      try do
        if Code.ensure_loaded?(Ezagent.Workspace) and
             function_exported?(Ezagent.Workspace, :list_workspaces_for, 2) do
          Ezagent.Workspace.list_workspaces_for(caller_uri, caps)
          |> Enum.map(fn ws -> %{name: ws.name, uri: ws.uri} end)
        else
          []
        end
      rescue
        _ -> []
      end

    Enum.sort_by(persisted, & &1.name)
  end

  # Load the caller's verified, current caps through the Entity-cap read facade.
  # Runtime grant/revoke stores into the live Identity slice; `users.caps_json`
  # is provisioning input and may lag behind that state. Reading Users here
  # made authenticated LiveViews deny newly granted authority and could expose
  # stale authority after a revoke. `read_entity_caps/1` owns the live-slice →
  # durable-snapshot fallback and applies receiver-aware `Cap.verified_set/2`
  # at that boundary.
  defp load_caps(%URI{} = caller_uri) do
    try do
      if Code.ensure_loaded?(Ezagent.EntityCaps) and
           function_exported?(Ezagent.EntityCaps, :load, 1) do
        caller_uri
        |> Ezagent.EntityCaps.load()
        |> MapSet.new()
      else
        MapSet.new()
      end
    rescue
      _ -> MapSet.new()
    end
  end

  defp load_caps(_), do: MapSet.new()

  # PR #149 (S-8): accept entity://user/* and entity://agent/* uniformly.
  #
  # V1 fix (Allen Feishu 2026-05-21) — strict delegation to
  # `Ezagent.URI.new!/1` (the SPEC v3 canonical parser). Previously
  # this accepted ANY `entity://<host>/<path>` shape including the
  # legacy 2-segment `entity://user/admin` form, which broke the
  # write/read URI parity invariant (memory
  # `feedback_register_lookup_key_parity`). Pre-Phase-9 cookies with
  # 2-segment URIs would parse to `{:ok, uri}` here, then flow into
  # `Ezagent.URI.entity_workspace_uri/1` which pattern-matches the
  # 3-segment shape → MatchError 500.
  #
  # Delegating to `parse!/1` means stale cookies raise `ArgumentError`
  # → `:error` → caller redirects to /login → session cleared → fresh
  # login writes a canonical 3-segment cookie. Single source of truth
  # for URI shape lives in `Ezagent.URI.new!/1`.
  @spec parse_entity_uri(any) :: {:ok, URI.t()} | :error
  defp parse_entity_uri(uri_str) when is_binary(uri_str) do
    try do
      uri = Ezagent.URI.new!(uri_str)

      if Ezagent.URI.scheme?(uri, :entity) and
           match?({:ok, kind} when kind in ["user", "agent"], Ezagent.URI.type(uri)) do
        {:ok, uri}
      else
        :error
      end
    rescue
      ArgumentError -> :error
    end
  end

  defp parse_entity_uri(_), do: :error
end
