# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

# Configure Mix tasks and generators
config :ezagent_core,
  ecto_repos: [EzagentCore.Repo]

# Task #58 — default SessionTemplate ⇄ cc-orchestrator decoupling.
#
# Legacy deployment seam retained for callers that still read it directly.
# The stock `default` SessionTemplate no longer consumes this value: main
# hotfix 2026-07-10 keeps default session creation plain (`installs: ["chat"]`)
# so it cannot block on orchestrator install/readiness. Explicit templates may
# still install orchestrator socialware.
config :ezagent_domain_session,
  default_orchestrator_template_uri: "template://system/agent/cc-orchestrator",
  socialware_manifest_boot_scan: config_env() in [:prod]

config :ezagent_domain_session,
  public_scheme: "https",
  public_host: "app.ezagent.chat",
  public_port: 443

config :ezagent_web,
  ecto_repos: [EzagentCore.Repo],
  generators: [context_app: :ezagent_core],
  # Operator-console host scope. dev/test keep Phoenix's `"world."` prefix
  # semantics (`world.localhost`, `world.ezagent.chat`); prod overrides to nil
  # so `/admin`, `/sessions`, `/identities`, etc. serve on the public apex.
  world_host_scope: "world.",
  # Session-cookie domain (read at compile time by EzagentWeb.Endpoint). Production
  # is fronted by the `*.ezagent.chat` tunnels, so the cookie is shared across the
  # `app.` / `world.` subdomains. `dev.exs` overrides this to `nil` (host-only) so
  # login works on `localhost` / `world.localhost`.
  session_cookie_domain: ".ezagent.chat",
  # Default workspace for short hello URLs (`/hello/<name>` → session://<ws>/hello/<name>).
  # Override per-environment (e.g. prod sets the production workspace).
  hello_workspace: "system"

# Configures the endpoint
config :ezagent_web, EzagentWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: EzagentWeb.ErrorHTML, json: EzagentWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: EzagentCore.PubSub,
  live_view: [signing_salt: "6S1Jg5/J"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  ezagent_web: [
    args:
      ~w(js/app.js js/viewer_app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/ezagent_web/assets", __DIR__),
    env: %{
      "NODE_PATH" => [
        Path.expand("../apps/ezagent_web/assets/node_modules", __DIR__),
        Path.expand("../deps", __DIR__),
        Mix.Project.build_path()
      ]
    }
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  ezagent_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/ezagent_web", __DIR__)
  ],
  # Standalone stylesheet for the socialware external viewer SPA. It is a public,
  # controller-rendered page (not a LiveView surface) so it does not load
  # app.css — it gets its own small Tailwind v4 + daisyUI build whose
  # @source directives scan the React SPA's JS for the classes it emits.
  ezagent_web_viewer: [
    args: ~w(
      --input=assets/css/viewer.css
      --output=priv/static/assets/css/viewer.css
    ),
    cd: Path.expand("../apps/ezagent_web", __DIR__)
  ]

config :ezagent_plugin_world,
  world_module_url: "/assets/world/main.js",
  world_css_url: "/assets/world/world.css"

# The hello @json-render operator island. Unlike world (which serves its island
# from a Vite dev server in dev), hello ships a PRE-BUILT bundle
# (apps/ezagent_plugin_hello/assets → priv/static/assets/hello), so the same URL
# works in dev and prod. Rebuild with: cd apps/ezagent_plugin_hello/assets &&
# PATH=~/.local/linux-node/bin:$PATH npm run build
config :ezagent_plugin_hello,
  hello_module_url: "/assets/hello/main.js"

# i18n (#91) — the hello builder narration is authored with English msgids and
# translated in priv/gettext/zh_CN. The narration runs in a Generator Task with
# no per-request Locale plug, so default the plugin's backend to zh_CN to
# preserve the pre-i18n Chinese copy. (Generator also pins the locale per turn.)
config :ezagent_plugin_hello, EzagentPluginHello.Gettext, default_locale: "zh_CN"

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Register text/event-stream so Plug's :accepts plug recognises it for
# Phase 1 v1_prototype's SSE endpoint at /api/cc-bridge/events. Without
# this entry, Plug returns 406 Not Acceptable for the bridge's
# `Accept: text/event-stream` request.
config :mime, :types, %{
  "text/event-stream" => ["event-stream"]
}

# Username & Auth M2 — Swoosh. Mail transport config (base_url/api_key, or
# SMTP relay/credentials) is supplied at deliver-time from Ezagent.AppSettings
# (runtime, admin-configured / boot-seeded), so only the adapter is fixed here.
#
# Prod auth mail (magic-link / confirm / reset) goes through
# `email.ezagent.chat` — Cloudflare Email Sending, REST only (POST /api/send),
# NOT an SMTP relay — so ezagent_web uses the REST adapter. It calls stdlib
# `:httpc` directly, so `api_client: false` (below) stays correct: no
# hackney/finch dependency is pulled in.
config :ezagent_web, EzagentWeb.Mailer, adapter: Ezagent.Mail.EzagentChatAdapter
config :ezagent_plugin_email, Ezagent.Email.Mailer, adapter: Swoosh.Adapters.SMTP

config :ezagent_plugin_email, :verification_base_url, "https://app.ezagent.chat"
config :swoosh, :api_client, false

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
