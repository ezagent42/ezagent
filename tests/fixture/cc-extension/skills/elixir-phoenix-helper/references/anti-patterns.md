# Anti-Patterns and Deprecated APIs

This file covers the Elixir anti-patterns and outdated API usage that Claude's training data most commonly emits. Read this reference whenever **reviewing existing code**, **migrating a project**, or whenever the user pastes a snippet that looks pre-1.15. For new code generation, the main `SKILL.md` idioms list is enough.

The official Elixir docs have a full [Anti-Patterns guide](https://hexdocs.pm/elixir/what-anti-patterns.html); this file picks the items Claude most often gets wrong and pairs them with specific rewrites.

## Code anti-patterns

### 1. Non-assertive map access

Silently accessing a map key that might not exist, using `map[:key]` when you actually expect the key to be there.

```elixir
# Anti-pattern — returns nil if :name is missing, usually followed by
# subtle bugs like "why is my greeting 'Hello, !'"
def greet(user), do: "Hello, #{user[:name]}"

# Better — asserts the key exists, crashes loudly if missing
def greet(user), do: "Hello, #{user.name}"

# Best — pattern match in the function head
def greet(%{name: name}), do: "Hello, #{name}"
```

**Rule:** use `map[:key]` / `Access.get/2` only when the key is genuinely optional. For required keys, use `map.key` or pattern matching. The dot notation raises `KeyError` on missing key — which is what you want.

### 2. Non-assertive truthiness

Using `if`/`&&`/`||` with values that are expected to be booleans — if a `nil` or unexpected value sneaks in, the branch silently takes the wrong path.

```elixir
# Anti-pattern — any non-false, non-nil value takes the truthy branch,
# including "", 0, [], all of which may indicate a bug upstream.
if user_active do
  send_notification(user)
end

# Better — be explicit about what you're testing for
if user_active == true do
  send_notification(user)
end

# Best — pattern match so a non-boolean crashes instead of silently proceeding
case user_active do
  true  -> send_notification(user)
  false -> :ok
end
```

Reserve `&&`/`||`/`!` for Elixir-style optional-chaining where you deliberately want `nil`-handling. Use `and`/`or`/`not` when you want strict boolean semantics and a crash on non-booleans.

### 3. Complex `else` in `with`

`with/else` branches that re-wrap errors or add no information should be removed — let the original `{:error, _}` propagate.

```elixir
# Anti-pattern — else re-wraps errors identically, adding only noise
def create_order(attrs) do
  with {:ok, user}    <- fetch_user(attrs.user_id),
       {:ok, product} <- fetch_product(attrs.product_id),
       {:ok, order}   <- insert_order(user, product, attrs) do
    {:ok, order}
  else
    {:error, :not_found} -> {:error, :not_found}
    {:error, changeset}  -> {:error, changeset}
    error                -> error
  end
end

# Better — no else branch; errors pass through naturally
def create_order(attrs) do
  with {:ok, user}    <- fetch_user(attrs.user_id),
       {:ok, product} <- fetch_product(attrs.product_id) do
    insert_order(user, product, attrs)
  end
end
```

Only include an `else` block when you are actually transforming or discriminating errors — e.g. turning `{:error, :not_found}` from the user fetch into `{:error, :user_missing}` so the caller can distinguish which step failed.

### 4. Long parameter lists

Functions taking 5+ positional arguments become guessing games at call sites.

```elixir
# Anti-pattern
def create_booking(user, room, check_in, check_out, guests, notes, channel) do
  # ...
end

# Call site is unreadable:
create_booking(user, room, ~D[2026-05-01], ~D[2026-05-04], 2, "quiet room", :direct)

# Better — group related args into a struct or keyword list
def create_booking(user, %BookingParams{} = params) do
  # ...
end

# Or when arguments are genuinely optional:
def create_booking(user, room, opts \\ []) do
  check_in  = Keyword.fetch!(opts, :check_in)
  check_out = Keyword.fetch!(opts, :check_out)
  # ...
end
```

**Threshold:** 3-4 positional args is the practical ceiling. At 5+, refactor.

### 5. Working with invalid data

Functions that accept and silently pass through malformed data, deferring the crash to somewhere confusing.

```elixir
# Anti-pattern — accepts anything, crashes deep in string_length with a
# confusing ArgumentError far from the call site
def greet(user) do
  "Hello, " <> user.name <> " (#{String.length(user.bio)} chars bio)"
end

# Better — pattern match on what you require; crash early and clearly
def greet(%User{name: name, bio: bio}) when is_binary(name) and is_binary(bio) do
  "Hello, " <> name <> " (#{String.length(bio)} chars bio)"
end
```

The principle: fail at the earliest point where the mismatch is detectable. Later failures are harder to diagnose.

## Design anti-patterns

### 6. Boolean obsession

Using multiple booleans to encode state that is actually a single enum.

```elixir
# Anti-pattern — invalid combinations like draft=true + published=true
# are representable but meaningless
defstruct [:draft, :published, :archived]

# Better — single field with atom values
defstruct [status: :draft]  # :draft | :published | :archived
```

Pattern match on `%{status: :published}`, not on `%{published: true}`. Use `Ecto.Enum` on the schema side for the same reason.

### 7. Primitive obsession

Passing raw strings/integers when a struct would carry intent and catch mismatches.

```elixir
# Anti-pattern — any string can be passed where an email is expected
@spec send_welcome(String.t()) :: :ok
def send_welcome(email), do: Mailer.send(email, "Welcome!")

# Better — a validated struct makes the contract explicit and catches
# "I passed the user's name instead of email" at compile time (with dialyzer)
defmodule Email do
  @type t :: %__MODULE__{address: String.t()}
  defstruct [:address]
  def new(str) when is_binary(str), do: {:ok, %__MODULE__{address: str}}
end

@spec send_welcome(Email.t()) :: :ok
def send_welcome(%Email{} = email), do: Mailer.send(email.address, "Welcome!")
```

Don't over-apply this — for one-shot scripts it is overkill. For domain types that appear in many signatures (user IDs, tenant IDs, money amounts), a struct wrapper pays off.

### 8. Unrelated multi-clause function

Multiple function heads that share a name but have nothing in common semantically — they were combined because the name matched, not because the behavior belonged together.

```elixir
# Anti-pattern — "process" does unrelated things for each input type
def process(%User{} = u),  do: send_welcome_email(u)
def process(%Order{} = o), do: charge_card(o)
def process(%Log{} = l),   do: write_to_disk(l)

# Better — each operation has its own name
def send_welcome_email(%User{} = u), do: # ...
def charge_card(%Order{} = o),       do: # ...
def write_to_disk(%Log{} = l),       do: # ...
```

Multi-clause is idiomatic when clauses are variations of the **same** operation (different encoding, default argument handling, etc.). It is an anti-pattern when clauses are different operations wearing the same hat.

### 9. Using exceptions for control flow

Raising and rescuing for expected conditions. Elixir's `{:ok, _} / {:error, _}` tuples are the contract — bang versions exist for when the caller has already verified the input.

```elixir
# Anti-pattern — using try/rescue on Map.fetch!/2 as a way to check for key
try do
  value = Map.fetch!(config, :host)
  connect(value)
rescue
  KeyError -> {:error, :missing_host}
end

# Better — use the non-bang version that already returns a tuple
case Map.fetch(config, :host) do
  {:ok, host} -> connect(host)
  :error      -> {:error, :missing_host}
end
```

Reserve `rescue` for genuinely unexpected exceptions coming from libraries you do not control (e.g. a parser that raises on malformed input and has no non-raising variant).

## Process anti-patterns

### 10. Scattered process interface

A GenServer whose state is mutated from many places via direct `send/2` or scattered `GenServer.call/cast` sites, instead of through a single API module.

```elixir
# Anti-pattern — callers touch GenServer internals directly
GenServer.call(MyApp.Cache, {:get, :users})
GenServer.cast(MyApp.Cache, {:put, :users, value})
send(MyApp.Cache, :flush)

# Better — client API is the only allowed touchpoint
MyApp.Cache.get(:users)
MyApp.Cache.put(:users, value)
MyApp.Cache.flush()
```

The client API is the encapsulation boundary. It lets you refactor the message protocol (maybe split the cache into two GenServers, maybe back it with ETS) without touching every call site.

### 11. Sending large or unnecessary data between processes

Every message sent to another process is **copied** (except for binaries ≥64 bytes, which are reference-counted). Sending megabyte-sized terms between processes is a performance trap.

```elixir
# Anti-pattern — sends the entire user list over the wire on every call
def list_users, do: GenServer.call(UserCache, :list)

# Better — store in ETS, caller reads directly (zero-copy)
def list_users, do: :ets.tab2list(:user_cache)
```

For large read-heavy state, use an ETS table owned by the GenServer but read directly by callers. Writes still go through the GenServer; reads bypass it.

## Deprecated APIs and community migrations

Code that still compiles but uses deprecated or community-abandoned patterns. These are high-frequency in Claude's training data and worth checking on every review.

| Old (deprecated or community-abandoned) | New (Elixir 1.19 / Phoenix 1.8 era) |
|---|---|
| `Logger.warn/1,2` | `Logger.warning/1,2` |
| `use Mix.Config` in `config/*.exs` | `import Config` |
| `Supervisor.Spec` / `supervisor/2` / `worker/2` | Child spec tuples `{Module, opts}` in `Supervisor.init/2` |
| `Phoenix.View` + `lib/my_app_web/views/*_view.ex` | Function components + `lib/my_app_web/controllers/*_html.ex` (Phoenix 1.7+) |
| `@current_user` / `conn.assigns.current_user` | `@current_scope` / `conn.assigns.current_scope` (Phoenix 1.8+) |
| `root.html.heex` + `app.html.heex` nested layouts | Single root + `<Layouts.app>` function component (Phoenix 1.8) |
| `use Phoenix.LiveView, layout: {MyAppWeb.Layouts, :app}` | Explicit `<Layouts.app>` call inside each `render/1` |
| `HTTPoison` for new HTTP client code | `Req` (community standard since ~2023) |
| `:hackney` directly | `Finch` (HTTP/2, connection pooling, used by Req and Swoosh) |
| `Timex` for basic date arithmetic | Stdlib `DateTime`, `Date`, `Calendar` — covers most cases since Elixir 1.11 |
| `Poison` for JSON | `Jason` (faster, Phoenix default) or `JSON` (stdlib, Elixir 1.18+) |
| `ExMachina` factories | Hand-rolled fixture functions using `System.unique_integer()` — simpler, fewer deps |
| `Ecto.DateTime` / `Ecto.Date` / `Ecto.Time` | Stdlib `DateTime` / `Date` / `Time` (Ecto 3+) |
| `model` macro / `Ecto.Model` | `use Ecto.Schema` + `import Ecto.Changeset` |
| `Repo.all(from u in User, select: u)` wildcards | Explicit `select:` of only the fields used |
| `GenServer.call(pid, msg, :infinity)` for long calls | Break into async pattern: `call` returns `:accepted`, result arrives as `handle_info/2` |
| `Task.start/1` unsupervised | `Task.Supervisor.start_child/2` under a `Task.Supervisor` in the tree |
| `spawn/1` anywhere in application code | Should be rare; prefer `Task` / `GenServer` / supervised processes |
| `Enum.*` on potentially large query results | Push work into Ecto `select:` / `where:` / `group_by:`; stream with `Repo.stream/2` for huge sets |
| `String.to_atom/1` on any externally-sourced input | `String.to_existing_atom/1` or a whitelist map |
| `System.get_env("FOO")` at compile time in `config.exs` | `System.get_env/1` in `config/runtime.exs` (for releases) |
| `Application.get_env/2` reads in function bodies | Module-level `@config Application.compile_env(:my_app, :key)` or runtime config pattern |
| `use ExUnit.Case` without `async: true` by default | Default to `async: true`; opt out only when sharing global state |
| `setup_all` for DB fixtures | `setup` + sandbox checkout per test |
| `assert_receive msg` without timeout | `assert_receive msg, 200` — always specify a bound |

### HTTP client: why `Req` now

The Elixir community consolidated on `Req` around 2023. It is higher-level than `Finch` (which it uses under the hood), has retry/redirect/decode built in, and has largely replaced `HTTPoison` and `Tesla` for new code.

```elixir
# Old — HTTPoison
{:ok, %HTTPoison.Response{body: body}} =
  HTTPoison.get("https://api.example.com/users", [{"Accept", "application/json"}])
{:ok, data} = Jason.decode(body)

# New — Req
{:ok, %Req.Response{body: data}} =
  Req.get("https://api.example.com/users")
# Req auto-decodes JSON, handles retries, follows redirects
```

For existing projects using `HTTPoison`, don't migrate unless there's a reason — but don't introduce new `HTTPoison` calls in Phoenix 1.8+ projects.

### Configuration: `config/runtime.exs` for releases

Reading env vars in `config/config.exs` happens **at compile time** and bakes the value into the release. Reading in `config/runtime.exs` happens **at boot** — what you want for containerized deployments.

```elixir
# Wrong for releases — DATABASE_URL is baked in at compile time
# config/config.exs
config :my_app, MyApp.Repo, url: System.get_env("DATABASE_URL")

# Correct — read at runtime
# config/runtime.exs
if config_env() == :prod do
  config :my_app, MyApp.Repo,
    url: System.fetch_env!("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
end
```

`mix phx.new` generates `config/runtime.exs` correctly by default — hand-edited configs often drift. Check.

### Compile-time vs runtime `Application` reads

```elixir
# Anti-pattern — reads on every call, cannot be overridden for tests
# without Application.put_env races
def mailer, do: Application.get_env(:my_app, :mailer)

# Better — compile-time read, fixed for the life of the release
@mailer Application.compile_env!(:my_app, :mailer)
def mailer, do: @mailer

# Best for testable swap — pass via opts or read from process dictionary
# via the Mox/behaviour pattern (see testing.md)
```

## Review workflow for legacy code

When the user asks "review this" / "refactor this" / "make this idiomatic", walk the code in this order:

1. **Deprecated APIs** (table above). Flag every instance. Usually quick wins.
2. **`{:ok, _} / {:error, _}` consistency.** Functions returning mixed shapes or raising for expected errors.
3. **Assertiveness.** `map[:key]` where `.key` would do; `if var` where `var == true` would clarify; `try/rescue` around non-bang calls.
4. **Supervision.** Any `spawn`, `Task.start`, or GenServer `start_link` not under a supervisor.
5. **Scope.** (Phoenix 1.8+) Context functions missing `scope` first argument.
6. **N+1.** Ecto queries in a loop or missing preloads for data the view will access.
7. **Process misuse.** Large messages between processes; scattered `GenServer.call` call sites; state in `Agent` that has grown to justify a `GenServer`.
8. **Test gaps (MANDATORY — always check).** Does the code have tests? If not, call it out — do not deliver a refactor of untested code without flagging the test gap. Also check: `async: false` without a stated reason, `assert_receive` without a timeout bound, `setup_all` for mutable state, fixtures bypassing context validations, tests that call `handle_call/3` directly instead of client API.

Produce the refactor as a diff where possible — easier for the user to review than a full rewrite. **If the original code lacked tests, your response must either (a) offer to add tests as a follow-up, or (b) include tests alongside the refactor.** Leaving a refactored module untested is worse than leaving the original — new code is less trusted than known-shipped code.
