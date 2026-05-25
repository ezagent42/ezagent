# Testing (ExUnit, Doctest, Mox, StreamData, LiveViewTest, ChannelTest)

Tests are part of every code generation. This file covers the patterns that keep test suites fast, clear, and maintainable.

## The ExUnit essentials

### Module structure

```elixir
defmodule MyApp.AccountsTest do
  use MyApp.DataCase, async: true

  alias MyApp.Accounts

  doctest MyApp.Accounts  # runs all iex> examples in the module's docs

  describe "create_user/1" do
    test "succeeds with valid attrs" do
      assert {:ok, user} = Accounts.create_user(%{email: "a@b.c", password: "secret12chars!"})
      assert user.email == "a@b.c"
    end

    test "returns changeset error for invalid email" do
      assert {:error, cs} = Accounts.create_user(%{email: "nope", password: "secret12chars!"})
      assert %{email: ["has invalid format"]} = errors_on(cs)
    end
  end

  describe "list_users/1" do
    setup do
      [alice: user_fixture(email: "alice@x.com"), bob: user_fixture(email: "bob@x.com")]
    end

    test "filters by email substring", %{alice: alice} do
      assert [^alice] = Accounts.list_users(%{"email" => "alice"})
    end
  end
end
```

Rules:

- **`async: true`** whenever the test does not touch global state. Async tests run in parallel and dramatically cut suite time.
- **`describe "function_name/arity"`** — one block per public function under test. Makes failures read cleanly ("AccountsTest.create_user/1: succeeds with valid attrs").
- **`doctest Module`** at the top — runs all `iex>` examples in the module's `@doc` blocks as tests.
- **Fixtures** (`user_fixture/1`) live in `test/support/fixtures/` and are imported by the `DataCase`.

### Assertions

- `assert {:ok, value} = call(...)` — binds and asserts in one line. Preferred over storing and re-asserting.
- `assert_raise ExpectedError, fn -> ... end` — for functions that raise.
- `assert_receive message, 100` — for processes that should receive a message within 100ms.
- `refute_receive message, 100` — for processes that should NOT receive a message within 100ms. **Always bound with a timeout** — default is 100ms; longer slows down the suite, shorter risks flaky false negatives.
- Pattern matching in assertions: `assert %{id: id, email: "a@b.c"} = user` — gives clear diff output on failure.

### `setup` vs `setup_all`

- **`setup`**: runs before each test. Use for per-test fixtures, sandbox checkout, test-specific state.
- **`setup_all`**: runs once per describe/module. Use for expensive static data. Rare — most setups should be per-test.

## Doctests

Doctest turns your `@doc` examples into tests:

```elixir
@doc """
Adds two numbers.

    iex> MyApp.Math.add(2, 3)
    5

    iex> MyApp.Math.add(-1, 1)
    0
"""
def add(a, b), do: a + b
```

Then in the test file:

```elixir
doctest MyApp.Math
```

### When doctests work well

- Pure functions with clear input → output.
- Small, self-contained examples that double as documentation.
- Functions where showing the call is better documentation than prose.

### When to skip doctests

- Side-effecting functions (DB writes, HTTP calls, PubSub broadcasts).
- Functions whose output includes non-deterministic values (timestamps, UUIDs, PIDs).
- Long multi-line setup — that belongs in a regular test.

### Non-deterministic output in doctests

Use `iex(n)>` to suppress output, or match on structure with `#PID<...>` placeholders:

```elixir
@doc """
    iex> {:ok, pid} = MyApp.Cache.start_link([])
    iex> is_pid(pid)
    true
"""
```

## The Phoenix test cases

Phoenix generates three base cases — use them instead of rolling your own:

- **`MyApp.DataCase`** — for Ecto tests. Handles sandbox checkout and provides `errors_on/1` helper.
- **`MyAppWeb.ConnCase`** — for controller tests. Provides `build_conn/0` and sandbox support.
- **`MyAppWeb.ChannelCase`** — for channel tests. Provides `connect/2` and `subscribe_and_join/2`.

If a test suite grows its own boilerplate (repeated imports, setup), add it to the relevant case module.

## Testing GenServers

Test through the **client API**, not the server callbacks directly:

