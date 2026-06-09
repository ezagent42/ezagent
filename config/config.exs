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

config :ezagent_web,
  ecto_repos: [EzagentCore.Repo],
  generators: [context_app: :ezagent_core]

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
      ~w(js/app.js js/customer_app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
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
  # Standalone stylesheet for the socialware customer SPA. It is a public,
  # controller-rendered page (not a LiveView surface) so it does not load
  # app.css — it gets its own small Tailwind v4 + daisyUI build whose
  # @source directives scan the React SPA's JS for the classes it emits.
  ezagent_web_customer: [
    args: ~w(
      --input=assets/css/customer.css
      --output=priv/static/assets/css/customer.css
    ),
    cd: Path.expand("../apps/ezagent_web", __DIR__)
  ]

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

# Username & Auth M2 — Swoosh. SMTP relay/credentials are supplied at
# deliver-time from Ezagent.AppSettings (runtime, admin-configured), so
# only the adapter is fixed here. api_client: false — SMTP only, no HTTP
# API adapters, so no hackney/finch dependency is pulled in.
config :ezagent_web, EzagentWeb.Mailer, adapter: Swoosh.Adapters.SMTP
config :swoosh, :api_client, false

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
