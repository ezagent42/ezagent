# Email+Password-Only Login — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the human login email+password only (URI/handle login removed), with email→canonical-URI resolution, self-registration + email confirmation, password reset, CF-via-SMTP mail, and minimal world identity changes.

**Architecture:** Add a resolution step at the login boundary (`email → Profile.by_email → entity_uri → Entity.authenticate/2`); canonical identity stays the entity URI. A new `users.email_verified` flag (independent of the `confirmed` anon-ness flag) gates form login. One-time tokens gain a `purpose` field so magic-link/confirm/reset can't be replayed across endpoints. Mail stays the compile-pinned `Swoosh.Adapters.SMTP` with runtime `smtp_config` (filled with Cloudflare's values in prod); dev/test use a compile-time Local adapter.

**Tech Stack:** Elixir/Phoenix umbrella, Ecto + SQLite (`EzagentCore.Repo`), Swoosh (`EzagentWeb.Mailer`), Bcrypt, controller-rendered login (heredoc + placeholder substitution, not HEEx).

**Spec:** `docs/superpowers/specs/2026-06-22-login-email-password-only-design.md` (read it first).

## Global Constraints

- Branch: all PRs target `feat/login-email-password`; Allen merges to `main`. (Per-task-branch model.)
- Canonical identifier is the entity URI; never key by email. Construct user URIs via `Ezagent.URI.user(workspace, name)` — never by string concatenation (URI segment order is opaque).
- Login authentication MUST go through `Ezagent.Entity.authenticate/2` (it does `ensure_spawned` + cap hydration) — never call `Users.verify_password/2` directly from the controller.
- `users.confirmed` = anon-ness (do NOT overload). Email-verification = new `users.email_verified`.
- Anti-enumeration: registration / reset-request / re-send return identical responses; constant-time `Bcrypt.no_user_verify/0` on the not-found branch; the "verify your email" message is shown ONLY after a correct password.
- Secrets (CF API token) live only in runtime `Ezagent.AppSettings`, never in the repo.
- Backend token auth (`Entity.authenticate/2` accepting bearer tokens; the API/CLI `Authorization: Bearer` path) is UNCHANGED — only the human FORM drops the token affordance.
- Each PR: implement → subagent adversarial review → full gate suite (`arch.scan` all_slices, `doc.scan`, `uri_query.scan`, `check_invariants`, `format`, `test`, `:ezagent_plugin_check`) → admin-merge into the task branch.
- TDD: failing test → confirm fail → minimal impl → confirm pass → commit. Run `mix test` from the umbrella root; per-app tests via `mix cmd --app <app> mix test <path>`.

## File Structure

| File | Responsibility | PR |
|------|----------------|-----|
| `apps/ezagent_core/priv/repo/migrations/2026062201*_add_email_verified_to_users.exs` | `users.email_verified` column | 1 |
| `apps/ezagent_core/priv/repo/migrations/2026062202*_email_lower_unique_index.exs` | `lower(email)` unique index + dup preflight | 1 |
| `apps/ezagent_core/priv/repo/migrations/2026062203*_add_purpose_to_magic_link_tokens.exs` | token `purpose` column | 3 |
| `apps/ezagent_domain_identity/lib/ezagent/users.ex` | `email_verified` in schema/decode/create + `mark_email_verified/1` | 1 |
| `apps/ezagent_domain_identity/lib/ezagent/entity/profile.ex` | unique-constraint name follows new index | 1 |
| `apps/ezagent_domain_identity/lib/ezagent/entity/magic_link_token.ex` | `purpose` on mint/consume/peek | 3 |
| `apps/ezagent_web/lib/ezagent_web/mailer.ex` | `deliver_confirmation/2`, `deliver_password_reset/2` | 2 |
| `apps/ezagent_web/config` (`config/dev.exs`,`config/test.exs`) | Local mailer adapter | 2 |
| `apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex` | email+password login + email_verified gate | 1,5 |
| `apps/ezagent_web/lib/ezagent_web/controllers/registration_controller.ex` | self-registration (email/password/display) + confirm | 3 |
| `apps/ezagent_web/lib/ezagent_web/controllers/password_reset_controller.ex` (new) | request + set-new-password | 4 |
| `apps/ezagent_web/lib/ezagent_web/router.ex` | route add/retire | 3,4,6 |
| `apps/ezagent_domain_identity/lib/ezagent/registration.ex` | `register_with_password/4`, domain→workspace | 3 |
| `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex` | idempotent admin repair | 6 |
| `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex` | identity display = display_name/email | 5 |

