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

---

## Verifying the credential chain end to end

Everything the Git provider does runs through one chain. When something is
misconfigured the symptom usually appears several links downstream of the cause,
so verify it link by link. Each step below tells you which permission or setting
is wrong when it is the one that fails.

```
private key ──sign──▶ App JWT
   │
   ├─ GET /app                                   → is the App reachable at all?
   ├─ GET /repos/{owner}/{repo}/installation     → is the App INSTALLED on that repo?
   ├─ POST /app/installations/{id}/access_tokens → can it mint an operation token?
   └─ POST /repos/{owner}/{repo}/git/blobs       → does the token actually have Contents: write?
```

| Failure | What it means |
|---|---|
| `GET /app` → 401 | The private key does not match the App, or `GITHUB_APP_ID` is wrong |
| `GET …/installation` → 404 | The App is **not installed** on that repository (settings alone are not enough — see step 8 above) |
| `POST …/access_tokens` → 403 | The installation is suspended |
| `POST …/git/blobs` → 403 `Resource not accessible by integration` | The installation does not have **Contents: write** — see the next section |

The blob write is the recommended write probe: it creates a **dangling blob**
(no ref, no commit, no PR, nothing visible in the repository UI, garbage-collected
by GitHub), so it is the smallest action that can distinguish "has write access"
from "does not".

### Permission changes need a SECOND approval

This is the one that most often looks like "I already set it".

An App's *declared* permissions and an installation's *accepted* permissions are
two different things. Editing **Permissions & events** on the App updates what it
**requests**; every existing installation keeps its old grant until the account
that installed it **approves the new permissions**. Tokens are minted from the
installation's grant, so until then nothing changes.

Diagnose it by comparing the two — they disagree exactly when an approval is pending:

```elixir
{:ok, %{body: app}}  = Req.get("https://api.github.com/app", headers: jwt_headers)
{:ok, %{body: inst}} = Req.get("https://api.github.com/repos/#{owner}/#{repo}/installation",
                               headers: jwt_headers)

app["permissions"]   # => %{"contents" => "write", "metadata" => "read", ...}   ← requested
inst["permissions"]  # => %{"metadata" => "read", ...}                          ← granted
```

To approve: `https://github.com/settings/installations/<installation_id>` →
**Configure** → accept the requested permissions. If no banner appears,
uninstalling and reinstalling the App grants the currently-declared set in one step.

### What each permission is for

| Permission | Level | Used by |
|---|---|---|
| **Contents** | Read and write | blob / tree / commit / ref creation — the provider-owned commit |
| **Pull requests** | Read and write | PR find-or-create, PR fresh-read |
| **Metadata** | Read | repository resolution (mandatory for every App) |
| **Checks** | Read | `list_checks` during observation |

A **public** repository will answer reads with any valid installation token, so
read probes can pass while `Contents: write` is still missing. Only the write
probe distinguishes them — do not conclude from green reads that the grant is
complete.

## Networks that require an HTTP proxy

Two independent things need proxy configuration, and neither picks it up from the
usual environment variables:

**1. Req (the plugin's HTTP client) ignores `HTTP_PROXY`/`HTTPS_PROXY`.** Finch
needs it passed explicitly. Every `GitHubClient` verb merges caller `opts` last,
and `GitHubAdapter` reads `:adapter_req_opts`, so a proxied environment configures
it there rather than by patching the client:

```elixir
config :ezagent_plugin_github,
  adapter_req_opts: [connect_options: [proxy: {:http, "127.0.0.1", 7890, []}]]
```

Symptom without it: `%Req.TransportError{reason: :timeout}`, which the client maps
to `:provider_unavailable` — indistinguishable from GitHub actually being down.

**2. `GitRunner` spawns git with a CLEARED environment** (`clear_env: true`, only
`GIT_CONFIG_NOSYSTEM` and `GIT_TERMINAL_PROMPT` survive). That is deliberate — no
ambient credential helper or user gitconfig may influence a task workspace — but
it also means `https_proxy` does not reach git. On such a machine a task workspace
cannot clone from a remote that requires the proxy; provision from a local mirror
instead.
