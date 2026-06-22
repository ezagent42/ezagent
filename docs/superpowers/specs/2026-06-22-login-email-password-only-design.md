# Login: Email + Password Only — Design

**Date:** 2026-06-22
**Status:** Draft v5 — codex-adversarial-reviewed twice (login design: 8 findings;
invite-code design: 10 findings — all folded). All Allen decisions folded in
(magic-link KEPT but SMTP-gated; self-build + OIDC seam; CF email via SMTP;
Decision 10 registration control + invite codes; random-suffix per-registrant
workspace for open-no-invite mode). Implemented on `login-with-email`: PR-1, PR-2,
PR-3 Task 3.1 (token purpose). PR-3 core (invite codes + registration) next.
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
   login method). Confirming sets a **new** `users.email_verified` flag — **not**
   the existing `confirmed` flag, which is the source of truth for anon-ness
   (overloading it would mark real registrants as anonymous).
1a. **Magic-link login is KEPT** (Allen 2026-06-22) as an optional passwordless
   login alongside email+password — *not* retired. It is made safe by the token
   `purpose` field (a `:login` magic-link token cannot be replayed at confirm/
   reset and vice-versa), so the endpoint can stay. **But it is hidden from the
   login page when SMTP is not configured** (`smtp_configured?/0` false) — there
   is no point offering a link the system cannot send. Email+password remains the
   primary method and always shows.
2. **Email transport = reuse the SMTP adapter pointed at Cloudflare.** CF Email
   Sending offers SMTP submission (`smtp.mx.cloudflare.net:465`, implicit TLS,
   username literal `api_token`, password = a CF API token with *Email Sending:
   Edit*). No new adapter, no new HTTP dependency. CF and generic-SMTP are both
   the **same compile-pinned `Swoosh.Adapters.SMTP`** differing only in the
   runtime `smtp_config` (host/creds) — CF is a *preset* of that config, not a
   different adapter. The transport stays admin-configurable (self-host brings
   its own SMTP); CF is the preset *our managed deployment* selects. Sender
   domain: **ezagent.chat** (Allen onboards it for Email Sending; reuses
   `ezagent_cf_token` with the added scope).
3. **Dev/test default = a compile-time logger/local adapter.** Because the
   Swoosh adapter is fixed per-mailer at compile time (not switchable at
   deliver-time), the dev/test default is set in `config/dev.exs` +
   `config/test.exs` as `adapter: Swoosh.Adapters.Local` (or a logger adapter).
   Confirmation/reset links then surface in logs / the local mailbox preview —
   zero external dependency, so local dev and the disposable E2E stack work
   without a real mail provider. (Prod stays SMTP/CF.)
4. **Bootstrap admin** is provisioned with email + password directly
   (`admin@ezagent.chat`, configurable) and `email_verified = true`, so first
   login **never** depends on email delivery. The bootstrap is an **idempotent
   repair**: if the admin row already exists, set a password when absent and
   upsert the admin profile email + `email_verified`, **preserving existing
   caps** — do not skip an already-present admin. Only self-registration needs a
   working transport.
5. **No existing-user migration.** There are no production users yet, so there
   is no email backfill, no `set_email` CLI, and no lockout concern.
