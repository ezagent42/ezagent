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

The UI **panel** is hosted by world because world's React app is the single
owner of all admin UI today — no plugin ships its own React assets, and admin
components are hard-coded (`apps/ezagent_plugin_world/assets/src/components/Admin.tsx`).
world reaches the email capability the same way it already reaches
`EzagentWeb.Mailer`: **runtime apply** (`Module.concat` + `function_exported?`),
so there is **no compile-time `world → plugin_email` edge** and the acyclic gate
stays satisfied.

**Correction (codex review):** `config_surface/0` does NOT render a panel — it is
validated only as a plugin-list link entry
(`apps/ezagent_core/lib/ezagent/plugin.ex:180-183`,
`apps/ezagent_plugin_world/lib/ezagent/world/workspace_plugin_data.ex:278-300`).
World has no generic per-plugin route renderer; unknown paths fall back to
sessions (`world_live.ex:807-808`). Therefore the email panel is **folded into
the existing world `/admin/settings` component** — the exact place the SMTP panel
already lives (an "Email" section beside the "SMTP" section in `Admin.tsx`), not a
new plugin route. `config_surface/0` is omitted (or used only as an optional
nav link), it is not load-bearing for the panel.

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
                        │  plugin_info/0  (use Ezagent.Plugin)      │
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
`AppSettings` already lives; `ezagent_web` already depends on identity —
`apps/ezagent_web/mix.exs:62-63` — so no cycle), and have **both**
`EzagentWeb.Mailer` and `Ezagent.Email.Mailer` call it. (Refactoring the web
mailer to use the shared helper is in scope precisely because we are creating a
second caller — leaving two copies of TLS-sensitive SMTP logic is a latent bug.)
The helper is a **pure** map→keyword function — it MUST NOT pull `:swoosh` (or any
transport dep) into `ezagent_domain_identity`; it only shapes options.

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

**Token never leaves the server (codex review):** the world state map is
serialized and `push_event`'d to the browser
(`admin_actions.ex:105-120`, `world_live.ex:269-273`). The settings read-back
therefore exposes only `has_token` (boolean), NEVER the raw `pull_token` — exactly
the `has_password` masking the SMTP panel uses (`admin_data.ex:102-113`). On save,
a blank `pull_token` field preserves the existing stored token (same
blank-preserves-existing rule as the SMTP password).

### 4.5 `Mix.Tasks.Ezagent.Email` (CLI)

- `mix ezagent.email send --to <addr> --subject <s> --body <b>`
- `mix ezagent.email inbox [--to <addr>] [--limit N]`
- `mix ezagent.email fetch <key>`
- `mix ezagent.email delete <key>`

Thin wrappers over `Ezagent.Email`. Print human-readable output; non-zero exit on error.

### 4.6 Plugin declaration

`use Ezagent.Plugin`; `plugin_info/0` (slug `"email"`). No
kinds/behaviors/adapters/children needed. `config_surface/0` is left at its
default (`nil`) — it does not host the panel (see §2 correction); an optional
plugin-list link could be added later but is not required.

**Boot wiring (codex review — required, else dead-at-boot):** a new plugin app
compiles standalone but will not boot or be plugin-checked unless wired in. The
plan MUST: (a) add `:ezagent_plugin_email` to `apps/ezagent_web/mix.exs` deps
(enforced by `all_plugin_apps_wired_to_web_test`), (b) add it to the root release
applications in `mix.exs`, and (c) give the app the standard plugin compiler/env
setup (`compilers` + `ezagent_plugin:` env) so `:ezagent_plugin_check` runs.

### 4.7 World-hosted panel (folded into the existing `/admin/settings`)

The panel is an **Email section inside world's existing settings surface** — the
same component that already renders the SMTP section — NOT a new route.

- `Ezagent.World.AdminData.settings_state/1` adds an `"email"` block:
  `%{"configured" => bool, "config" => %{backend, pull_url, has_token},
     "inbox" => [records], "send" => %{to, subject, body}, "flash", "result"}`.
  The inbox list is populated on demand (see refresh action), not on every read.
- `Ezagent.World.AdminActions.handle_dispatch/3` adds (and the world dispatch
  **whitelist** at `world_live.ex:219-222` must list these, like `admin.smtp.*`):
  - `"admin.email.save_config"` → write `email_inbox_config` to AppSettings.
  - `"admin.email.refresh"` → `Ezagent.Email.inbox/1` → put records into state.
  - `"admin.email.send"` → `Ezagent.Email.send/4` → status string.
  - `"admin.email.delete"` (`%{"key" => k}`) → `Ezagent.Email.delete/2` → refresh.
  All call `Ezagent.Email` via runtime apply (`Module.concat([Ezagent, Email])` +
  `function_exported?`), returning a clear error status if the plugin is absent.
- `apps/ezagent_plugin_world/assets/src/components/Admin.tsx` gains an Email
  section: config sub-form, inbox list (refresh + per-row open + delete-with-
  confirm), and a send form. Styling/layout reuse the SMTP section.

### 4.8 Worker change — `DELETE /inbox/<key>`

