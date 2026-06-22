# ezagent_plugin_email — admin email send/receive for ezagent.chat (#88, CLI-only)

> Status: design (brainstorm-approved + codex-reviewed 2026-06-22). Next: codex
> re-scan of this trimmed spec → plan.
> Simplified twice from the original "#88 second half": first dropping the heavy
> external_mirror `:pull` adapter + auto-ingest-to-session (deferred), then
> dropping the world UI panel entirely (Allen 2026-06-22). This is a **CLI-only**
> operator tool — no web/UI surface, which removes the two HIGH codex findings
> (config_surface panel hosting + admin authorization) by construction.

## 1. Goal

Give an operator a `mix ezagent.email` CLI to **send** and **read/delete** mail
for the `ezagent.chat` domain. Send uses real SMTP (Cloudflare's SMTP relay, or
any standard SMTP server a self-hoster configures). Receive/delete pull from the
already-deployed Cloudflare Email Worker (`ezagent-email-inbox`) over HTTP. The
receive side sits behind a backend abstraction so a standard **IMAP** mailbox can
be plugged in later for self-hosters who do not use Cloudflare.

Non-goals this round: any web/UI panel; turning inbound mail into session
messages; attachments; read/unread state; the IMAP implementation (seam only).

## 2. Why a dedicated plugin (`ezagent_plugin_email`)

Email is a **generic capability**, not a world/web concern. Per the
plugin-isolation North Star it gets its own umbrella app so any future consumer
(a later UI, a session-ingest path) can use it without dragging email into
another plugin or the web layer. It is a real `use Ezagent.Plugin` app for
ecosystem consistency and so a UI is a clean drop-in later, but it registers no
kinds/behaviors/adapters/UI — the plugin body is just `plugin_info/0`.

There is **no world or web code in this round.** The CLI is the only entry point.

## 3. Architecture overview

```
                  ┌─────────────────────────────────────────────┐
   operator ─────▶│  apps/ezagent_plugin_email                   │
   (mix CLI)      │                                              │
                  │  Mix.Tasks.Ezagent.Email   (CLI)             │
                  │        │                                     │
                  │  Ezagent.Email            (facade)           │
                  │   ├─ send/4   ─▶ Ezagent.Email.Mailer ───────┼─▶ SMTP relay (CF / any server)
                  │   │              (Swoosh, otp_app=            │
                  │   │               :ezagent_plugin_email)      │
                  │   ├─ inbox/1  ─┐                              │
                  │   ├─ fetch/2  ─┼─▶ Ezagent.Email.Inbox        │
                  │   └─ delete/2 ─┘   (behaviour)                │
                  │        ├─ Inbox.CFWorker (:httpc) ────────────┼─▶ Worker /inbox (GET, DELETE)
                  │        └─ Inbox.Imap     (future, deferred)   │
                  │                                               │
                  │  Ezagent.Email.Config  (creds-file + env)     │
                  │  plugin_info/0  (use Ezagent.Plugin)          │
                  └─────────────────────────────────────────────┘
```

Send transport is already backend-agnostic: Swoosh's SMTP adapter targets any
standard SMTP server; `smtp_config` (host/port/user/pass/from/tls) points it at
CF or a self-hoster's server. Only **receive** needs the backend seam.

## 4. Components & interfaces

### 4.1 `Ezagent.Email` (facade) — `apps/ezagent_plugin_email/lib/ezagent/email.ex`

```elixir
@spec send(to :: String.t(), subject :: String.t(), body :: String.t(), opts :: keyword()) ::
        {:ok, term()} | {:error, term()}
# opts: :from (defaults to smtp_config.from_address or "no-reply@ezagent.chat"),
#       :html (optional html body). Delegates to Ezagent.Email.Mailer.

@spec inbox(opts :: keyword()) :: {:ok, [map()]} | {:error, term()}
# opts: :to (filter recipient), :limit. Delegates to the configured Inbox backend.

@spec fetch(key :: String.t(), opts :: keyword()) :: {:ok, map()} | {:error, :not_found | term()}

@spec delete(key :: String.t(), opts :: keyword()) :: :ok | {:error, term()}
```

Each inbox record (CFWorker backend) has keys:
`%{"key","from","to","subject","date","text","html","messageId","receivedAt","size"}`.

### 4.2 `Ezagent.Email.Mailer` — Swoosh mailer

`use Swoosh.Mailer, otp_app: :ezagent_plugin_email`. Builds a plain message
(`to/from/subject/text_body[/html_body]`) and delivers it. Adapter is fixed at
compile time per env (Local in dev/test → always ready; `Swoosh.Adapters.SMTP`
in prod → needs runtime `smtp_config` from `Ezagent.AppSettings`, the existing
store the web mailer already uses). When SMTP is unset under a non-Local adapter,
`send/4` returns `{:error, :mail_not_configured}`.

