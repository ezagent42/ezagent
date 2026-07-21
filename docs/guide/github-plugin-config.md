# Guide: GitHub plugin configuration

> Operational how-to for setting up the GitHub OAuth App plugin (`ezagent_plugin_github`).
> This plugin provides Git REST API operations via the DomainGit.Adapter contract
> and encrypted credential storage.

## Required environment variables

| Variable | Purpose | Example |
|---|---|---|
| `GITHUB_CLIENT_ID` | GitHub OAuth App client ID | `Iv1.abcdef1234567890` |
| `GITHUB_CLIENT_SECRET` | GitHub OAuth App client secret | `abc123def456...` |
| `GITHUB_TOKEN_ENCRYPTION_KEY` | 32-byte AES-256-GCM key, base64-encoded | `uV0Jc1//tGxYs2Rf4Q==` (truncated) |

### GITHUB_TOKEN_ENCRYPTION_KEY

This key is used by the credential backend (`GitHubCredentialBackend`) to encrypt
GitHub access tokens at rest in the ETS table. Generate it with:

```bash
# Generate a 32-byte key and base64-encode it
openssl rand -base64 32
```

**Important:** Changing this key invalidates all stored credentials — they cannot
be decrypted after the key changes. Set it once at deployment time and treat it
as a permanent secret.

## Registering a GitHub OAuth App

1. Go to https://github.com/settings/developers
2. Click **New OAuth App** (top-right)
3. Fill in the registration form:
   - **Application name**: `ezagent` (or your deployment name)
   - **Homepage URL**: `https://<your-ezagent-host>`
   - **Authorization callback URL**: `https://<your-ezagent-host>/github/callback`
4. Click **Register application**
5. Copy the **Client ID** and generate a **Client secret**
6. Set `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET` in your deployment environment

### Callback URL

The GitHub OAuth flow redirects the user's browser to the callback URL after
authorization. This **must match exactly** what is configured in the GitHub App
settings. The default path is `/github/callback` and is handled by
`EzagentPluginGithub.GitHubCallbackPlug`.

To configure a custom redirect URI in ezagent config:

```elixir
# config/runtime.exs or equivalent
config :ezagent_plugin_github,
  redirect_uri: "https://my-ezagent.example.com/github/callback"
```

## Config block

Below is a complete example for `config/runtime.exs`. The `{:system, "VAR"}`
pattern is resolved at runtime by `EzagentPluginGithub.Config.fetch_env!/1`.

```elixir
# runtime.exs
import Config

config :ezagent_plugin_github,
  oauth_client_id: {:system, "GITHUB_CLIENT_ID"},
  oauth_client_secret: {:system, "GITHUB_CLIENT_SECRET"},
  token_encryption_key: {:system, "GITHUB_TOKEN_ENCRYPTION_KEY"},
  redirect_uri: "https://my-ezagent.example.com/github/callback"
```

For local development, you can set the variables in a `.envrc` or shell profile:

```bash
export GITHUB_CLIENT_ID="Iv1.abcdef1234567890"
export GITHUB_CLIENT_SECRET="abc123def456..."
export GITHUB_TOKEN_ENCRYPTION_KEY="$(openssl rand -base64 32)"
```

## Verifying the plugin is registered

Check the server logs at boot time for the `"github"` plugin registration:

```log
[info] Plugin registered: github (GitHub OAuth) v0.1.0
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
- Missing environment variables (raises at boot)
- `BackendPairRegistry` declaration drift (raises at boot)
- `DriverRegistry` declaration drift (raises at boot)
