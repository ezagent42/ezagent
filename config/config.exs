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

# NOTE (C5 §3.4): the actor-framework port wiring (`:ezagent_actor` app env)
# is applied at core boot by `Ezagent.Kind.Adapters.wire!/0`, NOT here —
# `config :ezagent_actor, …` for the not-yet-existing app makes Elixir
# 1.19's app.config validation hard-fail child-app boots and silently
# aborts umbrella-root `mix test` recursion. See the module's moduledoc.

config :ezagent_core, Ezagent.Authentication,
  pat_resolver: Ezagent.Entity.Token,
  bridge_resolver: Ezagent.AgentBridge.TokenStore

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

# Role/reference plugin app lists for the generic CLI tasks, moved OUT of the
# task modules' `@attribute` literals so a deployment can extend them without
# editing infra code (and so infra tasks don't hardcode a specific plugin).
#
# `role_plugins` — apps `mix ezagent.agent.grant_recipe_caps` boots best-effort
# so their `roles/0` recipes register into `RecipeRegistry` before the lookup.
# `socialware_check_reference_apps` — apps `mix ezagent.socialware.check` boots
# best-effort so a definition's referenced adapters/recipes/view render-caps
# resolve. Both are atom-only, best-effort (a no-op if an app is absent from the
# build). Defaults preserve the previous hardcoded lists.
config :ezagent_domain_agent,
  role_plugins: [:ezagent_plugin_kanban]

config :ezagent_domain_session,
  socialware_check_reference_apps: [
    :ezagent_domain_socialware,
    :ezagent_plugin_hello,
    :ezagent_plugin_kanban
  ]

# `:home_workspace` — the SINGLE source of truth for the hello home workspace
# (`EzagentPluginHello.home_workspace/0`). The boot 官网 seed, the #185
# credential bridge destination, and the `/hello/<name>` serve side ALL read
# this one key, so a split-brain between seed-side and serve-side is
# structurally impossible. Default `"ezagent"` for all envs; a lane that needs
# a different home overrides THIS key only.
#
# #185 — the hello plugin's boot-time `DEEPSEEK_API_KEY` env → curl credential
# bridge (`EzagentPluginHello.CredentialBridge`). When the deploy env carries
# the key, boot registers it as the home workspace's shared curl credential
# source so freshly seeded hello `llm` members are born credentialed. Scoped to
# that one workspace; never baked into the shared hello template.
#
# `:site_seed_boot` — the governed 官网 deploy-seed
# (`EzagentPluginHello.OfficialSiteSeed`). When on, boot idempotently ensures
# `session://<home>/hello/ezagent-official` (the ruihua marketing page +
# greeter) exists, so a reseed self-heals the 官网 instead of leaving it wiped.
# Same family as the credential bridge above (config-gated, deploy-owned, NOT
# the `HELLO_DEMO_SEED` demo flag); paired with it so the DeepSeek source and
# the site that consumes it come up in the same environments.
config :ezagent_plugin_hello,
  home_workspace: "ezagent",
  credential_bridge_boot: config_env() in [:dev, :prod],
  site_seed_boot: config_env() in [:dev, :prod]

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
  session_cookie_domain: ".ezagent.chat"

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
  hello_module_url: "/assets/hello/main.js",
  kanban_published_read_adapter: EzagentWeb.Socialware.KanbanPublishedReadAdapter

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

# Phase 3 capability issue inversion: core owns authorization, while the
# identity domain supplies its existing live + durable held-cap loader.
config :ezagent_core, Ezagent.Cap, authority_loader: Ezagent.Identity

# Durable capability delivery retries. `require_sync_ack` is a policy seam for
# a future external/adversarial deployment; the current implementation never
# waits for an outbox row to become applied.
config :ezagent_core, Ezagent.Cap.DeliveryOutbox,
  require_sync_ack: [],
  sweep_interval_ms: 1_000,
  retry_base_ms: 1_000,
  retry_max_ms: 60_000,
  lease_ms: 30_000

# D2 — GitHub App credentials (app_id 4361756). `app_id` and `client_id` are
# public identifiers and are configured directly. Secrets are resolved at runtime
# from env via the {:system, "ENV_VAR"} tuple (EzagentPluginGithub.Config), never
# hardcoded. In dev/test the secret env vars must be set (or overridden per-env).
#   * private_key  — the App's RS256 .pem, signs the App JWT (installation tokens)
#   * client_secret — user-to-server OAuth (identity only, no repo scope)
#   * webhook_secret — verifies inbound X-Hub-Signature-256 deliveries
config :ezagent_plugin_github,
  app_id: "4361756",
  client_id: "Iv23liKq2xku34o9IBwf",
  client_secret: {:system, "GITHUB_CLIENT_SECRET"},
  private_key: {:system, "GITHUB_APP_PRIVATE_KEY"},
  webhook_secret: {:system, "GITHUB_WEBHOOK_SECRET"},
  token_encryption_key: {:system, "GITHUB_TOKEN_ENCRYPTION_KEY"}

# D2 — register the GitHub credential backend module so the provider-connection
# domain resolves it at runtime (via RuntimeBindings / Exchange).
config :ezagent_domain_provider_connection,
  credential_backend_implementations:
    Map.merge(
      Application.get_env(
        :ezagent_domain_provider_connection,
        :credential_backend_implementations,
        %{}
      ),
      %{"github-credential-v1" => EzagentPluginGithub.GitHubCredentialBackend}
    ),
  callback_redirect_pairs:
    Map.merge(
      Application.get_env(:ezagent_domain_provider_connection, :callback_redirect_pairs, %{}),
      %{"github-oauth" => "pair-github-v1"}
    ),
  local_authorization_backend_pairs:
    Map.merge(
      Application.get_env(
        :ezagent_domain_provider_connection,
        :local_authorization_backend_pairs,
        %{}
      ),
      %{{"github", "oauth_user"} => "pair-github-v1"}
    )

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