---

## PR-1 — email-as-login backend + `email_verified`

**Goal:** Backend can authenticate by email and gate on `email_verified`; canonical auth path unchanged for existing flows.

### Task 1.1: `email_verified` column migration

**Files:** Create `apps/ezagent_core/priv/repo/migrations/20260622010000_add_email_verified_to_users.exs`

- [ ] **Step 1: Write the migration** (pattern copied from `20260619010000_add_confirmed_to_users.exs`)

```elixir
defmodule EzagentCore.Repo.Migrations.AddEmailVerifiedToUsers do
  @moduledoc """
  Login email+password (task #87) — `email_verified` is the source of truth for
  "this user has proven email ownership", independent of `confirmed` (anon-ness).
  Form login is gated on `email_verified == true`.
  """
  use Ecto.Migration

  def up do
    alter table(:users) do
      add(:email_verified, :boolean, null: false, default: false)
    end

    # No existing production users (Allen 2026-06-22). Backfill defensively:
    # any pre-existing real (confirmed) user is treated as already-verified so
    # this migration is behavior-preserving for any dev/test rows.
    execute("UPDATE users SET email_verified = TRUE WHERE confirmed = TRUE")
  end

  def down do
    alter table(:users) do
      remove(:email_verified)
    end
  end
end
```

- [ ] **Step 2: Run the migration** — `cd apps/ezagent_core && mix ecto.migrate` (or umbrella `mix ecto.migrate`). Expected: applies cleanly; `.../ecto migrations` shows it up.
- [ ] **Step 3: Commit** — `git commit -m "feat(login): add users.email_verified column"`

### Task 1.2: `email_verified` in the Users schema + write helper

**Files:** Modify `apps/ezagent_domain_identity/lib/ezagent/users.ex`; Test `apps/ezagent_domain_identity/test/ezagent/users_test.exs`

**Interfaces — Produces:**
- `Users.create(uri, password, caps, opts \\ [])` — `opts[:email_verified]` (default `true`; operator/programmatic creation is trusted). Self-registration passes `email_verified: false`.
- `Users.mark_email_verified(uri) :: {:ok, decoded} | {:error, :not_found}`
- `decoded` map gains `:email_verified` (boolean).

- [ ] **Step 1: Write failing tests**

```elixir
test "create/4 defaults email_verified to true; create/4 with opt false overrides" do
  {:ok, u1} = Ezagent.Users.create(Ezagent.URI.user("system", "ev_a"), "pw", [])
  assert u1.email_verified == true
  {:ok, u2} = Ezagent.Users.create(Ezagent.URI.user("system", "ev_b"), "pw", [], email_verified: false)
  assert u2.email_verified == false
end

test "mark_email_verified/1 flips an unverified user" do
  uri = Ezagent.URI.user("system", "ev_c")
  {:ok, _} = Ezagent.Users.create(uri, "pw", [], email_verified: false)
  assert {:ok, u} = Ezagent.Users.mark_email_verified(uri)
  assert u.email_verified == true
  assert Ezagent.Users.get_by_uri(uri).email_verified == true
end
```

- [ ] **Step 2: Run, verify fail** — `mix cmd --app ezagent_domain_identity mix test test/ezagent/users_test.exs` → FAIL (unknown opt / undefined `mark_email_verified`).
- [ ] **Step 3: Implement** in `users.ex`:
  - Add `field(:email_verified, :boolean, default: false)` to the schema (after `:confirmed`).
  - Add `email_verified: boolean()` to the `@type decoded`.
  - Change `def create(uri, password, caps)` → `def create(uri, password, caps, opts \\ [])`; thread `opts` into `do_create/4`, adding `email_verified: Keyword.get(opts, :email_verified, true)` to the changeset map.
  - In `decode/1` add `email_verified: row.email_verified == true`.
  - Add:
    ```elixir
    @spec mark_email_verified(URI.t() | String.t()) :: {:ok, decoded()} | {:error, :not_found}
    def mark_email_verified(uri) do
      case Repo.get_by(__MODULE__, uri: uri_to_str(uri)) do
        nil -> {:error, :not_found}
        row ->
          row
          |> Ecto.Changeset.change(%{email_verified: true})
          |> Repo.update()
          |> case do
            {:ok, updated} -> {:ok, decode(updated)}
            err -> err
          end
      end
    end
    ```
  - `create_read_only/2` keeps `email_verified` defaulting to false (anon viewers never log in by form).
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `git commit -m "feat(login): Users email_verified field + mark_email_verified/1"`

