defmodule EzagentActor.EtsOwner do
  @moduledoc """
  EtsOwner for the actor framework — owns the lifecycle of the ETS tables
  behind the framework's reliability primitives.

  Split out of `EzagentCore.EtsOwner` in the C5 physical move (spec
  `docs/superpowers/specs/2026-07-23-actor-framework-umbrella-extraction.md`
  §3.2): the tables whose owning MODULES moved to `ezagent_actor` are
  created here; the cap-spine / registry tables stay with
  `EzagentCore.EtsOwner`.

  Same Option-B shape as the core owner (one GenServer holds all tables,
  single restart point). All state in these tables is ephemeral by design
  (ReadyGate / PendingDelivery / Idempotency are "what's in flight right
  now"); persistent state lives in Postgres via `Ezagent.Kind.Snapshot`.

  ## Boot order invariant

  This GenServer must start before any process that touches the tables —
  the `Ezagent.KindRegistry` Registry, `Ezagent.Idempotency.Sweeper`, and
  any Kind instance. It is the first child of `EzagentActor.Application`,
  and OTP starts `ezagent_actor` before `ezagent_core` (core declares the
  dep), so the tables exist before any core boot code runs.
  """

  use GenServer

  @tables [
    {Ezagent.ReadyGate, :set},
    {Ezagent.PendingDelivery, :set},
    {Ezagent.Idempotency, :set},
    {Ezagent.BehaviorRegistry, :set},
    {Ezagent.SpawnRegistry, :set},
    # `:ezagent_slice_change_cursors` — per-URI monotonic cursor for
    # `Ezagent.SliceChange.emit/1`'s broadcast envelope (see the core
    # EtsOwner's historical note; the owning module moved with the
    # framework).
    {Ezagent.SliceChange.Cursors, :set}
    # `{Ezagent.URI.SchemeRegistry, :set}` moves here in the ATOMIC
    # scheme-registry commit (module + table + seed travel together).
  ]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    table_names =
      Enum.map(@tables, fn {mod, type} ->
        name = mod.table()
        :ets.new(name, [type, :public, :named_table, read_concurrency: true])
        name
      end)

    {:ok, %{tables: table_names}}
  end
end