```elixir
defmodule MyApp.RateLimiterTest do
  use ExUnit.Case, async: true

  alias MyApp.RateLimiter

  setup do
    # start_supervised/1 auto-terminates after the test
    pid = start_supervised!({RateLimiter, capacity: 3, refill_per_sec: 1, name: nil})
    %{limiter: pid}
  end

  test "allows requests up to capacity", %{limiter: limiter} do
    for _ <- 1..3, do: assert :ok = RateLimiter.take(limiter, :user_1)
    assert {:error, :rate_limited} = RateLimiter.take(limiter, :user_1)
  end
end
```

Key points:

- **`start_supervised!/1`** — starts the process under the test supervisor. Auto-cleaned at test end. Preferred over `start_link` directly.
- **`name: nil`** — skip the name to allow `async: true`. The returned PID is passed to the API.
- **Assert via the public API** — never call `GenServer.call(pid, {:internal_message, ...})` in a test.

### Testing processes that send messages to callers

```elixir
test "broadcasts :message_created on insert" do
  Phoenix.PubSub.subscribe(MyApp.PubSub, "room:42")
  {:ok, msg} = Rooms.create_message(%{room_id: 42, body: "hi"})
  assert_receive {:message_created, ^msg}, 200
end
```

## Testing LiveView

```elixir
defmodule MyAppWeb.RoomLiveTest do
  use MyAppWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "renders messages and allows posting", %{conn: conn} do
    room = room_fixture()
    {:ok, view, html} = live(conn, ~p"/rooms/#{room}")

    assert html =~ room.name

    # Submit the form
    assert view
           |> form("form", message: %{body: "hello"})
           |> render_submit()

    # After PubSub broadcast arrives back to the LiveView:
    assert render(view) =~ "hello"
  end

  test "clicking delete removes the message", %{conn: conn} do
    room = room_fixture()
    msg = message_fixture(room: room)
    {:ok, view, _html} = live(conn, ~p"/rooms/#{room}")

    view |> element("#msg-#{msg.id} button[phx-click=delete]") |> render_click()
    refute render(view) =~ msg.body
  end
end
```

Key APIs:

- **`live/2`** — mounts the LiveView and returns `{:ok, view, html}`.
- **`render_click/1`, `render_submit/1`, `render_change/2`, `render_hook/3`** — simulate events.
- **`element/2` and `form/3`** — target specific elements by selector.
- **`push_patch/2`, `push_navigate/2`** — test navigation.

### Presence in LiveView tests

Presence updates are asynchronous. Give them time:

```elixir
{:ok, view, _html} = live(conn, ~p"/rooms/42")
Process.sleep(50)  # let presence propagate
assert render(view) =~ "Alice"
```

Alternatively, subscribe to PubSub in the test and `assert_receive` on presence messages.

## Testing Channels

```elixir
defmodule MyAppWeb.RoomChannelTest do
  use MyAppWeb.ChannelCase, async: true

  alias MyAppWeb.{UserSocket, RoomChannel}

  setup do
    user = user_fixture()
    {:ok, _, socket} =
      UserSocket
      |> socket("user_socket:#{user.id}", %{user_id: user.id})
      |> subscribe_and_join(RoomChannel, "room:42")

    %{socket: socket, user: user}
  end

  test "new_message broadcasts to joined clients", %{socket: socket} do
    push(socket, "new_message", %{"body" => "hello"})
    assert_broadcast "new_message", %{body: "hello"}
  end

  test "replies with error for empty body", %{socket: socket} do
    ref = push(socket, "new_message", %{"body" => ""})
    assert_reply ref, :error, %{errors: %{body: ["can't be blank"]}}
  end
end
```

Key APIs:

- **`socket/3`** — builds a socket with assigns.
- **`subscribe_and_join/3`** — joins the channel, returning the joined socket.
- **`push/3`** — simulate client message.
- **`assert_broadcast/2`, `assert_push/2`, `assert_reply/3`** — match outgoing messages.

## Mox — mocking behaviours

For external services (HTTP clients, third-party APIs, email senders), do not mock the library directly. Define a behaviour, use it in production, mock it in tests.

```elixir
# Define the behaviour
defmodule MyApp.Mailer do
  @callback send_welcome(user :: map()) :: :ok | {:error, term()}
end

# Production implementation
defmodule MyApp.Mailer.Swoosh do
  @behaviour MyApp.Mailer
  @impl true
  def send_welcome(user), do: # ...real implementation
end

# In config:
config :my_app, :mailer, MyApp.Mailer.Swoosh

# In config/test.exs:
config :my_app, :mailer, MyApp.MailerMock

# In test/support:
Mox.defmock(MyApp.MailerMock, for: MyApp.Mailer)

# In the test:
import Mox
setup :verify_on_exit!

test "sends welcome email on registration" do
  expect(MyApp.MailerMock, :send_welcome, fn %{email: "a@b.c"} -> :ok end)
  {:ok, _user} = Accounts.register_user(%{email: "a@b.c", ...})
end
```