### Task 1.3: `lower(email)` unique index migration (Codex #8)

**Files:** Create `apps/ezagent_core/priv/repo/migrations/20260622020000_email_lower_unique_index.exs`; Modify `profile.ex:43` (constraint name)

- [ ] **Step 1: Write the migration** (preflight aborts on case-folded dupes; replace raw index)

```elixir
defmodule EzagentCore.Repo.Migrations.EmailLowerUniqueIndex do
  use Ecto.Migration
  import Ecto.Query

  def up do
    # Preflight: abort if case-folded duplicate emails exist (none expected).
    dups =
      EzagentCore.Repo.all(
        from(p in "entity_profiles",
          where: not is_nil(p.email),
          group_by: fragment("lower(?)", p.email),
          having: count(p.entity_uri) > 1,
          select: fragment("lower(?)", p.email)
        )
      )

    if dups != [], do: raise("duplicate case-folded emails block lower(email) unique index: #{inspect(dups)}")

    drop_if_exists(index(:entity_profiles, [:email], name: :entity_profiles_email_index))
    create(unique_index(:entity_profiles, ["lower(email)"], name: :entity_profiles_email_lower_index, where: "email IS NOT NULL"))
  end

  def down do
    drop_if_exists(index(:entity_profiles, ["lower(email)"], name: :entity_profiles_email_lower_index))
    create(unique_index(:entity_profiles, [:email], name: :entity_profiles_email_index, where: "email IS NOT NULL"))
  end
end
```

- [ ] **Step 2:** In `profile.ex:43` change `unique_constraint(:email, name: :entity_profiles_email_index)` → `name: :entity_profiles_email_lower_index`.
- [ ] **Step 3: Test** (profile_test) — inserting two profiles whose emails differ only by case returns `{:error, changeset}` on the second.

```elixir
test "email uniqueness is case-insensitive" do
  {:ok, _} = Ezagent.Entity.Profile.upsert(%{entity_uri: Ezagent.URI.user("system","u1") |> URI.to_string(), display_name: "U1", email: "Dup@Ex.com"})
  assert {:error, _} = Ezagent.Entity.Profile.upsert(%{entity_uri: Ezagent.URI.user("system","u2") |> URI.to_string(), display_name: "U2", email: "dup@ex.com"})
end
```

- [ ] **Step 4:** `mix ecto.migrate` + run test → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(login): case-insensitive unique email index"`

### Task 1.4: email→URI login in the controller (primary `POST /login`)

**Files:** Modify `apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex`; Test `apps/ezagent_web/test/ezagent_web/controllers/session_controller_test.exs`

**Interfaces — Produces:** `POST /login` with `%{"email","password"}` → on success canonical URI in session + redirect `/sessions`; unverified → generic message after correct password; bad creds → generic inline error.

- [ ] **Step 1: Write failing controller tests** (replace the handle/URI login tests)

