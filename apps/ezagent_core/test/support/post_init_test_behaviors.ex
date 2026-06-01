defmodule Ezagent.TestSupport.OrderTracker do
  @moduledoc """
  Tiny `Agent`-style tracker that records boot-order events in arrival
  order. Used by `Ezagent.Kind.ServerPostInitTest` to assert that
  `:announce_ready` ALWAYS fires before any post-init
  `handle_continue/3` callback (the boot-order invariant introduced
  by PR-EM-CORE).

  Storage is a per-process `:ets` set named via `start_link/1`'s
  caller pid so multiple tests can run concurrently without cross-talk.
  """

  use Agent

  @spec start_link(any()) :: Agent.on_start()
  def start_link(_), do: Agent.start_link(fn -> [] end)

  @spec record(pid(), term()) :: :ok
  def record(tracker, event) when is_pid(tracker) do
    Agent.update(tracker, fn events -> [event | events] end)
  end

  @spec events(pid()) :: [term()]
  def events(tracker) when is_pid(tracker) do
    Agent.get(tracker, fn events -> Enum.reverse(events) end)
  end
end

defmodule Ezagent.TestSupport.PostInitBehavior do
  @moduledoc """
  Test-only Behavior exercising the PR-EM-CORE post-init continuation
  hook. Returns `{:continue, :setup_thing}` from `post_init/2` and
  flips `slice[:setup_done] = true` in `handle_continue/3`. Both
  callbacks record their invocation to the `OrderTracker` (when one
  is supplied via `args[:tracker]`) so tests can assert ordering
  vs `:announce_ready`.

  Migrated to new-contract `use Ezagent.Behavior` as part of Phase 3
  r3 (2026-05-28) — `:noop` is a degenerate `{:ok, slice}` action so
  the new handler simply returns no effects.
  """

  use Ezagent.Behavior
  @behaviour Ezagent.Behavior

  action :noop,
    args: %{},
    returns: %{},
    modes: [:call],
    description: "test — no-op"

  @impl Ezagent.Behavior
  def state_slice, do: :post_init_behavior

  @impl Ezagent.Behavior
  def init_slice(args) do
    %{
      tracker: Map.get(args, :tracker),
      setup_done: false,
      continued_with: nil
    }
  end

  def handle_noop(_args, _ctx), do: {:ok, %{}, []}

  @impl Ezagent.Behavior
  def post_init(_args, _slice), do: {:continue, :setup_thing}

  @impl Ezagent.Behavior
  def handle_continue(:setup_thing, slice, %{self_uri: uri}) do
    if tracker = slice[:tracker] do
      # Observe the ReadyGate status + KindRegistry lookup AT THE
      # MOMENT the post-init continuation fires. Per codex round-2
      # HIGH-1 fix, the Kind is registered but stays `:not_ready`
      # through the entire post-init phase — `:ready` only flips
      # AFTER the last post-init continuation completes. The
      # safe-publish invariant the test asserts is: by the time
      # `:ready` is observable to outside dispatchers, the URI is
      # already registered AND every post-init `handle_continue/3`
      # has run + been merged into state.
      ready_status = Ezagent.ReadyGate.status(uri)
      registered? = match?({:ok, _}, Ezagent.KindRegistry.lookup(uri))

      Ezagent.TestSupport.OrderTracker.record(
        tracker,
        {:post_init, ready_status, registered?}
      )
    end

    {:ok, %{slice | setup_done: true, continued_with: :setup_thing}}
  end
end

defmodule Ezagent.TestSupport.PostInitBehaviorA do
  @moduledoc """
  First of two ordered post-init Behaviors used by Test 3 (multi-Behavior
  ordering). Records `:post_init_a` on the shared tracker.
  """

  use Ezagent.Behavior
  @behaviour Ezagent.Behavior

  action :noop,
    args: %{},
    returns: %{},
    modes: [:call],
    description: "test — no-op"

  @impl Ezagent.Behavior
  def state_slice, do: :post_init_a

  @impl Ezagent.Behavior
  def init_slice(args), do: %{tracker: Map.get(args, :tracker), ran: false}

  def handle_noop(_args, _ctx), do: {:ok, %{}, []}

  @impl Ezagent.Behavior
  def post_init(_args, _slice), do: {:continue, :run_a}

  @impl Ezagent.Behavior
  def handle_continue(:run_a, slice, _ctx) do
    if tracker = slice[:tracker],
      do: Ezagent.TestSupport.OrderTracker.record(tracker, :post_init_a)

    {:ok, %{slice | ran: true}}
  end
