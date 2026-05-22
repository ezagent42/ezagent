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
  pre-PR #123).

  ## Wiring

  Mounted via `live_session` block in the router:

      live_session :require_entity, on_mount: {EzagentWeb.LiveAuth, :require_entity} do
        live "/admin", EzagentPluginLiveview.AdminLive
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
  `entity://` shape with `host in ["user", "agent"]`. A malformed
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

    require_entity_mount(session, socket)
  end

  defp require_entity_mount(session, socket) do
    case session["current_entity_uri"] do
      nil ->
        {:halt, redirect(socket, to: "/login")}

      uri_str when is_binary(uri_str) ->
        case parse_entity_uri(uri_str) do
          {:ok, uri} ->
            workspace_uri = parse_workspace_uri(session["current_workspace_uri"], uri)
            is_system_member = system_member?(uri)

            {:cont,
             socket
             |> assign(:current_entity_uri, uri)
             |> assign(:current_workspace_uri, workspace_uri)
             |> assign(:is_admin?, admin?(uri))
             |> assign(:is_system_member?, is_system_member)
             |> assign(:workspaces, list_known_workspaces())}

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

  # Phase 9 PR-8 (SPEC v3 §13.3) — `is_system_member?` is the
  # membership-based cross-workspace authority predicate. Used by the
  # workspace dropdown to decide whether non-current workspaces are
  # clickable (system member: yes, regular user: yes but hits the
  # denial page).
  defp system_member?(%URI{} = entity_uri) do
    try do
      caller_workspace = Ezagent.URI.entity_workspace_uri(entity_uri)
      URI.to_string(caller_workspace) == "workspace://system"
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

  defp parse_workspace_uri(ws_str, _entity_uri) when is_binary(ws_str), do: URI.parse(ws_str)

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
  # not checked out) returns an empty list + default workspace stub.
  # The dropdown still renders sensibly with just "default".
  defp list_known_workspaces do
    # Phase 9 PR-8 (SPEC v3 §13.1) — use `list_visible/0` so the
    # `workspace://system` workspace stays out of the regular
    # operator-facing dropdown. System members still see it from the
    # admin tooling, but it is never a click-to-switch target.
    persisted =
      try do
        cond do
          Code.ensure_loaded?(Ezagent.Workspace) and
              function_exported?(Ezagent.Workspace, :list_visible, 0) ->
            Ezagent.Workspace.list_visible()
            |> Enum.map(fn ws -> %{name: ws.name, uri: ws.uri} end)

          Code.ensure_loaded?(Ezagent.Workspace) and
              function_exported?(Ezagent.Workspace, :list_persisted, 0) ->
            Ezagent.Workspace.list_persisted()
            |> Enum.map(fn ws -> %{name: ws.name, uri: ws.uri} end)

          true ->
            []
        end
      rescue
        _ -> []
      end

    # Always include `default` in the dropdown even if not yet
    # persisted in the Store (e.g. fresh DB before
    # `ensure_default_workspace/0` has run, or DB unavailable). The
    # `Manage workspaces…` link is the user's escape hatch to the
    # admin drawer.
    default = %{name: "default", uri: URI.parse("workspace://default")}

    if Enum.any?(persisted, &(&1.name == "default")) do
      persisted
    else
      [default | persisted]
    end
    |> Enum.sort_by(& &1.name)
  end

  # PR #149 (S-8): accept entity://user/* and entity://agent/* uniformly.
  #
  # V1 fix (Allen Feishu 2026-05-21) — strict delegation to
  # `Ezagent.URI.parse!/1` (the SPEC v3 canonical parser). Previously
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
  # for URI shape lives in `Ezagent.URI.parse!/1`.
  @spec parse_entity_uri(any) :: {:ok, URI.t()} | :error
  defp parse_entity_uri(uri_str) when is_binary(uri_str) do
    try do
      uri = Ezagent.URI.parse!(uri_str)

      case uri do
        %URI{scheme: "entity", host: host} when host in ["user", "agent"] ->
          {:ok, uri}

        _ ->
          :error
      end
    rescue
      ArgumentError -> :error
    end
  end

  defp parse_entity_uri(_), do: :error
end
