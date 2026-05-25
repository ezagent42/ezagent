# OTP Core (GenServer, Supervisor, Task, Agent, Registry, application structure)

This is the MVP anchor for the skill. Go deep here. Examples are full-module, not snippets, because OTP code is structural — you need to see the whole supervision tree and module to judge it.

**Target: Elixir 1.19+ / Erlang OTP 27+.** Elixir 1.19 added type inference across anonymous functions, protocol dispatch, and function captures (like `&String.to_integer/1`) — so stale `@spec`s or mismatched argument types will increasingly surface as compiler warnings. Lean into it: write accurate specs, trust the compiler to catch mistakes.

## Choosing an abstraction

Before writing a line, pick the right tool. Wrong choice here is the most common source of bad OTP code.

| Situation | Pick |
|---|---|
| No state, no long-running behavior, just transforms data | **Plain module + functions.** Do not reach for a process. |
| Short-lived async work (fire-and-forget OR awaited result) | **`Task` or `Task.Supervisor`** |
| Parallel async work over a collection with backpressure | **`Task.async_stream/3`** (under a `Task.Supervisor`) |
| Single long-lived stateful service (cache, rate limiter, connection pool front) | **`GenServer`** |
| A family of dynamically-spawned similar processes (one per user, per job, per connection) | **`DynamicSupervisor` + named/registered `GenServer`s** |
| Look up processes by name or key | **`Registry`** (often paired with `DynamicSupervisor`) |
| Simple mutable counter-ish state shared across callers | **`:counters` or `:atomics`** (faster than `Agent`); use `GenServer` only if complex |
| "I want shared mutable state" | Almost always **`GenServer`** — not `Agent`. `Agent` is a thin `GenServer` wrapper and its appeal is superficial. |
| Cross-process pub/sub | **`Phoenix.PubSub`** (see [realtime.md](realtime.md)) |
| In-memory key/value store with concurrent reads | **`:ets`** table owned by a `GenServer` |
| Periodic work inside a process | **`Process.send_after/3`** — do not spawn a separate Task for this |

**Rule of thumb:** start with a pure module. Only introduce a process when (a) state must outlive a function call, or (b) the work must happen concurrently with something else, or (c) you need supervision.

## GenServer — the workhorse

### Anatomy of a well-formed GenServer

```elixir
defmodule MyApp.RateLimiter do
  @moduledoc """
  Token-bucket rate limiter. One bucket per key, refilling at a fixed rate.
  """
  use GenServer

  @type key :: term()
  @type state :: %{
          buckets: %{key() => {tokens :: non_neg_integer(), last_refill_ms :: integer()}},
          capacity: pos_integer(),
          refill_per_sec: pos_integer()
        }

  # ── Client API ──

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec take(GenServer.server(), key(), pos_integer()) :: :ok | {:error, :rate_limited}
  def take(server \\ __MODULE__, key, n \\ 1) do
    GenServer.call(server, {:take, key, n})
  end

  # ── Server callbacks ──

  @impl true
  def init(opts) do
    state = %{
      buckets: %{},
      capacity: Keyword.fetch!(opts, :capacity),
      refill_per_sec: Keyword.fetch!(opts, :refill_per_sec)
    }
    {:ok, state}
  end

  @impl true
  def handle_call({:take, key, n}, _from, state) do
    {bucket, state} = get_or_init_bucket(state, key)
    {bucket, now} = refill(bucket, state)

    case bucket do
      {tokens, _} when tokens >= n ->
        new_bucket = {tokens - n, now}
        {:reply, :ok, put_in(state.buckets[key], new_bucket)}

      _ ->
        {:reply, {:error, :rate_limited}, put_in(state.buckets[key], bucket)}
    end
  end

  # ── Helpers ──

  defp get_or_init_bucket(state, key) do
    case Map.fetch(state.buckets, key) do
      {:ok, bucket} -> {bucket, state}
      :error ->
        bucket = {state.capacity, System.monotonic_time(:millisecond)}
        {bucket, put_in(state.buckets[key], bucket)}
    end
  end

  defp refill({tokens, last_ms}, %{capacity: cap, refill_per_sec: rate}) do
    now = System.monotonic_time(:millisecond)
    elapsed_sec = (now - last_ms) / 1_000
    refilled = min(cap, tokens + round(elapsed_sec * rate))
    {{refilled, now}, now}
  end
end
```