```elixir
test "POST /login with email+password creates session", %{conn: conn} do
  uri = Ezagent.URI.user("system", "loginok")
  {:ok, _} = Ezagent.Users.create(uri, "secret123", [], email_verified: true)
  {:ok, _} = Ezagent.Entity.Profile.upsert(%{entity_uri: URI.to_string(uri), display_name: "L", email: "loginok@ex.com"})
  conn = post(conn, "/login", %{"email" => "loginok@ex.com", "password" => "secret123"})
  assert redirected_to(conn) == "/sessions"
  assert get_session(conn, :entity_uri) == URI.to_string(uri)  # exact key per SessionPrincipal
end

test "POST /login unverified email shows generic message after correct password, no session", %{conn: conn} do
  uri = Ezagent.URI.user("system", "unverified")
  {:ok, _} = Ezagent.Users.create(uri, "secret123", [], email_verified: false)
  {:ok, _} = Ezagent.Entity.Profile.upsert(%{entity_uri: URI.to_string(uri), display_name: "U", email: "unv@ex.com"})
  conn = post(conn, "/login", %{"email" => "unv@ex.com", "password" => "secret123"})
  assert html_response(conn, 200) =~ "confirm your email"
  refute get_session(conn, :entity_uri)
end

test "POST /login wrong password → generic error, no enumeration", %{conn: conn} do
  conn = post(conn, "/login", %{"email" => "nobody@ex.com", "password" => "x"})
  assert html_response(conn, 200) =~ "Invalid email or password"
end
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement.** Replace `create/2` (currently magic-link) — magic-link send moves to `POST /login/magic` in PR-3; for now make `POST /login` the password path:

```elixir
def create(conn, %{"email" => email, "password" => password})
    when is_binary(email) and is_binary(password) do
  email = email |> String.trim() |> String.downcase()

  case resolve_and_auth(email, password) do
    {:ok, uri} ->
      if Ezagent.Users.get_by_uri(uri) |> verified?() do
        conn |> SessionPrincipal.put(uri, workspace: nil) |> redirect(to: "/sessions")
      else
        render_login_page(conn, cred_error: gettext("Please confirm your email to finish sign-in."))
      end

    :error ->
      render_login_page(conn, cred_error: gettext("Invalid email or password."))
  end
end

def create(conn, _), do: render_login_page(conn, cred_error: gettext("Email and password are required."))

defp verified?(%{email_verified: true}), do: true
defp verified?(_), do: false

# email → canonical URI → Entity.authenticate (spawn + caps). Constant-time on miss.
defp resolve_and_auth(email, password) do
  case Ezagent.Entity.Profile.by_email(email) do
    %{entity_uri: uri_str} ->
      case Entity.authenticate(Ezagent.URI.new!(uri_str), password) do
        {:ok, _} -> {:ok, uri_str}
        {:error, _} -> :error
      end
    _ ->
      Bcrypt.no_user_verify()
      :error
  end
