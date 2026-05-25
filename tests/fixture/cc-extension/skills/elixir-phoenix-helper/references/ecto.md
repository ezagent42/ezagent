# Ecto (Schemas, Changesets, Queries, Multi, Migrations)

Ecto 3.12+. For older versions, query Context7 first — there are subtle API differences.

## The four layers

- **Schema** — declarative mapping between a struct and a table.
- **Changeset** — validated, cast transformation of untrusted data into a schema-struct-shaped change.
- **Query** — composable, SQL-generating pipeline.
- **Repo** — the I/O boundary; `Repo.all`, `Repo.insert`, `Repo.update`, `Repo.transaction`.

## Schemas

```elixir
defmodule MyApp.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          email: String.t() | nil,
          hashed_password: String.t() | nil,
          posts: [MyApp.Blog.Post.t()] | Ecto.Association.NotLoaded.t()
        }

  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true

    has_many :posts, MyApp.Blog.Post

    timestamps(type: :utc_datetime)
  end

  # Changesets go here — see next section
end
```

Notes:

- `@type t` at the top, referencing `%__MODULE__{}` — used in specs across the context.
- `timestamps(type: :utc_datetime)` — store UTC, always. Do not use `:naive_datetime` unless you have a compelling reason (you do not).
- `redact: true` on sensitive fields — they will not appear in `inspect/1` output or error logs.
- `virtual: true` for fields that live in the struct during changeset but are not persisted (like a plaintext password that gets hashed before insert).

## Changesets

A changeset is a validated transformation. It is where all data validation happens — not in controllers, not in LiveViews.

```elixir
def registration_changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :password])
  |> validate_required([:email, :password])
  |> validate_format(:email, ~r/@/)
  |> validate_length(:password, min: 12, max: 72)
  |> unsafe_validate_unique(:email, MyApp.Repo)
  |> unique_constraint(:email)
  |> hash_password()
end

defp hash_password(%Ecto.Changeset{valid?: true, changes: %{password: pw}} = cs) do
  cs
  |> put_change(:hashed_password, Argon2.hash_pwd_salt(pw))
  |> delete_change(:password)
end

defp hash_password(cs), do: cs
```

Key principles:

- **One changeset per use case**, not one per schema. `registration_changeset`, `profile_changeset`, `password_reset_changeset` — each casts only its relevant fields.
- **Always pair `unsafe_validate_unique/3` with `unique_constraint/3`.** The first gives a friendly form error pre-insert; the second catches the DB race condition. Both are needed.
- **Derive `changes` from the changeset, not from the passed attrs.** Pattern match on `%Ecto.Changeset{changes: %{...}}`.
- **Never raise inside a changeset.** Return `add_error/3` instead — the caller decides what to do with an invalid changeset.

### Composed associations: `cast_assoc` and `put_assoc`

- **`cast_assoc/3`:** when the nested data is form input (strings from the user).
- **`put_assoc/3`:** when you already have structs to attach (loaded from DB, or passed through code).

Do not use `cast_assoc` for "link an existing record" — it will try to cast `%{"id" => 1}` into a new record and fail mysteriously. Use `put_assoc` with the loaded struct.

## Queries

Ecto queries compose. Start from the schema or a subquery, chain `where`, `order_by`, `select`, `join`, etc.

```elixir
import Ecto.Query

from(u in User,
  where: u.active == true,
  order_by: [desc: u.inserted_at],
  limit: 20,
  select: %{id: u.id, email: u.email}
)
|> Repo.all()
```

Or the pipeline form (often clearer when composing):

```elixir
User
|> where([u], u.active == true)
|> order_by([u], desc: u.inserted_at)
|> limit(20)
|> select([u], %{id: u.id, email: u.email})
|> Repo.all()
```

### Composing queries

```elixir
def list_users(params \\ %{}) do
  User
  |> filter_by_email(params)
  |> filter_by_status(params)
  |> sort(params)
  |> Repo.all()
end

defp filter_by_email(q, %{"email" => email}) when is_binary(email) and email != "" do
  from u in q, where: ilike(u.email, ^"%#{email}%")
end
defp filter_by_email(q, _), do: q

defp filter_by_status(q, %{"status" => "active"}), do: from u in q, where: u.active == true
defp filter_by_status(q, _), do: q
```

Each filter is a function `query → query`. Easy to test, easy to compose.

### `select/3` over `Enum.map/2`

When you only need certain fields, select them in SQL:

```elixir
# Good:
from(u in User, select: %{id: u.id, email: u.email})
|> Repo.all()

# Bad — fetches everything, then discards:
User |> Repo.all() |> Enum.map(fn u -> %{id: u.id, email: u.email} end)
```

### Preloading (N+1 prevention)

```elixir
User
|> where([u], u.active == true)
|> preload(:posts)                           # separate query
|> Repo.all()

# Or via join + preload (single query):
from(u in User,
  join: p in assoc(u, :posts),
  preload: [posts: p]
)

# Nested:
preload(query, posts: [:comments, author: :profile])

# From Repo directly on loaded records:
Repo.preload(user, [:posts])
```

