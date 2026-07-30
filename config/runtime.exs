import Config

if config_env() in [:dev, :prod] do
  config :ezagent_domain_provider_connection, Ezagent.ProviderConnection.AuthorizationKeyRing,
    source: :runtime_env,
    active_key_id: System.fetch_env!("EZAGENT_PROVIDER_AUTH_ACTIVE_KEY_ID"),
    keys_json: System.fetch_env!("EZAGENT_PROVIDER_AUTH_KEYS_JSON")

  config :ezagent_domain_provider_connection,
    children: [{Ezagent.ProviderConnection.AuthorizationKeyRing, []}]
end

pat_digest_version = String.to_integer(System.get_env("EZAGENT_PAT_DIGEST_VERSION", "1"))

pat_peppers =
  1..pat_digest_version
  |> Enum.reduce(%{}, fn version, acc ->
    case System.get_env("EZAGENT_PAT_PEPPER_V#{version}") do
      pepper when is_binary(pepper) and byte_size(pepper) >= 32 -> Map.put(acc, version, pepper)
      _ -> acc
    end
  end)

if map_size(pat_peppers) > 0 or config_env() == :prod do
  config :ezagent_domain_identity, Ezagent.Entity.Token,
    current_version: pat_digest_version,
    peppers: pat_peppers
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# Loaded by deployment from that environment's seed.env. This is a founder
# email reference, not a credential; OfficialSiteSeed resolves it to an
# already-registered user and fails loudly when absent or invalid.
config :ezagent_plugin_hello,
       :official_site_founder_email,
       System.get_env("EZAGENT_HELLO_FOUNDER_EMAIL")

# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

if config_env() == :dev do
  config :ezagent_core, EzagentCore.Repo,
    username: System.get_env("POSTGRES_USER", "ezagent_pg_compat"),
    password: System.get_env("POSTGRES_PASSWORD", "ezagent_pg_compat"),
    hostname: System.get_env("POSTGRES_HOST", "127.0.0.1"),
    port: String.to_integer(System.get_env("POSTGRES_PORT", "55432")),
    database: System.get_env("POSTGRES_DB", "ezagent_pg_compat_dev"),
    priv: "priv/repo_pg"
end

public_host = System.get_env("EZAGENT_PUBLIC_HOST", "app.ezagent.chat")
public_scheme = System.get_env("EZAGENT_PUBLIC_SCHEME", "https")

public_port =
  case System.get_env("EZAGENT_PUBLIC_PORT") do
    nil -> if public_scheme == "https", do: 443, else: 80
    port_str -> String.to_integer(port_str)
  end

public_authority =
  if (public_scheme == "https" and public_port == 443) or
       (public_scheme == "http" and public_port == 80) do
    public_host
  else
    "#{public_host}:#{public_port}"
  end

public_origin = "#{public_scheme}://#{public_authority}"

config :ezagent_domain_session,
  public_scheme: public_scheme,
  public_host: public_host,
  public_port: public_port

config :ezagent_plugin_email, :verification_base_url, public_origin

# The block below contains prod specific runtime configuration.
if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  config :ezagent_core, EzagentCore.Repo,
    url: database_url,
    priv: "priv/repo_pg",
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

  world_host_scope =
    case System.get_env("WORLD_HOST_SCOPE") do
      nil -> nil
      "" -> nil
      "nil" -> nil
      "none" -> nil
      scope -> scope
    end

  config :ezagent_web, :world_host_scope, world_host_scope

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
        public_origin,
        "http://100.64.0.27:10042",
        "http://localhost:10042",
        "http://127.0.0.1:10042"
      ] ++ extra_check_origins,
    secret_key_base: secret_key_base

  # Resource-unification P2 — upload download-token signing secret (core-owned
  # config key), wired to the SAME SECRET_KEY_BASE so a token minted by
  # web/operator surfaces verifies identically.
  config :ezagent_core, Ezagent.Uploads.DownloadToken, secret_key_base: secret_key_base

  # URI-share unification (A1) — bearer share-token signing secret (sibling of
  # DownloadToken; SAME SECRET_KEY_BASE so web claim + plugin mint verify identically).
  config :ezagent_core, Ezagent.Cap.ShareToken, secret_key_base: secret_key_base

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

  # GitHub App (ezagent-git) credentials for the git-provider plugin. Non-secret
  # IDs come from the deploy env_file (secrets-<env>/ezagent.env); the three real
  # secrets (client_secret / webhook_secret / private_key PEM) are injected as env
  # vars by the prod entrypoint from the read-only /secrets mount — see
  # ezagent-deploy docker/entrypoint.prod.sh. Every key is LAZY: EzagentPluginGithub
  # .Config.fetch_env!/1 reads the env var only when github code actually runs, so a
  # missing var never blocks boot — it raises a clear error at first github use.
  config :ezagent_plugin_github,
    app_id: {:system, "GITHUB_APP_ID"},
    client_id: {:system, "GITHUB_APP_CLIENT_ID"},
    client_secret: {:system, "GITHUB_APP_CLIENT_SECRET"},
    private_key: {:system, "GITHUB_APP_PRIVATE_KEY"},
    webhook_secret: {:system, "GITHUB_APP_WEBHOOK_SECRET"}
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
config :ezagent_web, EzagentWeb.Endpoint,
  url: [
    host: public_host,
    scheme: public_scheme,
    port: public_port
  ]
