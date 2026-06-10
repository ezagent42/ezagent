import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

# Dev DB path comes from EZAGENT_HOME so the working tree stays clean
# (Phase 6 PR 1). Test keeps its own ephemeral DB in repo root via
# config/test.exs (Sandbox pool, gitignored). Prod still requires
# DATABASE_PATH env.
if config_env() == :dev do
  File.mkdir_p!(Ezagent.Home.path(:db))

  config :ezagent_core, EzagentCore.Repo,
    database: Path.join(Ezagent.Home.path(:db), "ezagent_core.db")
end

# The block below contains prod specific runtime configuration.
if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/ezagent_core/ezagent_core.db
      """

  config :ezagent_core, EzagentCore.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # PR #123 hardening: when the public Cloudflare tunnel fronts the
  # phx endpoint, WS upgrades come from app.ezagent.chat (the tunnel
  # rewrites Origin). Lock check_origin to the public hostname +
  # the Tailscale IP for in-network admin access. Anything else
  # gets a 403 on WS upgrade — keeps any other-origin browser tab
  # from opening a cross-origin LV channel.
  # Extra WS check_origin entries (e.g. the Tailscale admin fallback on the
  # published host port :10043) — env-driven (comma-separated) so docker-compose
  # declares them without runtime.exs drift. codex #21 review.
  extra_check_origins =
    (System.get_env("EZAGENT_EXTRA_CHECK_ORIGINS") || "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)

  config :ezagent_web, EzagentWeb.Endpoint,
    # OTP release boot must start the endpoint (no `mix phx.server` in prod).
    # The prod container always serves, so set it unconditionally here.
    server: true,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT") || "10042")
    ],
    check_origin:
      [
        "https://app.ezagent.chat",
        "http://100.64.0.27:10042",
        "http://localhost:10042",
        "http://127.0.0.1:10042"
      ] ++ extra_check_origins,
    secret_key_base: secret_key_base

  # Resource-unification P2 — upload download-token signing secret (core-owned
  # config key), wired to the SAME SECRET_KEY_BASE so a token minted in
  # ezagent_web / ezagent_plugin_liveview verifies identically.
  config :ezagent_core, Ezagent.Uploads.DownloadToken, secret_key_base: secret_key_base

  # ## Using releases
  #
  # If you are doing OTP releases, you need to instruct Phoenix
  # to start each relevant endpoint:
  #
  #     config :ezagent_web, EzagentWeb.Endpoint, server: true
  #
  # Then you can assemble a release by calling `mix release`.
  # See `mix help release` for more information.

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :ezagent_web, EzagentWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :ezagent_web, EzagentWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  config :ezagent_core, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
end

# --- Public URL (all envs) -------------------------------------------------
# `EzagentWeb.Endpoint.url/0` must return the PUBLIC host, not localhost —
# magic-link emails embed an absolute URL the recipient opens in a browser.
# The app is fronted by the app.ezagent.chat Cloudflare tunnel in
# prod/staging deployments; dev-mode deployments accessed over Tailscale
# can override host + scheme + port so the magic-link URL points at the
# tailnet IP (e.g. `http://100.64.0.27:10042/auth/magic/...`) when the
# tunnel is intentionally not running.
#
# Three env vars, all optional:
#   - EZAGENT_PUBLIC_HOST   (default "app.ezagent.chat")
#   - EZAGENT_PUBLIC_SCHEME (default "https")
#   - EZAGENT_PUBLIC_PORT   (default depends on scheme: 443 for https, 80 for http)
#
# Endpoint `:url` only affects URL generation, not the bind address — the
# server still binds to the `:http` port configured above. (2026-05-26
# Allen: dev workflow needs Tailscale fallback when cloudflared is down.)
public_scheme = System.get_env("EZAGENT_PUBLIC_SCHEME", "https")

public_port =
  case System.get_env("EZAGENT_PUBLIC_PORT") do
    nil -> if public_scheme == "https", do: 443, else: 80
    port_str -> String.to_integer(port_str)
  end

config :ezagent_web, EzagentWeb.Endpoint,
  url: [
    host: System.get_env("EZAGENT_PUBLIC_HOST", "app.ezagent.chat"),
    scheme: public_scheme,
    port: public_port
  ]
