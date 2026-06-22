# ezagent_plugin_email — admin email send/receive for ezagent.chat (#88, simplified)

> Status: design (brainstorm-approved 2026-06-22). Next: codex adversarial review → plan.
> Supersedes the heavy "#88 second half" (external_mirror `:pull` adapter + GenServer
> poller + auto-ingest-to-session), which is **deferred**. This is the drastically
> simplified version Allen approved: one self-contained plugin owning the email
> capability, with an admin UI panel hosted by world.

## 1. Goal

Give an operator an admin-only tool to **send** and **read** mail for the
`ezagent.chat` domain. Send uses real SMTP (CF's SMTP relay, or any standard
SMTP server a self-hoster configures). Receive pulls from the already-deployed
Cloudflare Email Worker (`ezagent-email-inbox`) over HTTP. The receive side is
behind a backend abstraction so a standard **IMAP** mailbox can be plugged in
later for self-hosters who do not use Cloudflare.

Non-goal this round: turning inbound mail into session messages, attachments,
read/unread state, IMAP implementation (seam only).

## 2. Why a dedicated plugin (`ezagent_plugin_email`)

Email is a **generic capability**, not a world concern — world is only one
consumer (the admin panel). Per the plugin-isolation North Star, a generic
capability must not live inside another plugin (`ezagent_plugin_world`) nor be
bound to the web layer (`ezagent_web`). It gets its own umbrella app/plugin that
any consumer (the world panel, the CLI, a future session-ingest path) can use
without depending on world or web.

The UI **panel** is hosted by world because world's React renderer
(`world_renderer.js`) is the single owner of all admin UI today — no plugin ships
its own React assets. world reaches the email capability the same way it already
reaches `EzagentWeb.Mailer`: **runtime apply** (`Module.concat` +
`function_exported?`), so there is **no compile-time `world → plugin_email`
edge** and the acyclic gate stays satisfied. This mirrors the existing SMTP
settings panel (which is likewise hosted in world and dispatches `admin.smtp.*`).

## 3. Architecture overview