end

defmodule Ezagent.TestSupport.PostInitBehaviorB do
  @moduledoc """
  Second of two ordered post-init Behaviors used by Test 3. Records
  `:post_init_b` on the shared tracker. Together with `PostInitBehaviorA`
  this asserts the per-Behavior post-init continuations run in
  `Kind.behaviors/0` declaration order.
  """

  use Ezagent.Behavior
  @behaviour Ezagent.Behavior

  action :noop,
    args: %{},
    returns: %{},
    modes: [:call],
    description: "test — no-op"

  @impl Ezagent.Behavior
  def state_slice, do: :post_init_b

  @impl Ezagent.Behavior
  def init_slice(args), do: %{tracker: Map.get(args, :tracker), ran: false}

  def handle_noop(_args, _ctx), do: {:ok, %{}, []}

  @impl Ezagent.Behavior
  def post_init(_args, _slice), do: {:continue, :run_b}

  @impl Ezagent.Behavior
  def handle_continue(:run_b, slice, _ctx) do
    if tracker = slice[:tracker],
      do: Ezagent.TestSupport.OrderTracker.record(tracker, :post_init_b)

    {:ok, %{slice | ran: true}}
  end
end

defmodule Ezagent.TestSupport.NoPostInitBehavior do
  @moduledoc """
  Backwards-compat fixture used by Test 2 — a Behavior that does NOT
  declare `post_init/2` or `handle_continue/3`. Spawning a Kind that
  hosts only this Behavior must succeed with no extra continuation
  noise.
  """

  use Ezagent.Behavior
  @behaviour Ezagent.Behavior

  action :noop,
    args: %{},
    returns: %{},
    modes: [:call],
    description: "test — no-op"

  @impl Ezagent.Behavior
  def state_slice, do: :no_post_init

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{baseline: :ok, count: 0}

  def handle_noop(_args, _ctx), do: {:ok, %{}, []}
end

defmodule Ezagent.TestSupport.PostInitKind do
  @moduledoc "Kind hosting a single post-init Behavior (Test 1)."
  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :test

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.TestSupport.PostInitBehavior]

  @impl Ezagent.Kind
  def persistence, do: :ephemeral
end

defmodule Ezagent.TestSupport.PostInitCrashBehavior do
  @moduledoc """
  Test-only Behavior whose `handle_continue/3` raises. Used by the
  codex round-1 HIGH-1 regression test: a pre-ready buffered cast
  combined with a crashing post-init MUST NOT lose the buffered
  cast (the buffer must still be intact after the crash, since the
  fix defers `PendingDelivery.flush/1` until AFTER post-init).
  """

  use Ezagent.Behavior
  @behaviour Ezagent.Behavior

  action :noop,
    args: %{},
    returns: %{},
    modes: [:call],
    description: "test — no-op"

  @impl Ezagent.Behavior
  def state_slice, do: :crash

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{}

  def handle_noop(_args, _ctx), do: {:ok, %{}, []}

  @impl Ezagent.Behavior
  def post_init(_args, _slice), do: {:continue, :will_crash}

  @impl Ezagent.Behavior
  def handle_continue(:will_crash, _slice, _ctx), do: raise("boom from post_init")
end

defmodule Ezagent.TestSupport.PostInitCrashKind do
  @moduledoc "Kind hosting the crashing post-init Behavior (regression test)."
  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :test

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.TestSupport.PostInitCrashBehavior]

  @impl Ezagent.Kind
  def persistence, do: :ephemeral
end