end
```
  Note: `gettext` "confirm your email" / "Invalid email or password" copy must match the test substrings. Confirm the exact session key with `SessionPrincipal.put/3` + `get_session` (read `session_principal.ex` — the test asserts the real key).

- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `git commit -m "feat(login): email+password POST /login via Entity.authenticate + email_verified gate"`

### Task 1.5: PR-1 gates + review

- [ ] Run full gate suite (see Global Constraints). Fix any baseline drift.
- [ ] Dispatch subagent adversarial review of the PR diff (model opus; ezagent-developer skill).
- [ ] Admin-merge PR-1 into `feat/login-email-password`.

---

## PR-2 — mail transport (CF via SMTP) + confirmation/reset emails

**Goal:** Send confirmation + reset emails; CF is just `smtp_config` values; dev/test use Local adapter.

### Task 2.1: dev/test Local mailer adapter

**Files:** Modify `apps/ezagent_web/config/dev.exs`, `apps/ezagent_web/config/test.exs` (or umbrella `config/`)

- [ ] **Step 1:** Add `config :ezagent_web, EzagentWeb.Mailer, adapter: Swoosh.Adapters.Local` to dev + test config. (Prod stays the compile-pinned SMTP adapter in `config/config.exs`.)
- [ ] **Step 2: Test** — in test env, `EzagentWeb.Mailer.deliver_confirmation("x@ex.com", "http://link")` returns `{:ok, _}` without SMTP config (Local adapter). (Add in mailer_test.)
- [ ] **Step 3: Commit** — `git commit -m "feat(mail): Local mailer adapter for dev/test"`

### Task 2.2: `deliver_confirmation/2` + `deliver_password_reset/2`

**Files:** Modify `apps/ezagent_web/lib/ezagent_web/mailer.ex`; Test `apps/ezagent_web/test/.../mailer_test.exs`

**Interfaces — Produces:** `Mailer.deliver_confirmation(to_email, url)`, `Mailer.deliver_password_reset(to_email, url)` — same runtime-config pattern as `deliver_magic_link/2`; in dev/test the Local adapter ignores `smtp_config`.

- [ ] **Step 1: Write failing tests** — `build_confirmation_email/2` and `build_password_reset_email/2` produce a Swoosh email whose `text_body` contains the url; `deliver_*` returns `{:ok,_}` under Local adapter.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — add `build_confirmation_email/2`, `build_password_reset_email/2` (mirroring `build_magic_link_email/2` with appropriate subjects/copy), and `deliver_confirmation/2` + `deliver_password_reset/2`. For prod they reuse `smtp_runtime_config/1`; under the Local adapter `deliver/1` works with no runtime config — guard so that when the adapter is Local we call `deliver(email)` and otherwise the smtp_config path. (Read how `use Swoosh.Mailer` resolves the adapter; simplest: try the configured-adapter `deliver/1`, fall back to per-delivery smtp config only when adapter is SMTP.)
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `git commit -m "feat(mail): confirmation + password-reset emails"`

### Task 2.3: CF smtp_config preset doc + admin-settings helper

**Files:** docs/guide (operator note); admin settings UI module (locate via `grep -rn "smtp_config" apps/ezagent_plugin_world apps/ezagent_web` — likely `Behavior.*Settings`)

- [ ] **Step 1:** Document the CF preset values (host `smtp.mx.cloudflare.net`, port `465`, username `api_token`, password = CF token, from `…@ezagent.chat`) in `docs/guide/` (+ `.zh_cn.md`). Per bilingual-docs convention.
- [ ] **Step 2:** (Optional, if low-risk) add a "fill Cloudflare defaults" button to the SMTP settings form that pre-fills host/port/username. If the settings UI is risky to touch this round, defer the button and keep the doc; note it in the PR.
- [ ] **Step 3: Commit** — `git commit -m "docs(mail): Cloudflare SMTP preset for ezagent.chat"`

### Task 2.4: PR-2 gates + review + merge (as PR-1).

---

## PR-3 — self-registration + email confirmation + token purpose

**Goal:** New users register with email+password+display name; confirm via emailed link; magic-link login retained but purpose-gated.

### Task 3.1: token `purpose` migration + schema

**Files:** Create `apps/ezagent_core/priv/repo/migrations/20260622030000_add_purpose_to_magic_link_tokens.exs`; Modify `magic_link_token.ex`; Test `magic_link_token_test.exs`

**Interfaces — Produces:** `MagicLinkToken.mint(email, opts)` honours `opts[:purpose]` (`"login"|"confirm"|"reset"`, default `"login"`); `consume/2` and `peek/2` accept an expected purpose and reject mismatches (`{:error, :wrong_purpose}`).

- [ ] **Step 1: Migration** — `add(:purpose, :string, null: false, default: "login")` on `magic_link_tokens`.
- [ ] **Step 2: Failing tests** — a token minted `purpose: "reset"` consumed with expected `"login"` → `{:error, :wrong_purpose}`; matching purpose → `{:ok, email}`.
- [ ] **Step 3: Implement** — add `field(:purpose, :string, default: "login")`; `mint/2` writes `Keyword.get(opts, :purpose, "login")`; `consume(raw, expected_purpose \\ "login")` and `peek(raw, expected \\ "login")` compare `row.purpose` and return `{:error, :wrong_purpose}` on mismatch BEFORE consuming. Keep existing callers working (default `"login"`).
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `git commit -m "feat(login): one-time token purpose field + enforcement"`

### Task 3.2: `register_with_password/4` + domain→workspace

**Files:** Modify `apps/ezagent_domain_identity/lib/ezagent/registration.ex`; Test `registration_test.exs`

**Interfaces — Produces:**
- `Registration.workspace_for_email_domain(email) :: {:ok, workspace_name} | {:error, :domain_not_provisioned}` — maps the email domain to a pre-provisioned workspace; errors if none (no in-path workspace creation, per Codex #4).
- `Registration.register_with_password(email, password, display_name, opts) :: {:ok, uri} | {:error, term}` — creates a `confirmed:true, email_verified:false` user via `Users.create(uri, password, caps, email_verified: false)` in the derived workspace, upserts the profile, returns the URI.

- [ ] **Step 1: Failing tests** — register with a provisioned-domain email creates an unverified user + profile and returns its URI; a non-provisioned domain returns `{:error, :domain_not_provisioned}`; a duplicate email returns `{:error, _}`.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — derive `handle` from email local-part (collision-suffixed; reuse any existing slug helper in `registration.ex`), resolve the workspace from the domain (consult `registration_domains`/workspace mapping — read `Registration.email_allowed?/1` for the existing allowlist shape and extend to return the workspace). Build the URI with `Ezagent.URI.user(workspace, handle)`. Reject if `Profile.by_email/1` already resolves.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `git commit -m "feat(login): register_with_password + email-domain workspace resolution"`

### Task 3.3: registration controller + confirm endpoint + magic-link send

**Files:** Modify `apps/ezagent_web/lib/ezagent_web/controllers/registration_controller.ex`, `router.ex`, `session_controller.ex` (add `POST /login/magic`); Test controller tests

**Interfaces — Produces:** `GET /register`, `POST /register` (email/password/display → `register_with_password` → mint `purpose:"confirm"` token → `deliver_confirmation`), `GET /auth/confirm/:token` (consume `expected "confirm"` → `Users.mark_email_verified`), `POST /login/magic` (mint `purpose:"login"` → `deliver_magic_link`), `GET /auth/magic/:token` (consume `expected "login"`).

- [ ] **Step 1: Failing E2E-ish controller tests** — full register → capture link from Local mailbox (`Swoosh.Adapters.Local.Storage.Memory.all/0`) → GET confirm → user `email_verified` true → POST /login succeeds. Wrong-purpose token at `/auth/magic` → rejected.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** controllers + routes. Anti-enumeration: `POST /register` always renders the same "check your email" page. Honor `registration_domains`.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `git commit -m "feat(login): self-registration + email confirmation + purpose-gated magic-link"`

### Task 3.4: PR-3 gates + review + merge.

---

## PR-4 — password reset

**Files:** Create `apps/ezagent_web/lib/ezagent_web/controllers/password_reset_controller.ex`; Modify `router.ex`, `users.ex` (reuse `set_password/2`); Test controller tests

**Interfaces — Produces:** `GET /auth/reset` (request form), `POST /auth/reset` (mint `purpose:"reset"` → `deliver_password_reset`; always generic response), `GET /auth/reset/:token` (validate `expected "reset"` → render set-password form), `POST /auth/reset/:token` (consume + `Users.set_password/2` → redirect `/login`).

- [ ] **Step 1: Failing tests** — request reset for an existing email → link in Local mailbox; GET token form; POST new password → `Users.verify_password` true for new pw; reset token rejected at `/auth/magic` (wrong purpose); request for unknown email → same generic response, no email sent.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** controller + routes. Reset link mints no session; user logs in with the new password.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `git commit -m "feat(login): password reset via purpose-gated one-time token"`
- [ ] **Step 6: PR-4 gates + review + merge.**

---

## PR-5 — login page + world identity

**Files:** Modify `session_controller.ex` (`@login_card_body`, `render_login_page/2`), `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex`; Tests: controller render test + world_live test

### Task 5.1: collapse login page to email+password (+ conditional magic-link)

- [ ] **Step 1: Failing test** — `GET /login` HTML contains `name="email"` + `name="password"`, a "Create account" link (`/register`) and a "Forgot password" link (`/auth/reset`); does NOT contain `name="entity_uri"` or `name="secret"`. When `smtp_configured?` is false, the magic-link form is absent; when true, present.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — rewrite `@login_card_body` to the email+password form (action `POST /login`, fields `email`+`password`), drop the `entity_uri`/`secret` fields and the workspace hint about handles. Keep the magic-link `@email_form` block but render it (already gated on `smtp_configured?` in `render_login_page/2`) under a "passwordless" label only when configured; point its action at `POST /login/magic`. Add Create-account + Forgot-password links. Remove the now-dead `credentials_create/2`, `credentials_new/2`, `workspace_*` handle helpers (move to PR-6 if they have other refs).
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `git commit -m "feat(login): login page = email+password (+ conditional magic-link)"`

### Task 5.2: world identity display = display_name/email

- [ ] **Step 1: Failing test** — `world_live.ex` mount passes the profile `display_name` (fallback email, fallback URI) to the island assigns, not the raw `entity://...` URI. Assert the assign/payload key carries the display name for a user with a profile.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — in `world_live.ex` resolve `Ezagent.Entity.Profile.get(caller)` (or `EzagentPresenter`) and pass `display_name`/email in the island payload; keep `entity_uri` for internal identity. Use the existing presenter if one exists (`grep EntityPresenter`).
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `git commit -m "feat(world): show display name/email instead of raw URI"`

