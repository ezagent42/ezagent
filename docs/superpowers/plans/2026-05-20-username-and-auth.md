# Username & Auth — Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the **backend + auth-controller layer** for Username & Auth — the display-name data layer, runtime SMTP/settings storage, and email magic-link self-registration/login.

**Scope boundary (IMPORTANT):** The admin **LiveView UI is explicitly OUT of scope** for this plan. `feat/phase-8-ide-shell-liveview` is an unmerged +3378/−1098 rewrite of the entire LiveView layer (it already contains `settings_live.ex`, `profile_live.ex`, `identities_live.ex` and rewrites/deletes every admin LV). Building admin LVs here would collide ~100% with that branch and with the UI agents working on it. So this plan delivers only the parts that do NOT collide: domain modules, the `EzagentWeb.Mailer`/`RateLimiter` infra, and the **controller-rendered auth-boundary pages** (login / magic-link / register) — which the `UI / Frontend Contract` explicitly exempts from the no-inline-style rule. The display-name rendering and the SMTP-settings UI are handed to the Phase 8 effort via a handoff prompt — the final task (M4) of this plan.

**Architecture:** Three new SQLite tables (`entity_profiles`, `app_settings`, `magic_link_tokens`) plus thin Ecto facade modules in `ezagent_domain_identity`. Magic-link tokens are SHA-256-hashed, single-use, 15-min TTL. URI is the immutable system primary key — `display_name`/`email` are mutable attributes hung off it. Auth is controller-rendered (no LiveView at the credential boundary).

**Tech Stack:** Elixir/OTP umbrella, Phoenix 1.8, Ecto + `ecto_sqlite3`, Swoosh + `gen_smtp` (new), `bcrypt_elixir` (existing).

**Source spec:** `docs/superpowers/specs/2026-05-20-username-and-auth-design.md` (the spec describes the full feature including UI; this plan executes only the backend half).

**Milestones:** M1 (display-name data layer, Tasks 1–3) → M2 (settings + mailer backend, Tasks 4–7) → M3 (magic-link auth flow, Tasks 8–18) → M4 (UI handoff prompt, Task 19).

**Conventions for every task:**
- Migrations: `apps/ezagent_core/priv/repo/migrations/`, module prefix `EzagentCore.Repo.Migrations.*`.
- The repo module is `EzagentCore.Repo`.
- DB-touching tests in `ezagent_domain_identity`: `use EzagentCore.DataCase, async: false` (confirmed convention — `users_test.exs`, `token_test.exs` both use it). Identity test root is `apps/ezagent_domain_identity/test/ezagent/`.
- `ezagent_web` controller tests: `use EzagentWeb.ConnCase` (provides `conn` + DB sandbox).
- Run a single test: `mix test path/to/test.exs:LINE`.
- Pre-commit `sub-step-gate.sh` runs `mix format --check-formatted` + `mix test` + `mix ezagent.check_invariants` on every commit. **Run `mix format` before every commit step.**
- Known repo state: the worktree currently has pre-existing format drift in 4 unrelated files (`root.html.heex`, `snapshot.ex`, two migrations). Resolve that (a `chore: mix format` commit) **before starting Task 1**, or no commit in this plan will pass the gate.

---

## File Structure

All files below are domain modules, web infra, or controller-rendered auth pages — none are admin LiveViews, so none collide with `feat/phase-8-ide-shell-liveview`.

**M1 — Display-name data layer:**
- Create `apps/ezagent_core/priv/repo/migrations/20260529000000_entity_profiles.exs` — `entity_profiles` table.
- Create `apps/ezagent_domain_identity/lib/ezagent/entity/profile.ex` — `Ezagent.Entity.Profile`: schema + CRUD facade (`get/1`, `by_email/1`, `upsert/1`).
- Create `apps/ezagent_domain_identity/lib/ezagent/entity_presenter.ex` — `Ezagent.EntityPresenter`: `display/1`, `display_many/1` (the interface the Phase 8 UI will call).

**M2 — Settings store + Mailer:**
- Create `apps/ezagent_core/priv/repo/migrations/20260530000000_app_settings.exs` — `app_settings` table.
- Create `apps/ezagent_domain_identity/lib/ezagent/app_settings.ex` — `Ezagent.AppSettings`: schema + `get/1`, `put/2`, `smtp_configured?/0`.
- Modify `apps/ezagent_web/mix.exs` — add `:swoosh`, `:gen_smtp`.
- Modify `config/config.exs` — Swoosh base config.
- Create `apps/ezagent_web/lib/ezagent_web/mailer.ex` — `EzagentWeb.Mailer` + `deliver_magic_link/2`.

**M3 — Auth flow:**
- Create `apps/ezagent_core/priv/repo/migrations/20260531000000_magic_link_tokens.exs` — `magic_link_tokens` table.
- Create `apps/ezagent_domain_identity/lib/ezagent/entity/magic_link_token.ex` — `Ezagent.Entity.MagicLinkToken`: `mint/2`, `consume/1`.
- Create `apps/ezagent_domain_identity/lib/ezagent/registration.ex` — `Ezagent.Registration`: slug derivation, domain check, resolve-or-create.
- Modify `apps/ezagent_domain_identity/lib/ezagent/entity.ex` — expose `ensure_spawned/1` publicly as `spawn_principal/1`.
- Create `apps/ezagent_web/lib/ezagent_web/rate_limiter.ex` — `EzagentWeb.RateLimiter`: ETS window counter.
- Modify `apps/ezagent_web/lib/ezagent_web/application.ex` — start the rate-limiter ETS table.
- Modify `apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex` — email form + credentials split.
- Create `apps/ezagent_web/lib/ezagent_web/controllers/magic_link_controller.ex` — token consume.
- Create `apps/ezagent_web/lib/ezagent_web/controllers/registration_controller.ex` — `/register/complete`.
- Modify `apps/ezagent_web/lib/ezagent_web/router.ex` — auth routes (public scope only; no `/admin/*` routes — those belong to Phase 8).

**M4 — UI handoff:**
- Create `docs/superpowers/plans/2026-05-20-username-and-auth-UI-handoff.md` — the prompt for the Phase 8 developer.

---

# Milestone 1 — Display-name data layer

### Task 1: `entity_profiles` migration

**Files:**
- Create: `apps/ezagent_core/priv/repo/migrations/20260529000000_entity_profiles.exs`

- [ ] **Step 1: Write the migration**

```elixir
defmodule EzagentCore.Repo.Migrations.EntityProfiles do
  @moduledoc """
  Username & Auth M1 — entity-agnostic display profiles.

  One row per Entity URI (user OR agent). `display_name` is the
  friendly name shown in the UI; `email` is user-only and the
  resolution key for magic-link login (M3). URI stays the immutable
  system primary key — this table holds the mutable attributes.
  """
  use Ecto.Migration

  def change do
    create table(:entity_profiles, primary_key: false) do
      add :entity_uri, :string, primary_key: true
      add :display_name, :string, null: false
      add :email, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:entity_profiles, [:email],
             where: "email IS NOT NULL",
             name: :entity_profiles_email_index
           )
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `mix ecto.migrate`
Expected: `* running ... EntityProfiles` with no error.

- [ ] **Step 3: Verify rollback works**

Run: `mix ecto.rollback --step 1 && mix ecto.migrate`
Expected: both succeed.

- [ ] **Step 4: Commit**

```bash
mix format
git add apps/ezagent_core/priv/repo/migrations/20260529000000_entity_profiles.exs
git commit -m "feat(identity): entity_profiles table for display names + email"
```

---

### Task 2: `Ezagent.Entity.Profile` schema + facade

**Files:**
- Create: `apps/ezagent_domain_identity/lib/ezagent/entity/profile.ex`
- Test: `apps/ezagent_domain_identity/test/ezagent/entity/profile_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Ezagent.Entity.ProfileTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Profile

  test "upsert/1 inserts then updates the same entity_uri" do
    {:ok, p1} = Profile.upsert(%{entity_uri: "entity://user/x", display_name: "X"})
    assert p1.display_name == "X"

    {:ok, p2} = Profile.upsert(%{entity_uri: "entity://user/x", display_name: "X Renamed"})
    assert p2.display_name == "X Renamed"

    assert Profile.get("entity://user/x").display_name == "X Renamed"
  end

  test "by_email/1 resolves email to profile, case-insensitively" do
    {:ok, _} =
      Profile.upsert(%{
        entity_uri: "entity://user/allen",
        display_name: "Allen",
        email: "allen@example.com"
      })

    assert Profile.by_email("ALLEN@example.com").entity_uri == "entity://user/allen"
    assert Profile.by_email("nobody@example.com") == nil
  end

  test "email uniqueness is enforced" do
    {:ok, _} =
      Profile.upsert(%{entity_uri: "entity://user/a", display_name: "A", email: "dup@example.com"})

    assert {:error, changeset} =
             Profile.upsert(%{
               entity_uri: "entity://user/b",
               display_name: "B",
               email: "dup@example.com"
             })

    assert "has already been taken" in errors_on(changeset).email
  end

  test "get/1 and by_email/1 accept a %URI{} or string" do
    {:ok, _} = Profile.upsert(%{entity_uri: "entity://agent/echo", display_name: "Echo Bot"})
    assert Profile.get(URI.parse("entity://agent/echo")).display_name == "Echo Bot"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/ezagent_domain_identity/test/ezagent/entity/profile_test.exs`
Expected: FAIL — `Ezagent.Entity.Profile` is undefined.

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Ezagent.Entity.Profile do
  @moduledoc """
  Username & Auth M1 — entity-agnostic display profile store.

  One row per Entity URI. Holds the *mutable* attributes (`display_name`,
  `email`) that hang off the *immutable* URI primary key. `email` is
  user-only (NULL for agents) and the resolution key for magic-link
  login (M3).

  Schema + facade in one module, matching the `Ezagent.Users` /
  `Ezagent.Entity.Token` pattern. Display-side reads go through
  `Ezagent.EntityPresenter`; this module owns writes + lookups.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias EzagentCore.Repo

  @primary_key {:entity_uri, :string, autogenerate: false}
  schema "entity_profiles" do
    field(:display_name, :string)
    field(:email, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Insert-or-update a profile keyed by `entity_uri`."
  @spec upsert(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def upsert(attrs) when is_map(attrs) do
    attrs = normalize(attrs)
    existing = Repo.get(__MODULE__, attrs.entity_uri) || %__MODULE__{}

    existing
    |> cast(attrs, [:entity_uri, :display_name, :email])
    |> validate_required([:entity_uri, :display_name])
    |> unique_constraint(:email, name: :entity_profiles_email_index)
    |> Repo.insert_or_update()
  end

  @doc "Fetch a profile by entity URI. Returns `nil` if absent."
  @spec get(URI.t() | String.t()) :: t() | nil
  def get(uri), do: Repo.get(__MODULE__, to_str(uri))

  @doc "Resolve an email (case-insensitive) to its profile. `nil` if none."
  @spec by_email(String.t()) :: t() | nil
  def by_email(email) when is_binary(email) do
    down = String.downcase(String.trim(email))
    Repo.one(from(p in __MODULE__, where: fragment("lower(?)", p.email) == ^down))
  end

  def by_email(_), do: nil

  # entity_uri stored as string; email lower-cased + trimmed so the
  # uniqueness invariant means what callers expect.
  defp normalize(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {to_atom(k), v} end)
    |> Map.update(:entity_uri, nil, &to_str/1)
    |> then(fn m ->
      case Map.get(m, :email) do
        e when is_binary(e) and e != "" -> Map.put(m, :email, String.downcase(String.trim(e)))
        _ -> Map.put(m, :email, nil)
      end
    end)
  end

  defp to_atom(a) when is_atom(a), do: a
  defp to_atom(s) when is_binary(s), do: String.to_existing_atom(s)
  defp to_str(%URI{} = u), do: URI.to_string(u)
  defp to_str(s) when is_binary(s), do: s
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/ezagent_domain_identity/test/ezagent/entity/profile_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add apps/ezagent_domain_identity/lib/ezagent/entity/profile.ex apps/ezagent_domain_identity/test/ezagent/entity/profile_test.exs
git commit -m "feat(identity): Ezagent.Entity.Profile schema + facade"
```