The `smtp_config → Swoosh opts` mapping (465 implicit-SSL vs 587 STARTTLS, OTP
27/28 `tls_options` with `:public_key.cacerts_get()` + SNI) is **identical** to
`EzagentWeb.Mailer`'s existing private `smtp_runtime_config/1`. Extract it into a
**pure** shared helper `Ezagent.Mail.SmtpOpts.from_config/1` in
`ezagent_domain_identity` (where `AppSettings` already lives; `ezagent_web`
already depends on identity — `apps/ezagent_web/mix.exs:62-63` — so no cycle), and
have **both** `EzagentWeb.Mailer` and `Ezagent.Email.Mailer` call it. The helper
only shapes options; it MUST NOT pull `:swoosh` (or any transport dep) into
identity. Refactoring the web mailer to the shared helper is in scope precisely
because we add a second caller — two copies of TLS-sensitive SMTP logic is a
latent bug.

### 4.3 `Ezagent.Email.Inbox` (behaviour) + `Ezagent.Email.Inbox.CFWorker`

```elixir
@callback list(config :: map(), opts :: keyword()) :: {:ok, [map()]} | {:error, term()}
@callback fetch(config :: map(), key :: String.t()) :: {:ok, map()} | {:error, term()}
@callback delete(config :: map(), key :: String.t()) :: :ok | {:error, term()}
```

`Ezagent.Email.Inbox.CFWorker` implements all three with `:httpc` (the project's
existing HTTP client — feishu/curl_agent use it; no new dep) against the Worker's
pull API: `GET /inbox[?to=]`, `GET /inbox/<key>`, `DELETE /inbox/<key>`, sending
`Authorization: Bearer <pull_token>`. A single internal request helper handles
timeouts, status → tagged tuple (`{:error, {:http, status}}` on non-2xx), and
JSON. **TLS is explicit**: pass `{:ssl, [verify: :verify_peer, cacerts:
:public_key.cacerts_get()]}` in the `:httpc` http-options (same posture as the
mailer). Note: the existing `:httpc` callers (`plugin_feishu/client.ex:118`,
`plugin_curl_agent/api_client.ex:66`) pass NO ssl options and rely on `:httpc`'s
defaults — so this is a deliberate improvement, not a copy of the house pattern.
Backend selected by `config["backend"]` (`"cf_worker"` now; `"imap"` reserved →
returns `{:error, :backend_not_implemented}` with a clear message).

### 4.4 `Ezagent.Email.Config` — credentials file + env

Receive config is read at command time from a credentials JSON file (no DB, no
boot seed needed for a CLI tool):

```
<credentials>/email_inbox_config.json
{ "backend": "cf_worker",
  "pull_url": "https://ezagent-email-inbox.<acct>.workers.dev",
  "pull_token": "<bearer>" }
```

Path resolved via `Ezagent.System.FsResolver.path!(Ezagent.URI.system("credentials",
"email_inbox_config.json"))` — the same `system://credentials/…` location
`smtp_config.json` uses. Environment variables override file fields when set:
`EZAGENT_EMAIL_PULL_URL`, `EZAGENT_EMAIL_PULL_TOKEN`, `EZAGENT_EMAIL_BACKEND`.
`Ezagent.Email.Config.load/0 :: {:ok, map()} | {:error, :inbox_not_configured}`
returns `:inbox_not_configured` when neither file nor env supplies a non-blank
`pull_url`+`pull_token`. The token is read from disk/env only — it is never logged
or echoed (CLI prints `pull_url` and a masked token at most).

Send continues to read the existing `smtp_config` from `AppSettings` (the proven
path); this round does not move SMTP config to the file.

### 4.5 `Mix.Tasks.Ezagent.Email` (CLI)

- `mix ezagent.email send --to <addr> --subject <s> --body <b> [--html <h>]`
- `mix ezagent.email inbox [--to <addr>] [--limit N]`  → table: key, from, subject, receivedAt
- `mix ezagent.email fetch <key>`                       → full record (text body)
- `mix ezagent.email delete <key>`

Thin wrappers over `Ezagent.Email`. Human-readable output; non-zero exit on
error with the tagged reason printed. `use Mix.Task` and start the needed apps
with `Application.ensure_all_started(:ezagent_plugin_email)` (which transitively
starts `:swoosh`, `:inets`, `:ssl`, and the AppSettings-bearing apps) — the same
shape `Mix.Tasks.Ezagent.Invite` uses (`ensure_all_started` + `OptionParser`),
not `Mix.Task.run("app.start", …)`.

### 4.6 Worker change — method-aware `DELETE /inbox/<key>`