**Method-aware routing (codex review):** the current `fetch` handler matches by
path only and does not check `request.method`
(`infra/cf-email-worker/src/worker.js:47-64`), so a DELETE branch appended after
the `/inbox/<key>` GET branch would be unreachable. Restructure to route by
`{method, pathname}`: `GET /inbox` (list), `GET /inbox/<key>` (fetch),
`DELETE /inbox/<key>` → `env.EMAIL_INBOX.delete(key)` → `204`; other methods →
`405`. Keep the Bearer-token auth check first. Update README (currently documents
GET only, `README.md:16-20`). Redeploy (`wrangler deploy`) and verify with
`curl -X DELETE`.

## 5. Data flow

- **Send**: panel/CLI → `Ezagent.Email.send/4` → `Ezagent.Email.Mailer`
  (Swoosh SMTP, opts from `smtp_config`) → SMTP relay (CF or self-host).
- **Receive**: CF Email Routing catch-all → Worker `email()` → KV (live today).
  Admin clicks Refresh → `Ezagent.Email.inbox/1` → `Inbox.CFWorker.list` (`:httpc`
  GET) → records rendered.
- **Delete**: panel/CLI → `Ezagent.Email.delete/2` → `Inbox.CFWorker.delete`
  (`:httpc` DELETE) → KV key removed → refresh.

## 6. Authorization

**Codex review found the existing SMTP panel's gate is too weak to copy.** World
`/admin*` routes use `RequireEntity` (`router.ex:32-35`,
`require_entity.ex:6-9,31-34`), which admits **any** logged-in user or agent
entity, and `admin.smtp.*` actions are merely whitelisted and delegated with no
admin check (`world_live.ex:219-222`, `admin_actions.ex:14-25,34-53`). A
`:require_admin` LiveAuth hook exists but is unused by the world block
(`live_auth.ex:99-123`).

Email send / delete / inbox-token-config are more sensitive than the display-only
admin reads, so this round **adds a real admin gate** rather than inheriting the
weak one: before dispatching any `admin.email.*` action (and, since we are here,
the existing `admin.smtp.*` actions), assert the caller holds the admin
capability — either by moving the world `/admin*` route block under
`LiveAuth :require_admin`, or an action-level guard at the dispatch chokepoint.
The plan picks the smaller-blast-radius option; **tightening `admin.smtp.*` is an
in-scope security fix flagged to Allen** (it closes a pre-existing hole). The CLI
is an operator/node tool (already privileged). No anonymous/member access.

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
- Plugin: boots; module passes the `:ezagent_plugin_check` compiler; wired into
  `ezagent_web` deps + the release app list (`all_plugin_apps_wired_to_web_test`).
- Admin gate: a non-admin entity is rejected from every `admin.email.*` action
  (and `admin.smtp.*` after the tightening) — regression test for the new guard.
- Worker `DELETE`: manual `curl` verification (documented in README), like the
  existing live receive→cache→pull check.

## 9. Architectural gates (must stay green)

- **Acyclic gate**: `ezagent_plugin_email` depends only on `swoosh` + the layer
  holding `AppSettings`/`SmtpOpts` (`ezagent_domain_identity`) + `ezagent_core`
  (plugin behaviour). **No** edge to `ezagent_web` or `ezagent_plugin_world`.
  world → plugin_email is runtime-apply only (no compile edge), same as the
  existing world → `EzagentWeb.Mailer` call.
- **Plugin boot wiring** (codex review — §4.6): `:ezagent_plugin_email` added to
  `apps/ezagent_web/mix.exs` deps (enforced by `all_plugin_apps_wired_to_web_test`),
  to the root release applications (`mix.exs`), and given the standard plugin
  `compilers`/`ezagent_plugin:` env so `:ezagent_plugin_check` runs. A plugin that
  compiles but is unwired is dead at boot.
- **`:httpc` runtime deps** (codex review): the email plugin's `mix.exs` lists
  `:inets` and `:ssl` in `extra_applications` (same as `ezagent_plugin_feishu` /
  `ezagent_plugin_curl_agent`, the existing `:httpc` callers). The CFWorker
  backend centralizes one `:httpc` request helper (timeouts + status + JSON), and
  **explicitly decides TLS verification** for `https://*.workers.dev` (mirror the
  mailer's `verify_peer` + `:public_key.cacerts_get()` posture rather than leave
  it implicit).
- **`check_invariants` / path allowlists**: register the new app where the gate
  scripts enumerate apps (lesson: stale allowlists turned main red twice).
- **`:ezagent_plugin_check` compiler**: plugin module passes (no `config_surface`
  route is required; default `nil` is valid).
- **uri_query / doc gates**: facade + modules carry moduledocs with
  code-verified behavioral claims.

## 10. Out of scope (deferred, documented)

- Inbound mail → session messages (the original heavy half).
- IMAP backend implementation (seam + config value reserved; candidate libs:
  Mailroom or Eximap for transport + gen_smtp/`mail` for MIME — chosen at
  implementation time).
- Attachments, read/unread state, search, pagination beyond a simple limit.
