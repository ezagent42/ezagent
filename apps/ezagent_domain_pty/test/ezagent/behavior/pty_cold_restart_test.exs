defmodule Ezagent.ActionSet.PtyColdRestartTest do
  @moduledoc """
  Cold-restart invariant gate for the `Ezagent.ActionSet.Pty` Lifecycle
  migration (Phase B, SPEC `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md`
  §6) — the NO-TRANSIENTS shape (like example A `CurlAgent`).

  Pty holds NO process-bound resource in its slice (the PtyServer port is
  resolved per-write through the resolver seam, never stored), so
  the `assert_transients_rebuilt/2` helper does NOT apply — there is no
  transient to rebuild. The architectural invariant for a no-transients
  Lifecycle module is instead:

    1. `create/1` runs ONCE (first-ever existence), building the durable
       counter `state`.
    2. The counters live in `state` → they MUST survive a brutal cold
       restart (rehydrated from the snapshot), and `create/1` MUST NOT
       re-run (the ever-created marker gates it). A re-run would RESET the
       counters to 0 — the bug this gate forbids.

  Per `feedback_completion_requires_invariant_test`: this FAILS exactly
  when the cold-restart bug class reappears for a no-transients module
  (state lost, or `create/1` re-run on cold-load resetting the counters).
  """

  use Ezagent.LifecycleCase

  alias Ezagent.ActionSet.Pty

  # Pty-only test Kind that LISTS Pty in behaviors/0 (so the two-container
  # slice is created via Pty.create/1) + `{:snapshot, :on_change}` so the
  # durable counter `state` survives a brutal kill. No `supervisor/0` →
  # spawns under the core `Ezagent.KindSupervisor` as a `:permanent` child,
  # so `Process.exit(pid, :kill)` triggers OTP auto-restart at the same URI
  # (the production-faithful cold-load path).
  defmodule PtyCounterKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl Ezagent.Kind
    def type_name, do: :pty_cold_restart

    @impl Ezagent.Kind
    def behaviors, do: [Pty]

    @impl Ezagent.Kind
    def persistence, do: {:snapshot, :on_change}

    # P6 cold-restart determinism: isolate THE GATE Kind's kill→restart
    # from the shared `Ezagent.KindSupervisor`'s restart-intensity
    # exhaustion — see `Ezagent.LifecycleCase.ensure_gate_supervisor!/0`.
    @impl Ezagent.Kind
    def supervisor, do: Ezagent.LifecycleCase.gate_supervisor()
  end

  setup_all do
    Code.ensure_loaded!(Pty)
    Code.ensure_loaded!(PtyCounterKind)

    if Ezagent.BehaviorRegistry.lookup(PtyCounterKind, :write) == :error do
      :ok = Ezagent.CapabilityRegistry.register(PtyCounterKind, :write, Pty)
    end

    :ok
  end

  defp uri do
    URI.new!("system://pty_cold_restart/inst-#{System.unique_integer([:positive])}")
  end

  defp write(target_uri, bytes) do
    target = URI.new!("#{URI.to_string(target_uri)}?action=pty.write")

    %Ezagent.Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{bytes: bytes},
      ctx: %{
        caller: Ezagent.Entity.User.admin_uri(),
        caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
        reply: {:caller_inbox, self()}
      }
    }
    |> Ezagent.Test.CapHelper.signed_invocation!(:pty_cold_restart)
    |> Ezagent.Invocation.dispatch()
  end

  test "no-transients: counters survive cold restart in state; create/1 NOT re-run" do
    self_uri = uri()
    :ok = Ezagent.Ecto.KindSnapshot.delete(URI.to_string(self_uri))

    # A PtyServer must exist so handle_write's inline write_input succeeds
    # and the {:set, :write_calls, ...} effect fires (the only way the
    # durable counter advances).
    {:ok, pty_pid} =
      Ezagent.Domain.Pty.start(self_uri, %{cwd: File.cwd!(), test_mode: true})

    on_exit(fn ->
      if Process.alive?(pty_pid), do: Process.exit(pty_pid, :shutdown)
      Ezagent.Ecto.KindSnapshot.delete(URI.to_string(self_uri))
    end)

    # 1. Spawn fresh — create/1 builds the durable counters at 0.
    {:ok, pid1} = Ezagent.Kind.spawn(PtyCounterKind, %{uri: self_uri})
    wait_until(fn -> Ezagent.ReadyGate.status(self_uri) == :ready end)

    # 2. Drive 3 writes → counters accumulate in the durable :state.
    for b <- ["a", "bb", "ccc"], do: assert({:ok, _} = write(self_uri, b))

    wait_until(fn ->
      case Ezagent.Kind.SliceAccess.get_raw_slice(self_uri, :pty) do
        {:ok, %{state: %{write_calls: 3, total_bytes: 6}}} -> true
        _ -> false
      end
    end)

    {:ok, %{state: state_before}} = Ezagent.Kind.SliceAccess.get_raw_slice(self_uri, :pty)
    assert state_before == %{write_calls: 3, total_bytes: 6}

    # 3. Brutal kill — skips graceful deactivate/terminate. The :permanent
    #    child is OTP-auto-restarted at the same URI → cold-load
    #    (ever_created? true → create SKIPPED, state rehydrated).
    Process.exit(pid1, :kill)

    wait_until(fn ->
      case Ezagent.KindRegistry.lookup(self_uri) do
        {:ok, p} when p != pid1 -> Ezagent.ReadyGate.status(self_uri) == :ready
        _ -> false
      end
    end)

    {:ok, pid2} = Ezagent.KindRegistry.lookup(self_uri)
    refute pid1 == pid2, "cold restart must produce a new pid"

    # 4. THE GATE — counters rehydrated, NOT reset. If create/1 re-ran on
    #    cold-load the counters would be %{write_calls: 0, total_bytes: 0}.
    {:ok, %{state: state_after, transients: transients_after}} =
      Ezagent.Kind.SliceAccess.get_raw_slice(self_uri, :pty)

    assert state_after == %{write_calls: 3, total_bytes: 6},
           "durable counters did NOT rehydrate (or create/1 re-ran and reset them) " <>
             "— THIS IS the no-transients cold-restart bug class"

    # No transients ever — the PtyServer handle is resolved per-write, not
    # held in the slice.
    assert transients_after == %{},
           "Pty must hold NO transient (the PtyServer is resolved per-write)"

    # 5. A further write after the restart keeps accumulating (proves the
    #    rehydrated state is live + writable, not a frozen snapshot).
    assert {:ok, _} = write(self_uri, "dddd")

    wait_until(fn ->
      case Ezagent.Kind.SliceAccess.get_raw_slice(self_uri, :pty) do
        {:ok, %{state: %{write_calls: 4, total_bytes: 10}}} -> true
        _ -> false
      end
    end)
  end
end
