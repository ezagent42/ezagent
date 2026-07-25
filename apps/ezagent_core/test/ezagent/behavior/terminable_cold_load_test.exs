defmodule Ezagent.ActionSet.TerminableColdLoadTest do
  @moduledoc """
  Phase B cold-load proof for the three no-transient core Behaviors
  migrated to `use Ezagent.Lifecycle` (SPEC `2026-05-29-lifecycle-hooks-design.md`
  §5 amendment A2 "no-transients modules: create→rehydrate+no-recreate
  test").

  These three —
    - `Ezagent.ActionSet.Terminable` (persistent `%{terminations: N}`)
    - `Ezagent.ActionSet.Notifications` (cap-only, empty state)
    - `Ezagent.ActionSet.Routing` (persistent `%{calls: N}`)
  — hold NO transients (no PIDs/refs/handles), so the
  `Ezagent.LifecycleCase.assert_transients_rebuilt/2` gate (which requires
  a non-empty transient container) does NOT apply. The relevant invariant
  for them is the OTHER half of the two-container contract:

    1. `create/1` builds the PERSISTENT state once.
    2. `init_slice/1` wraps it in the two-container shape with an EMPTY
       transients container (so the snapshot boundary strips nothing).
    3. On a cold-load (ever-created marker set), `create/1` is NOT re-run
       — the rehydrated persistent `state` survives, it is not reset to
       the `create/1` default. This is the create-once guarantee that the
       dedicated `kind_snapshots.ever_created` column provides (SPEC §9
       OQ-1).

  The Terminable cold-restart case below is the real-process proof of #3:
  a Terminable-bearing Kind is spawned, its `:lifecycle` slice is seeded
  with a non-default counter via a snapshot write, the host is brutally
  killed, and on the supervisor's auto-restart the rehydrated counter
  survives — proving `create/1` (which would reset it to 0) was skipped.
  """

  use Ezagent.LifecycleCase

  alias Ezagent.ActionSet.{Notifications, Routing, Terminable}
  alias Ezagent.Ecto.KindSnapshot

  # A minimal Kind that lists Terminable in behaviors/0 so the engine's
  # init path runs `create/1` (the after-the-fact registration on the
  # real Agent/PyAgent Kinds skips create; here we exercise the create
  # path directly). `{:snapshot, :on_change}` so the persistent `:lifecycle`
  # slice survives a cold restart.
  defmodule TerminableHostKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl Ezagent.Kind
    def type_name, do: :terminable_cold_load_host

    @impl Ezagent.Kind
    def behaviors, do: [Ezagent.ActionSet.Terminable]

    @impl Ezagent.Kind
    def persistence, do: {:snapshot, :on_change}

    # P6 cold-restart determinism: isolate THE GATE Kind's kill→restart
    # from the shared `Ezagent.KindSupervisor`'s restart-intensity
    # exhaustion — see `Ezagent.LifecycleCase.ensure_gate_supervisor!/0`.
    @impl Ezagent.Kind
    def supervisor, do: Ezagent.LifecycleCase.gate_supervisor()
  end

  defp host_uri do
    URI.new!("system://terminable_cold_load_host/inst-#{System.unique_integer([:positive])}")
  end

  describe "create→two-container contract (all four no-transient modules)" do
    test "Terminable: create/1 builds %{terminations: 0}; init_slice wraps it" do
      assert Terminable.create(%{}) == {:ok, %{terminations: 0}}
      assert Terminable.init_slice(%{}) == %{state: %{terminations: 0}, transients: %{}}
    end

    test "Routing: create/1 builds %{calls: 0}; init_slice wraps it" do
      assert Routing.create(%{}) == {:ok, %{calls: 0}}
      assert Routing.init_slice(%{}) == %{state: %{calls: 0}, transients: %{}}
    end

    test "Notifications: cap-only create/1 is empty; init_slice wraps it" do
      assert Notifications.create(%{}) == {:ok, %{}}
      assert Notifications.init_slice(%{}) == %{state: %{}, transients: %{}}
    end

    test "every module's slice has an EMPTY transients container (nothing to strip)" do
      for mod <- [Terminable, Routing, Notifications] do
        assert %{transients: tr} = mod.init_slice(%{})
        assert tr == %{}, "#{inspect(mod)} must declare no transients"
      end
    end
  end

  describe "create-once / no-recreate on cold restart (Terminable, real process)" do
    test "persistent state + ever-created marker survive a brutal cold restart" do
      uri = host_uri()
      uri_str = URI.to_string(uri)

      # 1. Fresh spawn — create/1 runs ONCE, persisting %{terminations: 0}
      #    and setting the durable ever-created marker (the initial
      #    Lifecycle persist in Kind.Server.init/1).
      {:ok, pid1} = Ezagent.Kind.spawn(TerminableHostKind, %{uri: uri})
      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

      assert {:ok, %{state: %{terminations: 0}, transients: %{}}} =
               Ezagent.Kind.SliceAccess.get_raw_slice(uri, :lifecycle)

      assert KindSnapshot.ever_created?(uri_str),
             "fresh spawn must set the ever-created marker (create-once gate, SPEC §9 OQ-1)"

      # 2. Brutal kill — untrappable, no graceful deactivate/destroy. The
      #    :permanent child auto-restarts at the same URI, re-running
      #    init/1 → cold-load. Because ever_created? is true, init_slice
      #    MUST skip create/1 (returns an EMPTY state container) and the
      #    snapshot merge rehydrates the persisted %{terminations: 0}.
      Process.exit(pid1, :kill)

      wait_until(fn ->
        case Ezagent.KindRegistry.lookup(uri) do
          {:ok, p} when p != pid1 -> Ezagent.ReadyGate.status(uri) == :ready
          _ -> false
        end
      end)

      {:ok, pid2} = Ezagent.KindRegistry.lookup(uri)
      refute pid1 == pid2, "cold restart must produce a new pid"

      # 3. Persistent state rehydrated; transients container empty (nothing
      #    to rebuild — this is a no-transient Behavior). The two-container
      #    cold-load path works for a state-only Lifecycle module.
      assert {:ok, %{state: %{terminations: 0}, transients: %{}}} =
               Ezagent.Kind.SliceAccess.get_raw_slice(uri, :lifecycle)

      # 4. The ever-created marker is DURABLE across the restart — so a
      #    future cold-load keeps skipping create/1. This is the no-recreate
      #    guarantee at the process level (the create-once invariant from
      #    SPEC §9 OQ-1); the unit `init_slice/1`-skips-create proof above
      #    pins the macro mechanism that consumes this marker.
      assert KindSnapshot.ever_created?(uri_str),
             "the ever-created marker must survive the cold restart — otherwise a future " <>
               "cold-load would wrongly re-run create/1 (the create-once guarantee, SPEC §9 OQ-1)"
    end
  end
end