Things to notice:

- `use GenServer` at the top.
- Typespec for `state` — so you have a single source of truth for the state shape.
- Client API (`start_link/1`, `take/3`) above server callbacks. This is the idiomatic ordering.
- `@impl true` on every `init/1`, `handle_call/3`, `handle_cast/2`, `handle_info/2`, `terminate/2`, `code_change/3` that is implemented.
- State shape is a map (not a keyword list, not a bare tuple) for clarity and access ergonomics.
- Private helpers (`refill/2`) are pure functions — testable in isolation without spinning up the process.

### `handle_call` vs `handle_cast` vs `handle_info`

- **`call`**: synchronous, has a reply, has backpressure (the caller blocks until you reply). Default.
- **`cast`**: asynchronous, no reply, no backpressure. Use only when you truly want fire-and-forget AND the caller cannot recover from a crash anyway. Rare.
- **`info`**: for non-GenServer messages — `Process.send_after/3` self-sends, monitor `:DOWN` messages, `Phoenix.PubSub` broadcasts.

Default to `call`. Only downgrade to `cast` with a specific justification.

### Return tuples

- `{:reply, reply, new_state}` — most common from `handle_call/3`.
- `{:noreply, new_state}` — from `handle_cast/2` and `handle_info/2`; also from `handle_call/3` if replying later via `GenServer.reply/2`.
- `{:reply, reply, new_state, timeout}` — sends self a `:timeout` message after `timeout` ms of inactivity.
- `{:noreply, new_state, :hibernate}` — GC and compact before waiting for the next message. Use for processes with long idle periods and large state.
- `{:stop, reason, new_state}` — clean shutdown.

### Timeouts and hibernate

```elixir
@impl true
def handle_call(:work, _from, state) do
  {:reply, :ok, state, :hibernate}
end

@impl true
def handle_info(:timeout, state) do
  # self-triggered after inactivity
  {:noreply, cleanup(state)}
end
```

Use hibernate for GenServers that spike in memory and then idle (e.g. a process that builds a large intermediate structure, replies, then sits idle).

### Periodic work

Do not spin up a separate Task. Self-message:

```elixir
@impl true
def init(_) do
  schedule_tick()
  {:ok, %{}}
end

@impl true
def handle_info(:tick, state) do
  schedule_tick()
  {:noreply, do_work(state)}
end

defp schedule_tick, do: Process.send_after(self(), :tick, :timer.minutes(5))
```

### Naming

- **Local name** (`name: __MODULE__` or an atom): there is exactly one of this process in the node. Good for singletons.
- **`{:global, name}`**: distributed Erlang only; avoid unless you are running multi-node.
- **`{:via, Registry, {MyApp.Registry, key}}`**: when you want many dynamic instances, each looked up by key. See Registry below.

## Supervisor — the structural layer

A `Supervisor` starts, watches, and restarts child processes according to a strategy. Every long-lived process in an Elixir app sits under a supervisor. No exceptions.

### Child spec

```elixir
defmodule MyApp.Workers.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {MyApp.RateLimiter, capacity: 100, refill_per_sec: 10},
      {DynamicSupervisor, strategy: :one_for_one, name: MyApp.JobSup},
      {Registry, keys: :unique, name: MyApp.JobRegistry},
      MyApp.Scheduler
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

### Strategies

- **`:one_for_one`** (default): if a child crashes, restart just that child. Use when children are independent.
- **`:one_for_all`**: if any child crashes, restart all of them. Use when children have a shared lifecycle (e.g. they share ETS tables created by the first child).
- **`:rest_for_one`**: if a child crashes, restart it and everything started after it. Use when later children depend on earlier ones.

Default is `:one_for_one`. If you pick something else, the PR review will ask why — be prepared.

### Restart types

- **`:permanent`** (default): always restart.
- **`:transient`**: restart only if the child exits with a non-`:normal` reason.
- **`:temporary`**: never restart. Common for `Task` under `Task.Supervisor`.

### Max restart intensity

Default: 3 restarts in 5 seconds. If exceeded, the supervisor itself crashes (bubbling up). Tune with `max_restarts` and `max_seconds` in `Supervisor.init/2`. Do not tune these upward to "make things stable" — that hides bugs. Fix the crash instead.

## DynamicSupervisor — for on-demand children

Use when the set of children is not known at startup: one worker per active user, one connection per client, one job per queued task.

```elixir
# In the top-level supervision tree:
{DynamicSupervisor, strategy: :one_for_one, name: MyApp.JobSup}