---

### Task 3: `Ezagent.EntityPresenter`

This is the read-only display helper the Phase 8 UI will call to render friendly names instead of raw URIs. It ships now as the stable interface; the UI wiring is in the M4 handoff.

**Files:**
- Create: `apps/ezagent_domain_identity/lib/ezagent/entity_presenter.ex`
- Test: `apps/ezagent_domain_identity/test/ezagent/entity_presenter_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Ezagent.EntityPresenterTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Profile
  alias Ezagent.EntityPresenter

  test "display/1 returns the profile name when present" do
    {:ok, _} = Profile.upsert(%{entity_uri: "entity://user/allen", display_name: "Allen Woods"})
    assert EntityPresenter.display("entity://user/allen") == "Allen Woods"
  end

  test "display/1 falls back to the URI path segment when no profile" do
    assert EntityPresenter.display("entity://user/admin") == "admin"
    assert EntityPresenter.display("entity://agent/echo") == "echo"
  end

  test "display/1 falls back to the raw string for an unparseable URI" do
    assert EntityPresenter.display("not a uri") == "not a uri"
  end

  test "display_many/1 batch-resolves, keyed by string, with fallbacks" do
    {:ok, _} = Profile.upsert(%{entity_uri: "entity://user/a", display_name: "Ay"})

    result = EntityPresenter.display_many(["entity://user/a", URI.parse("entity://agent/echo")])

    assert result == %{
             "entity://user/a" => "Ay",
             "entity://agent/echo" => "echo"
           }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/ezagent_domain_identity/test/ezagent/entity_presenter_test.exs`