- **`expect/3`** — this call must happen exactly once with matching args.
- **`stub/3`** — may be called any number of times (including zero).
- **`verify_on_exit!`** — fails the test if `expect`ed calls did not happen.

This pattern keeps tests hermetic and fast without coupling to the specific mailer library.

## StreamData — property-based testing

For code with invariants that matter more than examples — parsers, serializers, round-trip encoders:

```elixir
use ExUnitProperties

property "encode and decode round-trip" do
  check all data <- term() do
    encoded = MyApp.Serializer.encode(data)
    assert {:ok, ^data} = MyApp.Serializer.decode(encoded)
  end
end
```

Built-in generators: `integer/0`, `string/1`, `list_of/1`, `map_of/2`, etc. Combine with `StreamData.bind/2` for custom structures.

Use property tests to complement example-based tests, not replace them. Examples pin down specific behaviors; properties pin down invariants.

## `capture_log` and `capture_io`

```elixir
import ExUnit.CaptureLog

test "logs a warning on retry" do
  log = capture_log(fn -> MyApp.Client.fetch_with_retry("bad-url") end)
  assert log =~ "retrying"
end
```

Essential for:

- Asserting on log output without polluting test output.
- Keeping the test console clean when the code under test logs intentionally.

Similarly `capture_io/1` for `IO.puts` / `IO.inspect`.

## Async gotchas

`async: true` gives you parallelism but requires test isolation:

1. **Named processes** — `name: __MODULE__` means only one instance per node. Two async tests both trying to start the process will conflict. Fix: omit the name, pass the PID to the API.
2. **Application env** — `Application.put_env/3` is global. If two tests change the same key concurrently, they will fight. Fix: wrap the code under test in a helper that takes the config as an argument; or mark those tests `async: false`.
3. **ETS tables with fixed names** — same issue. Use unique names or owned tables.
4. **Shared mocks** — Mox has `allow/3` for cross-process use, but by default mocks are private to the test process. If the code under test runs in a spawned process (e.g. a GenServer), use `Mox.allow/3` to share the mock.
5. **Database sandbox in `:shared` mode** — forces `async: false` because the connection is shared across processes. For tests that cross process boundaries (LiveView, Channel), this is usually necessary.

## Factories

Prefer simple fixture functions over factory libraries (ExMachina is fine, but rarely needed):

```elixir
# test/support/fixtures/accounts_fixtures.ex
defmodule MyApp.AccountsFixtures do
  def user_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{
      email: "user#{System.unique_integer()}@example.com",
      password: "valid-password-123"
    })

    {:ok, user} = MyApp.Accounts.register_user(attrs)
    user
  end
end
```

- **`System.unique_integer()`** for uniqueness — avoids collisions in async tests.
- **Go through the public API** (`register_user/1`) rather than direct `Repo.insert` — catches regressions in the context code.
- **Provide sensible defaults**, let the caller override via `attrs`.

## Coverage

```bash
mix test --cover
```

For richer reports, add `{:excoveralls, "~> 0.18", only: :test}` and run `mix coveralls.html`. Aim for meaningful coverage, not a number — a context with 100% coverage and no error-case tests is worse than 70% that tests the unhappy path.

## Pitfalls in testing

1. **Testing `handle_call/3` directly** instead of the client API — couples tests to internals.
2. **Shared setup bleeding across tests** — `setup_all` for mutable state causes flakes.
3. **`assert_receive` without a timeout bound** — flaky on CI.
4. **Mocking the HTTP library** (`:hackney`, `Finch`) instead of defining a behaviour — couples tests to the client.
5. **Tests that depend on wall-clock time or sleep to coordinate** — flaky. Use `assert_receive` with a message instead.
6. **Not using `start_supervised/1`** — manual `start_link + GenServer.stop` is more to maintain and can leak on test failure.
7. **`async: true` with named processes or shared ETS** — intermittent collisions.
8. **One giant `test` block** — split into small focused tests, each asserting one behavior.
9. **Fixture factories that do `Repo.insert` directly** — bypass context validations, so changesets do not catch regressions.
10. **Doctests on side-effecting or non-deterministic functions** — brittle, noisy.
