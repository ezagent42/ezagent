defmodule Ezagent.Behavior.EchoColdLoadTest do
  @moduledoc """
  Phase B (2026-05-29) Lifecycle migration — cold-load round-trip gate
  for `Ezagent.Behavior.Echo` (the simple no-transients case).

  SPEC `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` §6:
  the canonical `assert_transients_rebuilt/2` gate is N/A here because
  Echo has NO transients (no PID / ETS / port / subprocess / monitor).
  The architectural property a no-transients module MUST still pin is the
  OTHER half of the two-container contract:

    `create/1` → PERSISTENT `state` → snapshot → cold-load REHYDRATES it
    (and `create/1` does NOT re-run on the cold-load — the ever-created
    marker gates it).

  This is the parity-relevant invariant: the migration must not silently
  drop the durable `count` / `last_msg` that the old `init_slice` +
  snapshot path carried, NOR re-run `create/1` and clobber the rehydrated
  state back to `%{count: 0, last_msg: nil}`.

  ## Why a test-only `{:snapshot, :on_change}` Kind

  The production `Ezagent.Entity.Echo` Kind declares `persistence:
  :ephemeral` (echo agents are throwaway), so it never writes a snapshot
  — a cold-load on the production Kind would have nothing to rehydrate.
  To exercise the persistent-state half of the Lifecycle contract we host
  the unchanged `Echo` Behavior on a test-only Kind with `{:snapshot,
  :on_change}` (the same technique the reference
  `Ezagent.Behavior.SandboxColdRestartTest` uses for its transients gate).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Behavior.Echo
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.{Kind, KindRegistry}

  @slice_key :echo

  defmodule EchoColdLoadKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl Ezagent.Kind
    def type_name, do: :echo_cold_load

    @impl Ezagent.Kind
    def behaviors, do: [Echo]

    # `{:snapshot, :on_change}` so the durable `state` survives a
    # terminate + cold-load (production Entity.Echo is `:ephemeral`).
    @impl Ezagent.Kind
    def persistence, do: {:snapshot, :on_change}
  end

  setup_all do
    Code.ensure_loaded!(Echo)
    Code.ensure_loaded!(EchoColdLoadKind)

    # Register the Echo actions for this test-only Kind so dispatch can
    # resolve them (production Kinds register at app boot). Idempotent.
    for action <- [:say, :receive] do
      if Ezagent.BehaviorRegistry.lookup(EchoColdLoadKind, action) == :error do
        :ok = Ezagent.CapabilityRegistry.register(EchoColdLoadKind, action, Echo)
      end
    end

    :ok
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  test "create→state round-trips through a cold-load (state rehydrates; create does not re-run)" do
    uri = URI.new!("system://echo_cold_load/inst-#{System.unique_integer([:positive])}")
    uri_str = URI.to_string(uri)

    # 1. Fresh spawn via the production entry (`Kind.spawn/2`). `create/1`
    #    builds the PERSISTENT :echo state; `{:snapshot, :on_change}`
    #    persists at init.
    {:ok, pid1} = Kind.spawn(EchoColdLoadKind, %{uri: uri})
    wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

    # Drive a durable state change (count + last_msg) so the rehydrated
    # state is distinguishable from a freshly re-run `create/1`.
    {:ok, _result} =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: URI.new!("#{uri_str}?action=echo.say"),
        args: %{msg: "remember-me"},
        mode: :call,
        ctx: %{
          caller: Ezagent.Entity.User.admin_uri(),
          caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
          reply: {:caller_inbox, self()}
        }
      })

    wait_until(fn ->
      case Kind.get_raw_slice(uri, @slice_key) do
        {:ok, %{state: %{count: 1, last_msg: "remember-me"}}} -> true
        _ -> false
      end
    end)

    # T3: RAW read — assert on both containers.
    {:ok, %{state: state_before, transients: transients_before}} =
      Kind.get_raw_slice(uri, @slice_key)

    assert state_before == %{count: 1, last_msg: "remember-me"}
    # No transients — the no-transients property of this representative
    # example (so the cold-restart bug class does not apply here).
    assert transients_before == %{}

    # Snapshot row + ever-created marker present (so cold-load SKIPS create).
    assert %KindSnapshot{} = KindSnapshot.get(uri_str)
    assert KindSnapshot.ever_created?(uri_str)

    # 2. Permanent termination via the production teardown. The durable
    #    snapshot survives.
    ref = Process.monitor(pid1)
    :ok = Kind.terminate(uri)
    assert_receive {:DOWN, ^ref, :process, ^pid1, _}, 2_000
    wait_until(fn -> KindRegistry.lookup(uri_str) == :error end)

    assert %KindSnapshot{} = KindSnapshot.get(uri_str)
    assert KindSnapshot.ever_created?(uri_str)

    # 3. Cold-load — re-spawn the same URI. `init_slice` sees
    #    `ever_created?/1` true → SKIPS create/1; the snapshot merge
    #    rehydrates the persistent state.
    {:ok, pid2} = Kind.spawn(EchoColdLoadKind, %{uri: uri})
    refute pid1 == pid2
    wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

    {:ok, %{state: state_after, transients: transients_after}} =
      Kind.get_raw_slice(uri, @slice_key)

    # 4. State rehydrated correctly — the driven count/last_msg survived,
    #    and create/1 did NOT re-run (which would have reset to count: 0).
    assert state_after == state_before
    assert state_after.count == 1
    assert state_after.last_msg == "remember-me"

    # Still no transients on cold-load (activate is the no-op default).
    assert transients_after == %{}

    Kind.terminate(uri)
  end
end