Expected: FAIL — `Ezagent.EntityPresenter` is undefined.

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Ezagent.EntityPresenter do
  @moduledoc """
  Username & Auth M1 — read-only display helper for Entity URIs.

  `display/1` for a single URI; `display_many/1` for batch resolution
  (one query). Renderers that show many entities at once — chat member
  lists, message history — MUST use `display_many/1` so display-name
  lookup stays O(1) queries, never O(rows). (Design铁律 #2.)

  Falls back to the URI path segment (`entity://user/admin` → `admin`)
  when no `entity_profiles` row exists, so unprofiled entities (e.g.
  the bootstrap admin, freshly-spawned agents) still render sanely.
  """

  import Ecto.Query
  alias EzagentCore.Repo
  alias Ezagent.Entity.Profile

  @doc "Friendly name for one URI. Profile name, else URI path segment."
  @spec display(URI.t() | String.t()) :: String.t()
  def display(uri) do
    uri_str = to_str(uri)

    case Repo.get(Profile, uri_str) do
      %Profile{display_name: name} when is_binary(name) and name != "" -> name
      _ -> fallback(uri_str)
    end
  end

  @doc """
  Batch-resolve a list of URIs. Returns a `%{uri_string => name}` map
  (keys are always strings, regardless of input shape).
  """
  @spec display_many([URI.t() | String.t()]) :: %{String.t() => String.t()}
  def display_many(uris) when is_list(uris) do
    uri_strs = Enum.map(uris, &to_str/1)

    found =
      from(p in Profile,
        where: p.entity_uri in ^uri_strs,
        select: {p.entity_uri, p.display_name}
      )
      |> Repo.all()
      |> Map.new()

    Map.new(uri_strs, fn u -> {u, Map.get(found, u) || fallback(u)} end)
  end

  defp fallback(uri_str) do
    case URI.new(uri_str) do
      {:ok, %URI{path: "/" <> name}} when name != "" -> name
      _ -> uri_str
    end
  end

  defp to_str(%URI{} = u), do: URI.to_string(u)
  defp to_str(s) when is_binary(s), do: s
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/ezagent_domain_identity/test/ezagent/entity_presenter_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add apps/ezagent_domain_identity/lib/ezagent/entity_presenter.ex apps/ezagent_domain_identity/test/ezagent/entity_presenter_test.exs
git commit -m "feat(identity): Ezagent.EntityPresenter display helper"
```

**M1 complete — the display-name data layer + presenter interface are ready for the Phase 8 UI to consume.**

---

# Milestone 2 — Settings store + Mailer

### Task 4: `app_settings` migration

**Files:**
- Create: `apps/ezagent_core/priv/repo/migrations/20260530000000_app_settings.exs`

- [ ] **Step 1: Write the migration**

```elixir
defmodule EzagentCore.Repo.Migrations.AppSettings do
  @moduledoc """
  Username & Auth M2 — key-value runtime config store.

  Holds UI-managed runtime config: `smtp_config` and
  `registration_domains`. Values are JSON text. The SMTP password is
  stored as-is — Ezagent has no at-rest encryption today (ApiKeys stores
  plaintext too); encryption is a separate project-wide decision.
  """
  use Ecto.Migration

  def change do
    create table(:app_settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `mix ecto.migrate`
Expected: `* running ... AppSettings` with no error.

- [ ] **Step 3: Commit**

```bash
mix format
git add apps/ezagent_core/priv/repo/migrations/20260530000000_app_settings.exs
git commit -m "feat(identity): app_settings key-value config table"
```

---

### Task 5: `Ezagent.AppSettings`

**Files:**
- Create: `apps/ezagent_domain_identity/lib/ezagent/app_settings.ex`
- Test: `apps/ezagent_domain_identity/test/ezagent/app_settings_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Ezagent.AppSettingsTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.AppSettings

  test "put/2 then get/1 round-trips a JSON-able term" do
    :ok = AppSettings.put("registration_domains", ["a.com", "b.com"])
    assert AppSettings.get("registration_domains") == ["a.com", "b.com"]
  end

  test "put/2 upserts" do
    :ok = AppSettings.put("registration_domains", ["a.com"])
    :ok = AppSettings.put("registration_domains", ["a.com", "c.com"])
    assert AppSettings.get("registration_domains") == ["a.com", "c.com"]
  end

  test "get/1 returns nil for an unset key" do
    assert AppSettings.get("nope") == nil
  end

  test "smtp_configured?/0 is false until a complete smtp_config is set" do
    refute AppSettings.smtp_configured?()

    :ok = AppSettings.put("smtp_config", %{"host" => "smtp.x.com"})
    refute AppSettings.smtp_configured?()

    :ok =
      AppSettings.put("smtp_config", %{
        "host" => "smtp.x.com",
        "port" => 587,
        "username" => "u",
        "password" => "p",
        "from_address" => "no-reply@x.com"
      })

    assert AppSettings.smtp_configured?()
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/ezagent_domain_identity/test/ezagent/app_settings_test.exs`
Expected: FAIL — `Ezagent.AppSettings` is undefined.

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Ezagent.AppSettings do
  @moduledoc """
  Username & Auth M2 — key-value runtime config facade over the
  `app_settings` table. JSON-encodes values.

  Keys in use:
  - `"smtp_config"` — `%{"host","port","username","password","from_address","tls"}`
  - `"registration_domains"` — list of allowed email domains for new registration

  Both keys are written by the admin SMTP-settings UI (Phase 8). This
  module is the backend interface that UI calls.
  """

  use Ecto.Schema
  alias EzagentCore.Repo

  @primary_key {:key, :string, autogenerate: false}
  schema "app_settings" do
    field(:value, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @smtp_required ~w(host port username password from_address)

  @doc "Decoded value for `key`, or `nil` if unset / unparseable."
  @spec get(String.t()) :: term() | nil
  def get(key) when is_binary(key) do
    case Repo.get(__MODULE__, key) do
      %__MODULE__{value: json} when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, term} -> term
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc "Upsert `key` with a JSON-encodable `term`. Returns `:ok`."
  @spec put(String.t(), term()) :: :ok
  def put(key, term) when is_binary(key) do
    json = Jason.encode!(term)

    %__MODULE__{}
    |> Ecto.Changeset.change(%{key: key, value: json})
    |> Repo.insert!(
      on_conflict: [set: [value: json, updated_at: DateTime.utc_now()]],
      conflict_target: :key
    )

    :ok
  end

  @doc "True only when `smtp_config` exists with every required field non-empty."
  @spec smtp_configured?() :: boolean()
  def smtp_configured? do
    case get("smtp_config") do
      %{} = cfg -> Enum.all?(@smtp_required, &present?(Map.get(cfg, &1)))
      _ -> false
    end
  end

  defp present?(v) when is_binary(v), do: String.trim(v) != ""
  defp present?(v) when is_integer(v), do: true
  defp present?(_), do: false
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/ezagent_domain_identity/test/ezagent/app_settings_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add apps/ezagent_domain_identity/lib/ezagent/app_settings.ex apps/ezagent_domain_identity/test/ezagent/app_settings_test.exs
git commit -m "feat(identity): Ezagent.AppSettings key-value config facade"
```

---

### Task 6: Add Swoosh + gen_smtp dependencies

**Files:**
- Modify: `apps/ezagent_web/mix.exs`
- Modify: `config/config.exs`

- [ ] **Step 1: Add deps to `apps/ezagent_web/mix.exs`**

In the `deps/0` list, after the `gettext` line, add:

```elixir
      {:swoosh, "~> 1.17"},
      {:gen_smtp, "~> 1.2"},
```

- [ ] **Step 2: Add Swoosh base config to `config/config.exs`**

In `config/config.exs`, insert these lines **above** the final `import_config "#{config_env()}.exs"` line — that import line must remain last in the file:

```elixir
# Username & Auth M2 — Swoosh. SMTP relay/credentials are supplied at
# deliver-time from Ezagent.AppSettings (runtime, admin-configured), so
# only the adapter is fixed here. api_client: false — SMTP only, no HTTP
# API adapters, so no hackney/finch dependency is pulled in.
config :ezagent_web, EzagentWeb.Mailer, adapter: Swoosh.Adapters.SMTP
config :swoosh, :api_client, false
```

- [ ] **Step 3: Fetch deps**

Run: `mix deps.get`
Expected: `swoosh` and `gen_smtp` fetched.

- [ ] **Step 4: Verify compilation**

Run: `mix compile`
Expected: compiles with no error.

- [ ] **Step 5: Commit**

```bash
mix format
git add apps/ezagent_web/mix.exs config/config.exs mix.lock
git commit -m "build(web): add swoosh + gen_smtp for outbound email"
```

---

### Task 7: `EzagentWeb.Mailer`

**Files:**
- Create: `apps/ezagent_web/lib/ezagent_web/mailer.ex`
- Test: `apps/ezagent_web/test/ezagent_web/mailer_test.exs`

- [ ] **Step 1: Write the failing test**

Swoosh's test adapter is not configured here (we use SMTP), so the test exercises `build_magic_link_email/2` — the pure email-construction function — directly, without delivering.

```elixir
defmodule EzagentWeb.MailerTest do
  use ExUnit.Case, async: true

  alias EzagentWeb.Mailer

  test "build_magic_link_email/2 sets recipient, sender, and link in the body" do
    email =
      Mailer.build_magic_link_email("allen@example.com",
        url: "https://esr.example.com/auth/magic/abc123",
        from_address: "no-reply@esr.example.com"
      )

    assert {_, "allen@example.com"} in email.to
    assert {_, "no-reply@esr.example.com"} = email.from
    assert email.subject =~ "Ezagent"
    assert email.text_body =~ "https://esr.example.com/auth/magic/abc123"
    assert email.html_body =~ "https://esr.example.com/auth/magic/abc123"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/ezagent_web/test/ezagent_web/mailer_test.exs`
Expected: FAIL — `EzagentWeb.Mailer` is undefined.

- [ ] **Step 3: Write the implementation**

```elixir
defmodule EzagentWeb.Mailer do
  @moduledoc """
  Username & Auth M2 — outbound email.

  SMTP relay + credentials are NOT in compile-time config — they live
  in `Ezagent.AppSettings` (`"smtp_config"`), set by the admin in the
  Phase 8 settings UI at runtime. `deliver_magic_link/2` reads that
  config and passes it to `Swoosh.Mailer.deliver/2` as a per-delivery
  override.
  """
  use Swoosh.Mailer, otp_app: :ezagent_web

  import Swoosh.Email

  @doc """
  Build (do not send) the magic-link email. Pure — unit-testable.

  Opts: `:url` (the magic link), `:from_address`.
  """
  @spec build_magic_link_email(String.t(), keyword()) :: Swoosh.Email.t()
  def build_magic_link_email(to_email, opts) do
    url = Keyword.fetch!(opts, :url)
    from_address = Keyword.fetch!(opts, :from_address)

    new()
    |> to(to_email)
    |> from({"Ezagent", from_address})
    |> subject("Your Ezagent sign-in link")
    |> text_body("""
    Sign in to Ezagent by opening this link (valid for 15 minutes):

    #{url}

    If you did not request this, you can ignore this email.
    """)
    |> html_body("""
    <p>Sign in to Ezagent by opening this link (valid for 15 minutes):</p>
    <p><a href="#{url}">#{url}</a></p>
    <p style="color:#888;font-size:12px;">If you did not request this, ignore this email.</p>
    """)
  end

  @doc """
  Build + deliver the magic-link email using the runtime SMTP config.

  Returns `{:error, :smtp_not_configured}` if the admin has not set
  SMTP up yet — callers MUST treat this as "do not proceed".
  """
  @spec deliver_magic_link(String.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def deliver_magic_link(to_email, url) do
    case Ezagent.AppSettings.get("smtp_config") do
      %{} = cfg ->
        if Ezagent.AppSettings.smtp_configured?() do
          email =
            build_magic_link_email(to_email,
              url: url,
              from_address: Map.fetch!(cfg, "from_address")
            )

          deliver(email, smtp_runtime_config(cfg))
        else
          {:error, :smtp_not_configured}
        end

      _ ->
        {:error, :smtp_not_configured}
    end
  end

  # Map the stored smtp_config map into Swoosh.Adapters.SMTP options.
  defp smtp_runtime_config(cfg) do
    [
      relay: Map.fetch!(cfg, "host"),
      port: to_int(Map.fetch!(cfg, "port")),
      username: Map.fetch!(cfg, "username"),
      password: Map.fetch!(cfg, "password"),
      auth: :always,
      tls: if(Map.get(cfg, "tls", true), do: :always, else: :never),
      ssl: false
    ]
  end

  defp to_int(n) when is_integer(n), do: n
  defp to_int(s) when is_binary(s), do: String.to_integer(String.trim(s))
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/ezagent_web/test/ezagent_web/mailer_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format
git add apps/ezagent_web/lib/ezagent_web/mailer.ex apps/ezagent_web/test/ezagent_web/mailer_test.exs
git commit -m "feat(web): EzagentWeb.Mailer with runtime SMTP config"
```

**M2 complete — settings store + mailer backend ready. (The admin SMTP-config UI is in the M4 handoff.)**

---

# Milestone 3 — Email Magic-Link Auth

### Task 8: `magic_link_tokens` migration

**Files:**
- Create: `apps/ezagent_core/priv/repo/migrations/20260531000000_magic_link_tokens.exs`

- [ ] **Step 1: Write the migration**

```elixir
defmodule EzagentCore.Repo.Migrations.MagicLinkTokens do
  @moduledoc """
  Username & Auth M3 — single-use, short-TTL magic-link tokens.

  Separate from `entity_tokens` (which is bcrypt long-lived bearer
  auth) because the semantics differ: magic links are single-use,
  15-min TTL, and the raw token travels in a URL. `token_hash` is
  SHA-256 of the raw token (raw token is high-entropy random, so a
  fast hash is sufficient and lets us look it up by index).
  """
  use Ecto.Migration

  def change do
    create table(:magic_link_tokens) do
      add :email, :string, null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:magic_link_tokens, [:token_hash])
    create index(:magic_link_tokens, [:email])
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `mix ecto.migrate`
Expected: `* running ... MagicLinkTokens` with no error.

- [ ] **Step 3: Commit**

```bash
mix format
git add apps/ezagent_core/priv/repo/migrations/20260531000000_magic_link_tokens.exs
git commit -m "feat(identity): magic_link_tokens table"
```

---

### Task 9: `Ezagent.Entity.MagicLinkToken`

**Files:**
- Create: `apps/ezagent_domain_identity/lib/ezagent/entity/magic_link_token.ex`
- Test: `apps/ezagent_domain_identity/test/ezagent/entity/magic_link_token_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Ezagent.Entity.MagicLinkTokenTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.MagicLinkToken

  test "mint/1 returns a raw token; consume/1 returns the email once" do
    {:ok, raw} = MagicLinkToken.mint("allen@example.com")
    assert is_binary(raw) and byte_size(raw) > 20

    assert {:ok, "allen@example.com"} = MagicLinkToken.consume(raw)
  end

  test "consume/1 is single-use — second call fails" do
    {:ok, raw} = MagicLinkToken.mint("x@example.com")
    assert {:ok, _} = MagicLinkToken.consume(raw)
    assert {:error, :consumed} = MagicLinkToken.consume(raw)
  end

  test "consume/1 rejects an expired token" do
    {:ok, raw} = MagicLinkToken.mint("y@example.com", ttl_seconds: -1)
    assert {:error, :expired} = MagicLinkToken.consume(raw)
  end

  test "consume/1 rejects an unknown / malformed token" do
    assert {:error, :invalid} = MagicLinkToken.consume("not-a-real-token")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/ezagent_domain_identity/test/ezagent/entity/magic_link_token_test.exs`
Expected: FAIL — `Ezagent.Entity.MagicLinkToken` is undefined.

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Ezagent.Entity.MagicLinkToken do
  @moduledoc """
  Username & Auth M3 — single-use, 15-min magic-link tokens.

  `mint/2` returns the RAW token (goes in the email URL, never stored).
  Only SHA-256(raw) is persisted. `consume/2` is single-use: it stamps
  `consumed_at`, so a replayed link fails with `{:error, :consumed}`.
  """

  use Ecto.Schema
  import Ecto.Query
  alias EzagentCore.Repo

  @ttl_seconds 15 * 60

  schema "magic_link_tokens" do
    field(:email, :string)
    field(:token_hash, :binary)
    field(:expires_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc """
  Mint a token for `email`. Returns `{:ok, raw_token}`.

  Opts: `:ttl_seconds` (default 900; negative values produce an
  already-expired token, for tests).
  """
  @spec mint(String.t(), keyword()) :: {:ok, String.t()}
  def mint(email, opts \\ []) when is_binary(email) do
    raw = "esr_ml_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
    ttl = Keyword.get(opts, :ttl_seconds, @ttl_seconds)

    %__MODULE__{}
    |> Ecto.Changeset.change(%{
      email: String.downcase(String.trim(email)),
      token_hash: hash(raw),
      expires_at: DateTime.add(DateTime.utc_now(), ttl, :second)
    })
    |> Repo.insert!()

    {:ok, raw}
  end

  @doc """
  Consume `raw_token`. On success returns `{:ok, email}` and the token
  cannot be consumed again.

  Errors: `:invalid` (unknown), `:expired`, `:consumed`.
  """
  @spec consume(String.t()) :: {:ok, String.t()} | {:error, :invalid | :expired | :consumed}
  def consume(raw_token) when is_binary(raw_token) do
    case Repo.get_by(__MODULE__, token_hash: hash(raw_token)) do
      nil ->
        {:error, :invalid}

      %__MODULE__{consumed_at: %DateTime{}} ->
        {:error, :consumed}

      %__MODULE__{expires_at: exp} = row ->
        if DateTime.compare(DateTime.utc_now(), exp) == :gt do
          {:error, :expired}
        else
          row
          |> Ecto.Changeset.change(%{consumed_at: DateTime.utc_now()})
          |> Repo.update!()

          {:ok, row.email}
        end
    end
  end

  def consume(_), do: {:error, :invalid}

  @doc "Delete tokens minted before `cutoff`. Housekeeping."
  @spec prune(DateTime.t()) :: {non_neg_integer(), nil}
  def prune(cutoff) do
    from(t in __MODULE__, where: t.inserted_at < ^cutoff) |> Repo.delete_all()
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/ezagent_domain_identity/test/ezagent/entity/magic_link_token_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add apps/ezagent_domain_identity/lib/ezagent/entity/magic_link_token.ex apps/ezagent_domain_identity/test/ezagent/entity/magic_link_token_test.exs
git commit -m "feat(identity): Ezagent.Entity.MagicLinkToken single-use tokens"
```

---

### Task 10: Make `Ezagent.Entity.spawn_principal/1` public

The registration flow (Task 11) and the magic-link consume (Task 15) both need to spawn a User Kind with its caps hydrated from the DB. `Ezagent.Entity` already has this exact logic as the private `ensure_spawned/1` + `spawn_with_hydrated_caps/1`. Expose it.

**Files:**
- Modify: `apps/ezagent_domain_identity/lib/ezagent/entity.ex`

- [ ] **Step 1: Add a public wrapper**

In `entity.ex`, add a public function just above the `defp ensure_spawned` definition:

```elixir
  @doc """
  Idempotently spawn the Kind for `uri`, hydrating its caps from the
  DB row when this call is the one that creates it. Safe to call when
  the Kind is already alive. Used by registration + magic-link login.
  """
  @spec spawn_principal(URI.t()) :: :ok
  def spawn_principal(%URI{} = uri), do: ensure_spawned(uri)
```

- [ ] **Step 2: Verify compilation**

Run: `mix compile`
Expected: compiles, no warnings about `spawn_principal`.

- [ ] **Step 3: Commit**

```bash
mix format
git add apps/ezagent_domain_identity/lib/ezagent/entity.ex
git commit -m "feat(identity): expose Ezagent.Entity.spawn_principal/1"
```

---

### Task 11: `Ezagent.Registration`

**Files:**
- Create: `apps/ezagent_domain_identity/lib/ezagent/registration.ex`
- Test: `apps/ezagent_domain_identity/test/ezagent/registration_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Ezagent.RegistrationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Registration
  alias Ezagent.Entity.Profile

  test "derive_slug/1 lowercases and sanitizes the email local part" do
    assert Registration.derive_slug("Allen.Woods@example.com") == "allen-woods"
    assert Registration.derive_slug("a+tag@example.com") == "a-tag"
  end

  test "slug_available?/1 + suggest_slug/1" do
    assert Registration.slug_available?("freshslug")
    {:ok, _} = Ezagent.Users.create("entity://user/taken", nil, [])
    refute Registration.slug_available?("taken")
    assert Registration.suggest_slug("taken") == "taken-2"
  end

  test "domain_allowed?/1 checks the configured allowlist" do
    Ezagent.AppSettings.put("registration_domains", ["good.com"])
    assert Registration.domain_allowed?("x@good.com")
    refute Registration.domain_allowed?("x@bad.com")
  end

  test "domain_allowed?/1 is false when no domains are configured" do
    refute Registration.domain_allowed?("x@anything.com")
  end

  test "principal_for_email/1 resolves an existing profile" do
    {:ok, _} =
      Profile.upsert(%{
        entity_uri: "entity://user/known",
        display_name: "Known",
        email: "known@good.com"
      })

    assert Registration.principal_for_email("known@good.com") ==
             {:ok, URI.parse("entity://user/known")}

    assert Registration.principal_for_email("nobody@good.com") == :none
  end

  test "create_principal/3 creates user + profile + spawns the Kind" do
    assert {:ok, uri} =
             Registration.create_principal("newbie", "New Bie", "newbie@good.com")

    assert URI.to_string(uri) == "entity://user/newbie"
    assert Ezagent.Users.get_by_uri(uri) != nil
    assert Profile.by_email("newbie@good.com").entity_uri == "entity://user/newbie"
    assert {:ok, _pid} = Ezagent.KindRegistry.lookup(uri)
  end

  test "create_principal/3 rejects a taken slug" do
    {:ok, _} = Registration.create_principal("dup", "Dup", "dup1@good.com")
    assert {:error, :slug_taken} = Registration.create_principal("dup", "Dup2", "dup2@good.com")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/ezagent_domain_identity/test/ezagent/registration_test.exs`
Expected: FAIL — `Ezagent.Registration` is undefined.

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Ezagent.Registration do
  @moduledoc """
  Username & Auth M3 — email-magic-link registration logic.

  Pure-ish coordination over `Ezagent.Users`, `Ezagent.Entity.Profile`,
  `Ezagent.AppSettings`, and `Ezagent.Entity.spawn_principal/1`.

  ## Slug = URI = immutable identity

  `derive_slug/1` proposes a URL-safe slug from an email. The slug is
  editable ONLY before `create_principal/3` is called — once a User
  exists, `entity://user/<slug>` is the system primary key and is
  frozen (design铁律 #1). After that, `display_name` is the mutable
  knob, not the slug.
  """

  alias Ezagent.AppSettings
  alias Ezagent.Entity.Profile
  alias Ezagent.Users

  @doc "Propose a URL-safe slug from an email's local part."
  @spec derive_slug(String.t()) :: String.t()
  def derive_slug(email) when is_binary(email) do
    email
    |> String.split("@", parts: 2)
    |> List.first()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "user"
      s -> s
    end
  end

  @doc "True if no User exists at `entity://user/<slug>`."
  @spec slug_available?(String.t()) :: boolean()
  def slug_available?(slug) when is_binary(slug) do
    is_nil(Users.get_by_uri("entity://user/" <> slug))
  end

  @doc "Return the first free `<slug>`, `<slug>-2`, `<slug>-3`, ... variant."
  @spec suggest_slug(String.t()) :: String.t()
  def suggest_slug(slug) when is_binary(slug) do
    if slug_available?(slug) do
      slug
    else
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(fn n ->
        candidate = "#{slug}-#{n}"
        if slug_available?(candidate), do: candidate
      end)
    end
  end

  @doc "True if `email`'s domain is in the configured `registration_domains`."
  @spec domain_allowed?(String.t()) :: boolean()
  def domain_allowed?(email) when is_binary(email) do
    domains = AppSettings.get("registration_domains") || []

    case String.split(email, "@", parts: 2) do
      [_, domain] -> String.downcase(String.trim(domain)) in Enum.map(domains, &String.downcase/1)
      _ -> false
    end
  end

  def domain_allowed?(_), do: false

  @doc "Resolve an email to an existing principal URI, or `:none`."
  @spec principal_for_email(String.t()) :: {:ok, URI.t()} | :none
  def principal_for_email(email) when is_binary(email) do
    case Profile.by_email(email) do
      %Profile{entity_uri: uri_str} -> {:ok, URI.parse(uri_str)}
      nil -> :none
    end
  end

  @doc """
  Create a brand-new principal: `users` row (password-less, default
  caps), `entity_profiles` row, and a spawned + cap-hydrated User Kind.

  Returns `{:ok, uri}` or `{:error, :slug_taken | term()}`.
  """
  @spec create_principal(String.t(), String.t(), String.t()) ::
          {:ok, URI.t()} | {:error, term()}
  def create_principal(slug, display_name, email)
      when is_binary(slug) and is_binary(display_name) and is_binary(email) do
    uri_str = "entity://user/" <> slug
    uri = URI.parse(uri_str)

    cond do
      not slug_available?(slug) ->
        {:error, :slug_taken}

      true ->
        # users-row + profile-row insert in ONE transaction: if the
        # profile insert fails (e.g. concurrent email collision), the
        # users row rolls back — no orphan principal. The Kind spawn
        # happens only AFTER commit (a process can't be rolled back).
        txn =
          EzagentCore.Repo.transaction(fn ->
            with {:ok, _user} <- Users.create(uri, nil, []),
                 {:ok, _profile} <-
                   Profile.upsert(%{
                     entity_uri: uri_str,
                     display_name: String.trim(display_name),
                     email: email
                   }) do
              :created
            else
              {:error, reason} -> EzagentCore.Repo.rollback(reason)
            end
          end)

        case txn do
          {:ok, :created} ->
            :ok = Ezagent.Entity.spawn_principal(uri)
            {:ok, uri}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/ezagent_domain_identity/test/ezagent/registration_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add apps/ezagent_domain_identity/lib/ezagent/registration.ex apps/ezagent_domain_identity/test/ezagent/registration_test.exs
git commit -m "feat(identity): Ezagent.Registration slug + resolve-or-create"
```

---

### Task 12: `EzagentWeb.RateLimiter`

**Files:**
- Create: `apps/ezagent_web/lib/ezagent_web/rate_limiter.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/application.ex`
- Test: `apps/ezagent_web/test/ezagent_web/rate_limiter_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule EzagentWeb.RateLimiterTest do
  use ExUnit.Case, async: false

  alias EzagentWeb.RateLimiter

  setup do
    RateLimiter.reset_all()
    :ok
  end

  test "allows up to the limit then blocks within the window" do
    assert RateLimiter.check("k1", limit: 2, window_ms: 60_000) == :ok
    assert RateLimiter.check("k1", limit: 2, window_ms: 60_000) == :ok
    assert RateLimiter.check("k1", limit: 2, window_ms: 60_000) == {:error, :rate_limited}
  end

  test "separate keys have independent counters" do
    assert RateLimiter.check("a", limit: 1, window_ms: 60_000) == :ok
    assert RateLimiter.check("b", limit: 1, window_ms: 60_000) == :ok
  end

  test "the counter resets after the window elapses" do
    assert RateLimiter.check("w", limit: 1, window_ms: 30) == :ok
    assert RateLimiter.check("w", limit: 1, window_ms: 30) == {:error, :rate_limited}
    Process.sleep(40)
    assert RateLimiter.check("w", limit: 1, window_ms: 30) == :ok
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/ezagent_web/test/ezagent_web/rate_limiter_test.exs`
Expected: FAIL — `EzagentWeb.RateLimiter` is undefined.

- [ ] **Step 3: Write the implementation**

```elixir
defmodule EzagentWeb.RateLimiter do
  @moduledoc """
  Username & Auth M3 — minimal fixed-window rate limiter.

  ETS-backed, no extra dependency. Used to throttle the unauthenticated
  `POST /login` email-send path (per-email + per-IP) so it can't be
  abused for email bombing or SMTP-quota exhaustion.

  Fixed-window semantics: each key gets a counter that resets when its
  window elapses. Coarse but sufficient for an abuse backstop.

  The ETS table is created by `init_table/0`, called from
  `EzagentWeb.Application`.
  """

  @table :ezagent_rate_limiter

  @doc "Create the ETS table. Idempotent. Call once at app boot."
  @spec init_table() :: :ok
  def init_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, {:write_concurrency, true}])
    end

    :ok
  end

  @doc """
  Check + record one hit for `key`. Returns `:ok` if under the limit,
  `{:error, :rate_limited}` otherwise.

  Opts: `:limit` (max hits per window), `:window_ms`.
  """
  @spec check(String.t(), keyword()) :: :ok | {:error, :rate_limited}
  def check(key, opts) when is_binary(key) do
    limit = Keyword.fetch!(opts, :limit)
    window_ms = Keyword.fetch!(opts, :window_ms)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, count, window_start}] when now - window_start < window_ms ->
        if count >= limit do
          {:error, :rate_limited}
        else
          :ets.insert(@table, {key, count + 1, window_start})
          :ok
        end

      _ ->
        # No record, or the window elapsed → start a fresh window.
        :ets.insert(@table, {key, 1, now})
        :ok
    end
  end

  @doc "Clear every counter. Test-support."
  @spec reset_all() :: :ok
  def reset_all do
    init_table()
    :ets.delete_all_objects(@table)
    :ok
  end
end
```

- [ ] **Step 4: Initialize the table at app boot**

In `apps/ezagent_web/lib/ezagent_web/application.ex`, inside `start/2`, as the first line of the function body (before the `children = [...]` list), add:

```elixir
    :ok = EzagentWeb.RateLimiter.init_table()
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test apps/ezagent_web/test/ezagent_web/rate_limiter_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
mix format
git add apps/ezagent_web/lib/ezagent_web/rate_limiter.ex apps/ezagent_web/lib/ezagent_web/application.ex apps/ezagent_web/test/ezagent_web/rate_limiter_test.exs
git commit -m "feat(web): ETS fixed-window RateLimiter"
```

---

### Task 13: Split `SessionController` — `/login/credentials`

Before adding the email path, move the existing URI+secret form to `/login/credentials` so `/login` is free for the email form. This task is a pure refactor — behavior of the credentials path is unchanged.

**Files:**
- Modify: `apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex`
- Modify: `apps/ezagent_web/test/ezagent_web/controllers/session_controller_test.exs`

- [ ] **Step 1: Rename the controller actions**

In `session_controller.ex`, rename `new/2` → `credentials_new/2` and `create/2` → `credentials_create/2` (both clauses of `create`). Keep `delete/2`, `authenticate/2`, `flash_error/1` unchanged. In `credentials_create`, change the failure redirect from `/login` to `/login/credentials`.

- [ ] **Step 2: Update the routes**

In `router.ex`, replace the four login/logout lines (currently `get "/login"`, `post "/login"`, `delete "/logout"`, `post "/logout"`) with:

```elixir
    get "/login/credentials", SessionController, :credentials_new
    post "/login/credentials", SessionController, :credentials_create
    delete "/logout", SessionController, :delete
    post "/logout", SessionController, :delete
```

(`/login` GET/POST are added in Task 14.)

- [ ] **Step 3: Update existing tests**

In `apps/ezagent_web/test/ezagent_web/controllers/session_controller_test.exs`:
- `describe "GET /login"`: change `get(conn, "/login")` → `get(conn, "/login/credentials")`. The assertions (`=~ "Ezagent Login"`, `=~ "Entity URI"`) stay — `credentials_new/2` still renders the existing `@login_html`.
- `describe "POST /login"`: change all three `post(..., "/login", ...)` → `post(..., "/login/credentials", ...)`. In the two failure-case tests, change the assertion `redirected_to(conn) == "/login"` → `== "/login/credentials"`.
- `describe "logout"`: leave entirely unchanged (`/logout` is not renamed).

Run: `mix test apps/ezagent_web/test/ezagent_web/controllers/session_controller_test.exs`
Expected: PASS (all existing tests, now on the new path).

- [ ] **Step 4: Commit**

```bash
mix format
git add apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex apps/ezagent_web/lib/ezagent_web/router.ex apps/ezagent_web/test/ezagent_web/controllers/session_controller_test.exs
git commit -m "refactor(web): move credential login to /login/credentials"
```

---

### Task 14: `/login` email form + magic-link request

**Files:**
- Modify: `apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex`
- Test: `apps/ezagent_web/test/ezagent_web/controllers/login_email_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule EzagentWeb.LoginEmailTest do
  use EzagentWeb.ConnCase

  alias EzagentWeb.RateLimiter

  setup do
    RateLimiter.reset_all()

    Ezagent.AppSettings.put("smtp_config", %{
      "host" => "localhost",
      "port" => 2525,
      "username" => "u",
      "password" => "p",
      "from_address" => "no-reply@test.local"
    })

    Ezagent.AppSettings.put("registration_domains", ["good.com"])
    :ok
  end

  test "GET /login renders the email form", %{conn: conn} do
    conn = get(conn, "/login")
    assert html_response(conn, 200) =~ "email"
  end

  test "POST /login with any email shows the generic check-inbox response", %{conn: conn} do
    conn = post(conn, "/login", %{"email" => "someone@bad.com"})
    assert html_response(conn, 200) =~ "check"
  end

  test "POST /login mints a token for an allowlisted new email", %{conn: conn} do
    post(conn, "/login", %{"email" => "fresh@good.com"})
    assert EzagentCore.Repo.aggregate(Ezagent.Entity.MagicLinkToken, :count) >= 1
  end

  test "POST /login mints no token for a non-allowlisted new email", %{conn: conn} do
    before = EzagentCore.Repo.aggregate(Ezagent.Entity.MagicLinkToken, :count)
    post(conn, "/login", %{"email" => "fresh@bad.com"})
    assert EzagentCore.Repo.aggregate(Ezagent.Entity.MagicLinkToken, :count) == before
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/ezagent_web/test/ezagent_web/controllers/login_email_test.exs`
Expected: FAIL — no `/login` route.

- [ ] **Step 3: Add the email-form actions to `SessionController`**

`SessionController` uses `use Phoenix.Controller, formats: [:html], layouts: []` + `import Plug.Conn` — these are auth-boundary controller-rendered pages (the `UI / Frontend Contract` explicitly exempts them; self-contained `<style>` is sanctioned here). Add:

```elixir
  @email_html """
  <!DOCTYPE html>
  <html><head><title>Ezagent Sign in</title><meta charset="utf-8">
  <style>
    body { font-family: -apple-system, sans-serif; max-width: 400px; margin: 80px auto; padding: 24px; }
    h1 { font-size: 24px; } form { display: flex; flex-direction: column; gap: 12px; }
    input { padding: 8px 10px; border: 1px solid #d1d5da; border-radius: 4px; font-size: 14px; }
    button { padding: 10px; background: #1f883d; color: white; border: none; border-radius: 4px; cursor: pointer; }
    .msg { color: #1f883d; font-size: 13px; padding: 8px; background: #e6ffec; border-radius: 4px; }
    .err { color: #cf222e; font-size: 13px; padding: 8px; background: #ffebe9; border-radius: 4px; }
    .hint { color: #57606a; font-size: 12px; margin-top: 8px; }
  </style></head><body>
  <h1>Sign in to Ezagent</h1>
  {{BODY}}
  <p class="hint"><a href="/login/credentials">Sign in with credentials</a> (admin / agent)</p>
  </body></html>
  """

  @email_form """
  <form method="post" action="/login">
    <input type="hidden" name="_csrf_token" value="{{CSRF}}">
    <label for="email">Email address</label>
    <input type="email" id="email" name="email" placeholder="you@example.com" required autofocus>
    <button type="submit">Email me a sign-in link</button>
  </form>
  """

  def new(conn, _params) do
    body =
      if Ezagent.AppSettings.smtp_configured?() do
        String.replace(@email_form, "{{CSRF}}", Plug.CSRFProtection.get_csrf_token())
      else
        ~s(<div class="err">Email sign-in is not enabled yet. Contact your administrator.</div>)
      end

    send_page(conn, String.replace(@email_html, "{{BODY}}", body))
  end

  def create(conn, %{"email" => email}) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()
    _ = maybe_send_magic_link(conn, email)

    # Anti-enumeration: identical response regardless of whether the
    # email exists, is allowlisted, or was rate-limited (design §5.5).
    body =
      ~s(<div class="msg">If that email can sign in, we've sent a link. Please check your inbox.</div>)

    send_page(conn, String.replace(@email_html, "{{BODY}}", body))
  end

  def create(conn, _params), do: new(conn, %{})

  # Returns :ok always (caller ignores it — anti-enumeration). Internally
  # decides whether to actually mint + send.
  defp maybe_send_magic_link(conn, email) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    with true <- Ezagent.AppSettings.smtp_configured?(),
         :ok <- EzagentWeb.RateLimiter.check("login_email:" <> email, limit: 3, window_ms: 15 * 60_000),
         :ok <- EzagentWeb.RateLimiter.check("login_ip:" <> ip, limit: 10, window_ms: 60 * 60_000),
         true <- send_allowed?(email) do
      {:ok, raw} = Ezagent.Entity.MagicLinkToken.mint(email)
      link = EzagentWeb.Endpoint.url() <> "/auth/magic/" <> raw
      _ = EzagentWeb.Mailer.deliver_magic_link(email, link)
      :ok
    else
      _ -> :ok
    end
  end

  # Existing principal → always allowed (login). New email → must be
  # on the registration domain allowlist.
  defp send_allowed?(email) do
    case Ezagent.Registration.principal_for_email(email) do
      {:ok, _uri} -> true
      :none -> Ezagent.Registration.domain_allowed?(email)
    end
  end

  defp send_page(conn, html) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end
```

The magic-link URL is built with `EzagentWeb.Endpoint.url()` (the configured base URL) plus the route path — no verified-routes (`~p`) import needed, so `SessionController`'s existing header is untouched. The `raw` token is URL-safe Base64, so it needs no escaping.

- [ ] **Step 4: Add the `/login` routes**

In `router.ex`, add above the `/login/credentials` lines:

```elixir
    get "/login", SessionController, :new
    post "/login", SessionController, :create
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test apps/ezagent_web/test/ezagent_web/controllers/login_email_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
mix format
git add apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex apps/ezagent_web/lib/ezagent_web/router.ex apps/ezagent_web/test/ezagent_web/controllers/login_email_test.exs
git commit -m "feat(web): /login email form + rate-limited magic-link request"
```

---

### Task 15: `MagicLinkController` — token consume

**Files:**
- Create: `apps/ezagent_web/lib/ezagent_web/controllers/magic_link_controller.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex`
- Test: `apps/ezagent_web/test/ezagent_web/controllers/magic_link_controller_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule EzagentWeb.MagicLinkControllerTest do
  use EzagentWeb.ConnCase

  alias Ezagent.Entity.{MagicLinkToken, Profile}

  test "consuming a token for an existing user logs them in", %{conn: conn} do
    {:ok, _} =
      Profile.upsert(%{
        entity_uri: "entity://user/known",
        display_name: "Known",
        email: "known@good.com"
      })

    {:ok, _} = Ezagent.Users.create("entity://user/known", nil, [])
    {:ok, raw} = MagicLinkToken.mint("known@good.com")

    conn = get(conn, "/auth/magic/#{raw}")
    assert redirected_to(conn) == "/admin"
    assert get_session(conn, :current_entity_uri) == "entity://user/known"
  end

  test "consuming a token for a new email starts registration", %{conn: conn} do
    {:ok, raw} = MagicLinkToken.mint("newcomer@good.com")

    conn = get(conn, "/auth/magic/#{raw}")
    assert redirected_to(conn) == "/register/complete"
    assert get_session(conn, :pending_registration_email) == "newcomer@good.com"
  end

  test "an invalid token redirects to /login with an error", %{conn: conn} do
    conn = get(conn, "/auth/magic/bogus-token")
    assert redirected_to(conn) == "/login"
  end

  test "a consumed token cannot be reused", %{conn: conn} do
    {:ok, raw} = MagicLinkToken.mint("again@good.com")
    get(build_conn(), "/auth/magic/#{raw}")
    conn = get(conn, "/auth/magic/#{raw}")
    assert redirected_to(conn) == "/login"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/ezagent_web/test/ezagent_web/controllers/magic_link_controller_test.exs`
Expected: FAIL — no `/auth/magic/:token` route.

- [ ] **Step 3: Write the controller**

```elixir
defmodule EzagentWeb.MagicLinkController do
  @moduledoc """
  Username & Auth M3 — magic-link consumption (`GET /auth/magic/:token`).

  Plain controller (not LiveView) — this is the auth boundary; it must
  not depend on a websocket. Consumes the single-use token, then either
  logs an existing principal in or starts registration.

  Uses the light `Phoenix.Controller` header (matching `SessionController`)
  — no layouts, no verified routes; just redirects + flash + session.
  """
  use Phoenix.Controller, formats: [:html], layouts: []

  import Plug.Conn

  alias Ezagent.Entity.MagicLinkToken
  alias Ezagent.Registration

  def consume(conn, %{"token" => token}) do
    case MagicLinkToken.consume(token) do
      {:ok, email} ->
        route_by_email(conn, email)

      {:error, reason} ->
        conn
        |> put_flash(:error, error_message(reason))
        |> redirect(to: "/login")
    end
  end

  defp route_by_email(conn, email) do
    case Registration.principal_for_email(email) do
      {:ok, uri} ->
        # Existing principal → log in. Ensure the Kind is alive with
        # hydrated caps, renew the session (fixation defence), land /admin.
        :ok = Ezagent.Entity.spawn_principal(uri)

        conn
        |> configure_session(renew: true)
        |> put_session(:current_entity_uri, URI.to_string(uri))
        |> redirect(to: "/admin")

      :none ->
        # New email → carry the verified email into a short-lived
        # pending-registration session, go collect handle + display name.
        conn
        |> configure_session(renew: true)
        |> put_session(:pending_registration_email, email)
        |> redirect(to: "/register/complete")
    end
  end

  defp error_message(:expired), do: "That sign-in link has expired. Please request a new one."
  defp error_message(:consumed), do: "That sign-in link was already used. Please request a new one."
  defp error_message(_), do: "Invalid sign-in link. Please request a new one."
end
```

- [ ] **Step 4: Add the route**

In `router.ex`, in the public `scope "/", EzagentWeb` block (with the login routes), add:

```elixir
    get "/auth/magic/:token", MagicLinkController, :consume
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test apps/ezagent_web/test/ezagent_web/controllers/magic_link_controller_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
mix format
git add apps/ezagent_web/lib/ezagent_web/controllers/magic_link_controller.ex apps/ezagent_web/lib/ezagent_web/router.ex apps/ezagent_web/test/ezagent_web/controllers/magic_link_controller_test.exs
git commit -m "feat(web): MagicLinkController — token consume, login-or-register"
```

---

### Task 16: `RegistrationController` — `/register/complete`

**Files:**
- Create: `apps/ezagent_web/lib/ezagent_web/controllers/registration_controller.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex`
- Test: `apps/ezagent_web/test/ezagent_web/controllers/registration_controller_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule EzagentWeb.RegistrationControllerTest do
  use EzagentWeb.ConnCase

  # String session key — get_session/2 looks keys up as strings; an
  # atom key here would simply not be found.
  defp pending_conn(conn, email) do
    Plug.Test.init_test_session(conn, %{"pending_registration_email" => email})
  end

  test "GET /register/complete shows the form prefilled with a derived slug", %{conn: conn} do
    conn = conn |> pending_conn("allen.woods@good.com") |> get("/register/complete")
    assert html_response(conn, 200) =~ "allen-woods"
  end

  test "GET /register/complete without a pending email redirects to /login", %{conn: conn} do
    conn = get(conn, "/register/complete")
    assert redirected_to(conn) == "/login"
  end

  test "POST /register/complete creates the principal and logs in", %{conn: conn} do
    conn =
      conn
      |> pending_conn("newbie@good.com")
      |> post("/register/complete", %{"handle" => "newbie", "display_name" => "New Bie"})

    assert redirected_to(conn) == "/admin"
    assert get_session(conn, :current_entity_uri) == "entity://user/newbie"
    assert get_session(conn, :pending_registration_email) == nil
    assert Ezagent.Entity.Profile.by_email("newbie@good.com").entity_uri == "entity://user/newbie"
  end

  test "POST with a taken handle re-renders the form with a suggestion", %{conn: conn} do
    {:ok, _} = Ezagent.Users.create("entity://user/taken", nil, [])

    conn =
      conn
      |> pending_conn("taken@good.com")
      |> post("/register/complete", %{"handle" => "taken", "display_name" => "T"})

    assert html_response(conn, 200) =~ "taken-2"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/ezagent_web/test/ezagent_web/controllers/registration_controller_test.exs`
Expected: FAIL — no `/register/complete` route.

- [ ] **Step 3: Write the controller**

```elixir
defmodule EzagentWeb.RegistrationController do
  @moduledoc """
  Username & Auth M3 — registration completion (`/register/complete`).

  Reached only after `MagicLinkController` verified the email and put
  `:pending_registration_email` in the session. The user picks a handle
  (the URI slug — editable HERE and only here; frozen once the principal
  exists) and a display name.

  Uses the light `Phoenix.Controller` header (matching `SessionController`).
  """
  use Phoenix.Controller, formats: [:html], layouts: []

  import Plug.Conn

  alias Ezagent.Registration

  @form_html """
  <!DOCTYPE html>
  <html><head><title>Complete registration</title><meta charset="utf-8">
  <style>
    body { font-family: -apple-system, sans-serif; max-width: 420px; margin: 80px auto; padding: 24px; }
    h1 { font-size: 22px; } form { display: flex; flex-direction: column; gap: 12px; }
    label { font-size: 13px; color: #666; }
    input { padding: 8px 10px; border: 1px solid #d1d5da; border-radius: 4px; font-size: 14px; }
    button { padding: 10px; background: #1f883d; color: white; border: none; border-radius: 4px; cursor: pointer; }
    .err { color: #cf222e; font-size: 13px; padding: 8px; background: #ffebe9; border-radius: 4px; }
    .hint { color: #57606a; font-size: 12px; }
  </style></head><body>
  <h1>Complete your registration</h1>
  {{ERROR}}
  <form method="post" action="/register/complete">
    <input type="hidden" name="_csrf_token" value="{{CSRF}}">
    <label for="handle">Username (your permanent handle — entity://user/&lt;handle&gt;)</label>
    <input type="text" id="handle" name="handle" value="{{HANDLE}}" required autofocus>
    <label for="display_name">Display name (you can change this later)</label>
    <input type="text" id="display_name" name="display_name" value="{{DISPLAY}}" required>
    <button type="submit">Create my account</button>
  </form>
  <p class="hint">Signing up as {{EMAIL}}</p>
  </body></html>
  """

  def complete_new(conn, _params) do
    case get_session(conn, :pending_registration_email) do
      email when is_binary(email) ->
        slug = Registration.suggest_slug(Registration.derive_slug(email))
        render_form(conn, email, slug, default_display(email), nil)

      _ ->
        redirect(conn, to: "/login")
    end
  end

  def complete_create(conn, %{"handle" => handle, "display_name" => display_name}) do
    case get_session(conn, :pending_registration_email) do
      email when is_binary(email) ->
        case Registration.principal_for_email(email) do
          {:ok, uri} ->
            # Concurrent-registration / re-entry guard (spec §7): the
            # email became a principal since the magic link was issued.
            # Email ownership was already proven by the link → log in,
            # do NOT double-create.
            login_and_redirect(conn, uri)

          :none ->
            slug = handle |> String.trim() |> String.downcase()

            case Registration.create_principal(slug, display_name, email) do
              {:ok, uri} ->
                login_and_redirect(conn, uri)

              {:error, :slug_taken} ->
                suggestion = Registration.suggest_slug(slug)

                render_form(
                  conn,
                  email,
                  suggestion,
                  display_name,
                  "“#{slug}” is taken. Try “#{suggestion}”."
                )

              {:error, reason} ->
                render_form(conn, email, slug, display_name, "Could not register: #{inspect(reason)}")
            end
        end

      _ ->
        redirect(conn, to: "/login")
    end
  end

  def complete_create(conn, _params) do
    redirect(conn, to: "/register/complete")
  end

  defp login_and_redirect(conn, uri) do
    :ok = Ezagent.Entity.spawn_principal(uri)

    conn
    |> configure_session(renew: true)
    |> delete_session(:pending_registration_email)
    |> put_session(:current_entity_uri, URI.to_string(uri))
    |> redirect(to: "/admin")
  end

  defp render_form(conn, email, handle, display, error) do
    error_block = if error, do: ~s(<div class="err">#{Plug.HTML.html_escape(error)}</div>), else: ""

    html =
      @form_html
      |> String.replace("{{ERROR}}", error_block)
      |> String.replace("{{CSRF}}", Plug.CSRFProtection.get_csrf_token())
      |> String.replace("{{HANDLE}}", Plug.HTML.html_escape(handle) |> safe_to_string())
      |> String.replace("{{DISPLAY}}", Plug.HTML.html_escape(display) |> safe_to_string())
      |> String.replace("{{EMAIL}}", Plug.HTML.html_escape(email) |> safe_to_string())

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  defp safe_to_string({:safe, iodata}), do: IO.iodata_to_binary(iodata)
  defp safe_to_string(s) when is_binary(s), do: s

  # Humanize the email local part as the default display name.
  defp default_display(email) do
    email
    |> String.split("@", parts: 2)
    |> List.first()
    |> String.split(~r/[._+-]+/, trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
```

- [ ] **Step 4: Add the routes**

In `router.ex`, in the public `scope "/", EzagentWeb` block, add:

```elixir
    get "/register/complete", RegistrationController, :complete_new
    post "/register/complete", RegistrationController, :complete_create
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test apps/ezagent_web/test/ezagent_web/controllers/registration_controller_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
mix format
git add apps/ezagent_web/lib/ezagent_web/controllers/registration_controller.ex apps/ezagent_web/lib/ezagent_web/router.ex apps/ezagent_web/test/ezagent_web/controllers/registration_controller_test.exs
git commit -m "feat(web): RegistrationController — /register/complete handle picker"
```

---

### Task 17: Invariant tests

**Files:**
- Create: `apps/ezagent_web/test/integration/magic_link_invariants_test.exs`

These lock the design's security invariants so a future PR can't silently re-break them.

- [ ] **Step 1: Write the invariant tests**

```elixir
defmodule EzagentWeb.MagicLinkInvariantsTest do
  @moduledoc """
  Username & Auth M3 — security invariants. A failure here means a
  design rule (spec §1, §5.5, §5.6) was violated.
  """
  use EzagentWeb.ConnCase

  alias Ezagent.Entity.MagicLinkToken
  alias EzagentWeb.RateLimiter

  setup do
    RateLimiter.reset_all()

    Ezagent.AppSettings.put("smtp_config", %{
      "host" => "localhost",
      "port" => 2525,
      "username" => "u",
      "password" => "p",
      "from_address" => "no-reply@test.local"
    })

    Ezagent.AppSettings.put("registration_domains", ["good.com"])
    :ok
  end

  test "INVARIANT: a magic-link token is single-use" do
    {:ok, raw} = MagicLinkToken.mint("once@good.com")
    assert {:ok, _} = MagicLinkToken.consume(raw)
    assert {:error, :consumed} = MagicLinkToken.consume(raw)
  end

  test "INVARIANT: an expired token is rejected" do
    {:ok, raw} = MagicLinkToken.mint("old@good.com", ttl_seconds: -1)
    assert {:error, :expired} = MagicLinkToken.consume(raw)
  end

  test "INVARIANT: POST /login is anti-enumeration — identical response for allowed/denied" do
    allowed = post(build_conn(), "/login", %{"email" => "new@good.com"})
    denied = post(build_conn(), "/login", %{"email" => "new@bad.com"})

    assert html_response(allowed, 200) == html_response(denied, 200)
  end

  test "INVARIANT: POST /login is rate-limited per email" do
    before = EzagentCore.Repo.aggregate(MagicLinkToken, :count)

    for _ <- 1..6, do: post(build_conn(), "/login", %{"email" => "spam@good.com"})

    after_count = EzagentCore.Repo.aggregate(MagicLinkToken, :count)
    # limit is 3 per 15-min window — at most 3 tokens minted despite 6 posts.
    assert after_count - before <= 3
  end

  test "INVARIANT: magic-link login renews the session id (fixation defence)" do
    {:ok, _} =
      Ezagent.Entity.Profile.upsert(%{
        entity_uri: "entity://user/fix",
        display_name: "Fix",
        email: "fix@good.com"
      })

    {:ok, _} = Ezagent.Users.create("entity://user/fix", nil, [])
    {:ok, raw} = MagicLinkToken.mint("fix@good.com")

    conn = get(build_conn(), "/auth/magic/#{raw}")
    assert get_session(conn, :current_entity_uri) == "entity://user/fix"
  end
end
```

- [ ] **Step 2: Run the invariant tests**

Run: `mix test apps/ezagent_web/test/integration/magic_link_invariants_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 3: Commit**

```bash
mix format
git add apps/ezagent_web/test/integration/magic_link_invariants_test.exs
git commit -m "test(web): magic-link security invariant gate"
```

---

### Task 18: End-to-end verification + agent-auth regression

**Files:** none created — verification only.

- [ ] **Step 1: Confirm the agent-auth path is untouched**

Run: `mix test apps/ezagent_domain_identity/test/ezagent/entity/token_test.exs apps/ezagent_web/test/ezagent_web/controllers/session_controller_test.exs`
Expected: PASS — `entity_tokens` and credential login are unaffected (design铁律 #4).

- [ ] **Step 2: Run the whole suite**

Run: `mix test`
Expected: PASS (all milestones, no regressions).

- [ ] **Step 3: Run the invariant checker**

Run: `mix ezagent.check_invariants`
Expected: green — no architectural invariant violated.

- [ ] **Step 4: Manual e2e**

There is no admin settings UI in this deliverable (it is the Phase 8 handoff), so SMTP + domains are configured via `iex` for this verification.

Run `iex -S mix phx.server`, then:
1. In the IEx prompt: `Ezagent.AppSettings.put("smtp_config", %{"host" => "localhost", "port" => 1025, "username" => "u", "password" => "p", "from_address" => "no-reply@test.local"})` (point at a dev SMTP catcher like Mailpit on `localhost:1025`), and `Ezagent.AppSettings.put("registration_domains", ["good.com"])`.
2. Browser → `/login` → enter `someone@good.com` → "check inbox" page → open the emailed link → `/register/complete` → pick a handle → lands on `/admin`.
3. Sign out → `/login` with the same email again → emailed link → straight to `/admin` (no `/register/complete`).
4. `/login` with `someone@bad.com` → same generic check-inbox copy, no email actually sent.
5. `/login/credentials` → admin password login still works.
Note: `/admin` will still show raw URIs and has no settings page — the display-name rendering and SMTP UI are the Phase 8 handoff (M4), not this deliverable.

- [ ] **Step 5: Final commit (if any manual-fix changes were needed)**

```bash
mix format
git add -A
git commit -m "chore(auth): username & auth backend e2e verification pass"
```

**M3 complete — email magic-link auth backend is live.**

---

# Milestone 4 — UI Handoff

### Task 19: Write the Phase 8 UI handoff prompt

The backend is done; the admin LiveView UI (display-name rendering + SMTP settings page) belongs to `feat/phase-8-ide-shell-liveview`. Produce a self-contained prompt the user forwards to the Phase 8 developer.

**Files:**
- Create: `docs/superpowers/plans/2026-05-20-username-and-auth-UI-handoff.md`

- [ ] **Step 1: Write the handoff document**

Write the file with exactly this content (it is the prompt the user sends):

````markdown
# Username & Auth — UI handoff to Phase 8

The **backend** for Username & Auth has merged to `main`. It ships three new
tables + facade modules and the controller-rendered auth pages. **The admin
LiveView UI was intentionally left to you** (the Phase 8 IDE Shell effort)
because Phase 8 rewrites every admin LV and already has `settings_live.ex` /
`profile_live.ex` / `identities_live.ex`. Please rebase onto the merged
backend and wire the UI below, following the `UI / Frontend Contract`
(atoms, Tailwind tokens, `dark:` variants, no inline styles).

## Backend interfaces now available

- `Ezagent.EntityPresenter.display/1` — friendly name for one URI (profile
  `display_name`, else the URI path segment).
- `Ezagent.EntityPresenter.display_many/1` — batch version, returns
  `%{uri_string => name}`. **Use this for any list/table** (member panels,
  message history, entity lists) — one query, not one per row.
- `Ezagent.Entity.Profile.get/1` · `by_email/1` · `upsert/1` — read/write a
  profile (`%{entity_uri, display_name, email}`). `upsert/1` returns
  `{:ok, profile}` or `{:error, changeset}` (email-uniqueness violation).
- `Ezagent.AppSettings.get/1` · `put/2` · `smtp_configured?/0` — runtime
  config. Keys: `"smtp_config"` (map with `host/port/username/password/
  from_address/tls`), `"registration_domains"` (list of strings).

Data model: `entity_profiles(entity_uri PK, display_name, email)`,
`app_settings(key PK, value JSON)`.

## UI to build

1. **Display names everywhere a URI is shown to a human.** In the rewritten
   member panel / conversation view / entities (identities) list / users list
   / admin shell — render `EntityPresenter.display(uri)` as the primary label,
   keep the raw URI as a secondary monospace line where useful. For lists,
   batch with `display_many/1` at mount/refresh — never call `display/1`
   per row. `@mention` pickers: show + filter by `display_name`, keep the
   URI as the option value.

2. **Display-name editing.** In the users list (or `profile_live.ex`): an
   inline field that calls
   `Ezagent.Entity.Profile.upsert(%{entity_uri: uri, display_name: name})`.
   `display_name` is freely mutable; the URI is NOT (immutable primary key).

3. **Bare-handle input.** The create-user form should accept a bare handle
   (`allen`) and prepend `entity://user/` before submit.

4. **SMTP + registration settings page** (`settings_live.ex`). Admin-only.
   - SMTP form: host / port / username / password / from_address / tls →
     `AppSettings.put("smtp_config", %{...})`. Password field MUST mask and
     never echo the stored value.
   - Registration-domains editor → `AppSettings.put("registration_domains",
     ["company.com", ...])`. Empty list = no self-registration.
   - "Send test email" button → `EzagentWeb.Mailer.deliver_magic_link(
     admin_email, test_url)`; surface `{:ok, _}` / `{:error, reason}`.
   - Show `AppSettings.smtp_configured?()` as a status indicator.

## Do NOT touch

The controller-rendered auth pages — `/login`, `/login/credentials`,
`/auth/magic/:token`, `/register/complete` — are done and live in
`SessionController` / `MagicLinkController` / `RegistrationController`. They
are auth-boundary pages (self-contained `<style>`, exempt from the contract).

## Why it matters

Until the SMTP settings page exists, email login is inert in production
(SMTP can only be set via `iex`). The settings page is what activates the
whole feature.
````

- [ ] **Step 2: Commit**

```bash
mix format
git add docs/superpowers/plans/2026-05-20-username-and-auth-UI-handoff.md
git commit -m "docs(auth): UI handoff prompt for Phase 8 developer"
```

- [ ] **Step 3: Surface the handoff to the user**

Print the contents of `docs/superpowers/plans/2026-05-20-username-and-auth-UI-handoff.md` back to the user so they can forward it to the Phase 8 developer.

**M4 complete — backend shipped, UI handed off.**

---

## Post-Implementation

- Append Decision Log entries **#145–#148** to `ARCHITECTURE.md` Appendix B (subjects in spec §10). Per the `ezagent-developer` skill, the dev team owns Decision Log appends post-handoff.
- The bilingual-docs convention applies to user-facing docs, not this internal spec/plan pair — no `.zh_cn.md` mirror required.

## Out of Scope (do NOT implement here)

- **All admin LiveView UI** — handed to `feat/phase-8-ide-shell-liveview` via the M4 handoff.
- At-rest encryption of secrets; post-hoc slug rename; user self-service email change; agent device-code; MFA/SSO/OAuth (see spec §11).