### Task 5.3: PR-5 gates + review + merge. (Link `docs/guide/world-coordination.md`; this touches `world_live.ex` — keep the diff small, no `styles.css` collision.)

---

## PR-6 — route retirement + bootstrap admin + docs + E2E

### Task 6.1: idempotent admin repair

**Files:** Modify `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex` (`ensure_admin_user/0`); Test `application` boot test or a dedicated unit test of the repair fn

**Interfaces — Produces:** `ensure_admin_user/0` — whether or not the admin row exists: set a password hash if absent (from app env `EZAGENT_ADMIN_PASSWORD`, else generate + `Logger.warning` once), upsert the admin profile email (`EZAGENT_ADMIN_EMAIL` or `admin@ezagent.chat`), set `email_verified = true`, preserve existing caps.

- [ ] **Step 1: Failing test** — given an admin row with `password_hash: nil` and no profile, after `ensure_admin_user/0`: `Users.get_by_uri(admin).email_verified == true`, `verify_password(admin, env_pw) == true`, profile email set, caps unchanged.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — refactor `ensure_admin_user/0` to a repair: on existing row, if `password_hash` nil → `Users.set_password(admin, admin_password())`; upsert profile via `Profile.upsert/1`; `Users.mark_email_verified(admin)`. `admin_password/0` reads env or generates+logs. Keep the DB-unavailable rescue.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `git commit -m "feat(login): idempotent admin email+password+verified bootstrap repair"`