defmodule Ezagent.TestSupport.PersistentPostInitBehavior do
  @moduledoc """
  Test-only Behavior whose post-init `handle_continue/3` mutates its
  slice with a sentinel field — used by the codex round-1 MEDIUM-1
  regression test (a `{:snapshot, :on_change}` Kind hosting this
  Behavior must have the post-init mutation durably snapshotted, NOT
  just held in memory).
  """

  use Ezagent.Behavior
  @behaviour Ezagent.Behavior

  action :noop,
    args: %{},
    returns: %{},
    modes: [:call],
    description: "test — no-op"

  @impl Ezagent.Behavior
  def state_slice, do: :persistent

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{post_init_value: nil, init_value: :from_init_slice}

  def handle_noop(_args, _ctx), do: {:ok, %{}, []}

  @impl Ezagent.Behavior
  def post_init(_args, _slice), do: {:continue, :write_sentinel}

  @impl Ezagent.Behavior
  def handle_continue(:write_sentinel, slice, _ctx) do
    {:ok, %{slice | post_init_value: :written_by_post_init}}
  end
end

defmodule Ezagent.TestSupport.SlowPostInitBehavior do
  @moduledoc """
  Test-only Behavior whose `handle_continue/3` sleeps for a
  configurable duration before returning — used to exercise the
  round-2 HIGH-1 fix from the dispatcher side: while post-init is
  running, an external `Ezagent.Invocation.dispatch/1` MUST see
  `ReadyGate.status == :not_ready` and buffer the cast (or
  fail-fast for :call) — NOT deliver into a mailbox that could
  die with a crashing post-init.

  Sleep duration is read from `args[:post_init_sleep_ms]`
  (default 50ms — enough for the test to issue a dispatch).
  """

  use Ezagent.Behavior
  @behaviour Ezagent.Behavior

  action :noop,
    args: %{msg: :string},
    returns: %{echoed: :string},
    modes: [:call, :cast],
    description: "test — no-op"

  @impl Ezagent.Behavior
  def state_slice, do: :slow

  @impl Ezagent.Behavior
  def init_slice(args) do
    %{
      sleep_ms: Map.get(args, :post_init_sleep_ms, 50),
      tracker: Map.get(args, :tracker),
      msgs: []
    }
  end

  def handle_noop(%{msg: msg}, ctx) do
    msgs = ctx[:read].(:msgs, [])

    {:ok, %{echoed: msg},
     [
       {:set, :msgs, msgs ++ [msg]}
     ]}
  end

  @impl Ezagent.Behavior
  def post_init(_args, _slice), do: {:continue, :sleep_then_return}

  @impl Ezagent.Behavior
  def handle_continue(:sleep_then_return, slice, _ctx) do
    Process.sleep(slice.sleep_ms)
    {:ok, slice}
  end
end

defmodule Ezagent.TestSupport.SlowPostInitKind do
  @moduledoc "Kind hosting SlowPostInitBehavior."
  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :test

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.TestSupport.SlowPostInitBehavior]

  @impl Ezagent.Kind
  def persistence, do: :ephemeral
end

defmodule Ezagent.TestSupport.PersistentPostInitKind do
  @moduledoc """
  Kind with `{:snapshot, :on_change}` persistence policy hosting a
  Behavior that mutates its slice in `handle_continue/3`. Used to
  prove post-init writes are durably snapshotted (codex round-1
  MEDIUM-1 regression).
  """
  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :test

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.TestSupport.PersistentPostInitBehavior]

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}
end

defmodule Ezagent.TestSupport.NoPostInitKind do
  @moduledoc "Kind hosting a Behavior with no `post_init/2` (Test 2)."
  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :test

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.TestSupport.NoPostInitBehavior]

  @impl Ezagent.Kind
  def persistence, do: :ephemeral
end

defmodule Ezagent.TestSupport.MultiPostInitKind do
  @moduledoc """
  Kind hosting two post-init Behaviors (Test 3). Declaration order is
  `[A, B]` — the per-Behavior continuation order MUST match.
  """
  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :test

  @impl Ezagent.Kind
  def behaviors,
    do: [
      Ezagent.TestSupport.PostInitBehaviorA,
      Ezagent.TestSupport.PostInitBehaviorB
    ]

  @impl Ezagent.Kind
  def persistence, do: :ephemeral
end
