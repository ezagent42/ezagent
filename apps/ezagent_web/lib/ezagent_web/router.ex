defmodule EzagentWeb.Router do
  use EzagentWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    # i18n V1 (Allen 2026-05-21): resolves Gettext locale from query
    # string → session → Accept-Language → default "en". Persists the
    # choice in the session so subsequent requests stay translated.
    # Must run AFTER :fetch_session (reads + writes session) and
    # BEFORE the controller/LiveView pipeline (so dead-render sees
    # the locale).
    plug EzagentWeb.Plugs.Locale
    plug :fetch_live_flash
    plug :put_root_layout, html: {EzagentWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", EzagentWeb do
    pipe_through :browser

    # i18n V1: public LV needs the locale hook too so the WS process
    # inherits the session locale.
    live_session :public, on_mount: {EzagentWeb.LiveAuth, :put_locale} do
      live "/", HomeLive
    end

    # Phase 4-completion Spec 05 §A.2.3 — controller-rendered login.
    get "/login", SessionController, :new
    post "/login", SessionController, :create
    get "/login/credentials", SessionController, :credentials_new
    post "/login/credentials", SessionController, :credentials_create
    delete "/logout", SessionController, :delete
    post "/logout", SessionController, :delete
    get "/auth/magic/:token", MagicLinkController, :consume
    get "/register/complete", RegistrationController, :complete_new
    post "/register/complete", RegistrationController, :complete_create
  end

  # /admin* requires login (Phase 4-completion Spec 05 §A.2.3 +
  # PR #123 hardening: live_session on_mount gates the WS reconnect
  # path that bypasses the HTTP Plug pipeline).
  # PR-B: file download route for chat compose uploads. Mounted in the
  # EzagentWeb scope (so the controller resolves correctly), under the
  # same RequireEntity plug as the LV scope below.
  scope "/", EzagentWeb do
    pipe_through [:browser, EzagentWeb.Plugs.RequireEntity]

    get "/admin/uploads/:filename", UploadsController, :show

    # Phase 9 PR-5 (SPEC v3 §6.4 amended): workspace switcher endpoint.
    # Logged-in users POST here from the top-left workspace dropdown;
    # controller clears session + redirects to /login?workspace=<target>.
    # Must be inside `:require_entity` so anonymous traffic can't spam
    # session-clearing POSTs.
    post "/workspaces/switch", WorkspaceSwitchController, :switch
  end

  scope "/", EzagentPluginLiveview do
    pipe_through [:browser, EzagentWeb.Plugs.RequireEntity]

    live_session :require_entity, on_mount: {EzagentWeb.LiveAuth, :require_entity} do
      # Phase 8 polish — IA refactor (Allen 2026-05-20). Business-feature
      # routes live at top level. `/admin/*` is reserved for the admin
      # dashboard (KPIs + sysadmin sub-pages: logs, registry, snapshots).

      # Sessions Activity (was /admin in Phase 8).
      live "/sessions", AdminLive

      # Admin dashboard + sysadmin sub-pages.
      live "/admin", AdminDashboardLive
      live "/admin/logs", ObservabilityLive
      live "/admin/registry", EntitiesLive
      live "/admin/snapshots", SnapshotsLive
      # G-1 + G-2 V0 stop-gap (audit 2026-05-23): AgentTemplate +
      # SessionTemplate Kinds list, read-only. Detail link goes to
      # the existing /plugins/auto/:kind LV for raw slice inspection.
      live "/admin/templates", AdminTemplatesLive
      # CapabilityRegistry SPEC `docs/superpowers/specs/2026-05-23-capability-registry.md`
      # §8.1 — surfaces every cap subject registered via
      # `Ezagent.CapabilityRegistry` (dispatchable + cap-only) plus
      # default-grant policies per Kind. Admin-only at the mount level
      # (matches `AdminSettingsLive`'s `@is_admin?` redirect pattern).
      live "/admin/caps", AdminCapsLive
      # Design 2 from docs/notes/caps-e2e-design.md §5 — live stream of
      # CapBAC :granted / :denied telemetry. Makes the cap system
      # viscerally visible.
      live "/admin/audit/authz", AdminAuthzAuditLive
      # V1 fix (Allen Feishu 2026-05-21 17:44): /settings moved here
      # from top-level. The page hosts admin-only config (SMTP +
      # registration domains); belongs under /admin (admin scope),
      # not the avatar Preference dropdown (personal scope).
      live "/admin/settings", SettingsLive

      # Workspaces Activity.
      live "/workspaces", WorkspacesLive
      live "/workspaces/:name", WorkspaceDetailLive

      # Routing Activity.
      live "/routing", RoutingLive

      # Identities Activity (address book: users + agents are entity sub-types).
      live "/identities", IdentitiesLive
      live "/identities/users", UsersLive
      # Phase 8c follow-up (Allen 2026-05-20) — parallel to /identities/users.
      # /identities/agents was a dead link from agent_detail_live's "Back
      # to agents" anchors. Reuses IdentitiesLive; the LV defaults the
      # filter to "agents" when the URI path matches.
      live "/identities/agents", IdentitiesLive
      # PR-G (Phase 8c): EntityCapsLive serves both user + agent caps
      # (generalized from the former UserCapsLive). Backend
      # `Ezagent.Behavior.Identity` always accepted any entity URI;
      # this exposes the agent surface in the UI.
      live "/identities/users/:uri/caps", EntityCapsLive
      live "/identities/agents/:uri/caps", EntityCapsLive
      live "/identities/users/:uri/api-keys", UserApiKeysLive
      # Phase 8c PR-N: "/new" MUST appear before ":uri" — Phoenix
      # matches routes top-down and would otherwise bind "new" as the
      # `:uri` param for AgentDetailLive.
      live "/identities/agents/new", AgentNewLive
      live "/identities/agents/:uri", AgentDetailLive
      # Domain.Pty PR-D (2026-05-21) — standalone PTY terminal page.
      # Resource-first per SPEC §10 decision 2; sibling to /:uri/caps
      # and /:uri/api-keys. Bridge pattern per SPEC §13: `:uri` is the
      # URL-encoded canonical entity URI string, decoded + URI.new'd
      # at mount. Previously retired in Phase 8b in favor of the
      # SessionEditor view-switcher; brought back in V1 Domain.Pty so
      # operators can open a focused terminal without the chat panel.
      live "/identities/agents/:uri/terminal", TerminalLive

      # Plugins Activity.
      live "/plugins", PluginsLive
      live "/plugins/feishu/bindings", FeishuBindingsLive
      live "/plugins/auto/:kind", AutoDeriveLive
      live "/plugins/auto/:kind/:uri", AutoDeriveLive

      # Top-level Profile (reached via avatar dropdown — personal
      # config). Settings moved to /admin/settings above (admin scope).
      live "/profile", ProfileLive
    end
  end

  # Liveness probe — plain JSON, no ESR dispatch path involved.
  scope "/", EzagentWeb do
    pipe_through :api

    get "/_health", HealthController, :index
  end

  scope "/api", EzagentWeb do
    pipe_through :api

    # Phase 4-plus follow-up (2026-05-17): CC hook error reporting.
    # No auth — see CcEventsController moduledoc for trust-boundary
    # rationale (the agent the hook reports about may be down).
    post "/cc-events", CcEventsController, :report
  end

  # Phase 5 PR 6: Feishu webhook receiver. The ONLY touch
  # ezagent_plugin_feishu makes to ezagent_web — explicit exception per SPEC v2
  # north star ("beyond webhook route registration").
  forward "/api/feishu/webhook", EzagentPluginFeishu.WebhookPlug

  # Phase 6 PR 9: canonical auto-derived JSON API. Single controller
  # dispatches every `{kind, action}` registered in BehaviorRegistry.
  # GET /api/v1 = introspection (route catalog + interfaces).
  # POST /api/v1/:kind/:action = invoke.
  scope "/api/v1", EzagentWeb do
    pipe_through :api

    get "/", ApiV1Controller, :index
    post "/:kind/:action", ApiV1Controller, :invoke
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:ezagent_web, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: EzagentWeb.Telemetry
    end
  end

  # Catch-all browser GET — renders the ezagent-branded 404 page for any
  # path that didn't match above. Without this, Phoenix's dev `debug_errors`
  # serves the stacktrace exception page instead, which mis-represents
  # what a real user would see. Production behavior was already correct
  # via ErrorHTML; this just unifies dev with prod.
  #
  # Allen 2026-05-20: see memory feedback_ui_no_misleading_buttons —
  # 404s should be rare (every real link points somewhere) AND graceful.
  scope "/", EzagentWeb do
    pipe_through :browser

    get "/*path", FallbackController, :not_found
  end
end
