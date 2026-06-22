# Login: Email + Password Only — Design

**Date:** 2026-06-22
**Status:** Draft (awaiting Allen review)
**Owner:** Claude (brainstorm with Allen)
**Task:** #87 (login). Related: #88 (inbound email — separate), #82 (external-adapter), #83 (world beautification — separate), #65 (CF Workers).

## Goal

Make the human login experience **email + password only**. Today a user must
type a bare handle or a full entity URI (`entity://<workspace>/user/<name>`),
which is poor UX. Replace that with a single email + password form, and update
the world UI accordingly.

This is achieved by adding a **resolution step** at the login boundary
(email → canonical entity URI), **not** by changing the canonical identifier.
The entity URI remains the sole canonical principal key; email and display name
stay mutable, display/login-affordance values. (Standing rule: *UUID/URI is the
canonical identifier*.)

## Background — current state (verified in code)

- **Login UI**: `apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex`.
  Two forms on one page: (a) credentials — `entity_uri` (bare handle *or* full
  URI) + `secret` (password *or* bearer token), POST `/login/credentials`;
  (b) email **magic-link**, POST `/login`. Both fully functional and tested.
- **Auth backend**: `Ezagent.Entity.authenticate/2` (`apps/ezagent_domain_identity/lib/ezagent/entity.ex:48`)
  dispatches by URI type → `Ezagent.Users.verify_password/2`
  (`users.ex:231`, bcrypt) for users; `Entity.Token.verify/2` for tokens/agents.
  Lookup is by **URI** (`Repo.get_by(uri: ...)`); there is **no** username table.
- **Email resolver exists** but only for magic-link:
  `Ezagent.Entity.Profile.by_email/1` (`profile.ex:52`, case-insensitive) →
  `Ezagent.Registration.principal_for_email/1` (`registration.ex:90`).
- **User schema** (`users.ex:23`): `uri` (canonical, unique), `password_hash`
  (nullable), `caps_json`, `workspace_uri`, **`confirmed`** (boolean, added
  2026-06-19 — source of truth for anon-ness). **No** `username`/`email`
  columns. Email lives on `entity_profiles` (`profile.ex:21`), **nullable, not
  unique**.
- **Registration today** (`registration.ex:98`): magic-link is the *only*
  new-user onboarding path (email → link → pick workspace → pick handle).
  `create_principal/4` creates a user with **no password** + a profile with
  email; password is set later (`mix ezagent.user.set_password`).
- **Email transport** (`config/config.exs:111`): Swoosh,
  `adapter: Swoosh.Adapters.SMTP`, `api_client: false` (SMTP-only, no HTTP dep
  by design). Credentials supplied at deliver-time from
  `Ezagent.AppSettings` `"smtp_config"` (host/port/username/password/from_address/tls),
  written by an admin SMTP-settings UI. `AppSettings.smtp_configured?/0` gates
  sending; `registration_domains` AppSetting allowlists registration domains.
  Mailer: `EzagentWeb.Mailer.deliver_magic_link/2`.
- **Bootstrap admin** (`apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex:244`
  `ensure_admin_user/0`): provisions `entity://system/user/admin`, password
  `nil`, **no email**.
- **World** (`apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex`):
  **no** auth surface of its own. Reads `current_entity_uri` from the session
  and passes the raw entity URI to the React island for identity display.

## Decisions (locked with Allen 2026-06-22)

1. **Registration = email + password self-registration** with a one-time email
   confirmation link (the link only *verifies email ownership*; it is not a
   login method). Confirming sets `users.confirmed = true`. Magic-link is
   demoted from a login method to email-verification + password-reset only.
2. **Email transport = reuse the SMTP adapter pointed at Cloudflare.** CF Email
   Sending offers SMTP submission (`smtp.mx.cloudflare.net:465`, implicit TLS,
   username literal `api_token`, password = a CF API token with *Email Sending:
   Edit*). No new adapter, no new HTTP dependency. The transport stays
   admin-configurable (self-host brings its own SMTP); CF is the provider *our
   managed deployment* selects. Sender domain: **ezagent.chat** (Allen
   onboards it for Email Sending; reuses `ezagent_cf_token` with the added
   scope).
3. **Dev/test default = a local/logger mailer** so confirmation/reset links
   appear in logs — zero external dependency, so local dev and the disposable
   E2E stack work without a real mail provider.
4. **Bootstrap admin** is provisioned with email + password directly
   (`admin@ezagent.chat`, configurable) and `confirmed = true`, so first login
   **never** depends on email delivery. Only self-registration needs a working
   transport.
5. **No existing-user migration.** There are no production users yet, so there
   is no email backfill, no `set_email` CLI, and no lockout concern.
6. **Password reset is in this round** — emailed one-time link → set a new
   password (reuses the existing one-time-token machinery, sent via the CF
   channel; domain ezagent.chat).
