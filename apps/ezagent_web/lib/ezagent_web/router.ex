defmodule EzagentWeb.Router do
  @moduledoc """
  The Phoenix router for `:ezagent_web` — pipelines and route scopes.

  Note the `Plugs.Locale` ordering in the `:browser` pipeline: it must run after
  `:fetch_session` (it reads/writes the session — see the inline comment at that
  plug). Route scopes are declared here, including the public scope, the
  login-gated admin LiveView surface, and the socialware customer/chat routes.
  """
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

  @world_host_scope Application.compile_env(:ezagent_web, :world_host_scope)

  if is_binary(@world_host_scope) and @world_host_scope != "" do
    scope "/", EzagentPluginWorld, host: @world_host_scope do
      pipe_through [:browser, EzagentWeb.Plugs.RequireEntity]

      live_session :world_root_require_entity, on_mount: {EzagentWeb.LiveAuth, :require_entity} do
        live "/", WorldLive
        live "/sessions", WorldLive
        live "/identities", WorldLive
        live "/identities/users", WorldLive
        live "/identities/users/new", WorldLive
        live "/identities/agents", WorldLive
        live "/identities/users/:uri/caps", WorldLive
        live "/identities/users/:uri", WorldLive
        live "/identities/agents/:uri/caps", WorldLive
        live "/identities/agents/:uri/api-keys", WorldLive
        live "/identities/agents/:uri/config", WorldLive
        live "/identities/agents/new", WorldLive
        live "/identities/agents/:uri/extensions", WorldLive
        live "/identities/agents/:uri/terminal", WorldLive
        live "/identities/agents/:uri", WorldLive
        live "/workspaces", WorldLive
        live "/workspaces/:name/templates/new", WorldLive
        live "/workspaces/:name", WorldLive
        live "/plugins", WorldLive
        live "/plugins/feishu/bindings", WorldLive
        live "/plugins/auto/:kind", WorldLive
        live "/plugins/auto/:kind/:uri", WorldLive
        live "/plugins/kanban", WorldLive
        live "/plugins/kanban/:uri", WorldLive
        live "/profile", WorldLive
      end

      # Read-plane PR-4 rework (F3): the operator plane (`/overview` +
      # `/admin/*`) moved OUT of `:require_entity` into the centralized
      # `:require_admin` gate — an authenticated NON-admin deep-link is
      # rejected (redirect + flash), never shown cross-tenant
      # counts/registries/templates. (Overlaps #187, which keeps the
      # audit/authz/cc_event stream work.)
      live_session :world_root_require_admin, on_mount: {EzagentWeb.LiveAuth, :require_admin} do
        live "/overview", WorldLive
        live "/admin", WorldLive
        live "/admin/logs", WorldLive
        live "/admin/registry", WorldLive
        live "/admin/snapshots", WorldLive
        live "/admin/templates", WorldLive
        live "/admin/caps", WorldLive
        live "/admin/audit/authz", WorldLive
        live "/admin/settings", WorldLive
        live "/admin/routing", WorldLive
        live "/admin/sessions/:id/external_mirror", WorldLive
      end
    end
  end

  scope "/", EzagentPluginWorld do
    pipe_through [:browser, EzagentWeb.Plugs.WorldHostScope, EzagentWeb.Plugs.RequireEntity]

    live_session :world_require_entity, on_mount: {EzagentWeb.LiveAuth, :require_entity} do
      live "/sessions", WorldLive
      live "/identities", WorldLive
      live "/identities/users", WorldLive
      live "/identities/users/new", WorldLive
      live "/identities/agents", WorldLive
      live "/identities/users/:uri/caps", WorldLive
      live "/identities/users/:uri", WorldLive
      live "/identities/agents/:uri/caps", WorldLive
      live "/identities/agents/:uri/api-keys", WorldLive
      live "/identities/agents/:uri/config", WorldLive
      live "/identities/agents/new", WorldLive
      live "/identities/agents/:uri/extensions", WorldLive
      live "/identities/agents/:uri/terminal", WorldLive
      live "/identities/agents/:uri", WorldLive
      live "/workspaces", WorldLive
      live "/workspaces/:name/templates/new", WorldLive
      live "/workspaces/:name", WorldLive
      live "/plugins", WorldLive
      live "/plugins/feishu/bindings", WorldLive
      live "/plugins/auto/:kind", WorldLive
      live "/plugins/auto/:kind/:uri", WorldLive
      live "/plugins/kanban", WorldLive
      live "/plugins/kanban/:uri", WorldLive
      live "/profile", WorldLive
    end

    # Read-plane PR-4 rework (F3): see the host-scoped note above — the
    # operator plane requires admin, not merely a logged-in entity.
    live_session :world_require_admin, on_mount: {EzagentWeb.LiveAuth, :require_admin} do
      live "/overview", WorldLive
      live "/admin", WorldLive
      live "/admin/logs", WorldLive
      live "/admin/registry", WorldLive
      live "/admin/snapshots", WorldLive
      live "/admin/templates", WorldLive
      live "/admin/caps", WorldLive
      live "/admin/audit/authz", WorldLive
      live "/admin/settings", WorldLive
      live "/admin/routing", WorldLive
      live "/admin/sessions/:id/external_mirror", WorldLive
    end
  end

  scope "/", EzagentWeb do
    pipe_through :browser

    # i18n V1: public LV needs the locale hook too so the WS process
    # inherits the session locale.
    live_session :public, on_mount: {EzagentWeb.LiveAuth, :put_locale} do
      live "/", HomeLive
    end

    # Phase 4-completion Spec 05 §A.2.3 — controller-rendered login.
    # task #87: POST /login is now email+password; magic-link send moved to
    # POST /login/magic (kept, SMTP-gated). /login/credentials (handle/URI) is
    # orphaned from the page and retired in PR-6.
    get "/login", SessionController, :new
    get "/login/token", SessionController, :token
    post "/login", SessionController, :create
    post "/login/magic", SessionController, :magic_create
    delete "/logout", SessionController, :delete
    post "/logout", SessionController, :delete
    get "/auth/magic/:token", MagicLinkController, :consume
    # task #87 Decision 10 — email+password self-registration (gated; closed by
    # default). Replaces the legacy magic-link onboarding/register-complete chain
    # (retired). `/auth/confirm/:token` verifies email ownership.
    get "/register", RegistrationController, :new
    post "/register", RegistrationController, :create
    post "/register/request", RegistrationController, :request_access
    get "/auth/confirm/:token", RegistrationController, :confirm
    # #88 PR-2 — email external-mirror binding verification. The human clicks
    # the link in the verification email (a LINK, not a reply token) to flip
    # the binding to :verified. Public (token IS the secret).
    get "/auth/email/confirm/:token", EmailBindingController, :confirm
    # task #87 — password reset via emailed :reset one-time link.
    get "/auth/reset", PasswordResetController, :new
    post "/auth/reset", PasswordResetController, :create
    get "/auth/reset/:token", PasswordResetController, :edit
    post "/auth/reset/:token", PasswordResetController, :update

    # The external surface SPA — the agent-generated page projection. Anonymous
    # visitors to a `public_view` session are minted a read-only anon-User and
    # joined (modeled on ChatFeedController); a signed-in member uses their real
    # principal. The live `Ezagent.Session.Membership.authorize/2` re-check at the
    # channel remains the authorization (no identity-less token).
    get "/socialware/external", Socialware.ExternalFeedController, :show

    # Resource-unification P2a / OI-1 — PUBLIC external-feed attachment download
    # (no RequireEntity; feed viewers have a minted/anon principal). Authorized
    # by capability: the principal's ChatFeedAuth session token + the signed
    # UploadToken bound to the upload URI, with serve-time approved-only
    # re-validation in ExternalFeed.authorized_attachment_path/4.
    get "/socialware/external/download", Socialware.ExternalFeedController, :download

    # Back-compat 301: the legacy `/socialware/customer[/download]` paths are
    # retired in favour of `/socialware/external[/download]`. Static analysis
    # cannot enumerate external share-links, so a permanent redirect (preserving
    # the query string) is the safe default for any shipped link. First-party
    # consumers (world iframe, hello docstrings) are re-pointed in-repo.
    get "/socialware/customer", Socialware.ExternalFeedController, :legacy_show
    get "/socialware/customer/download", Socialware.ExternalFeedController, :legacy_download

    # #51 §4.1 — the CHAT external SPA. MOVED OUT of the RequireEntity scope into
    # the public `:browser` scope so an anonymous visitor can view a session with
    # web-anonymous socialware installed. The controller resolves the caller itself:
    # a still-signed-in member
    # (recovered via `optional_current_entity/1`) gets a token for that principal;
    # an anonymous visitor to a `Ezagent.Socialware.PublicView.web_anon_access?/1`
    # session is minted a read-only anon-User (cookie-bound) and joined; an
    # anonymous visitor to a PRIVATE session bounces to /login (the gate is the
    # public-view check, NOT a plug). The live ChatMembership re-check at the
    # channel remains the authorization.
    get "/socialware/chat", Socialware.ChatFeedController, :show

    # Path-route hello pages: `app.ezagent.chat/hello/<name>` serves the
    # public page for `session://<hello_workspace>/hello/<name>`. The workspace
    # comes from application config (default "demo" in dev); the full socialware
    # anon-access pipeline (PublicView gate, anon minting, SPA shell) runs
    # unchanged — this is just a short URL entry.
    get "/hello/:session_name", Socialware.ChatFeedController, :show_by_name
    post "/hello/delegate", HelloDelegationController, :create
    get "/hello/delegate/resume", HelloDelegationController, :resume
    post "/hello/delegate/resume", HelloDelegationController, :resume
  end

  # Plugin-package (Q1-C): hot-loaded plugins serve their frontend island
  # bundles here WITHOUT a web rebuild. `Ezagent.PluginAssetRegistry` is
  # augmented at hot-load (install) and reduced at unload; this controller
  # streams from the unpacked package's `priv/` dir. Public (an island JS/CSS
  # bundle is, like `ezagent_web/priv/static/assets`, a static asset — the
  # bundle is not a capability-gated surface; the BEHIND it is).
  scope "/plugin-assets", EzagentWeb do
    pipe_through :api

    get "/:slug/*path", PluginAssetController, :show
  end

  # /admin* requires login (Phase 4-completion Spec 05 §A.2.3 +
  # PR #123 hardening: live_session on_mount gates the WS reconnect
  # path that bypasses the HTTP Plug pipeline).
  # Authenticated chat-compose upload download. Mounted in the EzagentWeb
  # scope (so the controller resolves correctly), under the same
  # RequireEntity plug as the LV scope below.
  #
  # Resource-unification P2 (🔒 auth-contract change, Allen-approved
  # 2026-06-08): the legacy `/files/:filename` route is FULLY RETIRED — no
  # back-compat shim. There is exactly ONE download surface for internal
  # callers — `/uploads/download?token=` — authorized by a signed capability
  # token. The internal LiveView mints the SAME token at render time (via the
  # core `Ezagent.Uploads.DownloadToken` module), so the UI never builds a
  # `/files/...` link.
  scope "/", EzagentWeb do
    pipe_through [:browser, EzagentWeb.Plugs.RequireEntity]

    # Resource-unification P2 (🔒 auth-contract change) — the SOLE internal
    # upload download route: a signed capability token
    # (`Ezagent.Uploads.DownloadToken`) bound to the ws-scoped
    # resource://<ws>/uploads/<name> URI, authorized by ws-segment against the
    # authenticated mount workspace via the FsResolver `uploads` authority/2.
    # Replaces the retired participation-based `/files/:filename` route.
    get "/uploads/download", UploadsController, :download

    # LV→world parity PR-2b — the world composer's cap-authorized upload POST.
    # The React island can't use the LiveView uploader (`phx-update="ignore"`),
    # so files arrive here; the controller dispatches `:session :attach`
    # (authorized at the same chokepoint as `:session :send`), then stores the
    # bytes under the target session's workspace and returns a signed grant.
    post "/world/uploads", WorldUploadsController, :create

    # Phase 9 PR-5 (SPEC v3 §6.4 amended): workspace switcher endpoint.
    # Logged-in users POST here from the top-left workspace dropdown;
    # controller clears session + redirects to /login?workspace=<target>.
    # Must be inside `:require_entity` so anonymous traffic can't spam
    # session-clearing POSTs.
    post "/workspaces/switch", WorkspaceSwitchController, :switch

    # T6.4 — receive a SHARED kanban board. A logged-in user clicks a bare share
    # link (`?token=` only, signed by the world `kanban.share_board` action); the
    # controller verifies the read-only token, RESOLVES the receiver's own target
    # session server-side (the sharer can't know the receiver's session), and
    # `Mount.mount`s the board read-only into it (token IS the share-time
    # authorization — the sharer had access; the receiver just mounts), then
    # redirects to that session's world chat page. Behind RequireEntity so the
    # clicker is a resolved principal.
    get "/socialware/kanban/receive", Socialware.KanbanShareController, :claim
  end

  # Liveness probe — plain JSON, no Ezagent dispatch path involved.
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

  # LLM Protocol API: OpenAI-compatible inbound endpoint.
  forward "/v1/chat/completions", EzagentPluginProtocolApi.OpenAI.ChatCompletionsPlug

  # Phase 6 PR 9: canonical auto-derived JSON API. Single controller
  # dispatches every `{kind, action}` registered in BehaviorRegistry.
  # GET /api/v1 = introspection (route catalog + interfaces).
  # POST /api/v1/:kind/:action = invoke.
  scope "/api/v1", EzagentWeb do
    pipe_through :api

    get "/", ApiV1Controller, :index
    post "/:kind/:action", ApiV1Controller, :invoke
  end

  scope "/api/session-config", EzagentWeb do
    pipe_through :api

    get "/", SessionConfigController, :index
    post "/:operation", SessionConfigController, :invoke
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