# Starting a child on demand:
DynamicSupervisor.start_child(MyApp.JobSup, {MyApp.Job, job_id: 42})
```

Pair with a `Registry` so the child can be found later by key.

## Registry — process lookup by key

```elixir
# In the supervision tree:
{Registry, keys: :unique, name: MyApp.JobRegistry}

# In the worker's start_link:
def start_link(opts) do
  job_id = Keyword.fetch!(opts, :job_id)
  GenServer.start_link(__MODULE__, opts, name: via(job_id))
end

defp via(job_id), do: {:via, Registry, {MyApp.JobRegistry, job_id}}

# Calling it by key from anywhere:
def status(job_id), do: GenServer.call(via(job_id), :status)
defp via(job_id), do: {:via, Registry, {MyApp.JobRegistry, job_id}}
```

Keys can be `:unique` (one process per key) or `:duplicate` (many). Use `:duplicate` when Registry is being used as a pub/sub fan-out list — but most of the time, `Phoenix.PubSub` is better for that.

For high-concurrency registry access, set `partitions: System.schedulers_online()`.

## Task — short-lived async work

```elixir
# Fire-and-forget, not supervised (don't do this in production — no supervision):
Task.start(fn -> send_email(user) end)

# Awaited result, linked to caller:
task = Task.async(fn -> fetch(url) end)
result = Task.await(task, 5_000)

# Supervised fire-and-forget (do this instead):
Task.Supervisor.start_child(MyApp.TaskSup, fn -> send_email(user) end)

# Supervised async with result:
task = Task.Supervisor.async(MyApp.TaskSup, fn -> fetch(url) end)
Task.await(task)
```

### `Task.async_stream/3` — parallel map with backpressure

```elixir
ids
|> Task.async_stream(fn id -> fetch(id) end,
     max_concurrency: 10,
     timeout: 5_000,
     on_timeout: :kill_task)
|> Enum.to_list()
```

This is the right way to do "fetch N things in parallel". Do not spawn N `Task.async` calls and await them in a list comprehension — you lose backpressure and timeouts are awkward.

## Agent — usually the wrong choice

`Agent` looks simpler than `GenServer` but hides the message protocol, which makes reasoning harder. Unless the task is literally "a mutable cell of data with `get` and `update`", prefer `GenServer` — you will end up adding custom operations anyway, and switching from `Agent` to `GenServer` mid-development is friction you can avoid.

Legit uses of `Agent`: a tiny singleton configuration holder, a feature flag cache.

## Process linking and monitoring

- **Link (`Process.link/1` or `spawn_link/1`):** bidirectional. If either process crashes, the other also exits — unless it traps exits. Supervisors link their children.
- **Monitor (`Process.monitor/1`):** unidirectional. You receive a `{:DOWN, ref, :process, pid, reason}` message if the target exits.

As a GenServer, you should almost always **monitor**, not **link**, processes you spawn on behalf of clients — otherwise a client's bad input can crash your GenServer.

Handle `:DOWN`:

```elixir
@impl true
def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
  # clean up tracking for the monitored process
  {:noreply, handle_down(state, ref, reason)}