7. **World changes (keep simple)**: (a) restyle the server-rendered login page
   to a single email + password form (drop handle/URI + magic-link-as-login
   fields; add a "forgot password" link); (b) world authenticated identity
   display shows `display_name`/email instead of the raw entity URI. This stays
   minimal and will reconcile with the larger beautification (#83) when that
   lands.
8. **Token in the form**: the human login form is email + password only (no
   token field surfaced). The backend `Entity.authenticate/2` token-acceptance
   is **left intact** (it is shared with the API/CLI bearer path); we are not
   ripping out working business logic, only removing the affordance from the UI.
9. **Inbound email is out of scope** for login (login is outbound-only). It is
   tracked as task #88 and folds into the external-adapter (#82): CF has no
   mailbox, so inbound = CF Email Routing → Email Worker → webhook → ingest as a
   session message (symmetric to Feishu). The session message store is the
   "inbox"; no standalone inbox is built.

## Design

### 1. Auth model — email as the login key (resolution step)

The login boundary gains one step: resolve the typed **email → canonical entity
URI**, then verify the password against that URI.

```
login(email, password):
  uri = Profile.by_email(email)            # existing resolver, case-insensitive
  if uri == nil:           -> invalid (generic error; constant-time)
  user = Users.get_by_uri(uri)
  if not user.confirmed:   -> "please confirm your email" (no session)
  if Users.verify_password(uri, password): -> create session
  else:                    -> invalid (generic error)
```

- **Email uniqueness is required** for email to be a login key. Add a
  case-insensitive **unique index** on `entity_profiles.email` (partial: where
  email is not null). This makes `Profile.by_email/1` deterministic and is the
  DB-level guard against duplicate-email accounts.
- **`confirmed` gate**: only `confirmed = true` users can authenticate via the
  form. Reuses the boolean already on `users`. (Bootstrap admin is created
  `confirmed = true`.)
- Canonical identity is unchanged. We add a resolver call; we do **not** key
  users by email.

### 2. Self-registration flow

New registration form: **email, password, display name**.

```
register(email, password, display_name):
  reject if email domain not in registration_domains (existing AppSetting)
  reject if Profile.by_email(email) already exists  (unique-index backstop)
  workspace, handle = derive(email, display_name)   # see Open Question O1
  uri = URI.user(workspace, handle)
  Users.create(uri, password_hash(password), default_caps, confirmed: false)
  Profile.upsert(uri, display_name, email, workspace)
  token = ConfirmToken.mint(uri)                     # one-time, expiring
  Mailer.deliver_confirmation(email, confirm_url(token))
```

- Clicking the confirmation link (`GET /auth/confirm/:token`) marks
  `confirmed = true` and logs the user in once (or routes to the login page).
- Unconfirmed accounts cannot log in and can request a re-send (rate-limited via
  the existing anti-enumeration machinery in `session_controller.ex`).
- The confirmation token reuses the `MagicLinkToken` machinery
  (one-time, expiring), repurposed to "verify email / set confirmed", not
  "log in".

### 3. Password reset flow

```
request_reset(email):  -> if Profile.by_email(email): mint reset token; send link
                          (always show the same "if the account exists…" message)
GET  /auth/reset/:token -> render set-new-password form (token valid)
POST /auth/reset/:token -> set new password_hash; consume token; redirect to login
```

Reuses the one-time-token machinery and the CF send channel. Tokens are
single-use and expiring. No session is created by the reset link itself; the
user logs in with the new password.

### 4. Email transport — provider abstraction

Generalize the runtime mailer config from "SMTP only" to a **provider choice**
held in `AppSettings`, resolved at deliver-time:

- `provider = "smtp"` — existing behavior; admin supplies host/port/user/pass/from.
- `provider = "cloudflare"` — a **preset** that fixes host=`smtp.mx.cloudflare.net`,
  port=`465`, implicit TLS, username=`api_token`; admin supplies only the **API
  token** (password) and the **from address** (`...@ezagent.chat`). Still goes
  through `Swoosh.Adapters.SMTP` — no new adapter, no new dependency.
- Dev/test default — `Swoosh.Adapters.Local` (or a logger adapter) selected in
  `config/dev.exs` + `config/test.exs`, so confirmation/reset links are
  surfaced (logs / local mailbox preview) without any configured provider. This
  replaces today's "silently drop when unconfigured" dead-end for the
  registration path.

`Mailer` gains `deliver_confirmation/2` and `deliver_password_reset/2` alongside
the existing `deliver_magic_link/2` (the latter may be retired once magic-link
login is removed, or kept as the verification primitive). The
`smtp_configured?/0` gate generalizes to `mail_configured?/0` (true when the
selected provider has its required fields).

**Bootstrap admin**: `ensure_admin_user/0` is extended to set an admin email
(default `admin@ezagent.chat`, configurable via app env) on the admin profile,
a password (from app env / generated + logged once), and `confirmed = true`, so
the admin can log in by email+password immediately and independently of mail.

### 5. World / UI changes

- **Login page** (`session_controller.ex` + its HEEx template): collapse to a
  single email + password form. Remove the `entity_uri`/`secret`(token) fields
  and the magic-link login form. Add links: "Create account" (registration) and
  "Forgot password". Keep styling minimal and consistent; do not entangle with
  #83.
- **World identity display** (`world_live.ex` + island): pass `display_name`
  (and/or email) from the profile to the React island and render that instead of
  the raw `entity://...` URI. The canonical URI is still used internally for
  caller identity; only the *display* changes.

### 6. Routes (after)

```
GET  /login                 -> email+password form
POST /login                 -> resolve email→uri, verify password, create session
GET  /register              -> registration form
POST /register              -> create unconfirmed user + send confirmation
GET  /auth/confirm/:token   -> verify email, set confirmed=true
GET  /auth/reset            -> request-password-reset form
POST /auth/reset            -> send reset link
GET  /auth/reset/:token     -> set-new-password form
POST /auth/reset/:token     -> set new password
DELETE|POST /logout         -> unchanged
```

Removed/repurposed: `GET|POST /login/credentials` (handle/URI+secret) removed;
the onboarding/`/register/complete` magic-link chain removed or folded into the
new registration flow. The API/CLI bearer path (`api_v1_controller.ex`
`Authorization: Bearer` + `X-Ezagent-Entity-URI`) is **unchanged**.

## Data model changes

- **Migration**: add a case-insensitive partial **unique index** on
  `entity_profiles.email` (where email is not null). No column additions
  (`confirmed` already exists; email already exists).
- No data backfill (no existing users).

## Out of scope

- **Inbound email** (receiving at ezagent.chat) — task #88, via #82.
- **Big world beautification** — #83 (this spec only does the minimal login-page
  + identity-display change).
