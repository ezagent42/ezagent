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
  """

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:noop]

  @impl Ezagent.Behavior
  def cap_subjects, do: [{:noop, "test — no-op"}]

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

  @impl Ezagent.Behavior
  def invoke(:noop, slice, _args, _ctx), do: {:ok, slice}

  @impl Ezagent.Behavior
  def interface do
    %{
      noop: %{args: %{}, returns: %{}, modes: [:call]}
    }
  end

  @impl Ezagent.Behavior
  def post_init(_args, _slice), do: {:continue, :setup_thing}

  @impl Ezagent.Behavior
  def handle_continue(:setup_thing, slice, %{self_uri: uri}) do
    if tracker = slice[:tracker] do
      # Observe the ReadyGate status AT THE MOMENT the post-init
      # continuation fires. Since both `:announce_ready` and the
      # post-init `handle_continue` run on the same GenServer
      # process serially, observing `:ready` here is a race-free
      # proof that announce_ready ran first (the boot-order
      # invariant introduced by PR-EM-CORE).
      ready_status = Ezagent.ReadyGate.status(uri)
      Ezagent.TestSupport.OrderTracker.record(tracker, {:post_init, ready_status})
    end

    {:ok, %{slice | setup_done: true, continued_with: :setup_thing}}
  end
end

defmodule Ezagent.TestSupport.PostInitBehaviorA do
  @moduledoc """
  First of two ordered post-init Behaviors used by Test 3 (multi-Behavior
  ordering). Records `:post_init_a` on the shared tracker.
  """

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:noop]

  @impl Ezagent.Behavior
  def cap_subjects, do: [{:noop, "test — no-op"}]

  @impl Ezagent.Behavior
  def state_slice, do: :post_init_a

  @impl Ezagent.Behavior
  def init_slice(args), do: %{tracker: Map.get(args, :tracker), ran: false}

  @impl Ezagent.Behavior
  def invoke(:noop, slice, _args, _ctx), do: {:ok, slice}

  @impl Ezagent.Behavior
  def interface, do: %{noop: %{args: %{}, returns: %{}, modes: [:call]}}

  @impl Ezagent.Behavior
  def post_init(_args, _slice), do: {:continue, :run_a}

  @impl Ezagent.Behavior
  def handle_continue(:run_a, slice, _ctx) do
    if tracker = slice[:tracker], do: Ezagent.TestSupport.OrderTracker.record(tracker, :post_init_a)
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

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:noop]

  @impl Ezagent.Behavior
  def cap_subjects, do: [{:noop, "test — no-op"}]

  @impl Ezagent.Behavior
  def state_slice, do: :post_init_b

  @impl Ezagent.Behavior
  def init_slice(args), do: %{tracker: Map.get(args, :tracker), ran: false}

  @impl Ezagent.Behavior
  def invoke(:noop, slice, _args, _ctx), do: {:ok, slice}

  @impl Ezagent.Behavior
  def interface, do: %{noop: %{args: %{}, returns: %{}, modes: [:call]}}

  @impl Ezagent.Behavior
  def post_init(_args, _slice), do: {:continue, :run_b}

  @impl Ezagent.Behavior
  def handle_continue(:run_b, slice, _ctx) do
    if tracker = slice[:tracker], do: Ezagent.TestSupport.OrderTracker.record(tracker, :post_init_b)
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

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:noop]

  @impl Ezagent.Behavior
  def cap_subjects, do: [{:noop, "test — no-op"}]

  @impl Ezagent.Behavior
  def state_slice, do: :no_post_init

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{baseline: :ok, count: 0}

  @impl Ezagent.Behavior
  def invoke(:noop, slice, _args, _ctx), do: {:ok, slice}

  @impl Ezagent.Behavior
  def interface, do: %{noop: %{args: %{}, returns: %{}, modes: [:call]}}
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

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:noop]

  @impl Ezagent.Behavior
  def cap_subjects, do: [{:noop, "test — no-op"}]

  @impl Ezagent.Behavior
  def state_slice, do: :crash

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{}

  @impl Ezagent.Behavior
  def invoke(:noop, slice, _args, _ctx), do: {:ok, slice}

  @impl Ezagent.Behavior
  def interface, do: %{noop: %{args: %{}, returns: %{}, modes: [:call]}}

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

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:noop]

  @impl Ezagent.Behavior
  def cap_subjects, do: [{:noop, "test — no-op"}]

  @impl Ezagent.Behavior
  def state_slice, do: :persistent

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{post_init_value: nil, init_value: :from_init_slice}

  @impl Ezagent.Behavior
  def invoke(:noop, slice, _args, _ctx), do: {:ok, slice}

  @impl Ezagent.Behavior
  def interface, do: %{noop: %{args: %{}, returns: %{}, modes: [:call]}}

  @impl Ezagent.Behavior
  def post_init(_args, _slice), do: {:continue, :write_sentinel}

  @impl Ezagent.Behavior
  def handle_continue(:write_sentinel, slice, _ctx) do
    {:ok, %{slice | post_init_value: :written_by_post_init}}
  end
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