### Task 6.2: route retirement

**Files:** Modify `router.ex`; delete dead controller actions; `grep` for every reference

- [ ] **Step 1:** `grep -rn "login/credentials\|/auth/magic\|onboarding/workspace\|register/complete\|credentials_create\|credentials_new\|OnboardingController" apps/` — enumerate all references (routes, templates, redirects, tests).
- [ ] **Step 2:** Remove routes `get|post /login/credentials`, `get|post /onboarding/workspace`, `get|post /register/complete` and their controller actions / `OnboardingController` if fully dead. KEEP `get /auth/magic/:token` but ensure it consumes with `expected "login"`. Update any redirect that targeted the removed routes to `/register` / `/login`.
- [ ] **Step 3:** Run full test suite; fix references. Commit — `git commit -m "feat(login): retire handle/URI + onboarding routes"`

### Task 6.3: docs + disposable-stack E2E

- [ ] **Step 1:** Update `docs/guide/` login/registration how-to (+ `.zh_cn.md`); update CLAUDE.md/CONTRIBUTING pointer if the first-login instructions changed (admin now email+password).
- [ ] **Step 2:** E2E on the disposable stack (per `docs/guide/` disposable-stack recipe): register (link from logger/Local), confirm, email+password login, land in world showing display name; admin email+password login; forgot-password cycle. Capture agent-browser screenshots (per the standing E2E bar).
- [ ] **Step 3: Commit** — `git commit -m "docs+e2e(login): email+password flow guide + disposable-stack E2E"`

### Task 6.4: PR-6 gates + review + final merge of the task branch handback to Allen.

---

## Self-Review

**Spec coverage:** §1 auth → 1.4; `email_verified` → 1.1/1.2; `lower(email)` index → 1.3; §2 transport → 2.1–2.3; §3 self-registration → 3.x; password reset → PR-4; token purpose → 3.1; §5 world/UI → PR-5; route retirement → 6.2; bootstrap admin → 6.1; data migrations A/B/C → 1.1/1.3/3.1; security (enumeration, constant-time, purpose, email_verified) → 1.4/3.x/4; OIDC seam → preserved by routing all auth through `Entity.authenticate/2` (no task needed — it's a non-change). Inbound email → out of scope (#88). ✅ no gaps.

**Placeholder scan:** Two deliberate execution-time reads are flagged, not placeholders: the exact session key in `SessionPrincipal.put/get` (Task 1.4) and the admin settings UI module + EntityPresenter (Tasks 2.3/5.2) — each names the grep to run. All migrations/domain code is literal.

**Type consistency:** `Users.create/4` opts, `mark_email_verified/1`, `Profile.by_email/1` returning a struct with `:entity_uri`, `MagicLinkToken.consume/2` purpose arg, `Registration.register_with_password/4` + `workspace_for_email_domain/1` — names used consistently across PRs. URI construction via `Ezagent.URI.user/2` everywhere.

## Execution Handoff

Inline execution (Allen: "你来开发"), per-PR: implement → subagent adversarial review → full gates → admin-merge into `feat/login-email-password`. After the plan's own codex adversarial review lands and is folded in, begin PR-1.