- **Third-party self-host email** — self-host configures generic SMTP via the
  existing admin settings; the CF preset is for our managed deployment.

## Security considerations

- **Account enumeration**: registration, login, reset, and re-send all return
  generic messages and reuse the existing rate-limiting / anti-enumeration
  machinery (`session_controller.ex:326`+). Constant-time password verification
  (`Bcrypt.no_user_verify/0`) is preserved on the email-not-found branch.
- **Unique email index** prevents two accounts sharing an email (which would
  make the login key ambiguous).
- **Confirmed gate** prevents login before email ownership is proven.
- **Tokens** (confirm + reset) are single-use, expiring, and never log the user
  in with elevated state beyond the intended action.
- **Secrets** (CF API token) live only in runtime AppSettings, never in the
  repo.
- **Backend token auth untouched** — agents/CLI keep working; only the human
  form drops the affordance.

## Testing & gates

- **Unit/integration**: email→uri resolution; unique-index rejection of
  duplicate email; confirmed-gate blocks unconfirmed login; full
  register→confirm→login and request-reset→reset→login cycles; provider
  selection (smtp/cloudflare/logger) chooses the right Swoosh config;
  bootstrap-admin can log in by email+password with no mail configured.
- **E2E (disposable stack, agent-browser)**: register a new user (link captured
  from the logger adapter) → confirm → log in with email+password → land in
  world showing display name; admin email+password login; forgot-password cycle.
  Per standing E2E bar: agent-browser screenshots of the working login + world
  identity.
- **Full gate suite per PR**: `arch.scan` (all slices), `doc.scan`,
  `uri_query.scan`, `check_invariants`, `format`, `test`,
  `:ezagent_plugin_check`. New routes/modules wired into the relevant baselines.

## PR breakdown (per-task-branch; Allen merges to main)

All PRs target branch `feat/login-email-password`; the lead (Allen) merges the
branch to `main`. Each PR: implement → subagent adversarial review → full gate
suite → (admin-)merge into the task branch.

- **PR-1 — email-as-login backend.** Unique-index migration on
  `entity_profiles.email`; email→uri resolution + `confirmed` gate in the login
  path; backend tests. Behavior-preserving for existing auth dispatch.
- **PR-2 — mail transport provider.** Provider abstraction in AppSettings
  (smtp/cloudflare/logger); CF preset; dev/test logger default;
  `deliver_confirmation` + `deliver_password_reset`; generalize the
  `*_configured?` gate.
- **PR-3 — self-registration.** Registration form + flow (email/password/
  display name → unconfirmed user → confirmation email → confirm endpoint sets
  confirmed). Honors `registration_domains`.
- **PR-4 — password reset.** Request + reset endpoints and forms; one-time
  tokens; tests.
- **PR-5 — login page + world identity.** Collapse login UI to email+password
  (+ links); world identity display shows display_name/email.
- **PR-6 — bootstrap admin + cleanup + docs.** Admin email+password+confirmed;
  remove magic-link-as-login routes; update docs/guides; final E2E.

## Open questions for review

- **O1 — self-registrant workspace + handle derivation.** A user URI needs a
  workspace and a name. Proposed default (simplest, no interactive picker):
  derive `handle` from the email local-part (collision-suffixed) and place the
  user in their **own personal workspace** named from the handle, mirroring the
  existing per-user pattern (`<username>-default` agent). Alternative: keep a
  post-confirmation onboarding step where the user picks a workspace/handle.
  **Recommend the auto-derive default; flagging for your call.**
- **O2 — admin password source.** Bootstrap admin password from an app-env var
  (operator-set) vs generated-and-logged-once on first boot. **Recommend
  app-env with a generated fallback logged once.**