end
```

### Trap exits

`Process.flag(:trap_exit, true)` in `init/1` converts linked exits into `{:EXIT, from, reason}` messages. Use sparingly — it makes the process "sticky" and harder to crash cleanly. Supervisors trap exits internally; you rarely need to.

## Application callback module

Every Mix project has an `application/0` entry in `mix.exs` pointing to a module with `use Application`:

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MyApp.Repo,
      {Phoenix.PubSub, name: MyApp.PubSub},
      {Registry, keys: :unique, name: MyApp.JobRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: MyApp.JobSup},
      MyAppWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    MyAppWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
```

**Child order matters.** Children start in order and stop in reverse order. Dependencies come before dependents: `Repo` before anything that queries it; `PubSub` before anything that subscribes.

## Umbrella vs poncho vs single app

- **Single app:** default. Start here. One `mix.exs`, one `lib/`, one supervision tree. Almost all projects stay here forever.
- **Umbrella (`mix new myapp --umbrella`):** multiple apps under `apps/`, shared deps lock, each app can be compiled/released independently. Good for clearly separable bounded contexts. Also adds ceremony — dep management gets fiddly. Not a substitute for good module boundaries.
- **Poncho:** top-level project containing multiple independent Mix projects referenced via `path:` deps. Less tooling support than umbrella; more flexibility.

**Default to single app.** Move to umbrella only when boundaries are genuinely enforced by team separation or deploy independence, not for code organization reasons — Contexts already solve that within a single app.

## Telemetry basics

Emit telemetry events for observability. Do not manually build metrics pipelines.

```elixir
:telemetry.execute(
  [:my_app, :rate_limiter, :take],
  %{count: 1, duration: duration_us},
  %{key: key, result: result}
)
```

Consumers (Phoenix LiveDashboard, Prometheus exporters, custom handlers) subscribe to these events. The convention is `[:app, :component, :action]` for the event name, `%{measurements}` for numbers, `%{metadata}` for tags/dimensions.

Phoenix, Ecto, Oban, and most modern libraries emit telemetry by default — hook into their events rather than instrumenting the call sites yourself.

## Debugging running processes

In `iex` attached to a running node:

```elixir
# Inspect GenServer state without disturbing it:
:sys.get_state(MyApp.RateLimiter)

# Get a full process snapshot:
Process.info(pid)

# Watch messages flowing to a process:
:sys.trace(MyApp.RateLimiter, true)

# Memory and reductions across all processes:
:observer.start()
```

`:sys.get_state/1` and `:sys.trace/2` are sanctioned OTP tools — they go through the process's internal message loop and will not race. Never peek at state via private mechanisms.

## Common patterns

### Worker pool

Use `:poolboy` or `NimblePool` — do not hand-roll. Both are battle-tested and handle checkout/checkin with timeouts.

### Circuit breaker

Use `:fuse` or `ex_fuse`. Hand-rolling a circuit breaker is a classic yak-shave.

### Rate limiter

For in-process, the GenServer above is fine. For cross-node, use `Hammer` or a Redis-backed scheme.

### Caching

- **Short-lived, single-node:** `Cachex` or a `GenServer` with an ETS table.
- **Distributed:** `Nebulex` with a Redis/Memcached adapter.
- **Request-scoped:** `Process` dictionary is acceptable for memoizing within a single request (e.g. in a Plug); do not use it for longer-lived state.

## Gotchas that bite

- **`init/1` blocking:** anything that takes time (DB migrations, network calls) in `init/1` blocks the supervisor. Use `handle_continue/2` for post-init work:
  ```elixir
  @impl true
  def init(opts) do
    {:ok, %{opts: opts}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    data = expensive_load()
    {:noreply, Map.put(state, :data, data)}
  end
  ```
- **GenServer mailbox backpressure:** if producers call faster than the GenServer can process, the mailbox grows unboundedly → memory blowup and eventual crash. Solutions: use `GenStage` / `Flow` / `Broadway` for backpressured pipelines, or measure mailbox size and drop.
- **Hot code reload + state shape change:** if you change state shape, old state will crash on the new code. Implement `code_change/3` or rely on full restart. For production, prefer restart via releases.
- **Named process collisions in tests:** using `name: __MODULE__` means tests cannot run `async: true` against the same module. Use `start_supervised/1` without a name, or generate unique names per test.