```
                        ┌─────────────────────────────────────────┐
   admin (world panel)  │  apps/ezagent_plugin_email               │
   admin (CLI)  ───────▶│                                          │
                        │  Ezagent.Email           (facade)        │
                        │   ├─ send/3   ─▶ Ezagent.Email.Mailer ───┼─▶ SMTP relay (CF / any server)
                        │   │              (Swoosh, otp_app=        │
                        │   │               :ezagent_plugin_email,  │
                        │   │               smtp_config @AppSettings)
                        │   ├─ inbox/1  ─┐                          │
                        │   ├─ fetch/2  ─┼─▶ Ezagent.Email.Inbox    │
                        │   └─ delete/2 ─┘   (behaviour)            │
                        │        └─ Inbox.CFWorker (:httpc) ────────┼─▶ Worker /inbox  (GET, DELETE)
                        │           Inbox.Imap  (future, deferred)  │
                        │                                           │
                        │  Mix.Tasks.Ezagent.Email   (CLI)          │
                        │  plugin_info/0, config_surface/0 (route)  │
                        └─────────────────────────────────────────┘
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
in prod → needs runtime `smtp_config`). The `smtp_config → Swoosh opts` mapping
(465 implicit-SSL vs 587 STARTTLS, OTP 27/28 `tls_options` with
`:public_key.cacerts_get()` + SNI) is **identical** to `EzagentWeb.Mailer`'s
existing `smtp_runtime_config/1`. To avoid divergent copies, extract that mapping
into a shared helper `Ezagent.Mail.SmtpOpts.from_config/1` placed in a layer both
mailers depend on (a small module in `ezagent_domain_identity`, where
`AppSettings` already lives), and have **both** `EzagentWeb.Mailer` and
`Ezagent.Email.Mailer` call it. (Refactoring the web mailer to use the shared
helper is in scope precisely because we are creating a second caller — leaving
two copies of TLS-sensitive SMTP logic is a latent bug.)

### 4.3 `Ezagent.Email.Inbox` (behaviour) + `Ezagent.Email.Inbox.CFWorker`

```elixir
@callback list(config :: map(), opts :: keyword()) :: {:ok, [map()]} | {:error, term()}
@callback fetch(config :: map(), key :: String.t()) :: {:ok, map()} | {:error, term()}
@callback delete(config :: map(), key :: String.t()) :: :ok | {:error, term()}
```

`Ezagent.Email.Inbox.CFWorker` implements all three with `:httpc` (the project's
existing HTTP client — no new dependency) against the Worker's pull API:
`GET /inbox[?to=]`, `GET /inbox/<key>`, `DELETE /inbox/<key>`, sending
`Authorization: Bearer <pull_token>`. Backend selection is by
`config["backend"]` (`"cf_worker"` now; `"imap"` reserved). An unknown/`"imap"`
backend returns `{:error, :backend_not_implemented}` with a clear message.

### 4.4 Config — `email_inbox_config` in `Ezagent.AppSettings`

```
email_inbox_config = %{
  "backend"    => "cf_worker",   # | "imap" (future)
  "pull_url"   => "https://ezagent-email-inbox.<acct>.workers.dev",
  "pull_token" => "<bearer>"     # masked (has_token) on read-back to the UI
}
```

Set via the world panel (mirrors how `smtp_config` is saved by
`admin.smtp.save`). Send continues to read the existing `smtp_config`. When
`pull_url`/`pull_token` are blank, `inbox/1` returns
`{:error, :inbox_not_configured}`.

### 4.5 `Mix.Tasks.Ezagent.Email` (CLI)

- `mix ezagent.email send --to <addr> --subject <s> --body <b>`
- `mix ezagent.email inbox [--to <addr>] [--limit N]`
- `mix ezagent.email fetch <key>`
- `mix ezagent.email delete <key>`

Thin wrappers over `Ezagent.Email`. Print human-readable output; non-zero exit on error.

### 4.6 Plugin declaration

`use Ezagent.Plugin`; `plugin_info/0` (slug `"email"`); `config_surface/0 =>
%{kind: :route, path: "/settings/email", label: "邮箱"}` so world renders a nav
entry/route for the panel. No kinds/behaviors/adapters/children needed.

### 4.7 World-hosted panel (in `ezagent_plugin_world`)

- `Ezagent.World.AdminData.settings_state/1` adds an `"email"` block:
  `%{"configured" => bool, "config" => %{backend, pull_url, has_token},
     "inbox" => [records], "send" => %{to, subject, body}, "flash", "result"}`.
  The inbox list is populated on demand (see refresh action), not on every read.
- `Ezagent.World.AdminActions.handle_dispatch/3` adds:
  - `"admin.email.save_config"` → write `email_inbox_config` to AppSettings.
  - `"admin.email.refresh"` → `Ezagent.Email.inbox/1` → put records into state.
  - `"admin.email.send"` → `Ezagent.Email.send/4` → status string.
  - `"admin.email.delete"` (`%{"key" => k}`) → `Ezagent.Email.delete/2` → refresh.
  All call `Ezagent.Email` via runtime apply (`Module.concat([Ezagent, Email])` +
  `function_exported?`), returning a clear error status if the plugin is absent.
- `world_renderer.js` gains an Email settings panel component for the
  `/settings/email` route: config sub-form, inbox list (refresh + per-row open +
  delete-with-confirm), and a send form. Styling/layout reuse the SMTP panel.

### 4.8 Worker change — `DELETE /inbox/<key>`

Add to `infra/cf-email-worker/src/worker.js` `fetch` handler: on
`request.method === "DELETE"` and path `/inbox/<key>`, `env.EMAIL_INBOX.delete(key)`
→ `204`. Keep Bearer-token auth. Bump README. Redeploy (`wrangler deploy`) and
verify with `curl -X DELETE`.

## 5. Data flow

- **Send**: panel/CLI → `Ezagent.Email.send/4` → `Ezagent.Email.Mailer`
  (Swoosh SMTP, opts from `smtp_config`) → SMTP relay (CF or self-host).
- **Receive**: CF Email Routing catch-all → Worker `email()` → KV (live today).
  Admin clicks Refresh → `Ezagent.Email.inbox/1` → `Inbox.CFWorker.list` (`:httpc`
  GET) → records rendered.
- **Delete**: panel/CLI → `Ezagent.Email.delete/2` → `Inbox.CFWorker.delete`
  (`:httpc` DELETE) → KV key removed → refresh.

## 6. Authorization

Admin-only, identical to the existing SMTP settings panel: the world admin
dispatch path is reachable only for callers with the admin capability (reuse the
same gate the SMTP panel uses — no new cap subject). The CLI is an operator/node
tool (already privileged). No anonymous/member access.

## 7. Error handling

`Ezagent.Email` returns tagged tuples: `{:error, :inbox_not_configured}`,
`{:error, :mail_not_configured}`, `{:error, :backend_not_implemented}`,
`{:error, {:http, status}}`, `{:error, reason}`. The world panel maps these to
status strings (`"error:inbox_not_configured"`, etc.) exactly like
`admin.smtp.*`. The CLI prints the reason and exits non-zero. Worker-side parse
failures already swallow (don't bounce); nothing changes there.

## 8. Testing

- `Ezagent.Email.send/4`: built+delivered via Local adapter; `{:error,
  :mail_not_configured}` when SMTP unset under a non-Local adapter (unit).
- `Ezagent.Email.Inbox.CFWorker`: `list/fetch/delete` against a stub HTTP
  endpoint (bypass server or `:httpc` against a local `Plug`/`:inets` stub);
  assert Bearer header, URL shapes, `{:error,{:http,_}}` on non-2xx,
  `:inbox_not_configured` on blank config.
- Backend seam: unknown backend → `{:error, :backend_not_implemented}`.
- `Ezagent.Mail.SmtpOpts.from_config/1`: 465 vs 587 option shape (unit), and
  `EzagentWeb.Mailer` still builds the same opts after the refactor (regression).
- CLI: smoke each subcommand (with the facade mocked or Local adapter).
- World panel: `AdminData.settings_state` includes the email block;
  `handle_dispatch` for each `admin.email.*` action sets expected status —
  mirroring the existing SMTP panel tests.
- Plugin: boots; `config_surface/0` passes the `:ezagent_plugin_check` compiler.
- Worker `DELETE`: manual `curl` verification (documented in README), like the
  existing live receive→cache→pull check.

## 9. Architectural gates (must stay green)

- **Acyclic gate**: `ezagent_plugin_email` depends only on `swoosh` + the layer
  holding `AppSettings`/`SmtpOpts` (`ezagent_domain_identity`) + `ezagent_core`
  (plugin behaviour). **No** edge to `ezagent_web` or `ezagent_plugin_world`.
  world → plugin_email is runtime-apply only (no compile edge), same as the
  existing world → `EzagentWeb.Mailer` call.
- **`check_invariants` / path allowlists**: register the new app where the gate
  scripts enumerate apps (lesson: stale allowlists turned main red twice).
- **`:ezagent_plugin_check` compiler**: `config_surface/0` is a valid `:route`.
- **uri_query / doc gates**: facade + modules carry moduledocs with
  code-verified behavioral claims.

## 10. Out of scope (deferred, documented)

- Inbound mail → session messages (the original heavy half).
- IMAP backend implementation (seam + config value reserved; candidate libs:
  Mailroom or Eximap for transport + gen_smtp/`mail` for MIME — chosen at
  implementation time).
- Attachments, read/unread state, search, pagination beyond a simple limit.
