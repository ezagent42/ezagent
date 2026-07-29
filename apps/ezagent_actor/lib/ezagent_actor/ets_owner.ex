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
    {Ezagent.SliceChange.Cursors, :set},
    # PR #145 (SPEC v2 §5.6 §5.11): runtime ETS allowlist of URI schemes
    # accepted by `Ezagent.URI.new!/1`. Seeded by
    # `EzagentActor.Application.start/2` with the 6 core schemes; plugins
    # extend it ONLY via `Ezagent.SpawnRegistry.register/2` (which
    # co-registers). Moved here in the C5 ATOMIC scheme-registry commit —
    # module, table, and seed travel together (§3.2).
    {Ezagent.URI.SchemeRegistry, :set},
    # #201 PR-1 — per-URI create-vs-activate verdict bridge (see
    # `Ezagent.Kind.CreateFreshness`).
    {Ezagent.Kind.CreateFreshness, :set}
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

  @doc false
  # Test-only recreation of `Ezagent.BehaviorRegistry`'s table, run FROM
  # THIS OWNER'S OWN PROCESS so the recreated table's real ETS ownership
  # stays correctly tied to `EzagentActor.EtsOwner`'s lifecycle.
  #
  # Root-cause note (provider-connection suite-health P0, 2026-07):
  # `EzagentCore.EtsOwner.recreate_capability_tables_for_test/0` used to
  # reach across and `:ets.new` THIS table directly from ITS OWN process —
  # which silently reassigns the table's real ETS owner to
  # `EzagentCore.EtsOwner`. A later genuine `EzagentCore.EtsOwner` crash
  # then destroyed this table too, and since it isn't in core's `@tables`
  # list, it was never recreated — a permanent, deterministic loss that
  # crash-looped `Ezagent.ProviderConnection.RegistryOwner` (ArgumentError
  # on every reconcile attempt) until the whole domain Application died.
  # Callers that need to simulate a full capability-table wipe must call
  # BOTH this function AND `EzagentCore.EtsOwner.recreate_capability_tables_for_test/0`
  # — each recreates only the table(s) it actually owns.
  def recreate_capability_tables_for_test do
    GenServer.call(__MODULE__, :recreate_capability_tables_for_test)
  end

  @impl true
  def handle_call(:recreate_capability_tables_for_test, _from, state) do
    if Mix.env() == :test do
      recreate_table(Ezagent.BehaviorRegistry.table())
      {:reply, :ok, state}
    else
      {:reply, {:error, :test_only}, state}
    end
  end

  defp recreate_table(table) do
    if :ets.whereis(table) != :undefined, do: :ets.delete(table)
    :ets.new(table, [:set, :public, :named_table, read_concurrency: true])
  end
end