6. **Password reset is in this round** — emailed one-time link → set a new
   password. Reuses the one-time-token machinery, but tokens gain a **`purpose`
   field** (`login`|`confirm`|`reset`) and each consumer enforces its own purpose,
   so a confirm/reset token can never be replayed at the magic-link *login*
   endpoint (which only accepts `:login`). Sent via the CF channel; domain
   ezagent.chat.
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
10. **Registration control + invite codes** (Allen 2026-06-22). Self-registration
    is **closed by default** behind a toggle. Two AppSettings:
    `registration_open` (boolean, default **false** — when false, NO self-signup;
    only admin provisioning) and, when open, `registration_require_invite`
    (boolean) deciding whether a valid **invite code** is required. Invite codes
    support a **quota** (`max_uses`) and an expiry, and — crucially — **carry the
    target workspace (and optional role)**, which cleanly replaces the fragile
    email-domain→workspace derivation (Codex #9): a registrant joins the
    workspace named on the code. See "Registration control & invite codes" below.

## Design

### 0. Registration control & invite codes

Two `AppSettings`: `registration_open` (boolean, default **false**) and
`registration_require_invite` (boolean). The three modes:

1. `registration_open == false` (default) → **closed**: the registration UI shows
   "registration is closed" and POST is refused. Only admin provisioning creates
   users. Safe default for early launch. **This gate is enforced at EVERY
   self-registration entry point**, not just one route (Codex #1): the new
   `/register` flow AND the legacy `/onboarding/workspace` + `/register/complete`
   magic-link onboarding chain. PR-3 RETIRES the legacy self-registration chain
   (moved earlier from PR-6) so no ungated path survives.
2. open + `registration_require_invite == true` → a valid invite **code** is
   required; POST validates and consumes one use.
3. open + `registration_require_invite == false` → open registration; workspace
   is the registrant's own freshly-created workspace named
   `<handle>-<random-suffix>` (Allen 2026-06-22 — 0/many domain matches are
   normal, don't hard-error; a random suffix guarantees a unique workspace),
   created via the existing self-serve workspace-creation path (the one the old
   onboarding used). The legacy `Registration.email_allowed?/1` /
   `Workspace.any_workspace_accepts?/1` allowlist still applies if configured
   (Codex #9 — the removed `registration_domains` AppSetting fallback is NOT
   revived; we use the current workspace-rule mechanism). Invite-required mode
   bypasses this allowlist (the code IS the authorization).

**`invite_codes` table** (Migration D, in `ezagent_core`; facade in
`ezagent_domain_identity` beside `Users`/`Profile`/`MagicLinkToken` — Codex #2):
`code` (unique, high-entropy random), `workspace_uri` (authoritative target —
removes domain→workspace guessing), `role` (string, nullable), `max_uses`
(integer ≥ 1, default 1, CHECK ≥ 1), `used_count` (default 0, CHECK ≥ 0 and
≤ `max_uses` — Codex #10), `expires_at` (nullable), `created_by` (admin URI),
`revoked_at` (nullable), timestamps. Unique index on `code`. A code is **valid**
when not revoked, not expired, and `used_count < max_uses`.

**Consume + create are ONE transaction** (Codex #2). Registration runs an
`Ecto.Multi` / `Repo.transaction`: (a) consume the code via a conditional
`UPDATE invite_codes SET used_count = used_count + 1 WHERE code = ? AND
revoked_at IS NULL AND used_count < max_uses` and assert exactly 1 row affected
(SQLite single-writer makes this the race gate); (b) create the user
(`email_verified: false`, password set); (c) upsert the profile; (d) join the
workspace. If any step fails the whole transaction rolls back, so a use is never
burned without a user and a user is never created without consuming a use.

**Workspace membership uses an AUTHORIZED path** (Codex #3, Decision #154
no-unowned-permissions). The new member's workspace membership + caps are granted
under the invite code's `created_by` (admin) authority — NOT the trusted
`Workspace.add_member/2` self-authority facade (which the code reserves for
in-VM CLI/loader callers). Registration goes through the cap-checked
`add_member/3` (or equivalent) with the issuer as the granting authority.

**`role`** is stored on the code and, for now, maps to the **standard member cap
set** (same as a normal registrant) — there is no elevated-role model in
`ezagent_domain_workspace` yet (Codex #4). The field is carried for forward
compatibility; a richer role→caps mapping is a future task, explicitly out of
scope here. (Documented so the field isn't mistaken for an active privilege.)

**Self-registration does NOT reuse `create_principal/4`** (Codex #5 — it makes a
passwordless, already-`email_verified:true` row). A new
`Registration.register_with_password/…` creates the user inside the transaction
with the password hash and `email_verified: false`.

**Abuse/enumeration** (Codex #6): all registration failures (closed, invalid /
revoked / expired / exhausted code, disallowed email/domain) return ONE generic
message; codes are high-entropy; registration POST is rate-limited per-IP and
per-code (extend `EzagentWeb.RateLimiter`, today login-only).

**Revoke** (Codex #7) stops only FUTURE consumes; already-created users (even
unconfirmed) are unaffected — revoking a code does not delete or block existing
accounts.

**Admin authority** (Codex #8): `mix ezagent.invite.*` (mint/list/revoke) runs
in-VM and is the trusted boundary for now; a web/UI invite-admin surface would
require an admin cap and workspace-scoped list/revoke — deferred to a follow-up,
not in this PR.

### 1. Auth model — email as the login key (resolution step)

The login boundary gains one step: resolve the typed **email → canonical entity
URI**, then verify the password against that URI.

```
login(email, password):
  uri = Profile.by_email(email)            # existing resolver, lower(email)
  if uri == nil:           -> Bcrypt.no_user_verify(); invalid (generic; constant-time)
  case Entity.authenticate(uri, password):   # NOT verify_password directly — see below
    {:ok, principal} ->
      user = Users.get_by_uri(uri)
      if user.email_verified: -> create session
      else:                   -> generic "check your email to finish sign-up"
                                 (shown only AFTER a correct password, so it
                                  does not leak account existence)
    :error -> invalid (generic error)
```

- **Go through `Entity.authenticate/2`, not `Users.verify_password/2`.** The
  existing credential path uses `Entity.authenticate/2`
  (`entity.ex:48`), which not only verifies the password but spawns the
  principal Kind and hydrates caps. Email login must reuse it (with a
  password-only restriction in the form context) so authentication behavior does
  not fork. (Codex finding #6.)
- **`email_verified` gate, NOT `confirmed`.** `users.confirmed` already means
  "non-anonymous" (`true` for real users via `Users.create/3`, `false` for
  anonymous read-only viewers via `create_read_only/2` — `users.ex:109,162`).
  Reusing it for "email verified" would conflate the two and break anon flows.
  So we add a **new** `email_verified` boolean and gate the form login on it.
  (Codex finding #1.)
- **Email uniqueness.** A partial unique index on `entity_profiles.email`
  already exists, but on the **raw** value, while `Profile.by_email/1` resolves
  on `lower(email)`. Replace it with a partial unique index on `lower(email)`
  (where email is not null), preceded by a duplicate-email **preflight** in the
  migration that fails early if any case-folded collisions exist. (No existing
  users → preflight is trivially empty, but the migration is written correctly.)
  (Codex finding #8.)
- Canonical identity is unchanged. We add a resolver call; we do **not** key
  users by email.

### 2. Self-registration flow

New registration form: **email, password, display name**.

```
register(email, password, display_name):
  reject if email domain not in registration_domains (existing AppSetting)
  reject if Profile.by_email(email) already exists  (unique-index backstop)
  workspace = workspace_for_email_domain(email)     # derived from email domain; see O1
  handle    = derive_handle(email, display_name)    # local-part, collision-suffixed
  uri = URI.user(workspace, handle)
  Users.create(uri, password_hash(password), default_caps)  # confirmed: true (real, non-anon)
  set email_verified = false on the new user
  Profile.upsert(uri, display_name, email, workspace)
  token = Token.mint(uri, purpose: :confirm)         # one-time, expiring, purpose-tagged
  Mailer.deliver_confirmation(email, confirm_url(token))
```

- The user is created **`confirmed: true`** (a real, non-anonymous human) but
  **`email_verified: false`**. The two flags are independent (Codex finding #1).
- Clicking the confirmation link (`GET /auth/confirm/:token`) verifies the token
  `purpose == :confirm`, sets `email_verified = true`, and routes to login (it
  does **not** itself mint a session — keeps confirm/login distinct).
- Unverified accounts cannot log in and can request a re-send (rate-limited via
  the existing anti-enumeration machinery in `session_controller.ex`).
- **Workspace = derived from email domain** (Allen). `alice@acme.com` → the
  `acme` workspace. **Workspace provisioning constraint (Codex finding #4):**
  `create_principal/4` assumes the workspace already exists and cannot mint one
  with the right CapBAC authority. So the derived workspace **must pre-exist**:
  the admin provisions a workspace when adding its domain to the
  `registration_domains` allowlist (domain-allow and workspace-provision are
  tied). A registrant from an allowed domain joins that existing workspace; no
  new-workspace creation happens in the registration path.
- **Change workspace later** (Allen: "用户进入后可以再改") — after entering, a
  user can move/join a different workspace. That is a membership change handled
  by existing workspace/membership affordances; this spec only fixes the
  *initial* placement. See O1.

### 3. Password reset flow

```
request_reset(email):  -> if Profile.by_email(email): mint Token(purpose: :reset); send link
                          (always show the same "if the account exists…" message)
GET  /auth/reset/:token -> if token valid AND purpose==:reset: render set-new-password form
POST /auth/reset/:token -> set new password_hash; consume token; redirect to login
```

Reuses the one-time-token machinery and the CF send channel. Tokens are
single-use, expiring, and **purpose-tagged** (`:reset`); the consumer rejects a
token whose purpose is not `:reset`. No session is created by the reset link
itself; the user logs in with the new password. (Codex finding #3.)

### 4. Email transport

**There is no "provider" abstraction — Cloudflare *is* SMTP.** (Allen, and Codex
finding #2.) Swoosh fixes the adapter for a mailer at **compile time**
(`config :ezagent_web, EzagentWeb.Mailer, adapter: …`, `api_client: false`); only
the SMTP relay *options* are supplied at deliver-time from `AppSettings`. So we
keep the **single existing `smtp_config`** and do not add any provider enum:

- **Prod — the existing `smtp_config`, filled with CF's values** (our managed
  deployment): host `smtp.mx.cloudflare.net`, port `465`, implicit TLS, username
  `api_token`, password = the CF API token (with *Email Sending: Edit*),
  `from_address` `…@ezagent.chat`. Self-host fills the same fields with their own
  relay. The admin settings UI may offer a one-click "fill Cloudflare defaults"
  helper, but it is the same config — **no second adapter, no new dependency, no
  provider switch.**
- **Dev/test — compile-time Local adapter.** `config/dev.exs` and
  `config/test.exs` set `adapter: Swoosh.Adapters.Local` (or a logger adapter).
  Confirmation/reset links surface in logs / the local mailbox preview without
  any configured relay. This removes today's "silently drop when SMTP
  unconfigured" dead-end for the registration path.

`Mailer` gains `deliver_confirmation/2` and `deliver_password_reset/2` alongside
the existing `deliver_magic_link/2` (the latter is retired with magic-link
login). The `smtp_configured?/0` gate stays as the prod readiness check; in
dev/test the Local adapter is always "ready".

**Bootstrap admin** (Codex finding #5 — must be an idempotent **repair**, not a
skip): `ensure_admin_user/0` is extended so that, whether or not the admin row
already exists, it (a) sets a password hash if none is present (from app env, or
generated and logged once — see O2), (b) upserts the admin `entity_profiles`
email (default `admin@ezagent.chat`, app-env configurable), (c) sets
`email_verified = true`, and (d) **preserves existing caps**. The admin can then
log in by email+password immediately and independently of mail delivery.

### 5. World / UI changes

- **Login page** (`session_controller.ex` + its HEEx template): primary form is
  email + password. Remove the `entity_uri`/`secret`(token) fields (the old
  handle/URI path). **Keep the magic-link option, but render it only when
  `smtp_configured?/0` is true** (Allen) — hidden otherwise. Add links: "Create
  account" (registration) and "Forgot password". Keep styling minimal and
  consistent; do not entangle with #83.
- **World identity display** (`world_live.ex` + island): pass `display_name`
  (and/or email) from the profile to the React island and render that instead of
  the raw `entity://...` URI. The canonical URI is still used internally for
  caller identity; only the *display* changes.

### 6. Routes (after)

```
GET  /login                 -> email+password form (+ magic-link option iff smtp_configured?)
POST /login                 -> resolve email→uri, Entity.authenticate, email_verified gate, session
POST /login/magic           -> send a magic-link (Token purpose=:login)  [KEPT]
GET  /auth/magic/:token      -> consume magic-link, purpose==:login → session  [KEPT, purpose-gated]
GET  /register              -> registration form
POST /register              -> create user (confirmed:true, email_verified:false) + send confirm
GET  /auth/confirm/:token   -> verify token(purpose=:confirm), set email_verified=true
GET  /auth/reset            -> request-password-reset form
POST /auth/reset            -> send reset link (Token purpose=:reset)
GET  /auth/reset/:token     -> set-new-password form (token purpose=:reset)
POST /auth/reset/:token     -> set new password
DELETE|POST /logout         -> unchanged
```

**Routes to retire (Codex finding #7 — this cleanup is larger than one form).**
The router currently also exposes `GET|POST /login/credentials` (handle/URI +
secret — **removed**, replaced by email+password `POST /login`), `GET|POST
/onboarding/workspace`, and `GET|POST /register/complete` (magic-link onboarding
chain — **removed/folded** into `/register` + `/auth/confirm`). The magic-link
*login* endpoint `GET /auth/magic/:token` is **kept** (Allen) but hardened with
the `purpose == :login` check so confirm/reset tokens cannot be replayed there.
PR-6 enumerates each retired route, its controller action, and any template/link
that
references it (e.g. login-page links, onboarding redirects). The API/CLI bearer
path (`api_v1_controller.ex` `Authorization: Bearer` + `X-Ezagent-Entity-URI`)
is **unchanged**.

## Data model changes

- **Migration A — `email_verified`**: add a `email_verified` boolean column to
  `users` (default `false`). Distinct from `confirmed` (anon-ness). (Codex #1.)
- **Migration B — email uniqueness**: drop the existing **raw** partial unique
  index on `entity_profiles.email` and add a partial unique index on
  `lower(email)` (where email is not null), to match `Profile.by_email/1`'s
  `lower(email)` lookup. Run a duplicate-email **preflight** first that aborts
  with a report if any case-folded collisions exist. (Codex #8.)
- **Migration C — token purpose**: add a `purpose` column to the one-time-token
  table (`login`|`confirm`|`reset`); existing rows default to `:login`
  (magic-link login is kept, so the `:login` purpose stays live and is enforced
  at `/auth/magic/:token`). (Codex #3.)
- **Migration D — `invite_codes`** (Decision 10): new table — `code` (unique),
  `workspace_uri`, `role` (nullable), `max_uses` (default 1), `used_count`
  (default 0), `expires_at` (nullable), `created_by`, `revoked_at` (nullable),
  timestamps. Unique index on `code`. **CHECK constraints** (Codex #10):
  `max_uses >= 1`, `used_count >= 0`, `used_count <= max_uses` — plus changeset
  validations; the conditional UPDATE remains the concurrency gate.
- No data backfill (no existing users).

## Out of scope

- **Inbound email** (receiving at ezagent.chat) — task #88, via #82.
- **Big world beautification** — #83 (this spec only does the minimal login-page
  + identity-display change).
- **Third-party self-host email** — self-host configures generic SMTP via the
  existing admin settings; the CF preset is for our managed deployment.

## Security considerations

- **Account enumeration**: registration, reset-request, and re-send all return
  generic messages and reuse the existing rate-limiting / anti-enumeration
  machinery (`session_controller.ex:326`+). Constant-time password verification
  (`Bcrypt.no_user_verify/0`) is preserved on the email-not-found branch. The
  "finish sign-up / verify your email" message is shown **only after a correct
  password** (Codex #7), so an attacker without the password cannot use it to
  probe which emails are registered.
- **Unique `lower(email)` index** prevents two accounts sharing an email
  (case-insensitively), which would make the login key ambiguous.
- **`email_verified` gate** prevents login before email ownership is proven;
  it is independent of the `confirmed` anon-ness flag.
- **Tokens** (login + confirm + reset) are single-use, expiring, and
  **purpose-tagged**; each consumer enforces its own purpose, so a confirm/reset
  token cannot be replayed at the magic-link login endpoint (which accepts only
  `:login`). Magic-link login is hidden when SMTP is unconfigured.
- **Secrets** (CF API token) live only in runtime AppSettings, never in the
  repo.
- **Backend token auth untouched** — agents/CLI keep working; only the human
  form drops the affordance.

## Future extensibility — OIDC / third-party auth seam

We are **self-building** auth (not adopting Logto/an external IdP now), because a
third-party IdP only covers *authentication* while ezagent's complexity is in its
URI + CapBAC *authorization* model, and it would add a stateful infra dependency
against the lean / self-hostable direction. The *only* compelling future reason
to adopt one is **social login / SSO / MFA**, which is not a current requirement.

To keep that door open at low cost, credential verification is isolated behind a
single seam: **email → canonical URI → `Entity.authenticate/2`**. A future OIDC
provider (Logto, Auth0, Google, …) plugs in by resolving its identity to a
canonical entity URI at that same boundary; the CapBAC/workspace/Kind model and
everything downstream stay unchanged. No design choice here forecloses that swap.

## Testing & gates

- **Unit/integration**: email→uri resolution via `Entity.authenticate/2`
  (spawn + cap hydration exercised); `lower(email)` unique-index rejection of
  case-folded duplicate email; `email_verified` gate blocks unverified login
  while leaving `confirmed`/anon flows untouched; token `purpose` enforced
  (a `:reset` token rejected at confirm and vice-versa; no login replay); full
  register→confirm→login and request-reset→reset→login cycles; the CF
  `smtp_config` preset produces the right Swoosh SMTP options and dev/test uses
  the Local adapter; bootstrap-admin idempotent repair sets password/email/
  verified + preserves caps and can log in with no mail configured.
- **E2E (disposable stack, agent-browser)**: register a new user (link captured
  from the logger adapter) → confirm → log in with email+password → land in
  world showing display name; admin email+password login; forgot-password cycle.
  Per standing E2E bar: agent-browser screenshots of the working login + world
  identity.
- **Full gate suite per PR**: `arch.scan` (all slices), `doc.scan`,
  `uri_query.scan`, `check_invariants`, `format`, `test`,
  `:ezagent_plugin_check`. New routes/modules wired into the relevant baselines.

## PR breakdown (per-task-branch; Allen merges to main)

All PRs target branch `login-with-email`; the lead (Allen) merges the
branch to `main`. Each PR: implement → subagent adversarial review → full gate
suite → (admin-)merge into the task branch.

- **PR-1 — email-as-login backend.** Migration A (`email_verified` on `users`)
  + Migration B (`lower(email)` unique index + duplicate preflight); email→uri
  resolution routed through `Entity.authenticate/2` + `email_verified` gate in
  the login path; backend tests. Behavior-preserving for existing auth dispatch
  and untouched for `confirmed`/anon flows.
- **PR-2 — mail transport.** Fill the existing `smtp_config` with CF's values
  (no provider enum — CF *is* SMTP) + an optional "fill Cloudflare defaults"
  helper; dev/test compile-time Local adapter; `deliver_confirmation` +
  `deliver_password_reset`; keep `smtp_configured?/0` as the prod readiness check.
- **PR-3 — self-registration + registration control.** Migration C (token
  `purpose`) + Migration D (`invite_codes`); registration gates
  (`registration_open` default false; `registration_require_invite`); invite-code
  validate+consume (atomic `used_count < max_uses`); `mix ezagent.invite.*`
  CLI; registration form + flow (email/password/display name → user
  `confirmed:true, email_verified:false` in the **invite-code's workspace** when
  a code is used, else the email-domain-derived/default workspace → confirm email
  → `/auth/confirm` sets `email_verified`). Honors `registration_domains` in the
  open-no-invite mode.
- **PR-4 — password reset.** Request + reset endpoints and forms; purpose-tagged
  one-time tokens; tests.
- **PR-5 — login page + world identity.** Login UI = email+password primary +
  magic-link option shown only when `smtp_configured?/0` + "Create account"/
  "Forgot password" links; world identity display shows display_name/email.
- **PR-6 — route retirement + bootstrap admin + docs.** Remove
  `/login/credentials`, `/onboarding/workspace`, `/register/complete` and every
  template/link that references them (enumerated); **keep** `/auth/magic/:token`
  but enforce `purpose==:login`; idempotent admin repair
  (password/email/`email_verified`, preserve caps); update docs/guides; final
  E2E.

## Resolved (formerly open) questions

- **O1 — self-registrant workspace + handle (RESOLVED, Allen 2026-06-22).**
  Workspace is **derived from the email domain** (`alice@acme.com` → `acme`);
  `handle` is derived from the email local-part (collision-suffixed). The derived
  workspace must pre-exist — admin provisions it when allowing the domain in
  `registration_domains` (Codex #4 constraint respected; no in-path workspace
  creation). Users can move to a different workspace after entering, via existing
  membership affordances (initial placement only is in this spec's scope).
- **O2 — admin password source (RESOLVED, Allen 2026-06-22).** Bootstrap admin
  password comes from an **app-env variable** (operator-set). If the env var is
  unset on first boot, generate a random password and log it once (dev
  convenience); prod sets the env var.
