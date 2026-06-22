# Login, Registration & Email (task #87)

How authentication works in ezagent after the email+password-only change.

## Login

- The login page (`/login`) is **email + password**. The handle/URI login is gone.
- Internally the email is resolved to the canonical entity URI
  (`Profile.by_email/1`) and authenticated via `Ezagent.Entity.authenticate/3`
  with `allow_user_tokens: false` (a typed API token cannot be used as a
  password on the form). The entity URI remains the canonical identity.
- A user can log in only when `users.email_verified == true`.
- **Magic-link** passwordless login is available for existing accounts via
  `POST /login/magic`, shown on the login page **only when SMTP is configured**.
- Programmatic auth (CLI / API `Authorization: Bearer`) is unchanged.

## Registration

Self-registration is **closed by default**. Two runtime settings
(`Ezagent.AppSettings`):

| key | default | meaning |
|-----|---------|---------|
| `registration_open` | `false` | when `false`, no self-signup — admin provisions users |
| `registration_require_invite` | `false` | when open, require a valid invite code |

Open it:

```elixir
Ezagent.AppSettings.put("registration_open", true)
Ezagent.AppSettings.put("registration_require_invite", true)  # optional
```

Flow: `GET/POST /register` (email + password + display name, + invite code when
required) → an unverified user is created (`email_verified: false`) → a
confirmation email is sent → `GET /auth/confirm/:token` flips `email_verified` →
the user signs in. Failures are generic (anti-enumeration); registration is
rate-limited per IP and per email.

Workspace placement:
- **invite-code mode** — the registrant joins the workspace named on the code.
- **open, no invite** — the registrant gets a fresh `<handle>-<random>`
  workspace.

## Invite codes (`mix ezagent.invite`)

```bash
mix ezagent.invite mint --workspace team-alpha [--role member] [--max-uses 20] [--expires-in-days 14]
mix ezagent.invite list [--workspace team-alpha]
mix ezagent.invite revoke <code>
```

A code carries the **authoritative** target workspace, a quota (`max_uses`), and
an optional expiry. Consumption is race-safe (atomic conditional update) and runs
in the same transaction as user creation. Revoking a code stops future uses;
already-created accounts are unaffected.

## Password reset

`GET /auth/reset` (request) → emailed `:reset` one-time link → `GET/POST
/auth/reset/:token` (set a new password, min 8 chars) → sign in. The request
response is generic; only existing accounts receive an email.

## Email transport

The mailer is Swoosh with the adapter fixed at compile time:

- **dev / test** — `Swoosh.Adapters.Local` (in-memory; links appear in logs / the
  mailbox preview). No SMTP needed.
- **prod** — `Swoosh.Adapters.SMTP` with the relay supplied at runtime via the
  admin SMTP settings (`Ezagent.AppSettings` `"smtp_config"`).

### Cloudflare Email Sending (our managed deployment)

Cloudflare Email Sending offers SMTP submission, so it is just an `smtp_config`
— no separate adapter:

| field | value |
|-------|-------|
| host | `smtp.mx.cloudflare.net` |
| port | `465` (implicit TLS) |
| username | `api_token` (literal) |
| password | a Cloudflare API token with **Email Sending: Edit** |
| from_address | `…@ezagent.chat` |

Prerequisites (operator): the `ezagent.chat` domain must be onboarded for Email
Sending in the Cloudflare account, and the API token must hold *Email Sending:
Edit*. The token is a runtime secret — store it in `AppSettings`, never in the
repo. Self-hosters configure their own SMTP relay instead.

## Admin bootstrap

`entity://system/user/admin` is repaired idempotently at boot
(`EzagentDomainIdentity.Application.repair_admin_user/0`): it sets a password
when absent, sets the admin profile email, marks `email_verified`, and preserves
caps — so the admin can email+password login regardless of mail configuration.

| env var | default | purpose |
|---------|---------|---------|
| `EZAGENT_ADMIN_PASSWORD` | generated + logged once | admin password (set in prod) |
| `EZAGENT_ADMIN_EMAIL` | `admin@ezagent.chat` | admin login email |