**Default to preloading any association the view will access.** Missing preloads → N+1 queries → production latency spikes. The rule is: if a template accesses `@user.posts`, the context loading `@user` must preload `:posts`.

### Fragments for SQL-specific operations

```elixir
from u in User, where: fragment("LOWER(?) = LOWER(?)", u.email, ^email)
```

Use sparingly — fragments defeat Ecto's composability and portability. Reach for them only when the native operators cannot express what you need.

## `Ecto.Multi` — atomic multi-step operations

Any operation that touches 2+ records transactionally goes through `Multi`:

```elixir
alias Ecto.Multi

def register_user_and_send_welcome(attrs) do
  Multi.new()
  |> Multi.insert(:user, User.registration_changeset(%User{}, attrs))
  |> Multi.insert(:profile, fn %{user: user} ->
    Profile.changeset(%Profile{user_id: user.id}, %{})
  end)
  |> Multi.run(:email, fn _repo, %{user: user} ->
    Mailer.send_welcome(user)
  end)
  |> Repo.transaction()
  |> case do
    {:ok, %{user: user}} -> {:ok, user}
    {:error, step, reason, _changes} -> {:error, {step, reason}}
  end
end
```

Why `Multi` over `Repo.transaction(fn -> ... end)`:

- Each step is inspectable and testable.
- Errors carry which step failed and the partial changes map.
- Declarative structure is easier to read than a big `with` block inside a transaction.

**Pitfall:** `Multi.run` side effects (like sending email) will execute **inside** the transaction. If the transaction is rolled back later, the side effect has already happened. For external side effects, either: defer them until after the transaction commits (see `Ecto.Multi` + `Oban` pattern), or accept eventual inconsistency.

## Migrations

```elixir
defmodule MyApp.Repo.Migrations.CreatePosts do
  use Ecto.Migration

  def change do
    create table(:posts) do
      add :title, :string, null: false
      add :body, :text, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:posts, [:user_id])
  end
end
```

In Phoenix 1.8 scope-aware apps, generators automatically add the scope's foreign key (`user_id`, `organization_id`, etc.) to every generated table — and add the matching index. Every query that uses `%Scope{}` filters on this foreign key, and the index makes that filter cheap. If you hand-write a migration for a scope-owned resource, include the foreign key and its index.

Rules:

- **`null: false` + `default`** for any column that should not be nullable. Do not rely on the schema to enforce non-null.
- **`unique_index` matches every `unique_constraint/3`** in changesets.
- **Use `change/0`** unless the migration is irreversible. For irreversibles, implement `up/0` and `down/0`.
- **For production data migrations, use `Ecto.Migrator` + a separate mix task** — do not mix schema and data changes in the same migration.

### Zero-downtime migrations

Breaking-change migrations (dropping columns, renaming, adding non-null without default) need a multi-deploy dance:

1. **Add new column** (nullable) + backfill.
2. **Deploy code** that writes to both columns.
3. **Backfill completes**; deploy code reading from new column.
4. **Drop old column**.

Do not attempt to combine these in one migration in a deployed system.

## Sandbox (for tests)

In `test_helper.exs`:

```elixir
Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, :manual)
```

In each test (via `MyApp.DataCase`):

```elixir
setup do
  :ok = Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Repo)
  unless tags[:async] do
    Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, {:shared, self()})
  end
  :ok
end
```

- Async tests get their own connection, with changes rolled back at test end.
- Non-async tests (tests that spawn processes which also need DB access) use `:shared` mode — all processes see the same connection.
- LiveView/Channel tests typically need `:shared` because the Phoenix process is separate from the test process.

## Multi-tenancy: `prefix` option

For schema-per-tenant:

```elixir
Repo.all(User, prefix: "tenant_42")
Repo.insert(changeset, prefix: "tenant_42")
```

For row-per-tenant, filter explicitly in every query — there is no magic. Consider wrapping `Repo` in a tenant-aware helper module to avoid manual filtering.

## Pitfalls in Ecto

1. **Missing preloads → N+1.** Preload anything the view accesses.
2. **`Repo.all |> Enum.map` instead of `select`.** Fetch less, map more.
3. **`cast_assoc` for existing records.** Use `put_assoc`.
4. **Changesets without `unique_constraint`.** You will get `Ecto.ConstraintError` at runtime on races.
5. **Side effects in `Multi.run`.** Fire the side effect outside the transaction (pre-commit via `Oban.insert` in a Multi works because it is itself a DB write).
6. **Schema-wide changesets (`changeset/2`) that cast every field.** Use use-case-specific changesets.
7. **Raw SQL via `Repo.query/2`** when an `Ecto.Query` would work — you lose type casting and parameterization hygiene.
8. **Migrations that both create schema and backfill data.** Split them.
9. **`null: true` columns by default.** Make non-null the default.
10. **Using `:naive_datetime` for timestamps.** Use `:utc_datetime` (or `:utc_datetime_usec`) always.