The current `fetch` handler matches by path only and does not check
`request.method` (`infra/cf-email-worker/src/worker.js:47-64`), so a DELETE
branch appended after the `/inbox/<key>` GET branch would be unreachable.
Restructure to route by `{method, pathname}`: `GET /inbox` (list),
`GET /inbox/<key>` (fetch), `DELETE /inbox/<key>` → `env.EMAIL_INBOX.delete(key)`
→ `204`; other methods → `405`. Keep the Bearer-token auth check first. Update
README (currently documents GET only, `README.md:16-20`). Redeploy
(`wrangler deploy`) and verify with `curl -X DELETE`.

## 5. Data flow

- **Send**: CLI → `Ezagent.Email.send/4` → `Ezagent.Email.Mailer` (Swoosh SMTP,
  opts from `smtp_config` via `SmtpOpts.from_config/1`) → SMTP relay (CF/self-host).
- **Receive**: CF Email Routing catch-all → Worker `email()` → KV (live today).
  CLI `inbox`/`fetch` → `Ezagent.Email.inbox|fetch` → `Inbox.CFWorker` (`:httpc`
  GET, config from `Ezagent.Email.Config`) → records printed.
- **Delete**: CLI `delete` → `Ezagent.Email.delete/2` → `Inbox.CFWorker` (`:httpc`
  DELETE) → KV key removed.

## 6. Authorization

The CLI is an operator/node tool — running `mix ezagent.email` already implies
shell access to the deployment, the same trust level as `mix ezagent.invite`.
There is no web surface, so no in-app capability gate is needed this round. The
`pull_token` and SMTP credentials live in operator-controlled config
(credentials file / `AppSettings`), not exposed to any client.

## 7. Error handling

`Ezagent.Email` returns tagged tuples: `{:error, :inbox_not_configured}`,
`{:error, :mail_not_configured}`, `{:error, :backend_not_implemented}`,
`{:error, :not_found}`, `{:error, {:http, status}}`, `{:error, reason}`. The CLI
prints the reason and exits non-zero. Worker-side parse failures already swallow
(don't bounce); nothing changes there.

## 8. Testing

- `Ezagent.Email.send/4`: built+delivered via Local adapter; `{:error,
  :mail_not_configured}` when SMTP unset under a non-Local adapter (unit).
- `Ezagent.Email.Inbox.CFWorker`: `list/fetch/delete` against a stub HTTP
  endpoint (local `:inets`/`Plug` stub); assert Bearer header, URL shapes,
  `{:error,{:http,_}}` on non-2xx.
- `Ezagent.Email.Config`: file-only, env-override, and `:inbox_not_configured`
  when blank; token never appears in any logged/printed output.
- Backend seam: unknown/`"imap"` backend → `{:error, :backend_not_implemented}`.
- `Ezagent.Mail.SmtpOpts.from_config/1`: 465 vs 587 option shape (unit), and
  `EzagentWeb.Mailer` still builds the same opts after the refactor (regression).
- CLI: smoke each subcommand (facade mocked or Local adapter); non-zero exit on
  error.
- Plugin: boots; module passes the `:ezagent_plugin_check` compiler; wired into
  `ezagent_web` deps + the release app list (`all_plugin_apps_wired_to_web_test`).
- Worker `DELETE`: manual `curl` verification (documented in README), like the
  existing live receive→cache→pull check.

## 9. Architectural gates (must stay green)

- **Acyclic / layer purity**: `ezagent_plugin_email` depends only on `swoosh`,
  `ezagent_domain_identity` (`AppSettings` + the pure `SmtpOpts` helper),
  `ezagent_core` (plugin behaviour + `FsResolver`/`URI`), and `:inets`/`:ssl`.
  **No** edge to `ezagent_web` or `ezagent_plugin_world`
  (`layer_purity_test.exs`).
- **Plugin boot wiring**: add `:ezagent_plugin_email` to `apps/ezagent_web/mix.exs`
  deps (enforced by `all_plugin_apps_wired_to_web_test`), to the root release
  applications (`mix.exs`), and give it the standard plugin `compilers` +
  `ezagent_plugin:` env so `:ezagent_plugin_check` runs. An unwired plugin
  compiles but is dead at boot.
- **`:httpc` runtime deps**: `mix.exs` lists `:inets` and `:ssl` in
  `extra_applications` (same as `ezagent_plugin_feishu`/`ezagent_plugin_curl_agent`).
- **`check_invariants` / path allowlists**: register the new app where the gate
  scripts enumerate apps (lesson: stale allowlists turned main red twice).
- **uri_query / doc gates**: facade + modules carry moduledocs with
  code-verified behavioral claims.

## 10. Out of scope (deferred, documented)

- Any web/UI panel (a future drop-in; the plugin is structured so a UI consumer
  can call `Ezagent.Email` without changes here).
- Inbound mail → session messages (the original heavy half).
- IMAP backend implementation (seam + config value reserved; candidate libs:
  Mailroom or Eximap for transport + gen_smtp/`mail` for MIME — chosen at
  implementation time).
- Attachments, read/unread state, search, pagination beyond a simple limit.
