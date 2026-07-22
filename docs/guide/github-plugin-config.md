# Guide: GitHub plugin configuration

> Operational how-to for setting up the **GitHub App** plugin (`ezagent_plugin_github`,
> app_id `4361756`). This plugin provides Git REST API operations via the
> DomainGit.Adapter contract and encrypted credential storage.
>
> **Auth model:** the plugin authenticates as a GitHub App. Repository operations
> use short-lived **installation access tokens** minted from the App's private key;
> user login is a **user-to-server OAuth** flow used only for identity. This
> replaces the retired OAuth-App model (a deleted OAuth App / `scope=repo` user
> token).

## Required configuration

`app_id` and `client_id` are **public identifiers** and are set directly in
`config/config.exs` (no env var needed). The three **secrets** below MUST be
provided via environment variables and never hardcoded:

| Variable | Purpose | Notes |
|---|---|---|
| `GITHUB_APP_PRIVATE_KEY` | The App's RSA private key (**PEM**), signs the App JWT that mints installation tokens | Fail-loud: boot/first-use raises on a missing or malformed PEM |
| `GITHUB_CLIENT_SECRET` | The App's OAuth client secret (user-to-server identity flow) | secret |
| `GITHUB_WEBHOOK_SECRET` | HMAC key for verifying inbound webhook deliveries (`X-Hub-Signature-256`) | secret |
| `GITHUB_TOKEN_ENCRYPTION_KEY` | 32-byte AES-256-GCM key, base64-encoded, for credential-at-rest encryption | secret |

### GITHUB_APP_PRIVATE_KEY

The `.pem` GitHub generates when you create a private key for the App. Provide the
full PEM (including the `-----BEGIN … PRIVATE KEY-----` header/footer). Multi-line
values can be supplied via a file and exported, e.g.:

```bash
export GITHUB_APP_PRIVATE_KEY="$(cat /secure/path/ezagent-github-app.pem)"
```

The loader (`EzagentPluginGithub.Config.private_key/0`) decodes the PEM and **fails
loud** if it is missing or not a decodable private key — it never falls back to a
placeholder, so a misconfigured key surfaces immediately instead of producing JWTs
GitHub rejects.

### GITHUB_TOKEN_ENCRYPTION_KEY

Used by the credential backend (`GitHubCredentialBackend`) to encrypt stored
credentials at rest in the ETS table. Generate it with:

```bash
openssl rand -base64 32
```

**Important:** Changing this key invalidates all stored credentials — they cannot
be decrypted after the key changes. Set it once at deployment time and treat it as
a permanent secret.

## Configuring the GitHub App

1. Go to https://github.com/settings/apps (Settings → Developer settings → GitHub Apps).
2. Open the ezagent GitHub App (**app_id 4361756**, client_id `Iv23liKq2xku34o9IBwf`),
   or create a new App if provisioning a fresh deployment.
3. **Permissions** (repository): at minimum Contents (read/write), Pull requests
   (read/write), and Checks (read) for the Git provider's operations.
4. **User authorization callback URL**: `https://<your-ezagent-host>/github/callback`.
5. **Webhook** (optional but recommended): set the Webhook URL to your webhook
   endpoint and set a **Webhook secret** — provide the same value as
   `GITHUB_WEBHOOK_SECRET`.
6. Generate a **private key** (`.pem`) → provide as `GITHUB_APP_PRIVATE_KEY`.
7. Generate a **client secret** → provide as `GITHUB_CLIENT_SECRET`.
8. **Install** the App on the target account/org and the repositories it should
   operate on. Installation is what grants repo access (not the user token).

### Callback URL

The user-to-server OAuth flow redirects the user's browser to the callback URL
after authorization. This **must match exactly** what is configured in the App
settings. The default path is `/github/callback`, handled by
`EzagentPluginGithub.GitHubCallbackPlug`.

To configure a custom redirect URI:

```elixir
# config/runtime.exs or equivalent
config :ezagent_plugin_github,
  redirect_uri: "https://my-ezagent.example.com/github/callback"
```

## Config block

`app_id`/`client_id` are set in `config/config.exs`; the secrets resolve at runtime
via `{:system, "VAR"}` (`EzagentPluginGithub.Config`). A deployment override in
`config/runtime.exs` looks like:

```elixir
# runtime.exs
import Config

config :ezagent_plugin_github,
  # public identifiers (safe to commit)
  app_id: "4361756",
  client_id: "Iv23liKq2xku34o9IBwf",
  # secrets — from env, never hardcoded
  client_secret: {:system, "GITHUB_CLIENT_SECRET"},
  private_key: {:system, "GITHUB_APP_PRIVATE_KEY"},
  webhook_secret: {:system, "GITHUB_WEBHOOK_SECRET"},
  token_encryption_key: {:system, "GITHUB_TOKEN_ENCRYPTION_KEY"},
  redirect_uri: "https://my-ezagent.example.com/github/callback"
```

For local development, set the secrets in a `.envrc` or shell profile:

```bash
export GITHUB_APP_PRIVATE_KEY="$(cat /secure/path/ezagent-github-app.pem)"
export GITHUB_CLIENT_SECRET="<your-github-app-client-secret>"
export GITHUB_WEBHOOK_SECRET="<your-github-app-webhook-secret>"
export GITHUB_TOKEN_ENCRYPTION_KEY="$(openssl rand -base64 32)"
```

## Verifying the plugin is registered

Check the server logs at boot time for the `"github"` plugin registration:

```log
[info] Plugin registered: github (GitHub App) v0.1.0
```

You can also verify programmatically in an `iex` session:

```elixir
# Check that the credential backend module is loaded and callable
{:module, _} = Code.ensure_loaded(EzagentPluginGithub.GitHubCredentialBackend)

# Check that the adapter is registered
Ezagent.DomainGit.AdapterRegistry.lookup("github")
# => {:ok, EzagentPluginGithub.GitHubAdapter}
```

If the plugin did not boot, check for:
- Missing secret environment variables (raises at boot / first use)
- Malformed `GITHUB_APP_PRIVATE_KEY` PEM (fail-loud)
- `BackendPairRegistry` declaration drift (raises at boot)
- `DriverRegistry` declaration drift (raises at boot)
